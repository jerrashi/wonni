/**
 * wonni-listing.test.js — the pure mapping + patch layer of postToWonni.
 * The callable (Firestore reads/writes, the live-listing guard) needs an
 * emulator / manual smoke.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { toListingFields, variantToVariation } = require("../listing_shape");
const { _internal } = require("../wonni_listing");
const { RequestSchemas } = require("../contracts");

const { buildWonniCrossPost, wonniPublishedProductPatch } = _internal;

// ── listing_shape.toListingFields ──────────────────────────────────────────

test("toListingFields: maps product fields to the UserListing (marketplace) shape", () => {
  const f = toListingFields({
    title: "Photocard Set",
    description: "Official.",
    price: 18,
    images: ["a.jpg", "b.jpg"],
    options: [{ name: "Member", values: ["RM", "Jin"] }],
    variants: [{ id: "v1", optionValues: { Member: "RM" }, price: 20, quantity: 3, sku: "PC-RM" }],
    condition: "likenew",
    category: "Collectibles > K-pop",
    brand: "BTS",
    tags: ["kpop"],
  });
  assert.equal(f.customTitle, "Photocard Set");
  assert.equal(f.price, 18);
  assert.equal(f.coverPhotoPath, "a.jpg");
  assert.equal(f.condition, "likenew");
  assert.equal(f.currency, "USD");
  assert.deepEqual(f.options, [{ name: "Member", values: ["RM", "Jin"] }], "options preserved verbatim");
  assert.equal(f.variations[0].sku, "PC-RM");
  assert.deepEqual(f.variations[0].attributes, [{ name: "Member", value: "RM" }]);
  assert.equal(f.aiTracking, undefined, "no aiTracking without a suggestion");
  assert.ok(!("status" in f), "status is set by postToWonni, never the mapper");
});

test("toListingFields: condition falls back to 'new' (dropship imports are new stock)", () => {
  assert.equal(toListingFields({ title: "x" }).condition, "new");
});

test("toListingFields: builds aiTracking only when a suggestion is present, with edited flags", () => {
  const f = toListingFields({
    title: "Edited Title", description: "d", price: 10,
    aiSuggestedTitle: "AI Title", aiSuggestedPrice: 10, aiModel: "gemini", aiPromptVersion: "v1",
  });
  assert.ok(f.aiTracking);
  assert.equal(f.aiTracking.titleEdited, true);
  assert.equal(f.aiTracking.priceEdited, false);
  assert.equal(f.aiTracking.aiModel, "gemini");
});

test("toListingFields: shippingInfo uses Item's default values", () => {
  const s = toListingFields({ title: "x" }).shippingInfo;
  assert.equal(s.buyerPaysShipping, true);
  assert.equal(s.handlingFee, 0);
  assert.equal(s.estimatedShippingDays, 3);
  assert.equal(s.packageDimensions, null);
});

test("variantToVariation: Mercari status/id ride on the variation, not the parent", () => {
  const v = variantToVariation({ id: "v1", optionValues: { Size: "M" }, mercariStatus: "active", mercariListingId: "m123" });
  assert.equal(v.crossPostStatus.mercari, "active");
  assert.equal(v.crossPostListingIds.mercari, "m123");
});

// ── postToWonni internals ──────────────────────────────────────────────────

test("buildWonniCrossPost: only mirrors platforms the product actually has", () => {
  assert.deepEqual(
    buildWonniCrossPost({ ebayStatus: "active", ebayListingId: "111", listingStatus: { mercari: "active" }, listingId: { mercari: "m9" } }),
    { crossPostStatus: { ebay: "active", mercari: "active" }, crossPostListingIds: { ebay: "111", mercari: "m9" } },
  );
  assert.deepEqual(buildWonniCrossPost({}), { crossPostStatus: {}, crossPostListingIds: {} });
});

test("wonniPublishedProductPatch: marks the product published + not-draft (nested-map merge, no dotted paths)", () => {
  const p = wonniPublishedProductPatch("p1");
  assert.deepEqual(p.crossPostStatus, { wonni: "active" });
  assert.deepEqual(p.crossPostListingIds, { wonni: "p1" });
  assert.equal(p.isDraft, false);
  assert.ok(!Object.keys(p).some((k) => k.includes(".")), "no dotted field paths");
});

test("postToWonni contract: {productId} in, {listingId, alreadyPosted, skipped?} out", () => {
  assert.equal(RequestSchemas.postToWonni.safeParse({ productId: "p1" }).success, true);
  assert.equal(RequestSchemas.postToWonni.safeParse({}).success, false);
});
