/**
 * etsy_listing.js — Etsy listing CRUD + shop-setup helpers.
 *
 * Consolidated from the nested tree's `etsy_listing.js` (1043 L — the only real
 * Etsy implementation), rebased onto:
 *   - the canonical top-level `products/{id}` collection (was `listings/{id}` +
 *     a parallel `products/{id}` write)
 *   - the single shared Etsy keyset via `getActiveEtsyToken(uid)` (was a
 *     per-request `credentialSet: "ios" | "web"` — now accepted & ignored)
 *   - `platform_adapters.resolveListingPrice` / `listingImagesFor`
 *   - the `validated()` contract wrapper (contracts/etsy.js)
 *
 * Cross-post state on the product doc:
 *   crossPostStatus.etsy = "active"   ⟺ live listing
 *   crossPostListingIds.etsy = "<id>" ⟺ live listing
 *   etsyListingId = mirror of the above
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const https = require("https");

const { validated } = require("./contracts");
const { getActiveEtsyToken } = require("./etsy_auth");
const { resolveListingPrice, variantPriceOr, listingImagesFor } = require("./platform_adapters");
const { _internal: salesInternal } = require("./sales");

const { loadOwnedProduct } = salesInternal;

const ETSY_FALLBACK_TAXONOMY_ID = 69150398; // "Accessories"
const ETSY_MIN_PRICE = 0.2;

let taxonomyCache = null;

// ── Etsy REST ──────────────────────────────────────────────────────────────

async function etsyReq(method, path, { accessToken, clientId, body } = {}) {
  const headers = { "x-api-key": clientId };
  if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch(`https://openapi.etsy.com${path}`, {
    method,
    headers,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text }; }
  return { status: res.status, data };
}

function priceAmount(raw) {
  return Math.max(ETSY_MIN_PRICE, Math.round(Number(raw) * 100) / 100);
}

/** Sum of variant quantities, or the product-level quantity, or 1. */
function productTotalQuantity(product) {
  const variants = Array.isArray(product.variants) ? product.variants : [];
  if (variants.length) return variants.reduce((s, v) => s + (Number(v.quantity) || 0), 0);
  const q = Number(product.quantity);
  return Number.isFinite(q) ? q : 1;
}

// ── Taxonomy / category match (deterministic, no LLM) ──────────────────────

async function getTaxonomyLeafNodes(clientId) {
  if (taxonomyCache) return taxonomyCache;
  const { status, data } = await etsyReq("GET", "/v3/application/seller-taxonomy/nodes", { clientId });
  if (status !== 200) {
    console.error(`[etsy] taxonomy fetch failed (${status})`);
    return [];
  }
  taxonomyCache = (data.results || [])
    .filter((n) => n.children_count === 0)
    .map((n) => ({ id: n.id, name: n.full_path_taxonomy_string || n.name }));
  return taxonomyCache;
}

function categoryWords(s) {
  return String(s || "").toLowerCase().replace(/[^a-z0-9 ]/g, " ").split(/\s+/).filter(Boolean);
}

/** Best Etsy taxonomy leaf id for a Wonni "A > B > C" category path (weighted word overlap). */
function matchEtsyTaxonomyId(nodes, title, category) {
  if (!Array.isArray(nodes) || nodes.length === 0) return ETSY_FALLBACK_TAXONOMY_ID;
  const path = String(category || "").split(">").map((s) => s.trim()).filter(Boolean);
  const leaf = path.length ? path[path.length - 1] : "";

  const weights = new Map();
  const add = (text, w) => {
    for (const word of categoryWords(text)) weights.set(word, (weights.get(word) || 0) + w);
  };
  add(leaf, 3);
  add(path.join(" "), 1);
  add(title, 0.5);
  if (weights.size === 0) return ETSY_FALLBACK_TAXONOMY_ID;

  let bestId = ETSY_FALLBACK_TAXONOMY_ID;
  let bestScore = 0;
  for (const n of nodes) {
    const nameWords = new Set(categoryWords(n.name));
    let score = 0;
    for (const [word, w] of weights) if (nameWords.has(word)) score += w;
    if (score > bestScore) { bestScore = score; bestId = n.id; }
  }
  return bestScore > 0 ? bestId : ETSY_FALLBACK_TAXONOMY_ID;
}

