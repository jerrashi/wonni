/**
 * ebay-comps.test.js — ebayRetrieveComps' core: search eBay's Browse API by
 * title and return the raw active-listing results. Retrieval only, no
 * ranking/recommendation math (that's an explicitly deferred UI decision —
 * see docs/specs/2026-09-28-ebay-listing-management-api.md).
 *
 * No emulator: stubs fetch, same pattern as ebay-import-listing.test.js
 * (getEbayAppTokenCached is memoized in-process, so route by URL not call
 * order).
 */

"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "test-client-id";
process.env.EBAY_CLIENT_SECRET = "test-client-secret";

const { _internal } = require("../ebay_comps");
const { retrieveComps } = _internal;

let searchResponse;
let lastUrl;
const originalFetch = global.fetch;

beforeEach(() => {
  searchResponse = { ok: true, status: 200, body: { itemSummaries: [] } };
  lastUrl = null;
  // getEbayAppTokenCached() (in ebay_listing.js) mints its token via the
  // global `fetch`, not an injectable one — only the actual comp search
  // below goes through fetchImpl. Stub the token endpoint here so the cached
  // token resolves without a real network call.
  global.fetch = async (url) => {
    if (String(url).includes("oauth2/token")) {
      return { ok: true, status: 200, json: async () => ({ access_token: "app-token" }) };
    }
    throw new Error(`Unexpected global.fetch call in test: ${url}`);
  };
});

afterEach(() => {
  global.fetch = originalFetch;
});

function fetchImpl(url) {
  lastUrl = String(url);
  return Promise.resolve({
    ok: searchResponse.ok,
    status: searchResponse.status,
    json: async () => searchResponse.body,
  });
}

test("retrieveComps: maps Browse API itemSummaries into the comps shape", async () => {
  searchResponse.body = {
    itemSummaries: [
      {
        itemId: "v1|123|0",
        title: "Vintage Camera",
        price: { value: "42.50", currency: "USD" },
        condition: "Used",
        itemWebUrl: "https://ebay.com/itm/123",
        image: { imageUrl: "https://img.example/1.jpg" },
      },
      {
        itemId: "v1|456|0",
        title: "Vintage Camera Body Only",
        price: { value: "35.00", currency: "USD" },
        condition: "Used",
        thumbnailImages: [{ imageUrl: "https://img.example/2.jpg" }],
      },
    ],
  };

  const comps = await retrieveComps({ title: "Vintage Camera" }, { fetchImpl });

  assert.equal(comps.length, 2);
  assert.deepEqual(comps[0], {
    itemId: "v1|123|0",
    title: "Vintage Camera",
    price: 42.5,
    currency: "USD",
    condition: "Used",
    itemWebUrl: "https://ebay.com/itm/123",
    imageUrl: "https://img.example/1.jpg",
    shortDescription: null,
  });
  // Falls back to thumbnailImages when `image` is absent
  assert.equal(comps[1].imageUrl, "https://img.example/2.jpg");
});

test("retrieveComps: builds the search query from title + optional filters", async () => {
  await retrieveComps({ title: "Trading Card", categoryId: "183454", condition: "3000", limit: 10 }, { fetchImpl });

  assert.ok(lastUrl.includes("/buy/browse/v1/item_summary/search"));
  assert.ok(lastUrl.includes("q=Trading+Card") || lastUrl.includes("q=Trading%20Card"));
  assert.ok(lastUrl.includes("category_ids=183454"));
  assert.ok(lastUrl.includes("conditionIds"));
  assert.ok(lastUrl.includes("limit=10"));
  // EXTENDED is what returns each result's shortDescription (comp_match.js).
  assert.ok(decodeURIComponent(lastUrl).includes("fieldgroups=MATCHING_ITEMS,EXTENDED"));
});

test("retrieveComps: title-only search omits category/condition filters", async () => {
  await retrieveComps({ title: "Plain Search" }, { fetchImpl });

  assert.ok(!lastUrl.includes("category_ids"));
  assert.ok(!lastUrl.includes("filter="));
  assert.ok(lastUrl.includes("limit=25"), "defaults to 25");
});

test("retrieveComps: clamps limit to eBay's [1,50] range", async () => {
  await retrieveComps({ title: "x", limit: 500 }, { fetchImpl });
  assert.ok(lastUrl.includes("limit=50"));

  await retrieveComps({ title: "x", limit: 0 }, { fetchImpl });
  assert.ok(lastUrl.includes("limit=1"));
});

test("retrieveComps: empty itemSummaries returns an empty array, not an error", async () => {
  searchResponse.body = {};
  const comps = await retrieveComps({ title: "Nothing Matches" }, { fetchImpl });
  assert.deepEqual(comps, []);
});

test("retrieveComps: throws on a non-ok Browse API response", async () => {
  searchResponse = { ok: false, status: 400, body: { errors: [{ message: "Invalid request" }] } };
  await assert.rejects(
    () => retrieveComps({ title: "x" }, { fetchImpl }),
    /eBay comp search failed \(400\)/
  );
});
