"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { chunk, bulkPutInventoryItems, bulkCreateOffers } = require("../ebay_bulk");

test("chunk: 250 items → 10 calls of 25", () => {
  const c = chunk(Array.from({ length: 250 }, (_, i) => i));
  assert.equal(c.length, 10);
  assert.ok(c.every((x) => x.length === 25));
  assert.deepEqual(chunk([]), []);
});

test("bulkPutInventoryItems: 60 items → 3 bulk calls, nothing sent singly when all succeed", async () => {
  const calls = [];
  const request = async (m, path, body) => {
    calls.push([m, path]);
    return { responses: body.requests.map((r) => ({ sku: r.sku, statusCode: 200 })) };
  };
  await bulkPutInventoryItems(request, Array.from({ length: 60 }, (_, i) => ({ sku: `s${i}`, body: { x: i } })));
  assert.equal(calls.length, 3);
  assert.ok(calls.every(([m, p]) => m === "POST" && p.endsWith("bulk_create_or_replace_inventory_item")));
});

test("bulkPutInventoryItems: a failed row is retried singly so the real eBay error surfaces", async () => {
  const calls = [];
  const request = async (m, path, body) => {
    calls.push(`${m} ${path.split("/").pop()}`);
    if (m === "POST") return { responses: [{ sku: "a", statusCode: 200 }, { sku: "b", statusCode: 400 }] };
    if (path.endsWith("/b")) throw new Error("25002 bad aspect");
  };
  await assert.rejects(bulkPutInventoryItems(request, [{ sku: "a", body: {} }, { sku: "b", body: {} }]), /25002 bad aspect/);
  assert.deepEqual(calls, ["POST bulk_create_or_replace_inventory_item", "PUT b"]);
});

test("bulkPutInventoryItems: if the bulk call itself fails, every row falls back to single PUTs", async () => {
  const puts = [];
  const request = async (m, path) => {
    if (m === "POST") throw new Error("boom");
    puts.push(decodeURIComponent(path.split("/").pop()));
  };
  await bulkPutInventoryItems(request, [{ sku: "a", body: {} }, { sku: "b", body: {} }]);
  assert.deepEqual(puts, ["a", "b"]);
});

test("bulkCreateOffers: maps sku → offerId; rows bulk can't create adopt via createSingle", async () => {
  const request = async (m, path, body) => ({
    responses: body.requests.map((r) => r.sku === "dup"
      ? { sku: "dup", statusCode: 400 }
      : { sku: r.sku, statusCode: 201, offerId: `o-${r.sku}` }),
  });
  const single = [];
  const ids = await bulkCreateOffers(
    request,
    [{ sku: "a", body: { sku: "a" } }, { sku: "dup", body: { sku: "dup" } }],
    async (sku) => { single.push(sku); return `adopted-${sku}`; },
  );
  assert.deepEqual(ids, { a: "o-a", dup: "adopted-dup" });
  assert.deepEqual(single, ["dup"]);
});
