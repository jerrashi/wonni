/**
 * mercari.test.js — the Mercari-specific pieces of recordMercariSalesBatch:
 * the item-id → product/variant match map, the loose date parser, and the
 * contract envelope. Recording + cascade itself is covered in sales.test.js
 * (shared `recordSaleCore`).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal } = require("../mercari_sales");
const { MercariScrapeItemSchema } = require("../contracts");
const { RequestSchemas } = require("../contracts");

const { buildMercariMatchMap, looseDate } = _internal;

/** Mimic a Firestore query snapshot's `.docs` — [{ id, data() }]. */
function docs(map) {
  return Object.entries(map).map(([id, data]) => ({ id, data: () => data }));
}

// ── buildMercariMatchMap ────────────────────────────────────────────────────

test("buildMercariMatchMap: product-level pointer (current + legacy keys)", () => {
  const map = buildMercariMatchMap(docs({
    p_current: { crossPostListingIds: { mercari: "m111" } },
    p_legacy: { mercariListingId: "m222" },
  }));
  assert.deepEqual(map.get("m111"), { productId: "p_current", variantSku: null });
  assert.deepEqual(map.get("m222"), { productId: "p_legacy", variantSku: null });
});

test("buildMercariMatchMap: per-variant pointers carry the variant sku", () => {
  const map = buildMercariMatchMap(docs({
    p1: {
      variants: [
        { sku: "TEE-S", crossPostListingIds: { mercari: "m_s" } },
        { sku: "TEE-M", mercariListingId: "m_m" },
      ],
    },
  }));
  assert.deepEqual(map.get("m_s"), { productId: "p1", variantSku: "TEE-S" });
  assert.deepEqual(map.get("m_m"), { productId: "p1", variantSku: "TEE-M" });
});

test("buildMercariMatchMap: first writer wins on a duplicate item id", () => {
  const map = buildMercariMatchMap(docs({
    a: { crossPostListingIds: { mercari: "dup" } },
    b: { crossPostListingIds: { mercari: "dup" } },
  }));
  assert.equal(map.get("dup").productId, "a");
});

test("buildMercariMatchMap: an unmatched id returns undefined", () => {
  const map = buildMercariMatchMap(docs({ a: { crossPostListingIds: { mercari: "x" } } }));
  assert.equal(map.get("nope"), undefined);
});

// ── looseDate ───────────────────────────────────────────────────────────────

test("looseDate: parses common scraped formats, null on junk", () => {
  assert.equal(looseDate("2026-01-02"), Date.parse("2026-01-02"));
  assert.equal(looseDate("Jul 8, 2026"), Date.parse("Jul 8, 2026"));
  assert.equal(looseDate("   "), null);
  assert.equal(looseDate("sometime last week"), null);
  assert.equal(looseDate(null), null);
  assert.equal(looseDate(42), null);
});

// ── contract: MercariScrapeItemSchema ───────────────────────────────────────

test("MercariScrapeItemSchema: requires a positive price and an item id", () => {
  assert.equal(MercariScrapeItemSchema.safeParse({ mercariItemId: "m1", priceSoldFor: 12.5 }).success, true);
  assert.equal(MercariScrapeItemSchema.safeParse({ priceSoldFor: 12.5 }).success, false);
  assert.equal(MercariScrapeItemSchema.safeParse({ mercariItemId: "m1", priceSoldFor: 0 }).success, false);
  assert.equal(MercariScrapeItemSchema.safeParse({ mercariItemId: "m1", priceSoldFor: -3 }).success, false);
});

test("MercariScrapeItemSchema: accepts the current extension shape (soldDate alias, extra keys ignored via batch loose parse)", () => {
  const r = MercariScrapeItemSchema.safeParse({
    mercariItemId: "m1", priceSoldFor: 30, soldDate: "7/8/2026", buyerName: "A. Buyer",
  });
  assert.equal(r.success, true);
  assert.equal(r.data.soldDate, "7/8/2026");
});

// ── contract: batch envelope ────────────────────────────────────────────────

