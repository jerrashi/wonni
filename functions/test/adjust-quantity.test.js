/**
 * adjust-quantity.test.js — bulk edit "Quantity: Remove / Set / Add"
 * (adjustQuantityAndCascade, 2026-11-28). No live platforms, so the cascade
 * makes no network calls.
 */
"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { FakeFirestore } = require("./helpers/fake-firestore");
const { planQuantityAdjustment, adjustQuantityCore } = require("../sales")._internal;

const UID = "user_1";
const plain = (q, extra = {}) => ({ userId: UID, title: "Muffler", quantity: q, saleStatus: "active", crossPostStatus: {}, ...extra });
const sized = (qs, extra = {}) => ({
  userId: UID, title: "Jersey", hasVariants: true, quantityVariesByVariant: true, saleStatus: "active", crossPostStatus: {},
  variants: qs.map((q, i) => ({ id: `v${i}`, sku: `SKU${i}`, quantity: q, active: true })), ...extra,
});

test("plan: remove never goes below 0; set and add", () => {
  assert.equal(planQuantityAdjustment(plain(3), "remove", 5).after, 0);
  assert.equal(planQuantityAdjustment(plain(3), "set", 15).after, 15);
  assert.equal(planQuantityAdjustment(plain(3), "add", 2).after, 5);
});

test("plan: shared pool with sizes changes the one number, not each size", () => {
  const p = sized([15, 15, 15, 15], { quantityVariesByVariant: false, quantity: 15 });
  const plan = planQuantityAdjustment(p, "add", 5);
  assert.equal(plan.perVariant, false);
  assert.equal(plan.after, 20);
});

test("plan: per-variant gives every active variant the same change", () => {
  const p = sized([3, 0, 2]);
  p.variants.push({ id: "off", sku: "OFF", quantity: 9, active: false });
  const plan = planQuantityAdjustment(p, "add", 5);
  assert.deepEqual(plan.changes.map((c) => c.after), [8, 5, 7]);
  assert.equal(plan.before, 5);
  assert.equal(plan.after, 20);
});

test("adjust: set on a plain product updates quantity", async () => {
  const db = new FakeFirestore({ products: { p1: plain(3) } });
  const r = await adjustQuantityCore(db, UID, { productId: "p1", mode: "set", amount: 15 });
  assert.equal(r.outcome, "updated");
  assert.equal(db.peek("products", "p1").quantity, 15);
});

test("adjust: reaching 0 is mark sold out (and remembers the old number)", async () => {
  const db = new FakeFirestore({ products: { p1: plain(4) } });
  const r = await adjustQuantityCore(db, UID, { productId: "p1", mode: "remove", amount: 10 });
  assert.equal(r.outcome, "sold-out");
  const stored = db.peek("products", "p1");
  assert.equal(stored.quantity, 0);
  assert.equal(stored.saleStatus, "sold");
  assert.equal(stored.quantityBeforeSoldOut, 4);
});

test("adjust: from 0 back up is a restock", async () => {
  const db = new FakeFirestore({ products: { p1: plain(0, { saleStatus: "sold", pendingMercariDeactivation: true }) } });
  const r = await adjustQuantityCore(db, UID, { productId: "p1", mode: "add", amount: 15 });
  assert.equal(r.outcome, "restocked");
  const stored = db.peek("products", "p1");
  assert.equal(stored.quantity, 15);
  assert.equal(stored.saleStatus, "active");
  assert.equal(stored.pendingMercariDeactivation, undefined);
});

test("adjust: per-variant changes each size; one size at 0 leaves the product active", async () => {
  const db = new FakeFirestore({ products: { p1: sized([3, 1, 2]) } });
  const r = await adjustQuantityCore(db, UID, { productId: "p1", mode: "remove", amount: 1 });
  assert.equal(r.outcome, "updated");
  const stored = db.peek("products", "p1");
  assert.deepEqual(stored.variants.map((v) => v.quantity), [2, 0, 1]);
  assert.equal(stored.saleStatus, "active");
});

test("adjust: unchanged when the number is already there", async () => {
  const db = new FakeFirestore({ products: { p1: plain(15) } });
  const r = await adjustQuantityCore(db, UID, { productId: "p1", mode: "set", amount: 15 });
  assert.equal(r.outcome, "unchanged");
});

test("adjust: someone else's product is refused", async () => {
  const db = new FakeFirestore({ products: { p1: plain(3, { userId: "other" }) } });
  await assert.rejects(adjustQuantityCore(db, UID, { productId: "p1", mode: "set", amount: 1 }), /Not your product/);
});
