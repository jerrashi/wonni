/**
 * sales.test.js — unit coverage for the sale-write + quantity-cascade core.
 *
 * Runs on `node --test`, no emulator. Exercises the pure-ish `_internal`
 * functions from sales.js against the in-memory FakeFirestore. Every test
 * whose name starts "regression:" pins a bug found in review on 2026-09-08
 * (see memory `backend-consolidation`).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal } = require("../sales");

const {
  applyQuantityDelta, cascade, resolveStock, recordSaleCore, toTimestamp,
  shouldAdvanceStatus, applyMercariFlags,
} = _internal;

const UID = "user_1";

/** A no-variant product with `quantity` in stock. */
function plainProduct(overrides = {}) {
  return {
    userId: UID,
    title: "Plain Tee",
    images: ["https://cdn.example/tee.jpg"],
    quantity: 3,
    saleStatus: "active",
    crossPostStatus: {},
    ...overrides,
  };
}

/** A 2-variant product (S / M), each with its own quantity + eBay pointers. */
function variantProduct(overrides = {}) {
  return {
    userId: UID,
    title: "Variant Tee",
    hasVariants: true,
    variants: [
      { id: "vS", sku: "TEE-S", quantity: 2, active: true, optionValues: { Size: "S" } },
      { id: "vM", sku: "TEE-M", quantity: 4, active: true, optionValues: { Size: "M" } },
    ],
    saleStatus: "active",
    crossPostStatus: {},
    ...overrides,
  };
}

// ── resolveStock ────────────────────────────────────────────────────────────

test("resolveStock: no-variant product reads product.quantity", () => {
  assert.deepEqual(resolveStock(plainProduct({ quantity: 5 }), null), {
    scope: "product",
    qty: 5,
    variantIndex: -1,
  });
});

test("resolveStock: no-variant product with no quantity defaults to 1", () => {
  const p = plainProduct();
  delete p.quantity;
  assert.equal(resolveStock(p, null).qty, 1);
});

test("resolveStock: variant product resolves the matching sku", () => {
  const r = resolveStock(variantProduct(), "TEE-M");
  assert.equal(r.scope, "variant");
  assert.equal(r.qty, 4);
  assert.equal(r.variantIndex, 1);
});

test("resolveStock: variant product with no sku / unknown sku → qty null", () => {
  assert.equal(resolveStock(variantProduct(), null).qty, null);
  assert.equal(resolveStock(variantProduct(), "TEE-XL").qty, null);
});

// ── applyQuantityDelta ──────────────────────────────────────────────────────

test("applyQuantityDelta: decrements a no-variant product and flips status at 0", async () => {
  const db = new FakeFirestore({ products: { p1: plainProduct({ quantity: 1 }) } });
  const r = await applyQuantityDelta(db, "p1", UID, null, -1);
  assert.equal(r.previousQuantity, 1);
  assert.equal(r.newQuantity, 0);
  assert.equal(r.soldOut, true);
  assert.equal(db.peek("products", "p1").quantity, 0);
  assert.equal(db.peek("products", "p1").saleStatus, "sold");
});

test("applyQuantityDelta: decrement never goes below zero", async () => {
  const db = new FakeFirestore({ products: { p1: plainProduct({ quantity: 0 }) } });
  const r = await applyQuantityDelta(db, "p1", UID, null, -1);
  assert.equal(r.newQuantity, 0);
});

test("applyQuantityDelta: variant decrement only touches its own variant, keeps the array", async () => {
  const db = new FakeFirestore({ products: { p1: variantProduct() } });
  const r = await applyQuantityDelta(db, "p1", UID, "TEE-S", -1);
  assert.equal(r.newQuantity, 1);
  const stored = db.peek("products", "p1");
  assert.ok(Array.isArray(stored.variants), "variants must stay an array");
  assert.equal(stored.variants[0].quantity, 1);
  assert.equal(stored.variants[1].quantity, 4, "other variant untouched");
  assert.equal(stored.saleStatus, "active", "still stock in TEE-M");
});