test("recordMercariSalesBatch request: accepts items OR rawItems, rejects an empty batch", () => {
  const schema = RequestSchemas.recordMercariSalesBatch;
  assert.equal(schema.safeParse({ items: [{ mercariItemId: "m1" }] }).success, true);
  assert.equal(schema.safeParse({ rawItems: [{ mercariItemId: "m1" }] }).success, true);
  assert.equal(schema.safeParse({ items: [], rawItems: [] }).success, false);
  assert.equal(schema.safeParse({}).success, false);
});

// ── Refresh: review, link pointer, discard ─────────────────────────────────

const { FakeFirestore } = require("./helpers/fake-firestore");
const { mercariSaleKey, mercariPointerPatch, reviewMercariSalesCore, setMercariSalesDiscardedCore } = _internal;

const row = (id, extra = {}) => ({ mercariItemId: id, priceSoldFor: 12, title: `t ${id}`, ...extra });

async function seed() {
  const db = new FakeFirestore();
  await db.collection("products").doc("p1").set({ userId: "u1", title: "Tee", crossPostListingIds: { mercari: "m_known" } });
  return db;
}

test("mercariSaleKey: the order id wins, else the item id (matches recordSaleCore's dedupe key)", () => {
  assert.equal(mercariSaleKey({ mercariItemId: "m1", mercariOrderId: "o9" }), "mercari_o9");
  assert.equal(mercariSaleKey({ mercariItemId: "m1" }), "mercari_m1");
});

test("reviewMercariSales: new / recorded / discarded / invalid, matched product titled, stop index = first recorded", async () => {
  const db = await seed();
  await db.collection("sales").doc("mercari_m_old").set({ userId: "u1" });
  await setMercariSalesDiscardedCore(db, "u1", [{ mercariItemId: "m_no" }], true);

  const r = await reviewMercariSalesCore(db, "u1", [
    row("m_known"),            // new, matches p1
    row("m_no"),               // discarded
    { mercariItemId: "m_bad" },// invalid: no price
    row("m_old"),              // already a sale → stop here
    row("m_older"),            // new, but behind the stop point
  ]);
  assert.deepEqual(r.rows.map((x) => x.reviewState), ["new", "discarded", "invalid", "recorded", "new"]);
  assert.equal(r.rows[0].productId, "p1");
  assert.equal(r.rows[0].productTitle, "Tee");
  assert.equal(r.rows[1].productId, null);
  assert.equal(r.firstRecordedIndex, 3);
});

test("reviewMercariSales: all new → firstRecordedIndex null (keep scrolling)", async () => {
  const db = await seed();
  const r = await reviewMercariSalesCore(db, "u1", [row("m_a"), row("m_b")]);
  assert.equal(r.firstRecordedIndex, null);
});

test("setMercariSalesDiscarded: Restore removes the tombstone", async () => {
  const db = await seed();
  await setMercariSalesDiscardedCore(db, "u1", [{ mercariItemId: "m_x" }], true);
  assert.equal((await reviewMercariSalesCore(db, "u1", [row("m_x")])).rows[0].reviewState, "discarded");
  await setMercariSalesDiscardedCore(db, "u1", [{ mercariItemId: "m_x" }], false);
  assert.equal((await reviewMercariSalesCore(db, "u1", [row("m_x")])).rows[0].reviewState, "new");
});

test("mercariPointerPatch: fills an empty product pointer; never overwrites an existing one", () => {
  assert.deepEqual(mercariPointerPatch({ title: "x" }, null, "m1"), { crossPostListingIds: { mercari: "m1" } });
  assert.deepEqual(
    mercariPointerPatch({ crossPostListingIds: { ebay: "e1" } }, null, "m1"),
    { crossPostListingIds: { ebay: "e1", mercari: "m1" } },
  );
  assert.equal(mercariPointerPatch({ crossPostListingIds: { mercari: "live" } }, null, "m1"), null);
  assert.equal(mercariPointerPatch({ mercariListingId: "legacy" }, null, "m1"), null);
});

