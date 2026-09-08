/**
 * mercari_sales.js — recordMercariSalesBatch
 *
 * The client (Chrome extension / iOS WKWebView) scrapes the Mercari "in
 * progress" list and each order-status page — only it has the logged-in
 * session. It sends what it found. This function owns everything after that:
 *   1. match each mercariItemId → a products/{id} (+ variant) doc
 *   2. dedupe against sales/{id}
 *   3. write the canonical sale doc + fire the quantity cascade
 *      (all via recordSaleCore, shared with recordSale)
 *
 * Replaces nested `mercari_sale.js` (recordMercariSale + recordMercariSalesBatch),
 * rebased onto the web `products/` model.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { validated, MercariScrapeItemSchema } = require("./contracts");
const { _internal, EBAY_SECRETS } = require("./sales");

const { recordSaleCore } = _internal;

/** Best-effort parse of a scraped date string ("7/8/2026", "Jul 8, 2026"). */
function looseDate(text) {
  if (!text || typeof text !== "string") return null;
  const t = Date.parse(text.trim());
  return Number.isFinite(t) ? t : null;
}

/**
 * Build { mercariItemId -> { productId, variantSku } } for every Mercari
 * cross-post this user has, in one pass. Checks product-level and per-variant
 * pointers, current + legacy field names.
 */
function buildMercariMatchMap(productDocs) {
  const map = new Map();
  for (const doc of productDocs) {
    const p = doc.data();
    const add = (id, variantSku) => { if (id && !map.has(id)) map.set(id, { productId: doc.id, variantSku }); };

    add(p.crossPostListingIds?.mercari, null);
    add(p.mercariListingId, null);            // legacy product-level
    for (const v of Array.isArray(p.variants) ? p.variants : []) {
      add(v.crossPostListingIds?.mercari, v.sku ?? null);
      add(v.mercariListingId, v.sku ?? null); // legacy variant-level
    }
  }
  return map;
}

exports.recordMercariSalesBatch = onCall(
  { secrets: EBAY_SECRETS, timeoutSeconds: 120, memory: "512MiB" },
  validated("recordMercariSalesBatch", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const items = [...(data.items ?? []), ...(data.rawItems ?? [])];
    const db = admin.firestore();

    // One read: every product this user owns → the Mercari match map.
    const productsSnap = await db.collection("products").where("userId", "==", uid).get();
    const matchMap = buildMercariMatchMap(productsSnap.docs);
    const productById = new Map(productsSnap.docs.map((d) => [d.id, d.data()]));

    const results = [];
    let recorded = 0, duplicates = 0, unmatched = 0;

    for (const rawItem of items) {
      const parsed = MercariScrapeItemSchema.safeParse(rawItem);
      if (!parsed.success) {
        results.push({
          mercariItemId: rawItem?.mercariItemId ?? "(unknown)",
          outcome: "parse-failed",
          warning: parsed.error.errors[0]?.message ?? "invalid row",
        });
        continue;
      }
      const item = parsed.data;

      try {
        const match = matchMap.get(item.mercariItemId);
        if (!match) {
          unmatched++;
          results.push({ mercariItemId: item.mercariItemId, outcome: "no-match" });
          continue;
        }

        const soldAt = item.soldAt ?? looseDate(item.soldDateText ?? item.soldDate);
        const { saleId, created } = await recordSaleCore(db, uid, {
          platform: "mercari",
          productId: match.productId,
          variantSku: match.variantSku,
          soldPrice: item.priceSoldFor,
          takeHome: item.takeHome ?? null,
          shippingRevenue: item.shippingRevenue ?? null,
          quantity: 1,
          soldAt,
          platformOrderId: item.mercariOrderId ?? item.mercariItemId,
          platformItemId: item.mercariItemId,
          buyerName: item.buyerName ?? null,
          trackingNumber: item.trackingNumber ?? null,
          listingTitle: item.title ?? null,
          thumbnailUrl: item.thumbnailUrl ?? null,
          source: "mercari-scan",
          cascade: true,
        }, productById.get(match.productId) ?? null);

        if (created) {
          recorded++;
          results.push({ mercariItemId: item.mercariItemId, outcome: "recorded", saleId, productId: match.productId });
        } else {
          duplicates++;
          results.push({ mercariItemId: item.mercariItemId, outcome: "duplicate", saleId, productId: match.productId });
        }
      } catch (err) {
        console.error(`[recordMercariSalesBatch] ${item.mercariItemId}:`, err.message);
        results.push({ mercariItemId: item.mercariItemId, outcome: "parse-failed", warning: err.message });
      }
    }

    return { results, recorded, duplicates, unmatched };
  })
);
