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

/** Order id when the client has it, else the item id — same key recordSaleCore dedupes on. */
function mercariSaleKey(item) {
  return `mercari_${item.mercariOrderId ?? item.mercariItemId}`;
}

/**
 * Patch that writes a Mercari item id onto a product (or one of its variants)
 * ONLY where that pointer is empty — a user "Link to product…" answer must
 * never overwrite an existing, possibly-live listing id. Returns the fields to
 * merge into the product doc, or null when there is nothing to write.
 * Whole-array rebuild for variants: never a dotted `variants.N.x` path.
 */
function mercariPointerPatch(product, variantSku, mercariItemId) {
  if (!product || !mercariItemId) return null;
  const variants = Array.isArray(product.variants) ? product.variants : [];
  const idx = variantSku ? variants.findIndex((v) => v && v.sku === variantSku) : -1;
  if (idx >= 0) {
    const v = variants[idx];
    if (v.crossPostListingIds?.mercari || v.mercariListingId) return null;
    const next = variants.map((x, i) => i === idx
      ? { ...x, crossPostListingIds: { ...(x.crossPostListingIds ?? {}), mercari: mercariItemId } }
      : x);
    return { variants: next };
  }
  if (product.crossPostListingIds?.mercari || product.mercariListingId) return null;
  return { crossPostListingIds: { ...(product.crossPostListingIds ?? {}), mercari: mercariItemId } };
}

const inboxRef = (db, uid, key) => db.collection("users").doc(uid).collection("mercariSaleInbox").doc(key);

/**
 * Refresh step 1. Classify scraped rows (newest first) so the client can stop
 * at the first already-recorded row and show the opt-out review list. Records
 * nothing. A row is "recorded" when sales/{mercari_<order or item id>} exists;
 * "discarded" when the user said Never import.
 */
async function reviewMercariSalesCore(db, uid, items) {
  const productsSnap = await db.collection("products").where("userId", "==", uid).get();
  const matchMap = buildMercariMatchMap(productsSnap.docs);
  const productById = new Map(productsSnap.docs.map((d) => [d.id, d.data()]));

  const rows = [];
  let firstRecordedIndex = null;
  for (let i = 0; i < items.length; i++) {
    const raw = items[i];
    const parsed = MercariScrapeItemSchema.safeParse(raw);
    if (!parsed.success) {
      rows.push({
        mercariItemId: raw?.mercariItemId ?? "(unknown)", reviewState: "invalid",
        warning: parsed.error.issues[0]?.message ?? "invalid row",
      });
      continue;
    }
    const item = parsed.data;
    const key = mercariSaleKey(item);
    const match = matchMap.get(item.mercariItemId) ?? null;
    const base = {
      mercariItemId: item.mercariItemId,
      productId: match?.productId ?? null,
      variantSku: match?.variantSku ?? null,
      productTitle: match ? productById.get(match.productId)?.title ?? null : null,
    };
    if ((await db.collection("sales").doc(key).get()).exists) {
      rows.push({ ...base, reviewState: "recorded" });
      if (firstRecordedIndex === null) firstRecordedIndex = i;
      continue;
    }
    const tomb = await inboxRef(db, uid, key).get();
    rows.push({ ...base, reviewState: tomb.exists && tomb.data()?.state === "discarded" ? "discarded" : "new" });
  }
  return { rows, firstRecordedIndex };
}

async function setMercariSalesDiscardedCore(db, uid, items, discarded) {
  let updated = 0;
  for (const it of items) {
    const ref = inboxRef(db, uid, mercariSaleKey(it));
    if (discarded) {
      await ref.set({
        state: "discarded", mercariItemId: it.mercariItemId, mercariOrderId: it.mercariOrderId ?? null,
        title: it.title ?? null, priceSoldFor: it.priceSoldFor ?? null,
        discardedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      await ref.delete();
    }
    updated++;
  }
  return { updated };
}

exports.reviewMercariSales = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  validated("reviewMercariSales", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return reviewMercariSalesCore(admin.firestore(), uid, data.items);
  })
);

exports.setMercariSalesDiscarded = onCall(
  { timeoutSeconds: 60 },
  validated("setMercariSalesDiscarded", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return setMercariSalesDiscardedCore(admin.firestore(), uid, data.items, data.discarded);
  })
);

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
          warning: parsed.error.issues[0]?.message ?? "invalid row",
        });
        continue;
      }
      const item = parsed.data;

      try {
        let match = matchMap.get(item.mercariItemId);
        let pointerWritten = false;
        const link = data.links?.[item.mercariItemId];
        if (!match && link) {
          // The user's "Link to product…" answer. Must be their own product.
          const linked = productById.get(link.productId);
          if (!linked || linked.userId !== uid) {
            results.push({ mercariItemId: item.mercariItemId, outcome: "parse-failed", warning: "Linked product not found." });
            continue;
          }
          match = { productId: link.productId, variantSku: link.variantSku ?? null };
          const patch = mercariPointerPatch(linked, match.variantSku, item.mercariItemId);
          if (patch) {
            await db.collection("products").doc(link.productId).set(patch, { merge: true });
            productById.set(link.productId, { ...linked, ...patch });
            pointerWritten = true;
          }
        }
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
          results.push({ mercariItemId: item.mercariItemId, outcome: "recorded", saleId, productId: match.productId, pointerWritten });
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

// Internal — unit-tested in test/mercari.test.js.
exports._internal = {
  buildMercariMatchMap, looseDate, mercariSaleKey, mercariPointerPatch,
  reviewMercariSalesCore, setMercariSalesDiscardedCore,
};