async function resolveEtsyFields(clientId, title, category) {
  const taxonomy_id = matchEtsyTaxonomyId(await getTaxonomyLeafNodes(clientId), title, category);
  // Wonni resells modern merch; Etsy requires a value for both.
  return { taxonomy_id, when_made: "2020_2024", who_made: "someone_else" };
}

// ── Shop-setup lookups ────────────────────────────────────────────────────

async function firstShippingProfileId(shopId, auth) {
  const { status, data } = await etsyReq("GET", `/v3/application/shops/${shopId}/shipping-profiles`, auth);
  return status === 200 ? data.results?.[0]?.shipping_profile_id ?? null : null;
}
async function firstReturnPolicyId(shopId, auth) {
  const { status, data } = await etsyReq("GET", `/v3/application/shops/${shopId}/return-policies`, auth);
  return status === 200 ? data.results?.[0]?.return_policy_id ?? null : null;
}

// ── Image upload (multipart) ──────────────────────────────────────────────

function downloadBuffer(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return resolve(downloadBuffer(res.headers.location));
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", reject);
    }).on("error", reject);
  });
}

async function uploadListingImages(shopId, listingId, imageUrls, { accessToken, clientId }) {
  let rank = 1;
  for (const url of imageUrls.slice(0, 10)) {
    try {
      const buf = await downloadBuffer(url);
      const boundary = `----WonniBoundary${Date.now()}${rank}`;
      const body = Buffer.concat([
        Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="image"; filename="photo_${rank}.jpg"\r\nContent-Type: image/jpeg\r\n\r\n`),
        buf,
        Buffer.from(`\r\n--${boundary}\r\nContent-Disposition: form-data; name="rank"\r\n\r\n${rank}`),
        Buffer.from(`\r\n--${boundary}\r\nContent-Disposition: form-data; name="overwrite"\r\n\r\ntrue`),
        Buffer.from(`\r\n--${boundary}--\r\n`),
      ]);
      const res = await fetch(`https://openapi.etsy.com/v3/application/shops/${shopId}/listings/${listingId}/images`, {
        method: "POST",
        headers: {
          "x-api-key": clientId,
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
        },
        body,
      });
      if (!res.ok) console.error(`[etsy] image rank ${rank} failed (${res.status})`);
      rank++;
    } catch (e) {
      console.error(`[etsy] image ${url} failed: ${e.message}`);
    }
  }
}

// ── Payload builders (pure) ───────────────────────────────────────────────

/** Etsy `PUT /listings/{id}/inventory` payload from product variants. */
function buildEtsyInventoryPayload(variations = [], basePrice = 0) {
  const products = variations.map((v, idx) => {
    const price = priceAmount(variantPriceOr(v, basePrice));
    const qty = Number.isFinite(Number(v.quantity)) && Number(v.quantity) >= 0 ? Number(v.quantity) : 1;

    let property_values = [];
    const attrs = v.attributes || [];
    if (attrs.length) {
      property_values = attrs
        .filter((a) => a.name && a.value)
        .map((a) => ({ property_name: a.name, values: [String(a.value)] }));
    } else if (v.optionValues && Object.keys(v.optionValues).length) {
      property_values = Object.entries(v.optionValues)
        .filter(([n, val]) => n && val)
        .map(([n, val]) => ({ property_name: n, values: [String(val)] }));
    } else if (v.name) {
      property_values = [{ property_name: "Size", values: [String(v.name)] }];
    }
    if (!property_values.length) property_values = [{ property_name: "Size", values: ["Regular"] }];

    return {
      sku: v.sku || `SKU_${idx + 1}`,
      property_values,
      offerings: [{ price, quantity: qty, is_enabled: true }],
    };
  });
  return { products, price_on_property: [], quantity_on_property: [], sku_on_property: [] };
}

function buildEtsyCreateBody(product, { taxonomyId, whenMade, whoMade, price, quantity, shippingProfileId, returnPolicyId }) {
  const title = String(product.title || "").slice(0, 140) || "Product";
  return {
    quantity: Number.isFinite(quantity) && quantity > 0 ? quantity : 1,
    title,
    description: String(product.description || title).slice(0, 65000) || "Product description",
    price: priceAmount(price),
    who_made: whoMade,
    when_made: whenMade,
    taxonomy_id: taxonomyId,
    state: "active",
    shipping_profile_id: shippingProfileId,
    return_policy_id: returnPolicyId,
  };
}

