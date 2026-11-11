"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
process.env.EBAY_CLIENT_ID = "x";
process.env.EBAY_CLIENT_SECRET = "y";
const { _internal } = require("../ebay_listing");
const { pushEbayEdit, mapLimit } = _internal;

const calls = () => {
  const log = [];
  return { log, deps: { pushMulti: async () => { log.push("multi"); }, pushSingle: async () => { log.push("single"); } } };
};

test("regression: a multi-variation product is pushed through the item-group flow, not rejected as unimplemented", async () => {
  const { log, deps } = calls();
  const product = {
    options: [{ name: "Size", values: ["S", "M"] }],
    variants: [
      { id: "a", optionValues: { Size: "S" }, active: true },
      { id: "b", optionValues: { Size: "M" }, active: true },
    ],
  };
  await pushEbayEdit("u", product, "p1", {}, deps);
  assert.deepEqual(log, ["multi"]);
});

test("a listing already posted as an item group stays multi even if variants were trimmed to one", async () => {
  const { log, deps } = calls();
  await pushEbayEdit("u", { ebayInventoryItemGroupKey: "p1", variants: [] }, "p1", {}, deps);
  assert.deepEqual(log, ["multi"]);
});

test("a single-variant product still takes the single-offer path", async () => {
  const { log, deps } = calls();
  await pushEbayEdit("u", { title: "x", quantity: 1 }, "p1", {}, deps);
  assert.deepEqual(log, ["single"]);
});

test("mapLimit: never exceeds the concurrency limit, keeps result order, handles 250 items", async () => {
  let inFlight = 0, peak = 0;
  const items = Array.from({ length: 250 }, (_, i) => i);
  const out = await mapLimit(items, 8, async (n) => {
    inFlight++; peak = Math.max(peak, inFlight);
    await new Promise((r) => setImmediate(r));
    inFlight--;
    return n * 2;
  });
  assert.equal(peak <= 8, true);
  assert.deepEqual(out, items.map((n) => n * 2));
});
