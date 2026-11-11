"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { isSharedPool } = require("../quantity_model");
const { sharedPoolQuantity } = require("../platform_adapters");
const { chooseBackfillValue } = require("../scripts/backfill_quantity_model");

const V = (...qs) => qs.map((quantity, i) => ({ id: `v${i}`, quantity, active: true }));

test("unset flag on a variant product is a SHARED pool (default 2026-11-11)", () => {
  assert.equal(isSharedPool({ hasVariants: true, variants: V(1, 2) }), true);
  assert.equal(isSharedPool({ variants: V(1, 2) }), true);
});
test("explicit true is per-variant; explicit false is shared", () => {
  assert.equal(isSharedPool({ quantityVariesByVariant: true, variants: V(1, 2) }), false);
  assert.equal(isSharedPool({ quantityVariesByVariant: false, variants: V(1, 2) }), true);
});
test("a no-variant product with the flag unset is not a pool", () => {
  assert.equal(isSharedPool({ quantity: 3 }), false);
  assert.equal(isSharedPool(null), false);
});
test("sharedPoolQuantity follows the new default", () => {
  assert.equal(sharedPoolQuantity({ quantity: 4, variants: V(9, 9) }), 4);
  assert.equal(sharedPoolQuantity({ quantity: 4, quantityVariesByVariant: true, variants: V(9, 9) }), null);
});

test("backfill: differing variant quantities → true (keep per-variant)", () => {
  assert.deepEqual(chooseBackfillValue({ hasVariants: true, variants: V(3, 0) }), { value: true });
});
test("backfill: identical variant quantities → false (shared), and seeds quantity", () => {
  assert.deepEqual(chooseBackfillValue({ variants: V(2, 2) }), { value: false, quantity: 2 });
});
test("backfill: already set, or no variants → leave alone (null)", () => {
  assert.equal(chooseBackfillValue({ quantityVariesByVariant: false, variants: V(1, 2) }), null);
  assert.equal(chooseBackfillValue({ quantity: 3 }), null);
});

// The user's toggle is the only authority once set: matching quantities must
// never be read as "shared" (1 red + 1 white + 1 blue with the box ticked).
test("regression: explicit true with identical variant quantities stays per-variant", () => {
  const tee = { hasVariants: true, quantityVariesByVariant: true, quantity: 1, variants: V(1, 1, 1) };
  assert.equal(isSharedPool(tee), false);
  assert.equal(sharedPoolQuantity(tee), null);
  assert.equal(chooseBackfillValue(tee), null, "backfill never rewrites a set flag");
});
test("regression: explicit false with differing variant quantities stays shared", () => {
  const tee = { hasVariants: true, quantityVariesByVariant: false, quantity: 2, variants: V(5, 0, 1) };
  assert.equal(isSharedPool(tee), true);
  assert.equal(chooseBackfillValue(tee), null);
});
