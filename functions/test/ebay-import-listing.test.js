/**
 * ebay-import-listing.test.js — `ebayImportListing`'s core: fetch any eBay
 * listing by item id (Browse API, app token) to seed a new product.
 *
 * Registered as a callable (functions/index.js) since iOS's ImportListingSheet
 * calls it by name, but the function itself had never been implemented —
 * every "paste an eBay item URL" import failed outright (found in review
 * 2026-09-12). No emulator: stubs `global.fetch`, routed by URL rather than
 * call order, since the app token it also fetches (via ebay_listing.js's own
 * un-injectable getEbayAppTokenCached) is memoized across calls in-process —
 * a call-order-based stub would break once a later test reuses the cache.
 */

"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "test-client-id";
process.env.EBAY_CLIENT_SECRET = "test-client-secret";

const { _internal } = require("../ebay_listing");
const { ebayImportListingCore } = _internal;

let itemResponse;
const originalFetch = global.fetch;

beforeEach(() => {
  itemResponse = { ok: true, status: 200, body: { title: "unset" } };
  global.fetch = async (url) => {
    if (String(url).includes("oauth2/token")) {
      return { ok: true, status: 200, json: async () => ({ access_token: "app-token" }) };
    }
    return { ok: itemResponse.ok, status: itemResponse.status, json: async () => itemResponse.body };
  };
});

afterEach(() => {
  global.fetch = originalFetch;
});

test("ebayImportListingCore: maps a Browse API item into the import shape", async () => {
  itemResponse.body = {
    title: "Vintage Camera",
    price: { value: "42.50", currency: "USD" },
    shortDescription: "Works great, minor wear.",
    image: { imageUrl: "https://img.example/1.jpg" },
    additionalImages: [{ imageUrl: "https://img.example/2.jpg" }],
    condition: "Used",
  };

  const result = await ebayImportListingCore("204567891234");
  assert.equal(result.title, "Vintage Camera");
  assert.equal(result.price, 42.5);
  assert.equal(result.description, "Works great, minor wear.");
  assert.deepEqual(result.imageUrls, ["https://img.example/1.jpg", "https://img.example/2.jpg"]);
  assert.equal(result.condition, "Used");
});

test("ebayImportListingCore: missing price/description/images degrade to safe defaults", async () => {
  itemResponse.body = { title: "Bare Listing" };

  const result = await ebayImportListingCore("111");
  assert.equal(result.title, "Bare Listing");
  assert.equal(result.price, 0);
  assert.equal(result.description, "");
  assert.deepEqual(result.imageUrls, []);
  assert.equal(result.condition, "");
});

test("ebayImportListingCore: throws not-found when the item lookup fails", async () => {
  itemResponse = { ok: false, status: 404, body: { errors: [{ message: "Item not found." }] } };

  await assert.rejects(
    () => ebayImportListingCore("does-not-exist"),
    (err) => {
      assert.equal(err.code, "not-found");
      assert.match(err.message, /Item not found/);
      return true;
    }
  );
});
