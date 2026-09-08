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
const CASCADE_PLATFORMS = ["ebay", "etsy", "mercari", "tiktok"];

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
async function applyQuantityDelta(db, productId, uid, variantSku, delta, { force } = {}) {
  const ref = db.collection("products").doc(productId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const { scope, qty, variantIndex } = resolveStock(product, variantSku);
    if (qty === null) {
      // Variant product but no / unknown variant sku — can't safely decrement.
      return { previousQuantity: null, newQuantity: null, soldOut: false, variantSku, product, skipped: "no-variant-match" };
    }

    const previousQuantity = qty;
    const newQuantity = force != null ? force : Math.max(0, qty + delta);
    const soldOut = newQuantity <= 0;

    const update = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    if (scope === "variant") {
      const variants = product.variants.map((v, i) =>
        i === variantIndex ? { ...v, quantity: newQuantity } : v
      );
      update.variants = variants;
      // Product goes sold-out only when every active variant is at 0.
      const anyLeft = variants.some((v) => v.active !== false && Number(v.quantity) > 0);
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

  for (const p of CASCADE_PLATFORMS) {
    if (p === soldOnPlatform) { platforms[p] = "skipped"; continue; }
    const isActive = product.crossPostStatus?.[p] === "active";
    if (!isActive) { platforms[p] = "skipped"; continue; }

    try {
      if (p === "ebay") {
        platforms.ebay = await pushEbayQuantity(uid, product, productId, variantSku, newQuantity ?? 0);
      } else if (p === "etsy") {
        platforms.etsy = await pushEtsyQuantity(uid, product, newQuantity ?? 0);
      } else if (p === "mercari") {
        // Mercari has no API — leave a flag the client's headless-browser flow picks up.
        if (soldOut) productUpdate.pendingMercariDeactivation = true;
        else if (soldOnPlatform === "mercari") productUpdate.pendingMercariRelist = true;
        platforms.mercari = "pending-manual";
      } else if (p === "tiktok") {
        // TODO: wire tiktokUpdateListing quantity once its consolidation lands.
        platforms.tiktok = "pending-manual";
      }
    } catch (e) {
      console.error(`[cascade] ${p} failed for ${productId}:`, e.message);
      platforms[p] = "failed";
    }
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

exports.recordSale = onCall({ secrets: EBAY_SECRETS, timeoutSeconds: 60 }, validated("recordSale", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const db = admin.firestore();

  // Snapshot product fields for the sale row (survives edit/delete of the product).
  let product = null;
  if (data.productId) {
    const snap = await db.collection("products").doc(data.productId).get();
    if (snap.exists) {
      product = snap.data();
      if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    }
  }
  const variant = product && data.variantSku && Array.isArray(product.variants)
    ? product.variants.find((v) => v && v.sku === data.variantSku)
    : null;

  // Dedupe key: platform + platformOrderId when present (auto-imported sales).
  const saleId = data.platformOrderId
    ? `${data.platform}_${data.platformOrderId}`
    : db.collection("sales").doc().id;
  const saleRef = db.collection("sales").doc(saleId);
  const existing = await saleRef.get();

  const now = admin.firestore.FieldValue.serverTimestamp();
  const saleDoc = {
    userId: uid,
    productId: data.productId ?? null,
    variantSku: data.variantSku ?? null,
    variantOptionValues: variant?.optionValues ?? null,
    listingTitle: product?.title ?? data.listingTitle ?? null,
    thumbnailUrl: (Array.isArray(product?.images) && product.images[0]) || null,
    coverPhotoPath: null,
    productTags: Array.isArray(product?.tags) ? product.tags : null,
    platform: data.platform,
    platformOrderId: data.platformOrderId ?? null,
    platformItemId: data.platformItemId ?? null,
    priceSoldFor: data.soldPrice,
    shippingRevenue: data.shippingRevenue ?? null,
    shippingLabelCost: data.shippingLabelCost ?? null,
    takeHome: data.takeHome ?? null,
    quantity: data.quantity ?? 1,
    buyerName: data.buyerName ?? null,
    buyerAddress: data.buyerAddress ?? null,
    trackingNumber: data.trackingNumber ?? null,
    carrier: data.carrier ?? null,
    status: "pending",
    soldAt: toTimestamp(data.soldAt),
    updatedAt: now,
    notes: data.notes ?? null,
    externalUrl: data.externalUrl ?? null,
    source: data.platform === "manual" ? "manual" : "cross-post-drift",
  };
  if (!existing.exists) saleDoc.createdAt = now;

  await saleRef.set(saleDoc, { merge: true });

  // Cascade — skip when the caller opted out or there's no product to decrement.
  let cascadeResult = null;
  if (data.cascade && data.productId && product && !existing.exists) {
    const applied = await applyQuantityDelta(db, data.productId, uid, data.variantSku ?? null, -(data.quantity ?? 1));
    if (applied.skipped) {
      cascadeResult = { productId: data.productId, previousQuantity: null, newQuantity: null, soldOut: false, platforms: {} };
    } else {
      cascadeResult = await cascade(db, uid, applied.product, data.productId, {
        variantSku: data.variantSku ?? null,
        newQuantity: applied.newQuantity,
        soldOut: applied.soldOut,
        soldOnPlatform: data.platform,
      });
      cascadeResult.previousQuantity = applied.previousQuantity;
    }
  }

  return { saleId, created: !existing.exists, cascade: cascadeResult };
}));

// ── decrementAndCascade / restockAndCascade / markSoldOutAndCascade ────────
// Drift-correction callables for when a listing is found sold/changed on a
// platform without a `recordSale` having run.

exports.decrementAndCascade = onCall({ secrets: EBAY_SECRETS }, validated("decrementAndCascade", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  const db = admin.firestore();
  const applied = await applyQuantityDelta(db, data.productId, uid, null, -1);
  const cascadeResult = await cascade(db, uid, applied.product, data.productId, {
    variantSku: null,
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
  const applied = await applyQuantityDelta(db, data.productId, uid, null, 0, { force: data.quantity });
  await cascade(db, uid, applied.product, data.productId, {
    variantSku: null,
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
  const applied = await applyQuantityDelta(db, data.productId, uid, null, 0, { force: 0 });
  await cascade(db, uid, applied.product, data.productId, {
    variantSku: null,
    newQuantity: 0,
    soldOut: true,
    soldOnPlatform: null,
  });
  return { success: true };
}));

// Internal — reused by mercari.js recordMercariSalesBatch.
exports._internal = { applyQuantityDelta, cascade, resolveStock, toTimestamp };
