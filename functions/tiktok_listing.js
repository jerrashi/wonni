/**
 * tiktok_listing.js — TikTok Shop products (API 202309) through tiktok_client.
 *
 * Field model on products/{id}, mirroring eBay:
 *   crossPostStatus.tiktok = "active"  ⟺ live (in review counts as live: TikTok
 *                                       reviews every new product).
 *   crossPostListingIds.tiktok / tiktokProductId = TikTok product id.
 *   tiktokSkuId (no variants) / variants[i].tiktokSkuId = TikTok SKU ids, used by
 *   the sale cascade's inventory push and order matching.
 *   tiktokWarehouseId = the warehouse the stock was posted to.
 * Seller SKU = productId (no variants) or ebay_listing.variantSkuFor(...) — the
 * same SKU eBay uses, so order matching shares one rule.
 *
 * Category + required attributes: tiktok_category.js (the user's pick, else the
 * remembered `tiktokCategoryId`, else TikTok's recommendation from the title).
 * `tiktokSuggestCategory` previews that for the picker. Not built yet: editing
 * title / photos after posting.
 */

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { tiktokClientFor, TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");
const { listingImagesFor, toTiktokProductPayload, resolveListingPrice, variantPriceOr, sharedPoolQuantity } = require("./platform_adapters");
const { isSharedPool } = require("./quantity_model");
const { fetchBytes } = require("./source_links");
const { resolveTiktokCategory, categoryProblem } = require("./tiktok_category");

const TT_SECRETS = [TT_APP_KEY, TT_APP_SECRET];
// Same 6 oz default eBay uses (ebayPackageWeightAndSize); dims are a small padded
// mailer when the product has none.
const DEFAULT_WEIGHT_LB = 0.375;
const DEFAULT_DIMS_IN = { length: 8, width: 6, height: 2 };

// ── pure builders ──────────────────────────────────────────────────────────

/** Flat 202309 category list → [{id, name: "A > B > C"}] for leaves only. */
function buildCategoryList(categories = []) {
  const byId = new Map(categories.map((c) => [String(c.id), c]));
  const crumb = (c) => {
    const names = [];
    for (let cur = c, guard = 0; cur && guard < 10; cur = byId.get(String(cur.parent_id)), guard++) {
      names.unshift(cur.local_name ?? cur.name ?? "");
    }
    return names.filter(Boolean).join(" > ");
  };
  return categories.filter((c) => c.is_leaf).map((c) => ({ id: String(c.id), name: crumb(c) }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** The shop's default enabled sales warehouse (falls back to any enabled one). */
function pickWarehouse(warehouses = []) {
  const usable = warehouses.filter((w) => w.type === "SALES_WAREHOUSE" && w.effect_status !== "DISABLED");
  const w = usable.find((x) => x.is_default) ?? usable[0];
  if (!w?.id) {
    throw new HttpsError("failed-precondition", "Your TikTok shop has no sales warehouse. Add a shipping warehouse in TikTok Seller Center, then post again.");
  }
  return String(w.id);
}

function tiktokPackage(product) {
  const lbs = Number(product.weightLbs);
  const oz = Number(product.weightOz);
  let total = (Number.isFinite(lbs) ? lbs : 0) + (Number.isFinite(oz) ? oz : 0) / 16;
  if (!(total > 0)) total = DEFAULT_WEIGHT_LB;
  const [l, w, h] = [product.lengthIn, product.widthIn, product.heightIn].map(Number);
  const dims = [l, w, h].every((n) => Number.isFinite(n) && n > 0) ? { length: l, width: w, height: h } : DEFAULT_DIMS_IN;
  const s = (n) => String(Math.round(n * 100) / 100);
  return {
    package_weight: { value: s(total), unit: "POUND" },
    package_dimensions: { length: s(dims.length), width: s(dims.width), height: s(dims.height), unit: "INCH" },
  };
}

function activeVariants(product) {
  const vs = Array.isArray(product.variants) ? product.variants : [];
  return vs.map((v, index) => ({ v, index })).filter(({ v }) => v && v.active !== false);
}

function hasVariantSkus(product) {
  return activeVariants(product).length > 0 && (product.hasVariants === true || Array.isArray(product.options));
}

/** Stock TikTok should show for one SKU (variant = null for a plain product). */
function skuQuantity(product, variant) {
  const shared = sharedPoolQuantity(product);
  if (shared !== null) return shared;
  const q = Number(variant ? variant.quantity : product.quantity);
  if (variant) return Number.isFinite(q) && q >= 0 ? Math.floor(q) : 0;
  return Number.isFinite(q) && q >= 0 ? Math.floor(q) : 1;
}

function variantSkuFor(productId, variant, index) {
  // Lazy: ebay_listing.js is heavy and pulls in the eBay secrets.
  return require("./ebay_listing").variantSkuFor(productId, variant, index);
}

/** One SKU per active variant (or one for a plain product). */
function buildTiktokSkus(product, productId, { warehouseId }) {
  const base = resolveListingPrice(product);
  const money = (n) => ({ amount: Number(n).toFixed(2), currency: "USD" });
  if (!hasVariantSkus(product)) {
    return [{
      seller_sku: productId,
      sales_attributes: [],
      price: money(base),
      inventory: [{ warehouse_id: warehouseId, quantity: skuQuantity(product, null) }],
    }];
  }
  const optionNames = (Array.isArray(product.options) ? product.options : []).map((o) => o?.name).filter(Boolean);
  return activeVariants(product).map(({ v, index }) => {
    const values = v.optionValues ?? {};
    const names = optionNames.length ? optionNames : Object.keys(values);
    return {
      seller_sku: variantSkuFor(productId, v, index),
      sales_attributes: names.filter((n) => values[n] != null && values[n] !== "")
        .map((n) => ({ name: n, value_name: String(values[n]) })),
      price: money(variantPriceOr(v, base)),
      inventory: [{ warehouse_id: warehouseId, quantity: skuQuantity(product, v) }],
    };
  });
}

function buildTiktokCreatePayload(product, productId, { categoryId, titleOverride, imageUris, warehouseId, productAttributes = [] }) {
  const { images: _unused, price: _p, attributes: manual, ...base } = toTiktokProductPayload(product, { titleOverride, categoryId });
  // Hand-set `product.tiktokAttributes` win over the filled ones, per attribute id.
  const byId = new Map(productAttributes.map((a) => [String(a.id), a]));
  for (const a of manual || []) if (a?.id != null) byId.set(String(a.id), a);
  const attributes = [...byId.values()];
  return {
    ...base,
    ...(attributes.length ? { product_attributes: attributes } : {}),
    main_images: imageUris.map((uri) => ({ uri })),
    skus: buildTiktokSkus(product, productId, { warehouseId }),
    ...tiktokPackage(product),
  };
}

/**
 * Create response → the doc patch. Variants are written back as a WHOLE array
 * (never `variants.0.x` — that clobbers the array into a map).
 */
function createResultPatch(product, productId, data, warehouseId, categoryId = null) {
  const tiktokProductId = String(data.product_id);
  const bySeller = new Map((data.skus ?? []).map((s) => [s.seller_sku, String(s.id)]));
  const patch = {
    tiktokProductId,
    tiktokWarehouseId: warehouseId,
    ...(categoryId ? { tiktokCategoryId: String(categoryId) } : {}),
    "crossPostStatus.tiktok": "active",
    "crossPostListingIds.tiktok": tiktokProductId,
  };
  if (hasVariantSkus(product)) {
    patch.variants = product.variants.map((v, i) => {
      const id = v && v.active !== false ? bySeller.get(variantSkuFor(productId, v, i)) : null;
      return id ? { ...v, tiktokSkuId: id } : v;
    });
  } else {
    const id = bySeller.get(productId) ?? (data.skus?.[0]?.id != null ? String(data.skus[0].id) : null);
    if (id) patch.tiktokSkuId = id;
  }
  return patch;
}

/**
 * Body for POST /product/202309/products/{id}/inventory/update after a sale.
 * Shared pool → every SKU gets the new number; per-variant → the sold variant's
 * SKU only; plain product → its one SKU. null when there is nothing to push.
 */
function inventoryUpdateBody(product, { variantSku, newQuantity }) {
  const warehouseId = product.tiktokWarehouseId;
  if (!warehouseId) return null;
  const qty = Math.max(0, Math.floor(Number(newQuantity) || 0));
  const sku = (id) => ({ id, inventory: [{ warehouse_id: warehouseId, quantity: qty }] });
  if (!hasVariantSkus(product)) return product.tiktokSkuId ? { skus: [sku(product.tiktokSkuId)] } : null;
  const live = activeVariants(product).map(({ v }) => v).filter((v) => v.tiktokSkuId);
  const targets = isSharedPool(product) ? live : live.filter((v) => v.sku === variantSku);
  return targets.length ? { skus: targets.map((v) => sku(v.tiktokSkuId)) } : null;
}

// ── I/O ────────────────────────────────────────────────────────────────────

/**
 * Download a listing image and upload it to TikTok (multipart, unsigned body).
 * Image URLs come from the client-written product doc, so the download goes
 * through source_links.fetchBytes: public https hosts only (no loopback /
 * private / metadata addresses), redirects re-checked per hop, size-capped.
 */
async function uploadImage(client, imageUrl, fetchBytesImpl = fetchBytes) {
  const { buffer, contentType } = await fetchBytesImpl(imageUrl);
  if (!/^image\//.test(contentType || "")) throw new Error(`not an image (${contentType || "no type"})`);
  const form = new FormData();
  form.append("data", new Blob([buffer], { type: contentType }), "image");
  form.append("use_case", "MAIN_IMAGE");
  const data = await client.request("POST", "/product/202309/images/upload", { body: form, multipart: true, what: "Uploading a photo to TikTok" });
  return data.uri ?? null;
}

async function shopWarehouse(db, uid, client) {
  const ref = db.doc(`users/${uid}/integrations/tiktok`);
  const stored = (await ref.get()).data()?.warehouseId;
  if (stored) return stored;
  const data = await client.request("GET", "/logistics/202309/warehouses", { what: "Loading your TikTok warehouse" });
  const id = pickWarehouse(data.warehouses);
  await ref.set({ warehouseId: id }, { merge: true });
  return id;
}

async function createTiktokListingCore(db, uid, client, { productId, titleOverride, categoryId }, { fetchBytesImpl = fetchBytes } = {}) {
  const docRef = db.collection("products").doc(productId);
  const snap = await docRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
  if (product.crossPostStatus?.tiktok === "active" && product.tiktokProductId) {
    return { tiktokProductId: product.tiktokProductId, alreadyListed: true };
  }
  resolveListingPrice(product); // fail before any upload when there is no price
  const category = await resolveTiktokCategory(client, product, { categoryId });
  const problem = categoryProblem(category);
  if (problem) throw new HttpsError("failed-precondition", problem);

  const imageUris = [];
  for (const url of listingImagesFor(product, 9)) {
    try {
      const uri = await uploadImage(client, url, fetchBytesImpl);
      if (uri) imageUris.push(uri);
    } catch (e) {
      console.warn(`[tiktokCreateListing] photo skipped for ${productId}: ${e.message}`);
    }
  }
  if (!imageUris.length) throw new HttpsError("failed-precondition", "No photos could be uploaded to TikTok.");

  const warehouseId = await shopWarehouse(db, uid, client);
  const payload = buildTiktokCreatePayload(product, productId, {
    categoryId: category.categoryId, titleOverride, imageUris, warehouseId, productAttributes: category.attributes,
  });
  const data = await client.request("POST", "/product/202309/products", { body: payload, what: "Posting to TikTok" });
  const patch = createResultPatch(product, productId, data, warehouseId, category.categoryId);
  await docRef.update({ ...patch, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
  return { tiktokProductId: patch.tiktokProductId, categoryId: category.categoryId };
}

/** Sale cascade hook (sales.js). Returns "updated" | "skipped". */
async function pushTiktokQuantity(uid, product, { variantSku, newQuantity }, { client } = {}) {
  if (!product.tiktokProductId) return "skipped";
  const body = inventoryUpdateBody(product, { variantSku, newQuantity });
  if (!body) return "skipped";
  const c = client ?? tiktokClientFor(uid);
  await c.request("POST", `/product/202309/products/${product.tiktokProductId}/inventory/update`, {
    body, what: "Updating TikTok stock",
  });
  return "updated";
}

async function deleteTiktokListingCore(db, uid, client, productId) {
  const ref = db.collection("products").doc(productId);
  const snap = await ref.get();
  if (!snap.exists || snap.data().userId !== uid) throw new HttpsError("not-found", "Product not found.");
  const product = snap.data();
  if (product.tiktokProductId) {
    await client.request("DELETE", "/product/202309/products", {
      body: { product_ids: [product.tiktokProductId] }, what: "Removing the TikTok listing",
    });
  }
  const del = admin.firestore.FieldValue.delete();
  const patch = {
    "crossPostStatus.tiktok": del,
    "crossPostListingIds.tiktok": del,
    tiktokProductId: del,
    tiktokSkuId: del,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (Array.isArray(product.variants) && product.variants.some((v) => v?.tiktokSkuId)) {
    patch.variants = product.variants.map((v) => {
      if (!v?.tiktokSkuId) return v;
      const { tiktokSkuId: _gone, ...rest } = v;
      return rest;
    });
  }
  await ref.update(patch);
  return { success: true };
}

// ── callables ──────────────────────────────────────────────────────────────

function requireUid(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return uid;
}

exports.getTiktokCategories = onCall({ secrets: TT_SECRETS }, async (request) => {
  const uid = requireUid(request);
  const data = await tiktokClientFor(uid).request("GET", "/product/202309/categories", { what: "Loading TikTok categories" });
  return { categories: buildCategoryList(data.categories) };
});

exports.tiktokCreateListing = onCall(
  { secrets: TT_SECRETS, timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = requireUid(request);
    const { productId, title: titleOverride, categoryId } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    // categoryId is optional: without it the remembered or recommended category is used.
    return createTiktokListingCore(admin.firestore(), uid, tiktokClientFor(uid), { productId, titleOverride, categoryId });
  }
);

/** What a post would use: category (picked / remembered / recommended) and
 *  whether every required field can be filled. For the web/iOS category picker. */
async function suggestTiktokCategoryCore(db, uid, client, { productId, categoryId }) {
  const snap = await db.collection("products").doc(productId).get();
  if (!snap.exists || snap.data().userId !== uid) throw new HttpsError("not-found", "Product not found.");
  const c = await resolveTiktokCategory(client, snap.data(), { categoryId });
  return {
    categoryId: c.categoryId, path: c.path, recommended: c.recommended,
    filledAttributes: c.attributes.length, missing: c.missing, unmet: c.unmet, problem: categoryProblem(c),
  };
}

exports.tiktokSuggestCategory = onCall({ secrets: TT_SECRETS }, async (request) => {
  const uid = requireUid(request);
  const { productId, categoryId } = request.data ?? {};
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
  return suggestTiktokCategoryCore(admin.firestore(), uid, tiktokClientFor(uid), { productId, categoryId });
});

// Partial edit passthrough (no client calls it yet; plan § 4 "Edit").
exports.tiktokUpdateListing = onCall({ secrets: TT_SECRETS }, async (request) => {
  const uid = requireUid(request);
  const { productId, updates } = request.data ?? {};
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
  const snap = await admin.firestore().collection("products").doc(productId).get();
  if (!snap.exists || snap.data().userId !== uid) throw new HttpsError("not-found", "Product not found.");
  const { tiktokProductId } = snap.data();
  if (!tiktokProductId) throw new HttpsError("failed-precondition", "Not listed on TikTok yet.");
  await tiktokClientFor(uid).request("POST", `/product/202309/products/${tiktokProductId}/partial_edit`, {
    body: updates ?? {}, what: "Updating the TikTok listing",
  });
  return { success: true };
});

exports.tiktokDeleteListing = onCall({ secrets: TT_SECRETS }, async (request) => {
  const uid = requireUid(request);
  const { productId } = request.data ?? {};
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
  return deleteTiktokListingCore(admin.firestore(), uid, tiktokClientFor(uid), productId);
});

exports.pushTiktokQuantity = pushTiktokQuantity;
exports._internal = {
  buildCategoryList, pickWarehouse, tiktokPackage, skuQuantity, buildTiktokSkus,
  buildTiktokCreatePayload, createResultPatch, inventoryUpdateBody, uploadImage,
  createTiktokListingCore, deleteTiktokListingCore, pushTiktokQuantity, suggestTiktokCategoryCore,
};
