"use strict";

// Live failures 2026-11-26 on BTS tour shirts imported from Weverse:
// 25002 "Style is not allowed as a variation specific" and
// 25129 "BTS is not a valid value for Size".

const test = require("node:test");
const assert = require("node:assert/strict");
const { isSizeValue, looksLikeSizes, ebayVariationNames } = require("../variation_names");
const { mapWeverseVariantsToOptions } = require("../weverse_product");
const { _internal: { fillValueForAspect, buildProductAspects, hasRealOptions } } = require("../ebay_listing");

const apparel = [
  { name: "Size", mode: "FREE_TEXT", values: ["XS", "S", "M", "L", "XL", "2XL"], required: true, variationEnabled: true },
  { name: "Color", mode: "FREE_TEXT", values: ["Black", "White", "Red"], required: false, variationEnabled: true },
  { name: "Style", mode: "FREE_TEXT", values: ["T-Shirt", "Hoodie"], required: false, variationEnabled: false },
  { name: "Brand", mode: "FREE_TEXT", values: [], required: true, variationEnabled: false },
];

test("size values are recognised, names are not", () => {
  for (const v of ["S", "xl", "XXL", "2XL", "Free", "100", "M-L", "XL / XXL"]) assert.ok(isSizeValue(v), v);
  for (const v of ["Jimin", "Scarf", "Madrid", "", null]) assert.ok(!isSizeValue(v), String(v));
  assert.ok(looksLikeSizes(["S", "M", "L", "XL"]));
  assert.ok(!looksLikeSizes(["RM", "Jin"]));
  assert.ok(!looksLikeSizes([]));
});

test("regression: Style of S/M/L/XL goes to eBay as Size", () => {
  const names = ebayVariationNames([{ name: "Style", values: ["S", "M", "L", "XL"] }], apparel);
  assert.deepEqual(names, { Style: "Size" });
});

test("a variation-enabled name is kept; a refused non-size name becomes Option", () => {
  assert.deepEqual(ebayVariationNames([{ name: "Size", values: ["S"] }], apparel), { Size: "Size" });
  assert.deepEqual(ebayVariationNames([{ name: "Style", values: ["Madrid", "Paris"] }], apparel), { Style: "Option" });
  assert.deepEqual(ebayVariationNames([{ name: "Member", values: ["RM", "Jin"] }], apparel), { Member: "Member" });
  assert.deepEqual(ebayVariationNames([{ name: "Style", values: ["Black", "White"] }], apparel), { Style: "Color" });
});

test("two options never map to the same eBay name", () => {
  const names = ebayVariationNames([{ name: "Size", values: ["S", "M"] }, { name: "Style", values: ["L", "XL"] }], apparel);
  assert.deepEqual(names, { Size: "Size", Style: "Style" });
});

test("regression: a missing Size is never filled with the brand", () => {
  assert.equal(fillValueForAspect("Size", apparel, "BTS", "BTS ARIRANG Tour T-Shirt"), null);
  assert.deepEqual(fillValueForAspect("Size", apparel, "BTS", "BTS Tour T-Shirt Medium"), ["M"]);
  assert.deepEqual(fillValueForAspect("Brand", apparel, "BTS", "BTS Tour T-Shirt"), ["BTS"]);
  const aspects = buildProductAspects(apparel, "BTS", "BTS ARIRANG Tour T-Shirt");
  assert.equal(aspects.Size, undefined);
});

test("Weverse import names a lone size dimension Size", () => {
  const { options, variants } = mapWeverseVariantsToOptions([
    { name: "S", stockId: 1 }, { name: "M", stockId: 2 }, { name: "L", stockId: 3 },
  ]);
  assert.equal(options[0].name, "Size");
  assert.deepEqual(variants[0].optionValues, { Size: "S" });
  const members = mapWeverseVariantsToOptions([{ name: "RM", stockId: 1 }, { name: "Jin", stockId: 2 }]);
  assert.equal(members.options[0].name, "Style");
});

test("every variation turned off on a real choice is caught", () => {
  assert.ok(hasRealOptions({ options: [{ values: ["S", "M"] }], variants: [{}, {}] }));
  assert.ok(!hasRealOptions({ options: [{ values: ["Scarf"] }], variants: [{}] }));
  assert.ok(!hasRealOptions({}));
});
