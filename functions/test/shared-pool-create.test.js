"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { sharedPoolQuantity, tiktokSkuQuantity } = require("../platform_adapters");

test("sharedPoolQuantity: null unless quantityVariesByVariant is explicitly false", () => {
  assert.equal(sharedPoolQuantity({ quantity: 3 }), null);
  assert.equal(sharedPoolQuantity({ quantity: 3, quantityVariesByVariant: true }), null);
  assert.equal(sharedPoolQuantity({ quantity: 3, quantityVariesByVariant: false }), 3);
});

test("sharedPoolQuantity: floors, clamps junk to 0 (matches eBay postMultiVariant)", () => {
  assert.equal(sharedPoolQuantity({ quantity: 2.9, quantityVariesByVariant: false }), 2);
  assert.equal(sharedPoolQuantity({ quantityVariesByVariant: false }), 0);
  assert.equal(sharedPoolQuantity({ quantity: -1, quantityVariesByVariant: false }), 0);
});

test("tiktokSkuQuantity: shared pool sends the master number; otherwise legacy 999", () => {
  assert.equal(tiktokSkuQuantity({ quantity: 2, quantityVariesByVariant: false }), 2);
  assert.equal(tiktokSkuQuantity({ quantity: 0, quantityVariesByVariant: false }), 0);
  assert.equal(tiktokSkuQuantity({ quantity: 2 }), 999);
});