// ── Drift (pure) ──────────────────────────────────────────────────────────

function etsyDriftDiff(product, etsyItem) {
  const etsyTitle = etsyItem.title ?? null;
  const etsyPrice = etsyItem.price ? etsyItem.price.amount / etsyItem.price.divisor : null;
  const etsyQuantity = typeof etsyItem.quantity === "number" ? etsyItem.quantity : null;
  const etsyStatus = etsyItem.state === "active" ? "active"
    : etsyItem.state ? String(etsyItem.state).toLowerCase() : "active";

  const wonniTitle = product.title ?? "";
  const wonniPrice = Number(product.listingPrice) || 0;
  const wonniQty = productTotalQuantity(product);

  const diff = [];
  if (etsyTitle && etsyTitle.trim() && etsyTitle.trim() !== wonniTitle.trim()) {
    diff.push({ field: "Title", wonni: wonniTitle, external: etsyTitle, key: "title", value: etsyTitle });
  }
  if (etsyPrice != null && Math.abs(etsyPrice - wonniPrice) >= 0.01) {
    diff.push({ field: "Price", wonni: `$${wonniPrice.toFixed(2)}`, external: `$${etsyPrice.toFixed(2)}`, key: "price", value: etsyPrice });
  }
  if (etsyQuantity != null && etsyQuantity !== wonniQty) {
    diff.push({ field: "Quantity", wonni: String(wonniQty), external: String(etsyQuantity), key: "quantity", value: etsyQuantity });
  }

  return {
    hasDrift: diff.length > 0,
    diff,
    etsyData: {
      title: etsyTitle, price: etsyPrice, quantity: etsyQuantity,
      status: etsyStatus, listingId: String(etsyItem.listing_id ?? ""),
    },
    wonniData: {
      title: wonniTitle, price: wonniPrice, quantity: wonniQty,
      status: product.crossPostStatus?.etsy || "active",
    },
  };
}

/** { title?, price?, quantity? } from a drift diff → product doc updates. */
function etsyImportUpdates(fields = {}) {
  const updates = {};
  if (fields.title != null) updates.title = fields.title;
  if (typeof fields.price === "number") updates.listingPrice = fields.price;
  if (typeof fields.quantity === "number") updates.quantity = fields.quantity;
  return updates;
}

const etsyIdOf = (product) =>
  product.crossPostListingIds?.etsy || product.etsyListingId || null;

// ── Callables ─────────────────────────────────────────────────────────────

