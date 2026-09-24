/**
 * weverse-shipping-estimate.test.js — unit coverage for the per-(user,
 * platform, itemType) shipping-estimate lookup table: the max-merge
 * ratchet, the stored-value lookup, and the known-types list used to seed
 * both Gemini classification and the manual-confirm dropdown. Gemini itself
 * (classifyItemType / classifyWeverseItemTypes) isn't covered here — it's a
 * live network call, same as gemini_identify.js's own enrichment call.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const {
  getKnownItemTypes,
  getStoredEstimate,
  mergeShippingEstimate,
  baselineItemTypes,
} = require("../weverse_shipping_estimate");

const UID = "user_1";

test("mergeShippingEstimate: first write for a type stores the probed value as-is", async () => {
  const db = new FakeFirestore();
  const result = await mergeShippingEstimate(db, UID, "weverse", "Album/CD", 9.57);
  assert.equal(result, 9.57);

  const stored = db.peek("users/user_1/shippingEstimates", "weverse_Album-CD");
  assert.equal(stored.shippingCost, 9.57);
  assert.equal(stored.userId, UID);
  assert.equal(stored.platform, "weverse");
  assert.equal(stored.itemType, "Album/CD");
});

test("mergeShippingEstimate: a higher new probe raises the stored value", async () => {
  const db = new FakeFirestore();
  await mergeShippingEstimate(db, UID, "weverse", "Apparel", 12.00);
  const result = await mergeShippingEstimate(db, UID, "weverse", "Apparel", 21.22);
  assert.equal(result, 21.22);
  assert.equal(db.peek("users/user_1/shippingEstimates", "weverse_Apparel").shippingCost, 21.22);
});

test("mergeShippingEstimate: a lower new probe never lowers the stored value", async () => {
  const db = new FakeFirestore();
  await mergeShippingEstimate(db, UID, "weverse", "Apparel", 21.22);
  const result = await mergeShippingEstimate(db, UID, "weverse", "Apparel", 12.00);
  assert.equal(result, 21.22);
  assert.equal(db.peek("users/user_1/shippingEstimates", "weverse_Apparel").shippingCost, 21.22);
});

test("mergeShippingEstimate: rejects a non-numeric cost", async () => {
  const db = new FakeFirestore();
  await assert.rejects(
    () => mergeShippingEstimate(db, UID, "weverse", "Apparel", "not a number"),
    /invalid-argument|finite number/
  );
});

test("mergeShippingEstimate: types with a slash get a filesystem-safe doc id", async () => {
  const db = new FakeFirestore();
  await mergeShippingEstimate(db, UID, "weverse", "Keychain/Accessory", 5);
  assert.ok(db.peek("users/user_1/shippingEstimates", "weverse_Keychain-Accessory"));
});

test("getStoredEstimate: null when this type has never been probed", async () => {
  const db = new FakeFirestore();
  const result = await getStoredEstimate(db, UID, "weverse", "Plushie");
  assert.equal(result, null);
});

test("getStoredEstimate: returns the merged value once one exists", async () => {
  const db = new FakeFirestore();
  await mergeShippingEstimate(db, UID, "weverse", "Plushie", 15);
  const result = await getStoredEstimate(db, UID, "weverse", "Plushie");
  assert.equal(result, 15);
});

test("getKnownItemTypes: baseline types are always included even with no stored estimates", async () => {
  const db = new FakeFirestore();
  const known = await getKnownItemTypes(db, UID, "weverse");
  for (const t of baselineItemTypes("weverse")) {
    assert.ok(known.includes(t), `expected baseline type "${t}" in known types`);
  }
});

test("getKnownItemTypes: merges in the user's own previously-confirmed custom types, deduped", async () => {
  const db = new FakeFirestore();
  await mergeShippingEstimate(db, UID, "weverse", "Slime", 6.5);
  await mergeShippingEstimate(db, UID, "weverse", "Apparel", 20); // already in baseline
  const known = await getKnownItemTypes(db, UID, "weverse");
  assert.ok(known.includes("Slime"));
  assert.equal(known.filter((t) => t === "Apparel").length, 1, "baseline + stored duplicate should collapse to one entry");
});

test("getKnownItemTypes: scoped per user — another user's types don't leak in", async () => {
  const db = new FakeFirestore();
  await mergeShippingEstimate(db, "user_2", "weverse", "Slime", 6.5);
  const known = await getKnownItemTypes(db, UID, "weverse");
  assert.ok(!known.includes("Slime"));
});
