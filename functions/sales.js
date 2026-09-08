/**
 * sales.js — the sale-recording + quantity-cascade domain.
 *
 * Consolidated from the nested tree's `sale_sync.js` / `mercari_sale.js`,
 * rebased onto the canonical **web** model:
 *   - listing record   : `products/{productId}` (top-level collection)
 *   - stock            : `product.quantity` (no-variant) OR
 *                        `product.variants[i].quantity` (variant products)
 *   - cross-post state  : `product.crossPostStatus.<platform> === "active"`
 *   - eBay offer ptrs   : `product.ebayOfferId` (single) /
 *                         `product.ebayInventoryItemGroupKey` +
 *                         `product.variants[i].ebayOfferId` (multi)
 *   - sale record       : `sales/{saleId}`, shape = contracts/sales.js SaleDoc
 *
 * `recordSale` is the ONE write path (replaces web LogSaleModal's bare addDoc
 * and iOS SaleRepository.addSale). It writes the sale and fires the cascade in
 * the same invocation, so there's no client round-trip and no double-decrement.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { validated } = require("./contracts");
const { ebayRequest, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET } = require("./ebay_auth");
const { getValidEtsyToken, getEtsyClientId } = require("./etsy_auth");
const { variantSkuFor } = require("./ebay_listing");

const EBAY_SECRETS = [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET];

// ── quantity model ─────────────────────────────────────────────────────────

/** Resolve the stock bucket a sale hits. Returns { scope, qty, variantIndex }. */
function resolveStock(product, variantSku) {
  const variants = Array.isArray(product.variants) ? product.variants : [];
  const isVariantProduct = product.hasVariants === true || variants.length > 0;

  if (isVariantProduct) {
    if (!variantSku) return { scope: "variant", qty: null, variantIndex: -1 };
    const variantIndex = variants.findIndex((v) => v && v.sku === variantSku);
    if (variantIndex === -1) return { scope: "variant", qty: null, variantIndex: -1 };
    const q = Number(variants[variantIndex].quantity);
    return { scope: "variant", qty: Number.isFinite(q) ? q : 0, variantIndex };
  }

  const q = Number(product.quantity);
  return { scope: "product", qty: Number.isFinite(q) ? q : 1, variantIndex: -1 };
}

/**
 * Apply a signed delta to the right stock bucket, read-modify-write the whole
 * `variants` array (NEVER a dotted `variants.0.x` path — that clobbers the
 * array into a map). Runs in a transaction. Returns
 * { previousQuantity, newQuantity, soldOut, variantSku }.
 */
async function applyQuantityDelta(db, productId, uid, variantSku, delta, { force, zeroAll } = {}) {
  const ref = db.collection("products").doc(productId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const variants = Array.isArray(product.variants) ? product.variants : [];
    const isVariantProduct = product.hasVariants === true || variants.length > 0;
    const update = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };

    // zeroAll: force every active variant (or the product) to 0. Used by
    // markSoldOutAndCascade, which is unambiguous even without a variant sku.
    if (zeroAll) {
      if (isVariantProduct) {
        update.variants = variants.map((v) => (v.active !== false ? { ...v, quantity: 0 } : v));
      } else {
        update.quantity = 0;
      }
      update.saleStatus = "sold";
      tx.update(ref, update);
      return { previousQuantity: null, newQuantity: 0, soldOut: true, variantSku, product: { ...product, ...update } };
    }

    const { scope, qty, variantIndex } = resolveStock(product, variantSku);
    if (qty === null) {
      // Variant product but no / unknown variant sku — caller must disambiguate.
      return { previousQuantity: null, newQuantity: null, soldOut: false, variantSku, product, skipped: "no-variant-match" };
    }

    const previousQuantity = qty;
    const newQuantity = force != null ? Math.max(0, force) : Math.max(0, qty + delta);
    const soldOut = newQuantity <= 0;

    if (scope === "variant") {
      const nextVariants = variants.map((v, i) =>
        i === variantIndex ? { ...v, quantity: newQuantity } : v
      );
      update.variants = nextVariants;
      // Product goes sold-out only when every active variant is at 0.
      const anyLeft = nextVariants.some((v) => v.active !== false && Number(v.quantity) > 0);
      if (!anyLeft) update.saleStatus = "sold";
      else if (product.saleStatus === "sold") update.saleStatus = "active";
    } else {
      update.quantity = newQuantity;
      update.saleStatus = soldOut ? "sold" : "active";
    }

    tx.update(ref, update);
    return { previousQuantity, newQuantity, soldOut, variantSku, product: { ...product, ...update } };
  });
}

