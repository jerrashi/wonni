const test = require("node:test");
const assert = require("node:assert/strict");
const { ebayPackageWeightAndSize } = require("../ebay_listing.js");

test("under a pound goes to eBay as whole ounces (error 25020 on 0.063 POUND)", () => {
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: 0.0625 }).weight, { value: 1, unit: "OUNCE" });
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: 0.25 }).weight, { value: 4, unit: "OUNCE" });
  assert.deepEqual(ebayPackageWeightAndSize({ weightOz: 5.4 }).weight, { value: 6, unit: "OUNCE" });
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: 0.01 }).weight, { value: 1, unit: "OUNCE" });
});

test("a pound or more stays in pounds; missing weight is the 6 oz default", () => {
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: 1 }).weight, { value: 1, unit: "POUND" });
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: 1, weightOz: 8 }).weight, { value: 1.5, unit: "POUND" });
  assert.deepEqual(ebayPackageWeightAndSize({}).weight, { value: 6, unit: "OUNCE" });
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: "x" }).weight, { value: 6, unit: "OUNCE" });
});

test("dimensions ride along only when all three are positive", () => {
  assert.deepEqual(ebayPackageWeightAndSize({ weightLbs: 2, lengthIn: 4, widthIn: 3, heightIn: 0.3 }).dimensions,
    { length: 4, width: 3, height: 0.3, unit: "INCH" });
  assert.equal(ebayPackageWeightAndSize({ weightLbs: 2, lengthIn: 4 }).dimensions, undefined);
});