exports.etsyCreateListing = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  validated("etsyCreateListing", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();
    const product = await loadOwnedProduct(db, uid, data.productId);
    if (!product) throw new HttpsError("not-found", "Product not found.");
    const ref = db.collection("products").doc(data.productId);

    if (product.crossPostStatus?.etsy === "active" && etsyIdOf(product)) {
      return { success: true, listingId: String(etsyIdOf(product)) };
    }

    await ref.set({ crossPostStatus: { etsy: "pending" } }, { merge: true });
    try {
      const auth = await getActiveEtsyToken(uid);
      const { shopId } = auth;

      const shippingProfileId = data.shippingProfileId ?? await firstShippingProfileId(shopId, auth);
      const returnPolicyId = data.returnPolicyId ?? await firstReturnPolicyId(shopId, auth);
      if (!shippingProfileId) throw new HttpsError("failed-precondition", "etsy_missing_shipping_profile: add a shipping profile in your Etsy shop settings.");
      if (!returnPolicyId) throw new HttpsError("failed-precondition", "etsy_missing_return_policy: add a return policy in your Etsy shop settings.");

      let taxonomyId = data.taxonomyId != null ? Number(data.taxonomyId) : null;
      let whenMade = "2020_2024";
      let whoMade = "someone_else";
      if (!taxonomyId) {
        const r = await resolveEtsyFields(auth.clientId, product.title, product.category || product.artistName);
        taxonomyId = r.taxonomy_id;
        whenMade = r.when_made;
        whoMade = r.who_made;
      }

      const price = resolveListingPrice(product);
      const quantity = productTotalQuantity(product);
      const createBody = buildEtsyCreateBody(product, {
        taxonomyId, whenMade, whoMade, price, quantity, shippingProfileId, returnPolicyId,
      });

      const { status, data: created } = await etsyReq(
        "POST", `/v3/application/shops/${shopId}/listings`, { ...auth, body: createBody },
      );
      if (status !== 200 && status !== 201) {
        throw new Error(`Etsy create failed (${status}): ${JSON.stringify(created)}`);
      }
      const etsyListingId = String(created.listing_id);

      const images = listingImagesFor(product, 10);
      if (images.length) await uploadListingImages(shopId, etsyListingId, images, auth);

      const variants = Array.isArray(product.variants) ? product.variants.filter((v) => v.active !== false) : [];
      if (variants.length > 1) {
        try {
          await etsyReq("PUT", `/v3/application/listings/${etsyListingId}/inventory`,
            { ...auth, body: buildEtsyInventoryPayload(variants, priceAmount(price)) });
        } catch (e) {
          console.warn(`[etsyCreateListing] inventory update failed: ${e.message}`);
        }
      }

      await ref.set({
        crossPostStatus: { etsy: "active" },
        crossPostListingIds: { etsy: etsyListingId },
        etsyListingId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, listingId: etsyListingId };
    } catch (err) {
      await ref.set({ crossPostStatus: { etsy: "failed" } }, { merge: true });
      if (err instanceof HttpsError) throw err;
      console.error(`[etsyCreateListing] ${data.productId}: ${err.stack || err.message}`);
      throw new HttpsError("internal", `Etsy listing failed: ${err.message}`);
    }
  }),
);

exports.etsyUpdateListing = onCall(
  { timeoutSeconds: 60 },
  validated("etsyUpdateListing", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();
    const product = await loadOwnedProduct(db, uid, data.productId);
    if (!product) throw new HttpsError("not-found", "Product not found.");
    const etsyId = etsyIdOf(product);
    if (!etsyId) throw new HttpsError("failed-precondition", "No Etsy listing id on record.");

    const auth = await getActiveEtsyToken(uid);
    const price = resolveListingPrice(product);
    const { status, data: res } = await etsyReq(
      "PATCH", `/v3/application/shops/${auth.shopId}/listings/${etsyId}`,
      { ...auth, body: {
        title: String(product.title || "").slice(0, 140),
        description: product.description || product.title || "",
        price: priceAmount(price),
        quantity: productTotalQuantity(product),
      } },
    );

    if (status === 404) {
      await db.collection("products").doc(data.productId).set(
        { crossPostStatus: { etsy: "deleted" } }, { merge: true });
      throw new HttpsError("not-found", "Etsy listing not found — it may have been deleted.");
    }
    if (status !== 200) throw new HttpsError("internal", `Etsy update failed (${status}): ${JSON.stringify(res)}`);

    const variants = Array.isArray(product.variants) ? product.variants.filter((v) => v.active !== false) : [];
    if (variants.length > 1) {
      try {
        await etsyReq("PUT", `/v3/application/listings/${etsyId}/inventory`,
          { ...auth, body: buildEtsyInventoryPayload(variants, priceAmount(price)) });
      } catch (e) {
        console.warn(`[etsyUpdateListing] inventory update failed: ${e.message}`);
      }
    }
    await db.collection("products").doc(data.productId).set(
      { updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
    return { success: true };
  }),
);

exports.etsyDeleteListing = onCall(
  { timeoutSeconds: 30 },
  validated("etsyDeleteListing", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();
    const product = await loadOwnedProduct(db, uid, data.productId);
    if (!product) throw new HttpsError("not-found", "Product not found.");
    const etsyId = etsyIdOf(product);
    if (!etsyId) return { success: true };

    const auth = await getActiveEtsyToken(uid);
    // Etsy has no delete for active listings — set inactive (draft).
    await etsyReq("PATCH", `/v3/application/shops/${auth.shopId}/listings/${etsyId}`,
      { ...auth, body: { state: "inactive" } });

    await db.collection("products").doc(data.productId).set({
      crossPostStatus: { etsy: "" },
      crossPostListingIds: { etsy: admin.firestore.FieldValue.delete() },
      etsyListingId: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { success: true };
  }),
);

exports.etsyCheckShopSetup = onCall(
  { timeoutSeconds: 60 },
  validated("etsyCheckShopSetup", async (_data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const auth = await getActiveEtsyToken(uid);
    const [shippingId, returnId] = await Promise.all([
      firstShippingProfileId(auth.shopId, auth),
      firstReturnPolicyId(auth.shopId, auth),
    ]);
    return { hasShippingProfile: shippingId !== null, hasReturnPolicy: returnId !== null };
  }),
);

exports.etsyPullSync = onCall(
  { memory: "512MiB", timeoutSeconds: 60 },
  validated("etsyPullSync", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();
    const product = await loadOwnedProduct(db, uid, data.productId);
    if (!product) throw new HttpsError("not-found", "Product not found.");
    const etsyId = etsyIdOf(product);
    if (!etsyId) throw new HttpsError("not-found", "No Etsy listing id on record.");

    const auth = await getActiveEtsyToken(uid);
    const { status, data: item } = await etsyReq("GET", `/v3/application/listings/${etsyId}`, auth);
    if (status !== 200) throw new HttpsError("not-found", `Etsy listing ${etsyId} not found (${status}).`);
    return etsyDriftDiff(product, item);
  }),
);

exports.etsyImportPullSync = onCall(
  { memory: "512MiB", timeoutSeconds: 30 },
  validated("etsyImportPullSync", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();
    await loadOwnedProduct(db, uid, data.productId); // ownership check
    const updates = etsyImportUpdates(data.fields);
    updates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
    await db.collection("products").doc(data.productId).set(updates, { merge: true });
    return { success: true };
  }),
);