// ── per-platform quantity push ─────────────────────────────────────────────

async function pushEbayQuantity(uid, product, productId, variantSku, newQty) {
  // Resolve the eBay SKU + offer pointer for the bucket that sold.
  // Single-variant: SKU = productId, offer ptr = product.ebayOfferId.
  // Multi-variant:  SKU + offer ptr live on the matching variant.
  let ebaySku = productId;
  let offerId = product.ebayOfferId || null;

  if (variantSku && Array.isArray(product.variants)) {
    const idx = product.variants.findIndex((x) => x && x.sku === variantSku);
    if (idx !== -1) {
      const v = product.variants[idx];
      ebaySku = v.ebayVariantSku || variantSkuFor(productId, v, idx);
      offerId = v.ebayOfferId || offerId;
    }
  }

  if (offerId) {
    await ebayRequest(uid, "POST", "/sell/inventory/v1/bulk_update_price_quantity", {
      requests: [{ sku: ebaySku, offers: [{ offerId, availableQuantity: Math.max(0, newQty) }] }],
    });
    return "updated";
  }

  // No stored offer pointer — fall back to the inventory-item availability PUT.
  const item = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(ebaySku)}`).catch(() => null);
  if (!item) return "skipped";
  item.availability = { ...(item.availability || {}), shipToLocationAvailability: { quantity: Math.max(0, newQty) } };
  await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(ebaySku)}`, item);
  return "updated";
}

async function pushEtsyQuantity(uid, product, newQty) {
  const etsyListingId = product.etsyListingId || product.crossPostListingIds?.etsy;
  if (!etsyListingId) return "skipped";
  const [token, clientId] = await Promise.all([
    getValidEtsyToken(uid).catch(() => null),
    getEtsyClientId().catch(() => null),
  ]);
  if (!token || !clientId) return "skipped";
  const res = await fetch(`https://openapi.etsy.com/v3/application/listings/${etsyListingId}`, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "x-api-key": clientId,
    },
    body: JSON.stringify(newQty <= 0 ? { state: "inactive" } : { quantity: Math.max(1, newQty) }),
  });
  return res.ok ? "updated" : "failed";
}

/**
 * Propagate a post-sale quantity to every OTHER connected platform, plus set
 * the Mercari manual-action flags. Best-effort: a platform failure is recorded,
 * never thrown — the sale is already persisted.
 */
async function cascade(db, uid, product, productId, { variantSku, newQuantity, soldOut, soldOnPlatform }) {
  const platforms = {};
  const productUpdate = {};

  // API platforms (eBay/Etsy/TikTok): push the new quantity — UNLESS the sale
  // came from that platform, which already decremented itself.
  for (const p of ["ebay", "etsy", "tiktok"]) {
    if (p === soldOnPlatform) { platforms[p] = "skipped"; continue; }
    if (product.crossPostStatus?.[p] !== "active") { platforms[p] = "skipped"; continue; }
    try {
      if (p === "ebay") {
        platforms.ebay = await pushEbayQuantity(uid, product, productId, variantSku, newQuantity ?? 0);
      } else if (p === "etsy") {
        platforms.etsy = await pushEtsyQuantity(uid, product, newQuantity ?? 0);
      } else {
        // TODO: tiktokUpdateListing quantity once its consolidation lands.
        platforms.tiktok = "pending-manual";
      }
    } catch (e) {
      console.error(`[cascade] ${p} failed for ${productId}:`, e.message);
      platforms[p] = "failed";
    }
  }

  // Mercari has no API — always resolved by a client-side headless flow, so
  // it's handled even when the sale itself came from Mercari (a multi-qty
  // Mercari listing auto-ends on each sale and must be re-listed).
  if (product.crossPostStatus?.mercari === "active") {
    if (soldOut) productUpdate.pendingMercariDeactivation = true;
    else if (soldOnPlatform === "mercari") productUpdate.pendingMercariRelist = true;
    platforms.mercari = Object.keys(productUpdate).length ? "pending-manual" : "skipped";
  } else {
    platforms.mercari = "skipped";
  }

  if (Object.keys(productUpdate).length) {
    productUpdate.updatedAt = admin.firestore.FieldValue.serverTimestamp();
    await db.collection("products").doc(productId).set(productUpdate, { merge: true });
  }

  return {
    productId,
    previousQuantity: null,
    newQuantity: newQuantity ?? null,
    soldOut,
    platforms,
  };
}

