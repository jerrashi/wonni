/**
 * mercari_sales.js — Mercari sale import (review + record), server side.
 *
 * The client (Chrome extension for the web dashboard / iOS WKWebView) scrapes
 * Mercari's "in progress" + "complete" lists and each order-status page; only it
 * has the logged-in session. It sends what it found. This file owns everything
 * after that:
 *   - reviewMercariSales: classify rows (new / recorded / discarded / invalid).
 *     With `autoImport` (current clients, decided with the user 2026-11-14):
 *       * a row matched by a Mercari id already on a product AND carrying title +
 *         price + sold date is recorded right away, like an eBay/Etsy sale;
 *       * every other new row is saved to users/{uid}/mercariSaleInbox as
 *         "pending", so it waits for review across refreshes and devices. This is
 *         what lets the scan stop at the first already-seen row without ever
 *         losing an unchecked or incomplete sale below it.
 *   - recordMercariSalesBatch: record the rows the user imported from review
 *     (`links` = "Link to product…" answers, `allowUnlinked` = record a sale with
 *     no product and no stock change). Recorded rows leave the inbox.
 *   - undoMercariAutoImport: the toast's Undo for auto-recorded rows.
 *   - setMercariSalesDiscarded / listMercariSaleInbox: Never import / Restore, and
 *     the inbox for the banner.
 * Recording itself is sales.js recordSaleCore (dedupe, sale doc, stock cascade).
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { validated, MercariScrapeItemSchema, MercariPendingItemSchema } = require("./contracts");
const { _internal, EBAY_SECRETS } = require("./sales");

const { recordSaleCore, resolveSaleId, applyQuantityDelta, cascade } = _internal;

/** Best-effort parse of a scraped date string ("7/8/2026", "Jul 8, 2026"). */
function looseDate(text) {
  if (!text || typeof text !== "string") return null;
  const t = Date.parse(text.trim());
  return Number.isFinite(t) ? t : null;
}

/** The row's sale time (ms or ISO) or null when it has none we can read. */
function itemSoldAt(item) {
  return item.soldAt ?? looseDate(item.soldDateText ?? item.soldDate);
}

