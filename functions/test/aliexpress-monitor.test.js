/**
 * aliexpress-monitor.test.js — daily AliExpress price/stock check.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { HttpsError } = require("firebase-functions/v2/https");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal: M } = require("../aliexpress_monitor");

const fresh = (price, stocks) => ({ price, variants: stocks.map((stock, i) => ({ skuId: String(i + 1), stock, price })) });

test("compareSource: price moves under $0.25 or 5% are noise", () => {
  assert.equal(M.compareSource({ sourcePrice: 10 }, fresh(10.2, [5]), 1).sourceAlert, null);
  assert.equal(M.compareSource({ sourcePrice: 100 }, fresh(103, [5]), 1).sourceAlert, null, "3% of $100");
  assert.equal(M.compareSource({ sourcePrice: 10 }, fresh(12.1, [5]), 1).sourceAlert, "AliExpress price went up $2.10");
  assert.equal(M.compareSource({ sourcePrice: 10 }, fresh(8, [5]), 1).sourceAlert, "AliExpress price went down $2.00");
});

test("compareSource: variant and whole-product stock-outs; variants array refreshed whole", () => {
  const product = { sourcePrice: 5, variants: [
    { id: "a", sourceVariantId: "1", quantity: 2 }, { id: "b", sourceVariantId: "2", quantity: 1 }, { id: "c", quantity: 3 },
  ] };
  const one = M.compareSource(product, fresh(5, [0, 9]), 1);
  assert.equal(one.sourceAlert, "1 variant out of stock at source");
  assert.deepEqual(one.sourceCheck.outOfStockVariantIds, ["a"]);
  assert.deepEqual(one.variants.map((v) => [v.id, v.quantity, v.sourceStock]), [["a", 2, 0], ["b", 1, 9], ["c", 3, undefined]]);
  assert.equal(M.compareSource(product, fresh(5, [0, 0]), 1).sourceAlert, "Out of stock at source");
});

test("compareSource: a product gone from AliExpress", () => {
  const r = M.compareSource({ sourcePrice: 3 }, null, 7);
  assert.equal(r.sourceAlert, "No longer on AliExpress");
  assert.equal(r.sourceCheck.gone, true);
});

test("checkAliexpressSourcesForUser: oldest-checked first, capped, never touches price/quantity/listings", async () => {
  const db = new FakeFirestore({ products: {
    old: { userId: "u", source: "aliexpress", aliexpressProductId: "11", sourcePrice: 10, quantity: 4, listingPrice: 25, sourceCheck: { checkedAt: 1 } },
    never: { userId: "u", source: "aliexpress", sourceId: "22", sourcePrice: 10 },
    recent: { userId: "u", source: "aliexpress", aliexpressProductId: "33", sourcePrice: 10, sourceCheck: { checkedAt: 99 } },
    weverse: { userId: "u", source: "weverse", sourceId: "44" },
    other: { userId: "x", source: "aliexpress", aliexpressProductId: "55" },
  } });
  const seen = [];
  const fetchProduct = async (id) => {
    seen.push(id);
    if (id === "22") throw new HttpsError("not-found", "gone");
    return fresh(13, [3]);
  };
  const r = await M.checkAliexpressSourcesForUser(db, "u", { fetchProduct, now: () => 500, limit: 2 });
  assert.deepEqual(seen, ["22", "11"]);
  assert.deepEqual(r, { checked: 2, flagged: 2, failed: 0 });
  const p = db.peek("products", "old");
  assert.equal(p.sourceAlert, "AliExpress price went up $3.00");
  assert.deepEqual([p.sourcePrice, p.quantity, p.listingPrice], [10, 4, 25]);
  assert.equal(db.peek("products", "never").sourceAlert, "No longer on AliExpress");
});

test("checkAliexpressSourcesForUser: an auth failure stops the run; other errors skip one product", async () => {
  const db = new FakeFirestore({ products: {
    a: { userId: "u", source: "aliexpress", aliexpressProductId: "1" },
    b: { userId: "u", source: "aliexpress", aliexpressProductId: "2" },
  } });
  const flaky = async (id) => { if (id === "1") throw new Error("timeout"); return fresh(1, [1]); };
  assert.deepEqual(await M.checkAliexpressSourcesForUser(db, "u", { fetchProduct: flaky }), { checked: 1, flagged: 0, failed: 1 });
  const auth = async () => { throw new HttpsError("failed-precondition", "Reconnect AliExpress"); };
  await assert.rejects(M.checkAliexpressSourcesForUser(db, "u", { fetchProduct: auth }), /Reconnect/);
});
