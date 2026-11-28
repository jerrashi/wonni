"use strict";

// Live failures 2026-11-27 posting ~9 BTS products at once:
// taxonomy 503s, "item specific Color is missing", a hoodie put in a category
// that refuses variations ("…Zip-Up Ho" — the search text was cut at 80).

const test = require("node:test");
const assert = require("node:assert/strict");
const { _internal: L } = require("../ebay_listing");

const jsonRes = (status, body) => ({ ok: status < 400, status, json: async () => body });

test("category query keeps the whole title when the hint would push it past 80", () => {
  const title = "BTS ARIRANG World Tour Official Charcoal Distressed Zip-Up Hoodie";
  assert.equal(L.categoryQuery(title, "Collectibles > K-pop > Clothing & Apparel"), title);
  assert.equal(L.categoryQuery("Scarf", "A > Scarves & Wraps"), "Scarves & Wraps Scarf");
});

test("taxonomy 503 is retried, then succeeds", async () => {
  let calls = 0;
  L.setPublicFetch(async () => (++calls < 3 ? jsonRes(503, {}) : jsonRes(200, { ok: 1 })), async () => {});
  try {
    assert.deepEqual(await L.ebayTaxonomyFetch("/x"), { ok: 1 });
    assert.equal(calls, 3);
  } finally { L.setPublicFetch(null); }
});

test("a product with sizes takes the first suggested category that allows variations", async () => {
  L.setPublicFetch(async (url) => {
    if (url.includes("get_category_suggestions")) {
      return jsonRes(200, { categorySuggestions: [{ category: { categoryId: "69528" } }, { category: { categoryId: "155183" } }] });
    }
    return jsonRes(200, { listingStructurePolicies: [
      { categoryId: "69528", variationsSupported: false }, { categoryId: "155183", variationsSupported: true },
    ] });
  }, async () => {});
  try {
    assert.equal(await L.suggestCategoryId("u", "Hoodie", null, { needsVariations: true }), "155183");
    assert.equal(await L.suggestCategoryId("u", "Hoodie", null), "69528");
  } finally { L.setPublicFetch(null); }
});

test("Color comes from the title, then the description; charcoal is Gray", () => {
  const aspects = [{ name: "Color", mode: "FREE_TEXT", values: ["Black", "Gray", "White"], required: true }];
  assert.deepEqual(L.buildProductAspects(aspects, "BTS", "Charcoal Fleece Jacket").Color, ["Gray"]);
  assert.deepEqual(L.buildProductAspects(aspects, "BTS", "Photo T-Shirt", {}, {}, "A white cotton tee with a black print").Color, ["White"]);
  assert.equal(L.buildProductAspects(aspects, "BTS", "Photo T-Shirt").Color, undefined, "no guess when nothing says a color");
});

test("materials come from the description and are never the brand", () => {
  const aspects = [{ name: "Outer Shell Material", mode: "FREE_TEXT", values: ["Polyester", "Cotton"], required: true }];
  assert.deepEqual(L.buildProductAspects(aspects, "BTS", "Zip Jacket", {}, {}, "Made of 100% polyester.")["Outer Shell Material"], ["Polyester"]);
  assert.equal(L.buildProductAspects(aspects, "BTS", "Jacket")["Outer Shell Material"], undefined);
});

test("sizes: skip a variation category that can't vary by Size", async () => {
  L.setPublicFetch(async (url) => {
    if (url.includes("get_category_suggestions")) {
      return jsonRes(200, { categorySuggestions: ["108857", "155183"].map((categoryId) => ({ category: { categoryId } })) });
    }
    if (url.includes("get_listing_structure_policies")) {
      return jsonRes(200, { listingStructurePolicies: [{ categoryId: "108857", variationsSupported: true }, { categoryId: "155183", variationsSupported: true }] });
    }
    const sizeOk = url.includes("155183");
    return jsonRes(200, { aspects: [{ localizedAspectName: "Size", aspectConstraint: { aspectEnabledForVariations: sizeOk } }] });
  }, async () => {});
  try {
    const options = [{ name: "Size", values: ["S", "M", "L"] }];
    assert.equal(await L.suggestCategoryId("u", "Hoodie", null, { needsVariations: true, options }), "155183");
  } finally { L.setPublicFetch(null); }
});