test("applyQuantityDelta: variant product goes sold only when every active variant hits 0", async () => {
  const db = new FakeFirestore({
    products: { p1: variantProduct({ variants: [
      { id: "vS", sku: "TEE-S", quantity: 1, active: true },
      { id: "vM", sku: "TEE-M", quantity: 0, active: true },
    ] }) },
  });
  const r = await applyQuantityDelta(db, "p1", UID, "TEE-S", -1);
  assert.equal(r.newQuantity, 0);
  assert.equal(db.peek("products", "p1").saleStatus, "sold");
});

test("applyQuantityDelta: rejects a product owned by someone else", async () => {
  const db = new FakeFirestore({ products: { p1: plainProduct({ userId: "someone_else" }) } });
  await assert.rejects(() => applyQuantityDelta(db, "p1", UID, null, -1), /Not your product/);
});

test("regression: applyQuantityDelta on a variant product with no sku SKIPS (must not push qty 0)", async () => {
  // Bug 2026-09-08: this returned newQuantity:null which the cascade treated as
  // 0 and pushed to eBay/Etsy, deactivating a live multi-variant listing.
  const db = new FakeFirestore({ products: { p1: variantProduct() } });
  const r = await applyQuantityDelta(db, "p1", UID, null, -1);
  assert.equal(r.skipped, "no-variant-match");
  assert.equal(r.newQuantity, null);
  // nothing written
  assert.deepEqual(db.peek("products", "p1").variants.map((v) => v.quantity), [2, 4]);
});

test("regression: zeroAll zeros every active variant (markSoldOutAndCascade path)", async () => {
  // Bug 2026-09-08: markSoldOut on a variant product only zeroed one bucket.
  const db = new FakeFirestore({ products: { p1: variantProduct({ variants: [
    { id: "vS", sku: "TEE-S", quantity: 2, active: true },
    { id: "vM", sku: "TEE-M", quantity: 4, active: true },
    { id: "vL", sku: "TEE-L", quantity: 9, active: false },
  ] }) } });
  const r = await applyQuantityDelta(db, "p1", UID, null, 0, { zeroAll: true });
  assert.equal(r.soldOut, true);
  const stored = db.peek("products", "p1");
  assert.deepEqual(stored.variants.map((v) => v.quantity), [0, 0, 9], "inactive variant left alone");
  assert.equal(stored.saleStatus, "sold");
});

// ── cascade ─────────────────────────────────────────────────────────────────

test("cascade: skips every platform that isn't active", async () => {
  const db = new FakeFirestore({ products: { p1: plainProduct() } });
  const r = await cascade(db, UID, plainProduct(), "p1", {
    variantSku: null, newQuantity: 2, soldOut: false, soldOnPlatform: "manual",
  });
  assert.deepEqual(r.platforms, { ebay: "skipped", etsy: "skipped", tiktok: "skipped", mercari: "skipped" });
});

test("regression: a Mercari-origin sale still sets pendingMercariRelist", async () => {
  // Bug 2026-09-08: the cascade for-loop `continue`d on p === soldOnPlatform,
  // so a sale that happened ON Mercari never got its relist flag — dead code.
  const product = plainProduct({ crossPostStatus: { mercari: "active" } });
  const db = new FakeFirestore({ products: { p1: product } });
  const r = await cascade(db, UID, product, "p1", {
    variantSku: null, newQuantity: 2, soldOut: false, soldOnPlatform: "mercari",
  });
  assert.equal(r.platforms.mercari, "pending-manual");
  assert.equal(db.peek("products", "p1").pendingMercariRelist, true);
});

test("cascade: a Mercari listing that sold out gets pendingMercariDeactivation", async () => {
  const product = plainProduct({ crossPostStatus: { mercari: "active" } });
  const db = new FakeFirestore({ products: { p1: product } });
  await cascade(db, UID, product, "p1", {
    variantSku: null, newQuantity: 0, soldOut: true, soldOnPlatform: "ebay",
  });
  assert.equal(db.peek("products", "p1").pendingMercariDeactivation, true);
});

// ── per-variation Mercari flags (one Mercari listing per size) ───────────────

/** Variant product where each variant is its own Mercari listing. */
function mercariVariantProduct(overrides = {}) {
  return {
    userId: UID, title: "Mercari Variant Tee", hasVariants: true,
    variants: [
      { id: "vS", sku: "TEE-S", quantity: 2, active: true, crossPostListingIds: { mercari: "m_s" } },
      { id: "vM", sku: "TEE-M", quantity: 4, active: true, crossPostListingIds: { mercari: "m_m" } },
    ],
    crossPostStatus: {}, saleStatus: "active", ...overrides,
  };
}