exports.getEtsyCategories = onCall(
  { timeoutSeconds: 60 },
  validated("getEtsyCategories", async (_data, request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const auth = await getActiveEtsyToken(request.auth.uid);
    return { categories: await getTaxonomyLeafNodes(auth.clientId) };
  }),
);

exports.suggestEtsyCategory = onCall(
  { timeoutSeconds: 60 },
  validated("suggestEtsyCategory", async (data, request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const auth = await getActiveEtsyToken(request.auth.uid);
    const nodes = await getTaxonomyLeafNodes(auth.clientId);
    const taxonomyId = matchEtsyTaxonomyId(nodes, data.title, data.category);
    return { taxonomyId, taxonomyName: nodes.find((n) => n.id === taxonomyId)?.name || "Other" };
  }),
);

exports.getEtsyShippingProfiles = onCall(
  { timeoutSeconds: 60 },
  validated("getEtsyShippingProfiles", async (_data, request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const auth = await getActiveEtsyToken(request.auth.uid);
    const { status, data } = await etsyReq("GET", `/v3/application/shops/${auth.shopId}/shipping-profiles`, auth);
    if (status !== 200) throw new HttpsError("internal", `Failed to fetch shipping profiles (${status}).`);
    return { profiles: (data.results || []).map((p) => ({ id: p.shipping_profile_id, title: p.title })) };
  }),
);

exports.getEtsyReturnPolicies = onCall(
  { timeoutSeconds: 60 },
  validated("getEtsyReturnPolicies", async (_data, request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const auth = await getActiveEtsyToken(request.auth.uid);
    const { status, data } = await etsyReq("GET", `/v3/application/shops/${auth.shopId}/return-policies`, auth);
    if (status !== 200) throw new HttpsError("internal", `Failed to fetch return policies (${status}).`);
    return {
      policies: (data.results || []).map((p) => ({
        id: p.return_policy_id,
        name: `${p.accepts_returns ? "Accepts" : "No"} returns / ${p.accepts_exchanges ? "Accepts" : "No"} exchanges`,
      })),
    };
  }),
);

exports._internal = {
  matchEtsyTaxonomyId, categoryWords, buildEtsyInventoryPayload, buildEtsyCreateBody,
  etsyDriftDiff, etsyImportUpdates, productTotalQuantity, priceAmount, etsyIdOf,
};