test("mercariPointerPatch: variant link rebuilds the WHOLE variants array, other variants untouched", () => {
  const product = { variants: [{ sku: "S", price: 1 }, { sku: "M", price: 2, crossPostListingIds: { mercari: "mM" } }] };
  const patch = mercariPointerPatch(product, "S", "m1");
  assert.equal(patch.variants.length, 2);
  assert.equal(patch.variants[0].crossPostListingIds.mercari, "m1");
  assert.equal(patch.variants[0].price, 1);
  assert.deepEqual(patch.variants[1], product.variants[1]);
  assert.equal(mercariPointerPatch(product, "M", "m2"), null);   // already linked
});

// ── cross-tenant guards (security review 2026-11-12) ───────────────────────

test("reviewMercariSales: another user's sale with the same id is NOT 'recorded' for me", async () => {
  const db = await seed();
  await db.collection("sales").doc("mercari_m_shared").set({ userId: "someone_else" });
  await db.collection("sales").doc("mercari_m_mine").set({ userId: "u1" });
  const r = await reviewMercariSalesCore(db, "u1", [row("m_shared"), row("m_mine")]);
  assert.deepEqual(r.rows.map((x) => x.reviewState), ["new", "recorded"]);
  assert.equal(r.firstRecordedIndex, 1);
});

test("recordSaleCore: an order id held by another account never touches it, and the caller's sale still records", async () => {
  const db = new FakeFirestore();
  await db.collection("sales").doc("mercari_o1").set({ userId: "victim", priceSoldFor: 50, buyerName: "Real Buyer" });
  const { _internal: s } = require("../sales");
  const r = await s.recordSaleCore(db, "attacker", { platform: "mercari", platformOrderId: "o1", soldPrice: 1, buyerName: "Evil" }, null);
  assert.equal(r.created, true);
  assert.equal(r.saleId, "attacker_mercari_o1");
  const victim = (await db.collection("sales").doc("mercari_o1").get()).data();
  assert.deepEqual([victim.userId, victim.priceSoldFor, victim.buyerName], ["victim", 50, "Real Buyer"]);
  // and the attacker re-recording stays on their own doc
  const again = await s.recordSaleCore(db, "attacker", { platform: "mercari", platformOrderId: "o1", soldPrice: 2 }, null);
  assert.deepEqual([again.saleId, again.created], ["attacker_mercari_o1", false]);
});

test("resolveSaleId: free or own plain id is kept (existing sales dedupe unchanged)", async () => {
  const db = new FakeFirestore();
  const { _internal: s } = require("../sales");
  assert.equal(await s.resolveSaleId(db, "u1", "ebay", "9"), "ebay_9");
  await db.collection("sales").doc("ebay_9").set({ userId: "u1" });
  assert.equal(await s.resolveSaleId(db, "u1", "ebay", "9"), "ebay_9");
  assert.equal(await s.resolveSaleId(db, "u2", "ebay", "9"), "u2_ebay_9");
});

test("recordSaleCore: backstop refuses a pre-planted doc at the caller's prefixed id, and leaves it untouched", async () => {
  const db = new FakeFirestore();
  const { _internal: s } = require("../sales");
  await db.collection("sales").doc("mercari_o2").set({ userId: "victim" });
  // attacker guessed the victim's prefixed id and planted a doc there
  await db.collection("sales").doc("victim_mercari_o2").set({ userId: "attacker", priceSoldFor: 1 });
  // victim syncs: plain id is taken by someone else's doc? no, it is theirs -> plain id used
  const r = await s.recordSaleCore(db, "victim", { platform: "mercari", platformOrderId: "o2", soldPrice: 9 }, null);
  assert.equal(r.saleId, "mercari_o2");
  // now the case that reaches the backstop: plain id held by a third party, prefixed id planted
  await db.collection("sales").doc("mercari_o3").set({ userId: "third" });
  await db.collection("sales").doc("victim_mercari_o3").set({ userId: "attacker", priceSoldFor: 1 });
  await assert.rejects(
    s.recordSaleCore(db, "victim", { platform: "mercari", platformOrderId: "o3", soldPrice: 9 }, null),
    (e) => e.code === "aborted" && !/account|attacker|third/i.test(e.message),
  );
  assert.equal((await db.collection("sales").doc("victim_mercari_o3").get()).data().priceSoldFor, 1);
});