test("cascade: one variant selling out flags only that variant's Mercari listing", async () => {
  const product = mercariVariantProduct({ variants: [
    { id: "vS", sku: "TEE-S", quantity: 0, active: true, crossPostListingIds: { mercari: "m_s" } },
    { id: "vM", sku: "TEE-M", quantity: 4, active: true, crossPostListingIds: { mercari: "m_m" } },
  ] });
  const db = new FakeFirestore({ products: { p1: product } });
  const r = await cascade(db, UID, product, "p1", {
    variantSku: "TEE-S", newQuantity: 0, soldOut: false, soldOnPlatform: "ebay",
  });
  assert.equal(r.platforms.mercari, "pending-manual");
  const v = db.peek("products", "p1").variants;
  assert.equal(v[0].pendingMercariDeactivation, true);
  assert.equal(v[1].pendingMercariDeactivation, undefined, "in-stock variant untouched");
  assert.equal(db.peek("products", "p1").pendingMercariDeactivation, undefined, "not a whole-product flag");
});

test("cascade: a Mercari-origin variant sale with stock left flags that variant for relist", async () => {
  const product = mercariVariantProduct();
  const db = new FakeFirestore({ products: { p1: product } });
  await cascade(db, UID, product, "p1", {
    variantSku: "TEE-M", newQuantity: 3, soldOut: false, soldOnPlatform: "mercari",
  });
  const v = db.peek("products", "p1").variants;
  assert.equal(v[1].pendingMercariRelist, true);
  assert.equal(v[0].pendingMercariRelist, undefined);
});

test("regression: GUI mark-out-of-stock deactivates EVERY per-variation Mercari listing", async () => {
  // The user flow: "mark out of stock" in the Wonni GUI on a product that's on
  // Mercari must end all of its per-size listings, not just one.
  const product = mercariVariantProduct({ variants: [
    { id: "vS", sku: "TEE-S", quantity: 0, active: true, crossPostListingIds: { mercari: "m_s" } },
    { id: "vM", sku: "TEE-M", quantity: 0, active: true, crossPostListingIds: { mercari: "m_m" } },
  ] });
  const db = new FakeFirestore({ products: { p1: product } });
  await cascade(db, UID, product, "p1", {
    variantSku: null, newQuantity: 0, soldOut: true, soldOnPlatform: null,
  });
  const v = db.peek("products", "p1").variants;
  assert.equal(v[0].pendingMercariDeactivation, true);
  assert.equal(v[1].pendingMercariDeactivation, true);
});

test("applyMercariFlags: no-op when the product/variant has no Mercari listing", () => {
  const upd = {};
  assert.equal(
    applyMercariFlags(variantProduct(), upd, { variantSku: "TEE-S", soldOut: false, soldOnPlatform: "ebay" }),
    "skipped",
  );
  assert.deepEqual(upd, {});
});

// ── recordSaleCore ──────────────────────────────────────────────────────────

test("recordSaleCore: new sale writes the canonical doc + decrements stock", async () => {
  const product = plainProduct({ quantity: 3, tags: ["kpop", "tee"] });
  const db = new FakeFirestore({ products: { p1: product } });
  const { saleId, created, cascade: casc } = await recordSaleCore(db, UID, {
    platform: "manual",
    productId: "p1",
    soldPrice: 25,
    quantity: 1,
    source: "manual",
    cascade: true,
  }, product);

  assert.equal(created, true);
  const sale = db.peek("sales", saleId);
  assert.equal(sale.priceSoldFor, 25);
  assert.equal(sale.userId, UID);
  assert.equal(sale.listingTitle, "Plain Tee");
  assert.equal(sale.thumbnailUrl, "https://cdn.example/tee.jpg");
  assert.deepEqual(sale.productTags, ["kpop", "tee"]);
  assert.equal(sale.status, "pending");
  assert.equal(sale.source, "manual");
  assert.equal(db.peek("products", "p1").quantity, 2);
  assert.equal(casc.previousQuantity, 3);
  assert.equal(casc.newQuantity, 2);
});

