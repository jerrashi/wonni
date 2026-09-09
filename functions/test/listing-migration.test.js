/**
 * listing-migration.test.js — listing_shape.listingDocToProduct, the pure
 * mapper behind scripts/migrate_listings_to_products.js (BACKEND.md step 7).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { listingDocToProduct, normalizeCondition, normalizeCrossPostStatus } = require("../listing_shape");

const ID = "0089695A-AF02-4CAB-AD44-3719A7AE2365";

const singleListing = {
  userId: "u1",
  customTitle: "Seonghyeon CORTIS Photocard",
  customDescription: "Official.",
  price: 30,
  quantity: 1,
  condition: "likeNew",
  category: "Collectibles > Photocards",
  brand: "CORTIS",
  tags: ["kpop"],
  photoPaths: ["users/u1/x/0.jpg", "users/u1/x/1.jpg"],
  status: "active",
  crossPostStatus: { ebay: "posted", etsy: "failed", mercari: "posted" },
  crossPostListingIds: { ebay: "147365534168", mercari: "m94466710587" },
  shippingInfo: { buyerPaysShipping: true, estimatedShippingDays: 3, handlingFee: 0, weightLbs: 0.1, packageDimensions: { heightIn: 0.01, lengthIn: 3.4, widthIn: 2.1 } },
};

test("listingDocToProduct: single-item listing → product shape", () => {
  const p = listingDocToProduct(singleListing, ID);
  assert.equal(p.userId, "u1");
  assert.equal(p.title, "Seonghyeon CORTIS Photocard");
  assert.equal(p.listingPrice, 30);
  assert.equal(p.quantity, 1);
  assert.equal(p.condition, "likenew", "iOS 'likeNew' → canonical");
  assert.equal(p.saleStatus, "active");
  assert.equal(p.isDraft, false);
  assert.deepEqual(p.images, ["users/u1/x/0.jpg", "users/u1/x/1.jpg"]);
  assert.deepEqual(p.variants, []);
  assert.equal(p.source, "ios-listing");
  assert.equal(p.sourceId, ID);
  assert.equal(p.migratedFromListing, true);
});

test("listingDocToProduct: crossPost 'posted' → 'active', keeps others, adds wonni", () => {
  const p = listingDocToProduct(singleListing, ID);
  assert.equal(p.crossPostStatus.ebay, "active");
  assert.equal(p.crossPostStatus.etsy, "failed");
  assert.equal(p.crossPostStatus.mercari, "active");
  assert.equal(p.crossPostStatus.wonni, "active", "the listing IS the live Wonni entry");
  assert.equal(p.crossPostListingIds.wonni, ID);
  assert.equal(p.crossPostListingIds.ebay, "147365534168");
});

test("listingDocToProduct: shipping flattened onto the product", () => {
  const p = listingDocToProduct(singleListing, ID);
  assert.equal(p.weightLbs, 0.1);
  assert.equal(p.lengthIn, 3.4);
  assert.equal(p.heightIn, 0.01);
  assert.equal(p.buyerPaysShipping, true);
});

test("listingDocToProduct: sold listing", () => {
  const p = listingDocToProduct({ ...singleListing, status: "sold", quantity: 0, pendingMercariDeactivation: true }, ID);
  assert.equal(p.saleStatus, "sold");
  assert.equal(p.crossPostStatus.wonni, "sold");
  assert.equal(p.quantity, 0);
  assert.equal(p.pendingMercariDeactivation, true);
});

test("listingDocToProduct: draft listing is not marked live-on-wonni", () => {
  const p = listingDocToProduct({ ...singleListing, status: "draft" }, ID);
  assert.equal(p.isDraft, true);
  assert.equal(p.crossPostStatus.wonni, undefined);
  assert.equal(p.crossPostListingIds.wonni, undefined);
});

test("listingDocToProduct: variations → variants (attributes → optionValues)", () => {
  const p = listingDocToProduct({
    ...singleListing,
    options: [{ id: "opt-0", name: "Size", values: ["M", "L"] }],
    variations: [
      { id: "v1", attributes: [{ name: "Size", value: "M" }], price: 60, quantity: 2, sku: "w-1" },
      { id: "v2", attributes: [{ name: "Size", value: "L" }], price: 60, quantity: 1, sku: "w-2", crossPostStatus: { mercari: "posting" } },
    ],
  }, ID);
  assert.equal(p.variants.length, 2);
  assert.deepEqual(p.variants[0].optionValues, { Size: "M" });
  assert.equal(p.variants[0].quantity, 2);
  assert.equal(p.variants[0].sku, "w-1");
  assert.equal(p.variants[0].active, true);
  assert.deepEqual(p.options, [{ id: "opt-0", name: "Size", values: ["M", "L"] }]);
  assert.equal(p.variants[1].crossPostStatus.mercari, "posting", "unknown status kept verbatim");
});

test("listingDocToProduct: missing/blank fields get safe defaults", () => {
  const p = listingDocToProduct({ userId: "u1" }, ID);
  assert.equal(p.title, "");
  assert.equal(p.listingPrice, null);
  assert.equal(p.quantity, 1);
  assert.equal(p.condition, "good");
  assert.deepEqual(p.images, []);
});

test("normalizeCondition / normalizeCrossPostStatus", () => {
  assert.equal(normalizeCondition("forParts"), "poor");
  assert.equal(normalizeCondition("NWT"), null);
  assert.deepEqual(normalizeCrossPostStatus({ ebay: "posted", mercari: null, x: "weird" }), { ebay: "active", x: "weird" });
});