/** Required review fields the row lacks: a title, a price above 0, a sold date. */
function missingFields(item) {
  const out = [];
  if (!item.title || !String(item.title).trim()) out.push("title");
  if (!(Number(item.priceSoldFor) > 0)) out.push("price");
  if (itemSoldAt(item) == null) out.push("date");
  return out;
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

const STOP_WORDS = new Set(["the", "and", "for", "with", "new", "used", "ver", "version", "set", "lot"]);
const titleWords = (s) => new Set(String(s ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").split(" ")
  .filter((w) => w.length >= 3 && !STOP_WORDS.has(w)));

/**
 * Title-only guess for a row with no id match: the product sharing the most
 * words with the sale title, when it shares at least 60% of the sale's words and
 * no other product ties it. Only ever shown as "Suggested"; never auto-recorded,
 * since a wrong guess would lower the wrong stock.
 */
function suggestProduct(title, products) {
  const want = titleWords(title);
  if (want.size < 2) return null;
  let best = null, bestScore = 0, tie = false;
  for (const p of products) {
    if (p.data.isDeleted === true) continue;
    const have = titleWords(p.data.title);
    let shared = 0;
    for (const w of want) if (have.has(w)) shared++;
    const score = shared / want.size;
    if (score > bestScore) { best = p; bestScore = score; tie = false; }
    else if (score === bestScore && score > 0) tie = true;
  }
  if (!best || tie || bestScore < 0.6) return null;
  return { productId: best.id, title: best.data.title ?? null };
}

/** Inbox doc id: the plain sale key (per-user subcollection, so never contested). */
function mercariSaleKey(item) {
  return `mercari_${item.mercariOrderId ?? item.mercariItemId}`;
}

/** The key this user's sale actually lives under (see sales.resolveSaleId). */
function mercariSaleId(db, uid, item) {
  return resolveSaleId(db, uid, "mercari", item.mercariOrderId ?? item.mercariItemId);
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

const inboxCol = (db, uid) => db.collection("users").doc(uid).collection("mercariSaleInbox");
const inboxRef = (db, uid, item) => inboxCol(db, uid).doc(mercariSaleKey(item));

/** Strip undefined so Firestore accepts the stored row. */
const clean = (o) => JSON.parse(JSON.stringify(o));

/** Load this user's products once: match map, by-id map, and the list for suggestions. */
async function loadProducts(db, uid) {
  const snap = await db.collection("products").where("userId", "==", uid).get();
  return {
    matchMap: buildMercariMatchMap(snap.docs),
    byId: new Map(snap.docs.map((d) => [d.id, d.data()])),
    list: snap.docs.map((d) => ({ id: d.id, data: d.data() })),
  };
}

/** One inbox row as the client shows it (match, suggestion, missing fields). */
function inboxRowView(stored, products) {
  const item = stored.item ?? { mercariItemId: stored.mercariItemId };
  const match = products.matchMap.get(item.mercariItemId) ?? null;
  const suggestion = match ? null : suggestProduct(item.title, products.list);
  return {
    item,
    state: stored.state,
    productId: match?.productId ?? null,
    variantSku: match?.variantSku ?? null,
    productTitle: match ? products.byId.get(match.productId)?.title ?? null : null,
    suggestedProductId: suggestion?.productId ?? null,
    suggestedProductTitle: suggestion?.title ?? null,
    missing: missingFields(item),
  };
}

/** Everything waiting for review + everything hidden, newest first. */
async function readInbox(db, uid, products) {
  const snap = await inboxCol(db, uid).get();
  const pending = [], discarded = [];
  const rows = snap.docs.map((d) => d.data())
    .filter((d) => d.state === "pending" || d.state === "discarded")
    .sort((a, b) => (b.seenAt ?? 0) - (a.seenAt ?? 0));
  for (const d of rows) {
    const view = inboxRowView(d, products);
    // A row without a readable item (a tombstone from before 2026-11-14) still lists
    // under discarded so it can be restored; it never lands in pending.
    if (d.state === "discarded") discarded.push(view);
    else if (d.item) pending.push(view);
  }
  return { pending, discarded };
}

/**
 * Record one row through recordSaleCore. `match` = {productId, variantSku} or
 * null (an unlinked sale: no product, no stock change).
 */
async function recordItem(db, uid, item, match, products) {
  const product = match ? products.byId.get(match.productId) ?? null : null;
  return recordSaleCore(db, uid, {
    platform: "mercari",
    productId: match?.productId ?? null,
    variantSku: match?.variantSku ?? null,
    soldPrice: item.priceSoldFor,
    takeHome: item.takeHome ?? null,
    shippingRevenue: item.shippingRevenue ?? null,
    quantity: item.quantity ?? 1,
    soldAt: itemSoldAt(item),
    platformOrderId: item.mercariOrderId ?? item.mercariItemId,
    platformItemId: item.mercariItemId,
    buyerName: item.buyerName ?? null,
    trackingNumber: item.trackingNumber ?? null,
    listingTitle: item.title ?? null,
    thumbnailUrl: item.thumbnailUrl ?? null,
    source: "mercari-scan",
    cascade: true,
  }, product);
}

/**
 * Refresh step 1. Classify scraped rows (newest first) so the client can stop
 * at the first already-recorded row. A row is "recorded" when this user's
 * sales/{mercari_<order or item id>} exists; "discarded" when the user said
 * Never import. Without `autoImport` it records nothing (older clients).
 */
async function reviewMercariSalesCore(db, uid, items, { autoImport = false } = {}) {
  const products = await loadProducts(db, uid);

  const rows = [];
  let firstRecordedIndex = null;
  let autoRecorded = 0;
  for (let i = 0; i < items.length; i++) {
    const raw = items[i];
    const parsed = (autoImport ? MercariPendingItemSchema : MercariScrapeItemSchema).safeParse(raw);
    if (!parsed.success) {
      rows.push({
        mercariItemId: raw?.mercariItemId ?? "(unknown)", reviewState: "invalid",
        warning: parsed.error.issues[0]?.message ?? "invalid row",
      });
      continue;
    }
    const item = parsed.data;
    const key = await mercariSaleId(db, uid, item);
    const match = products.matchMap.get(item.mercariItemId) ?? null;
    const missing = missingFields(item);
    const base = {
      mercariItemId: item.mercariItemId,
      productId: match?.productId ?? null,
      variantSku: match?.variantSku ?? null,
      productTitle: match ? products.byId.get(match.productId)?.title ?? null : null,
      missing,
    };
    // `key` is already resolved to this user's own id, so another account's sale
    // with the same plain id can never read as "recorded".
    const saleSnap = await db.collection("sales").doc(key).get();
    if (saleSnap.exists && saleSnap.data()?.userId === uid) {
      rows.push({ ...base, reviewState: "recorded" });
      if (firstRecordedIndex === null) firstRecordedIndex = i;
      continue;
    }
    const ref = inboxRef(db, uid, item);
    const stored = (await ref.get()).data();
    if (stored?.state === "discarded") { rows.push({ ...base, reviewState: "discarded" }); continue; }
    if (!autoImport) { rows.push({ ...base, reviewState: "new" }); continue; }

    if (match && missing.length === 0) {
      try {
        const { saleId } = await recordItem(db, uid, item, match, products);
        await db.collection("sales").doc(saleId).set({ autoImported: true }, { merge: true });
        await ref.set(clean({ state: "autoRecorded", item, saleId, mercariItemId: item.mercariItemId, seenAt: Date.now() }));
        autoRecorded++;
        rows.push({ ...base, reviewState: "autoRecorded", saleId });
        continue;
      } catch (err) {
        console.error(`[reviewMercariSales] auto-record ${item.mercariItemId}:`, err.message);
        // falls through: it waits for review like any other row
      }
    }
    // Pending. A row already waiting keeps the user's earlier copy only where the
    // fresh scrape is blank (a later scrape may have the price an earlier one missed).
    const merged = stored?.state === "pending" && stored.item
      ? { ...stored.item, ...Object.fromEntries(Object.entries(item).filter(([, v]) => v != null)) }
      : item;
    await ref.set(clean({
      state: "pending", item: merged, mercariItemId: item.mercariItemId,
      seenAt: stored?.seenAt ?? Date.now(),
    }));
    rows.push({ ...base, missing: missingFields(merged), reviewState: "new" });
  }
  const out = { rows, firstRecordedIndex };
  if (autoImport) {
    out.autoRecorded = autoRecorded;
    out.inbox = await readInbox(db, uid, products);
  }
  return out;
}

/**
 * Never import (tombstone) or Restore. The scraped row is kept on the tombstone so
 * Restore can put it straight back in review; a tombstone without one (older
 * clients) is forgotten instead and the next full scan finds the sale again.
 */
async function setMercariSalesDiscardedCore(db, uid, items, discarded) {
  let updated = 0;
  for (const it of items) {
    const ref = inboxRef(db, uid, it);
    const cur = (await ref.get()).data();
    if (discarded) {
      await ref.set(clean({
        ...(cur ?? {}),
        state: "discarded", mercariItemId: it.mercariItemId, mercariOrderId: it.mercariOrderId ?? null,
        title: it.title ?? cur?.item?.title ?? null, priceSoldFor: it.priceSoldFor ?? cur?.item?.priceSoldFor ?? null,
        seenAt: cur?.seenAt ?? Date.now(),
        discardedAt: Date.now(),
      }));
    } else if (cur?.item) {
      const { discardedAt, title, priceSoldFor, mercariOrderId, ...rest } = cur;
      await ref.set(clean({ ...rest, state: "pending" }));
    } else {
      await ref.delete();
    }
    updated++;
  }
  return { updated };
}

/**
 * Record the rows the user imported from review. Recorded and duplicate rows
 * leave the inbox. `allowUnlinked` records a no-product row instead of
 * answering "no-match".
 */
async function recordMercariSalesBatchCore(db, uid, data) {
  const items = [...(data.items ?? []), ...(data.rawItems ?? [])];
  const products = await loadProducts(db, uid);

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
      let match = products.matchMap.get(item.mercariItemId) ?? null;
      let pointerWritten = false;
      const link = data.links?.[item.mercariItemId];
      if (!match && link) {
        // The user's "Link to product…" answer. Must be their own product.
        const linked = products.byId.get(link.productId);
        if (!linked || linked.userId !== uid) {
          results.push({ mercariItemId: item.mercariItemId, outcome: "parse-failed", warning: "Linked product not found." });
          continue;
        }
        match = { productId: link.productId, variantSku: link.variantSku ?? null };
        const patch = mercariPointerPatch(linked, match.variantSku, item.mercariItemId);
        if (patch) {
          await db.collection("products").doc(link.productId).set(patch, { merge: true });
          products.byId.set(link.productId, { ...linked, ...patch });
          pointerWritten = true;
        }
      }
      if (!match && !data.allowUnlinked) {
        unmatched++;
        results.push({ mercariItemId: item.mercariItemId, outcome: "no-match" });
        continue;
      }

      const { saleId, created } = await recordItem(db, uid, item, match, products);
      await inboxRef(db, uid, item).delete();
      if (created) {
        recorded++;
        results.push({ mercariItemId: item.mercariItemId, outcome: "recorded", saleId, productId: match?.productId ?? null, pointerWritten });
      } else {
        duplicates++;
        results.push({ mercariItemId: item.mercariItemId, outcome: "duplicate", saleId, productId: match?.productId ?? null });
      }
    } catch (err) {
      console.error(`[recordMercariSalesBatch] ${item.mercariItemId}:`, err.message);
      results.push({ mercariItemId: item.mercariItemId, outcome: "parse-failed", warning: err.message });
    }
  }

  return { results, recorded, duplicates, unmatched };
}

/**
 * Undo for auto-recorded rows: delete the sale, put the stock back (and push the
 * restored number to eBay/Etsy), and return the row to review. Only sales this
 * call's auto-import made qualify (`autoImported` on the sale, "autoRecorded" in
 * the inbox) — Undo can never delete a sale the user recorded by hand.
 * NOTE: a Weverse re-order task the sale created is left in place.
 */
async function undoMercariAutoImportCore(db, uid, items, deps = {}) {
  const restore = deps.restoreStock ?? (async (productId, variantSku, qty) => {
    const applied = await applyQuantityDelta(db, productId, uid, variantSku, qty);
    if (applied.skipped) return;
    // soldOnPlatform null + soldOut false: pushes the number to eBay/Etsy and sets no
    // Mercari flag (the Mercari listing really did sell; nothing to relist there).
    await cascade(db, uid, applied.product, productId, {
      variantSku, newQuantity: applied.newQuantity, soldOut: applied.newQuantity <= 0, soldOnPlatform: null,
    });
  });
  let undone = 0;
  for (const it of items) {
    const ref = inboxRef(db, uid, it);
    const stored = (await ref.get()).data();
    if (stored?.state !== "autoRecorded" || !stored.saleId) continue;
    const saleRef = db.collection("sales").doc(stored.saleId);
    const sale = (await saleRef.get()).data();
    if (sale && (sale.userId !== uid || sale.autoImported !== true)) continue;
    if (sale) {
      await saleRef.delete();
      if (sale.productId) {
        try {
          await restore(sale.productId, sale.variantSku ?? null, sale.quantity ?? 1);
        } catch (err) {
          console.error(`[undoMercariAutoImport] restock ${sale.productId}:`, err.message);
        }
      }
    }
    const { saleId, ...rest } = stored;
    await ref.set(clean({ ...rest, state: "pending" }));
    undone++;
  }
  return { undone, inbox: await readInbox(db, uid, await loadProducts(db, uid)) };
}

const requireUid = (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return uid;
};

exports.reviewMercariSales = onCall(
  { secrets: EBAY_SECRETS, timeoutSeconds: 300, memory: "512MiB" },
  validated("reviewMercariSales", async (data, request) =>
    reviewMercariSalesCore(admin.firestore(), requireUid(request), data.items, { autoImport: data.autoImport === true }))
);

exports.listMercariSaleInbox = onCall(
  { timeoutSeconds: 60 },
  validated("listMercariSaleInbox", async (data, request) => {
    const uid = requireUid(request);
    const db = admin.firestore();
    return readInbox(db, uid, await loadProducts(db, uid));
  })
);

exports.undoMercariAutoImport = onCall(
  { secrets: EBAY_SECRETS, timeoutSeconds: 120, memory: "512MiB" },
  validated("undoMercariAutoImport", async (data, request) =>
    undoMercariAutoImportCore(admin.firestore(), requireUid(request), data.items))
);

exports.setMercariSalesDiscarded = onCall(
  { timeoutSeconds: 60 },
  validated("setMercariSalesDiscarded", async (data, request) =>
    setMercariSalesDiscardedCore(admin.firestore(), requireUid(request), data.items, data.discarded))
);

exports.recordMercariSalesBatch = onCall(
  { secrets: EBAY_SECRETS, timeoutSeconds: 120, memory: "512MiB" },
  validated("recordMercariSalesBatch", async (data, request) =>
    recordMercariSalesBatchCore(admin.firestore(), requireUid(request), data))
);

// Internal — unit-tested in test/mercari.test.js.
exports._internal = {
  buildMercariMatchMap, looseDate, mercariSaleKey, mercariPointerPatch, missingFields, suggestProduct,
  reviewMercariSalesCore, setMercariSalesDiscardedCore, recordMercariSalesBatchCore,
  undoMercariAutoImportCore, readInbox, loadProducts,
};