test("recordSaleCore: dedupes on platform + platformOrderId", async () => {
  const product = plainProduct({ quantity: 3 });
  const db = new FakeFirestore({ products: { p1: product } });
  const first = await recordSaleCore(db, UID, {
    platform: "mercari", productId: "p1", soldPrice: 20, platformOrderId: "ORD9", cascade: true,
  }, product);
  const second = await recordSaleCore(db, UID, {
    platform: "mercari", productId: "p1", soldPrice: 20, platformOrderId: "ORD9", cascade: true,
  }, db.peek("products", "p1"));

  assert.equal(first.created, true);
  assert.equal(second.created, false);
  assert.equal(first.saleId, "mercari_ORD9");
  assert.equal(db.peek("products", "p1").quantity, 2, "second call must NOT decrement again");
});

test("regression: re-recording a sale is merge-ADD only", async () => {
  // Bug 2026-09-08: lifecycle fields written unconditionally reset shipped→pending.
  // Fix 2026-09-09: a re-record backfills snapshots, overwrites mutable fields
  // only when it carries a value, and never nulls stored data.
  const product = plainProduct({ quantity: 3 });
  const db = new FakeFirestore({
    products: { p1: product },
    sales: {
      mercari_ORD1: {
        userId: UID, productId: "p1", platform: "mercari", platformOrderId: "ORD1",
        priceSoldFor: 20, quantity: 1, status: "shipped", source: "mercari-scan",
        createdAt: "T0", trackingNumber: "1Z-EXISTING", carrier: "USPS",
        listingTitle: "Frozen Title",
      },
    },
  });
  const res = await recordSaleCore(db, UID, {
    platform: "mercari", productId: "p1", soldPrice: 22, platformOrderId: "ORD1", cascade: true,
  }, product);

  assert.equal(res.created, false);
  const sale = db.peek("sales", "mercari_ORD1");
  assert.equal(sale.status, "shipped", "lifecycle status preserved");
  assert.equal(sale.source, "mercari-scan", "source preserved");
  assert.equal(sale.createdAt, "T0", "createdAt preserved");
  assert.equal(sale.trackingNumber, "1Z-EXISTING", "blank pass does NOT null stored tracking");
  assert.equal(sale.carrier, "USPS");
  assert.equal(sale.listingTitle, "Frozen Title", "snapshot fields are not refreshed once set");
  assert.equal(sale.priceSoldFor, 22, "a value the pass carries still overwrites");
});

test("re-record: a pass WITH a value overwrites; forward status advances; backfills fill gaps", async () => {
  const db = new FakeFirestore({
    sales: {
      ebay_A1: {
        userId: UID, productId: "p1", platform: "ebay", platformOrderId: "A1",
        priceSoldFor: 40, quantity: 1, status: "pending", source: "ebay-poll", createdAt: "T0",
      },
    },
  });
  await recordSaleCore(db, UID, {
    platform: "ebay", productId: "p1", soldPrice: 40, platformOrderId: "A1",
    trackingNumber: "1Z999", carrier: "UPS", takeHome: 33.5, status: "shipped",
    listingTitle: "Backfilled Title",
  }, null);

  const sale = db.peek("sales", "ebay_A1");
  assert.equal(sale.status, "shipped", "pending → shipped advances");
  assert.equal(sale.trackingNumber, "1Z999");
  assert.equal(sale.takeHome, 33.5);
  assert.equal(sale.listingTitle, "Backfilled Title", "snapshot backfilled because it was absent");
});

test("re-record: status never moves backward or out of a terminal state", async () => {
  const db = new FakeFirestore({
    sales: {
      ebay_A1: { userId: UID, platform: "ebay", platformOrderId: "A1", priceSoldFor: 10, status: "complete" },
      ebay_A2: { userId: UID, platform: "ebay", platformOrderId: "A2", priceSoldFor: 10, status: "cancelled" },
    },
  });
  await recordSaleCore(db, UID, { platform: "ebay", soldPrice: 10, platformOrderId: "A1", status: "shipped" }, null);
  await recordSaleCore(db, UID, { platform: "ebay", soldPrice: 10, platformOrderId: "A2", status: "shipped" }, null);
  assert.equal(db.peek("sales", "ebay_A1").status, "complete", "no backward move");
  assert.equal(db.peek("sales", "ebay_A2").status, "cancelled", "terminal state sticks");
});

