import test from "node:test";
import assert from "node:assert/strict";
import { adjustPrice, bulkEditPatch, hasVariantPriceOverrides, hasAnyEdit } from "./bulkEdit.js";

test("adjustPrice: increase/decrease by % or $, set, limits, cents", () => {
  assert.equal(adjustPrice(20, { mode: "increase", unit: "pct", amount: "10" }), 22);
  assert.equal(adjustPrice(20, { mode: "increase", unit: "pct", amount: "10", limit: "21" }), 21);
  assert.equal(adjustPrice(20, { mode: "decrease", unit: "usd", amount: "5" }), 15);
  assert.equal(adjustPrice(20, { mode: "decrease", unit: "usd", amount: "50", limit: "12" }), 12);
  assert.equal(adjustPrice(20, { mode: "decrease", unit: "usd", amount: "50" }), 0.01);
  assert.equal(adjustPrice(19.99, { mode: "increase", unit: "pct", amount: "15" }), 22.99);
  assert.equal(adjustPrice(20, { mode: "set", amount: "9.5" }), 9.5);
  assert.equal(adjustPrice(null, { mode: "increase", unit: "usd", amount: "5" }), null, "no price to change");
  assert.equal(adjustPrice(20, { mode: "increase", unit: "usd", amount: "" }), null);
  assert.equal(adjustPrice(20, { mode: null, amount: "5" }), null);
});

test("title and description prepend/append; blank edits change nothing", () => {
  const p = { title: "Scarf", description: "Wool", listingPrice: 45 };
  assert.deepEqual(bulkEditPatch(p, { titleAppend: " - Official ", descPrepend: "NEW" }), {
    title: "Scarf - Official", description: "NEW\n\nWool",
  });
  assert.deepEqual(bulkEditPatch({ title: "x", description: "" }, { descAppend: "Ships fast" }), { description: "Ships fast" });
  assert.equal(bulkEditPatch(p, { titlePrepend: "  ", price: {} }), null);
});

test("variant prices change only when asked, as a whole array", () => {
  const p = { listingPrice: 30, variants: [{ id: "a", price: 35 }, { id: "b", price: null }] };
  const edits = { price: { mode: "increase", unit: "usd", amount: "5" } };
  assert.deepEqual(bulkEditPatch(p, edits), { listingPrice: 35 });
  const withVariants = bulkEditPatch(p, { ...edits, changeVariantPrices: true });
  assert.deepEqual(withVariants.variants, [{ id: "a", price: 40 }, { id: "b", price: null }]);
  assert.deepEqual(
    bulkEditPatch(p, { price: { mode: "set", amount: "25" }, changeVariantPrices: true }).variants,
    [{ id: "a", price: null }, { id: "b", price: null }],
    "set: every variant follows the new price",
  );
});

test("hasVariantPriceOverrides: only a variant priced differently counts", () => {
  assert.equal(hasVariantPriceOverrides({ listingPrice: 30, variants: [{ price: null }, { price: 30 }] }), false);
  assert.equal(hasVariantPriceOverrides({ listingPrice: 30, variants: [{ price: 32 }] }), true);
  assert.equal(hasVariantPriceOverrides({ listingPrice: 30 }), false);
});

test("details and package", () => {
  const patch = bulkEditPatch({ title: "x" }, {
    condition: "likenew", shipping: "free", handling: "3", weightLbs: "1", weightOz: "4", lengthIn: "10", widthIn: "8", heightIn: "",
  });
  assert.deepEqual(patch, {
    condition: "likenew", mercariCondition: "likenew", buyerPaysShipping: false, mercariBuyerPaysShipping: false,
    handlingTimeDays: 3, weightLbs: 1, weightOz: 4,
  });
  assert.deepEqual(bulkEditPatch({}, { handling: "reset" }), { handlingTimeDays: null });
  assert.deepEqual(bulkEditPatch({}, { lengthIn: "10", widthIn: "8", heightIn: "2" }), { lengthIn: 10, widthIn: 8, heightIn: 2 });
});

test("hasAnyEdit", () => {
  assert.equal(hasAnyEdit({}), false);
  assert.equal(hasAnyEdit({ markOutOfStock: true }), true);
  assert.equal(hasAnyEdit({ price: { mode: "set", amount: "5" } }), true);
  assert.equal(hasAnyEdit({ shipping: "buyer" }), true);
});