// ── recordSale ─────────────────────────────────────────────────────────────

function toTimestamp(input) {
  if (input == null) return admin.firestore.Timestamp.now();
  if (typeof input === "number") return admin.firestore.Timestamp.fromMillis(input);
  return admin.firestore.Timestamp.fromDate(new Date(input));
}

/**
 * Core sale-write + cascade. Shared by `recordSale` (one sale) and
 * `recordMercariSalesBatch` (many). `fields` uses the canonical SaleDoc names.
 * `product` is the already-fetched + ownership-checked product doc (or null).
 * Returns { saleId, created, cascade }.
 */
async function recordSaleCore(db, uid, fields, product) {
  const {
    platform, productId = null, variantSku = null, soldPrice,
    shippingRevenue = null, shippingLabelCost = null, takeHome = null,
    quantity = 1, soldAt = null, platformOrderId = null, platformItemId = null,
    buyerName = null, buyerAddress = null, trackingNumber = null, carrier = null,
    listingTitle = null, thumbnailUrl = null, notes = null, externalUrl = null,
    cascade: doCascade = true, source = null,
  } = fields;

  const variant = product && variantSku && Array.isArray(product.variants)
    ? product.variants.find((v) => v && v.sku === variantSku)
    : null;

  // Dedupe key: platform + order id when present (auto-imported sales).
  const saleId = platformOrderId
    ? `${platform}_${platformOrderId}`
    : db.collection("sales").doc().id;
  const saleRef = db.collection("sales").doc(saleId);
  const existing = await saleRef.get();

  const now = admin.firestore.FieldValue.serverTimestamp();
  const saleDoc = {
    userId: uid,
    productId,
    variantSku,
    variantOptionValues: variant?.optionValues ?? null,
    listingTitle: product?.title ?? listingTitle ?? null,
    thumbnailUrl: thumbnailUrl ?? ((Array.isArray(product?.images) && product.images[0]) || null),
    coverPhotoPath: null,
    productTags: Array.isArray(product?.tags) ? product.tags : null,
    platform,
    platformOrderId,
    platformItemId,
    priceSoldFor: soldPrice,
    shippingRevenue,
    shippingLabelCost,
    takeHome,
    quantity,
    buyerName,
    buyerAddress,
    trackingNumber,
    carrier,
    soldAt: toTimestamp(soldAt),
    updatedAt: now,
    notes,
    externalUrl,
  };
  if (!existing.exists) {
    // Lifecycle fields — set once; a re-record must not stomp a status that has
    // since advanced to shipped/complete.
    saleDoc.status = "pending";
    saleDoc.createdAt = now;
    saleDoc.source = source ?? (platform === "manual" ? "manual" : "cross-post-drift");
  }

  await saleRef.set(saleDoc, { merge: true });

  let cascadeResult = null;
  if (doCascade && productId && product && !existing.exists) {
    const applied = await applyQuantityDelta(db, productId, uid, variantSku, -(quantity || 1));
    if (applied.skipped) {
      cascadeResult = { productId, previousQuantity: null, newQuantity: null, soldOut: false, platforms: {} };
    } else {
      cascadeResult = await cascade(db, uid, applied.product, productId, {
        variantSku, newQuantity: applied.newQuantity, soldOut: applied.soldOut, soldOnPlatform: platform,
      });
      cascadeResult.previousQuantity = applied.previousQuantity;
    }
  }

  return { saleId, created: !existing.exists, cascade: cascadeResult };
}