test("re-record: a sale that reappears through sync is un-deleted", async () => {
  const db = new FakeFirestore({
    sales: {
      ebay_A1: {
        userId: UID, platform: "ebay", platformOrderId: "A1", priceSoldFor: 10,
        status: "pending", isDeleted: true, deletedAt: "T0",
      },
    },
  });
  await recordSaleCore(db, UID, { platform: "ebay", soldPrice: 10, platformOrderId: "A1" }, null);
  const sale = db.peek("sales", "ebay_A1");
  assert.equal(sale.isDeleted, undefined);
  assert.equal(sale.deletedAt, undefined);
});

test("re-record: soldAt is not overwritten by a pass that omits it", async () => {
  const original = toTimestamp("2026-01-01T00:00:00.000Z");
  const db = new FakeFirestore({
    sales: {
      ebay_A1: {
        userId: UID, platform: "ebay", platformOrderId: "A1", priceSoldFor: 10,
        status: "pending", soldAt: { _seconds: original.seconds, _nanoseconds: 0 },
      },
    },
  });
  await recordSaleCore(db, UID, { platform: "ebay", soldPrice: 10, platformOrderId: "A1" }, null);
  assert.equal(db.peek("sales", "ebay_A1").soldAt._seconds, original.seconds, "original sold time kept");
});

test("shouldAdvanceStatus: forward-only, terminal-wins", () => {
  assert.equal(shouldAdvanceStatus("pending", "shipped"), true);
  assert.equal(shouldAdvanceStatus("shipped", "pending"), false);
  assert.equal(shouldAdvanceStatus("pending", "cancelled"), true);
  assert.equal(shouldAdvanceStatus("complete", "shipped"), false);
  assert.equal(shouldAdvanceStatus("cancelled", "shipped"), false);
  assert.equal(shouldAdvanceStatus("pending", null), false);
  assert.equal(shouldAdvanceStatus("pending", "bogus"), false);
});

test("regression: recordSaleCore on a variant product with no sku records the sale but skips the cascade", async () => {
  const product = variantProduct();
  const db = new FakeFirestore({ products: { p1: product } });
  const { created, cascade: casc } = await recordSaleCore(db, UID, {
    platform: "manual", productId: "p1", soldPrice: 30, cascade: true,
  }, product);

  assert.equal(created, true);
  assert.equal(casc.newQuantity, null, "no bucket to decrement");
  assert.deepEqual(db.peek("products", "p1").variants.map((v) => v.quantity), [2, 4], "stock untouched");
});

test("recordSaleCore: cascade:false records the sale without touching stock", async () => {
  const product = plainProduct({ quantity: 3 });
  const db = new FakeFirestore({ products: { p1: product } });
  const { created, cascade: casc } = await recordSaleCore(db, UID, {
    platform: "manual", productId: "p1", soldPrice: 10, cascade: false,
  }, product);
  assert.equal(created, true);
  assert.equal(casc, null);
  assert.equal(db.peek("products", "p1").quantity, 3);
});

test("recordSaleCore: a manual sale with no product still writes a row", async () => {
  const db = new FakeFirestore({});
  const { saleId, created } = await recordSaleCore(db, UID, {
    platform: "manual", productId: null, soldPrice: 15, listingTitle: "Yard-sale mug", cascade: true,
  }, null);
  assert.equal(created, true);
  assert.equal(db.peek("sales", saleId).listingTitle, "Yard-sale mug");
  assert.equal(db.peek("sales", saleId).productId, null);
});

// ── toTimestamp ─────────────────────────────────────────────────────────────

test("toTimestamp: accepts null (→ now), epoch ms, and ISO strings", () => {
  assert.ok(toTimestamp(null));
  assert.equal(toTimestamp(1_700_000_000_000).toMillis(), 1_700_000_000_000);
  assert.equal(toTimestamp("2026-01-02T03:04:05.000Z").toDate().toISOString(), "2026-01-02T03:04:05.000Z");
});