// ── auto-import + review inbox (2026-11-14) ────────────────────────────────

const {
  recordMercariSalesBatchCore, undoMercariAutoImportCore, suggestProduct, missingFields, readInbox, loadProducts,
} = _internal;

const full = (id, extra = {}) => ({ mercariItemId: id, priceSoldFor: 20, title: `t ${id}`, soldAt: "2026-11-12T10:00:00Z", ...extra });

async function seedStock() {
  const db = new FakeFirestore();
  await db.collection("products").doc("p1").set({ userId: "u1", title: "Tee", quantity: 3, crossPostListingIds: { mercari: "m_known" } });
  await db.collection("products").doc("p2").set({ userId: "u1", title: "Seventeen Carat Bong lightstick ver 2", quantity: 1 });
  return db;
}
const stock = async (db, id) => (await db.collection("products").doc(id).get()).data().quantity;
const inboxDoc = async (db, key) => (await db.collection("users").doc("u1").collection("mercariSaleInbox").doc(key).get()).data();

test("missingFields: title, price > 0 and a readable date are required", () => {
  assert.deepEqual(missingFields(full("m1")), []);
  assert.deepEqual(missingFields({ mercariItemId: "m1" }), ["title", "price", "date"]);
  assert.deepEqual(missingFields({ mercariItemId: "m1", title: " ", priceSoldFor: 0, soldDate: "7/8/2026" }), ["title", "price"]);
});

test("suggestProduct: best word overlap ≥ 60%, unique; ties and weak overlaps suggest nothing", () => {
  const list = [{ id: "a", data: { title: "Seventeen Carat Bong lightstick ver 2" } }, { id: "b", data: { title: "Stray Kids album" } }];
  assert.equal(suggestProduct("Seventeen lightstick ver 2", list).productId, "a");
  assert.equal(suggestProduct("Phone case clear", list), null);
  const tied = [{ id: "a", data: { title: "Stray Kids Karma" } }, { id: "b", data: { title: "Stray Kids Karma" } }];
  assert.equal(suggestProduct("Stray Kids Karma photocard", tied), null);
});

test("autoImport: an id-matched complete row is recorded now, lowers stock, and is marked undoable", async () => {
  const db = await seedStock();
  const r = await reviewMercariSalesCore(db, "u1", [full("m_known")], { autoImport: true });
  assert.equal(r.rows[0].reviewState, "autoRecorded");
  assert.equal(r.autoRecorded, 1);
  const sale = (await db.collection("sales").doc(r.rows[0].saleId).get()).data();
  assert.deepEqual([sale.productId, sale.autoImported, sale.priceSoldFor], ["p1", true, 20]);
  assert.equal(await stock(db, "p1"), 2);
  assert.equal(r.inbox.pending.length, 0);
});

test("autoImport: id-matched but missing its date waits in review (Needs info), nothing recorded", async () => {
  const db = await seedStock();
  const r = await reviewMercariSalesCore(db, "u1", [full("m_known", { soldAt: null })], { autoImport: true });
  assert.equal(r.rows[0].reviewState, "new");
  assert.deepEqual(r.rows[0].missing, ["date"]);
  assert.equal(await stock(db, "p1"), 3);
  assert.equal(r.inbox.pending[0].productId, "p1");
});

test("autoImport: a title-only match waits as Suggested; a price-less row is kept, not invalid", async () => {
  const db = await seedStock();
  const r = await reviewMercariSalesCore(db, "u1", [
    full("m_new", { title: "Seventeen lightstick ver 2" }),
    { mercariItemId: "m_noprice", title: "Wii remote" },
  ], { autoImport: true });
  assert.deepEqual(r.rows.map((x) => x.reviewState), ["new", "new"]);
  const byId = Object.fromEntries(r.inbox.pending.map((p) => [p.item.mercariItemId, p]));
  assert.equal(byId.m_new.suggestedProductId, "p2");
  assert.equal(byId.m_new.productId, null);
  assert.deepEqual(byId.m_noprice.missing, ["price", "date"]);
  assert.equal(await stock(db, "p2"), 1);
});

