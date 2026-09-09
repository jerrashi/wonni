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

const { applyQuantityDelta, cascade, resolveStock, recordSaleCore, toTimestamp } = _internal;

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

test("regression: re-recording a sale does not stomp an advanced status", async () => {
  // Bug 2026-09-08: lifecycle fields were written unconditionally, so a poller
  // re-seeing an order reset status:"shipped" back to "pending".
  const product = plainProduct({ quantity: 3 });
  const db = new FakeFirestore({
    products: { p1: product },
    sales: {
      mercari_ORD1: {
        userId: UID, productId: "p1", platform: "mercari", platformOrderId: "ORD1",
        priceSoldFor: 20, status: "shipped", source: "mercari-scan",
        trackingNumber: "1Z-EXISTING",
      },
    },
  });
  const res = await recordSaleCore(db, UID, {
    platform: "mercari", productId: "p1", soldPrice: 22, platformOrderId: "ORD1", cascade: true,
  }, product);

  assert.equal(res.created, false);
  const sale = db.peek("sales", "mercari_ORD1");
  assert.equal(sale.status, "shipped", "lifecycle status must be preserved on re-record");
  assert.equal(sale.source, "mercari-scan", "source is a lifecycle field — preserved");
  assert.equal(sale.priceSoldFor, 22, "mutable fields still update");
  // NOTE (flagged 2026-09-09): a re-record DOES currently overwrite non-lifecycle
  // fields the caller left blank — e.g. trackingNumber → null. Only `status`,
  // `createdAt`, `source` are guarded. See BACKEND.md "re-record field policy".
  assert.equal(sale.trackingNumber, null);
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
