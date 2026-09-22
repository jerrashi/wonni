/**
 * stock-watch-diff.test.js — diffSnapshot() is a pure function: plain
 * StockSnapshot fixtures in, typed event arrays out. No network / DB.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { diffSnapshot } = require("../stock_watch/diff_snapshot");

function snapshot(overrides = {}) {
  return {
    platform: "weverse",
    url: "https://shop.weverse.io/en/shop/USD/artists/255/sales/64536",
    sourceId: "64536",
    title: "RM Jersey",
    description: "",
    images: [],
    inStock: true,
    quantityAvailable: 5,
    price: 55,
    currency: "USD",
    variants: [
      { optionValues: { Style: "RM", Size: "M-L" }, sku: "w-1", inStock: true, quantityAvailable: 5, price: 55 },
    ],
    fetchedAt: 1000,
    ...overrides,
  };
}

test("no previous snapshot -> new-item", () => {
  const events = diffSnapshot(null, snapshot());
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "new-item");
  assert.equal(events[0].sourceId, "64536");
});

test("nothing changed -> empty events", () => {
  const prev = snapshot();
  const curr = snapshot({ fetchedAt: 2000 }); // fetchedAt never drives events
  assert.deepEqual(diffSnapshot(prev, curr), []);
});

test("was out of stock, now in stock -> back-in-stock", () => {
  const prev = snapshot({ inStock: false });
  const curr = snapshot({ inStock: true });
  const events = diffSnapshot(prev, curr);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "back-in-stock");
});

test("was in stock, now out of stock -> sold-out", () => {
  const prev = snapshot({ inStock: true });
  const curr = snapshot({ inStock: false });
  const events = diffSnapshot(prev, curr);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "sold-out");
});

test("price differs -> price-changed, with before/after", () => {
  const prev = snapshot({ price: 55 });
  const curr = snapshot({ price: 60 });
  const events = diffSnapshot(prev, curr);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "price-changed");
  assert.equal(events[0].previousPrice, 55);
  assert.equal(events[0].price, 60);
});

test("a new option combo appears -> variant-added (existing variants untouched)", () => {
  const prev = snapshot({
    variants: [{ optionValues: { Style: "RM", Size: "M-L" }, sku: "w-1", inStock: true, quantityAvailable: 5, price: 55 }],
  });
  const curr = snapshot({
    variants: [
      { optionValues: { Style: "RM", Size: "M-L" }, sku: "w-1", inStock: true, quantityAvailable: 5, price: 55 },
      { optionValues: { Style: "Jimin", Size: "M-L" }, sku: "w-2", inStock: true, quantityAvailable: 3, price: 55 },
    ],
  });
  const events = diffSnapshot(prev, curr);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "variant-added");
  assert.deepEqual(events[0].optionValues, { Style: "Jimin", Size: "M-L" });
});

test("variant-added ignores option key order", () => {
  const prev = snapshot({
    variants: [{ optionValues: { Size: "M-L", Style: "RM" }, sku: "w-1", inStock: true, quantityAvailable: 5, price: 55 }],
  });
  const curr = snapshot({
    variants: [{ optionValues: { Style: "RM", Size: "M-L" }, sku: "w-1", inStock: true, quantityAvailable: 5, price: 55 }],
  });
  assert.deepEqual(diffSnapshot(prev, curr), []);
});

test("multiple events can fire in the same diff", () => {
  const prev = snapshot({ inStock: true, price: 55, variants: [
    { optionValues: { Style: "RM", Size: "M-L" }, sku: "w-1", inStock: true, quantityAvailable: 5, price: 55 },
  ] });
  const curr = snapshot({ inStock: false, price: 60, variants: [
    { optionValues: { Style: "RM", Size: "M-L" }, sku: "w-1", inStock: false, quantityAvailable: 0, price: 60 },
    { optionValues: { Style: "Jimin", Size: "M-L" }, sku: "w-2", inStock: true, quantityAvailable: 2, price: 60 },
  ] });
  const events = diffSnapshot(prev, curr);
  const types = events.map((e) => e.type).sort();
  assert.deepEqual(types, ["price-changed", "sold-out", "variant-added"]);
});