/** Fetch + ownership-check a product; throws permission-denied on mismatch. */
async function loadOwnedProduct(db, uid, productId) {
  if (!productId) return null;
  const snap = await db.collection("products").doc(productId).get();
  if (!snap.exists) return null;
  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
  return product;
}

exports.recordSale = onCall({ secrets: EBAY_SECRETS, timeoutSeconds: 60 }, validated("recordSale", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const db = admin.firestore();
  const product = await loadOwnedProduct(db, uid, data.productId);

  return recordSaleCore(db, uid, {
    platform: data.platform,
    productId: data.productId ?? null,
    variantSku: data.variantSku ?? null,
    soldPrice: data.soldPrice,
    shippingRevenue: data.shippingRevenue,
    shippingLabelCost: data.shippingLabelCost,
    takeHome: data.takeHome,
    quantity: data.quantity ?? 1,
    soldAt: data.soldAt ?? null,
    platformOrderId: data.platformOrderId ?? null,
    platformItemId: data.platformItemId ?? null,
    buyerName: data.buyerName,
    buyerAddress: data.buyerAddress,
    trackingNumber: data.trackingNumber,
    carrier: data.carrier,
    listingTitle: data.listingTitle ?? null,
    notes: data.notes ?? null,
    externalUrl: data.externalUrl ?? null,
    cascade: data.cascade,
  }, product);
}));

// ── decrementAndCascade / restockAndCascade / markSoldOutAndCascade ────────
// Drift-correction callables for when a listing is found sold/changed on a
// platform without a `recordSale` having run.

const VARIANT_NEEDS_SKU =
  "This product has variants — the sale must name which variant (variantSku).";

exports.decrementAndCascade = onCall({ secrets: EBAY_SECRETS }, validated("decrementAndCascade", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = admin.firestore();
  const applied = await applyQuantityDelta(db, data.productId, uid, data.variantSku ?? null, -1);
  if (applied.skipped) throw new HttpsError("failed-precondition", VARIANT_NEEDS_SKU);
  const cascadeResult = await cascade(db, uid, applied.product, data.productId, {
    variantSku: data.variantSku ?? null,
    newQuantity: applied.newQuantity,
    soldOut: applied.soldOut,
    soldOnPlatform: data.platform,
  });
  cascadeResult.previousQuantity = applied.previousQuantity;
  return { success: true, cascade: cascadeResult };
}));

exports.restockAndCascade = onCall({ secrets: EBAY_SECRETS }, validated("restockAndCascade", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = admin.firestore();
  const applied = await applyQuantityDelta(db, data.productId, uid, data.variantSku ?? null, 0, { force: data.quantity });
  if (applied.skipped) throw new HttpsError("failed-precondition", VARIANT_NEEDS_SKU);
  await cascade(db, uid, applied.product, data.productId, {
    variantSku: data.variantSku ?? null,
    newQuantity: applied.newQuantity,
    soldOut: false,
    soldOnPlatform: null,
  });
  await db.collection("products").doc(data.productId).set({
    pendingMercariDeactivation: admin.firestore.FieldValue.delete(),
    pendingMercariRelist: admin.firestore.FieldValue.delete(),
  }, { merge: true });
  return { success: true };
}));

exports.markSoldOutAndCascade = onCall({ secrets: EBAY_SECRETS }, validated("markSoldOutAndCascade", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = admin.firestore();
  // zeroAll — unambiguous even for a variant product (every active variant → 0).
  const applied = await applyQuantityDelta(db, data.productId, uid, null, 0, { zeroAll: true });
  await cascade(db, uid, applied.product, data.productId, {
    variantSku: null,
    newQuantity: 0,
    soldOut: true,
    soldOnPlatform: null,
  });
  return { success: true };
}));

// Internal — reused by mercari_sales.js recordMercariSalesBatch.
exports._internal = { applyQuantityDelta, cascade, resolveStock, toTimestamp, recordSaleCore, loadOwnedProduct };
exports.EBAY_SECRETS = EBAY_SECRETS;