test("autoImport: pending rows survive a later refresh that never reaches them (stop-at-known safe)", async () => {
  const db = await seedStock();
  await reviewMercariSalesCore(db, "u1", [full("m_old_unlinked")], { autoImport: true });
  const r = await reviewMercariSalesCore(db, "u1", [full("m_newer")], { autoImport: true });
  assert.deepEqual(r.inbox.pending.map((p) => p.item.mercariItemId).sort(), ["m_newer", "m_old_unlinked"]);
});

test("autoImport: a re-scan keeps fields the earlier scrape had when the new one is blank", async () => {
  const db = await seedStock();
  await reviewMercariSalesCore(db, "u1", [{ mercariItemId: "m_x", title: "Thing", priceSoldFor: 9 }], { autoImport: true });
  await reviewMercariSalesCore(db, "u1", [{ mercariItemId: "m_x", soldDate: "11/10/2026" }], { autoImport: true });
  const stored = await inboxDoc(db, "mercari_m_x");
  assert.deepEqual([stored.item.title, stored.item.priceSoldFor, stored.item.soldDate], ["Thing", 9, "11/10/2026"]);
});

test("recordMercariSalesBatch: allowUnlinked records a no-product sale (no stock change) and clears the inbox row", async () => {
  const db = await seedStock();
  await reviewMercariSalesCore(db, "u1", [full("m_case", { title: "Phone case", quantity: 2 })], { autoImport: true });
  const old = await recordMercariSalesBatchCore(db, "u1", { items: [full("m_case")] });
  assert.equal(old.results[0].outcome, "no-match");
  const r = await recordMercariSalesBatchCore(db, "u1", { items: [full("m_case", { quantity: 2 })], allowUnlinked: true });
  assert.equal(r.results[0].outcome, "recorded");
  const sale = (await db.collection("sales").doc(r.results[0].saleId).get()).data();
  assert.deepEqual([sale.productId, sale.quantity], [null, 2]);
  assert.equal(await inboxDoc(db, "mercari_m_case"), undefined);
});

test("undoMercariAutoImport: deletes the sale, restores stock, row goes back to review", async () => {
  const db = await seedStock();
  const r = await reviewMercariSalesCore(db, "u1", [full("m_known")], { autoImport: true });
  const u = await undoMercariAutoImportCore(db, "u1", [{ mercariItemId: "m_known" }]);
  assert.equal(u.undone, 1);
  assert.equal((await db.collection("sales").doc(r.rows[0].saleId).get()).exists, false);
  assert.equal(await stock(db, "p1"), 3);
  assert.equal(u.inbox.pending[0].item.mercariItemId, "m_known");
});

test("regression: undoMercariAutoImport never deletes a sale the user imported by hand", async () => {
  const db = await seedStock();
  await recordMercariSalesBatchCore(db, "u1", { items: [full("m_known")] });
  const u = await undoMercariAutoImportCore(db, "u1", [{ mercariItemId: "m_known" }]);
  assert.equal(u.undone, 0);
  assert.equal((await db.collection("sales").doc("mercari_m_known").get()).exists, true);
});

test("Never import keeps the scraped row; Restore puts it straight back in review", async () => {
  const db = await seedStock();
  await reviewMercariSalesCore(db, "u1", [full("m_z")], { autoImport: true });
  await setMercariSalesDiscardedCore(db, "u1", [{ mercariItemId: "m_z" }], true);
  let inbox = await readInbox(db, "u1", await loadProducts(db, "u1"));
  assert.deepEqual([inbox.pending.length, inbox.discarded[0].item.title], [0, "t m_z"]);
  await setMercariSalesDiscardedCore(db, "u1", [{ mercariItemId: "m_z" }], false);
  inbox = await readInbox(db, "u1", await loadProducts(db, "u1"));
  assert.equal(inbox.pending[0].item.mercariItemId, "m_z");
});
