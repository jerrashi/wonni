/**
 * etsy.test.js — pure logic of the Etsy CRUD port (contracts/etsy.js impl in
 * etsy_listing.js). The Etsy HTTP layer isn't injectable, so the callables need
 * an emulator / manual smoke; covered here: taxonomy matching, inventory +
 * create payload builders, drift diff (rebased on products/), field import.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal } = require("../etsy_listing");
const { RequestSchemas } = require("../contracts");

const {
  matchEtsyTaxonomyId, buildEtsyInventoryPayload, buildEtsyCreateBody,
  etsyDriftDiff, etsyImportUpdates, productTotalQuantity, priceAmount, etsyIdOf,
} = _internal;

const FALLBACK = 69150398;
const NODES = [
  { id: 1, name: "Clothing > Men's Clothing > Shirts & Tees" },
  { id: 2, name: "Accessories > Keychains & Lanyards" },
  { id: 3, name: "Electronics & Accessories > Headphones" },
];

// ── taxonomy match ─────────────────────────────────────────────────────────

test("matchEtsyTaxonomyId: falls back when there are no nodes / no signal", () => {
  assert.equal(matchEtsyTaxonomyId([], "x", "y"), FALLBACK);
  assert.equal(matchEtsyTaxonomyId(NODES, "", ""), FALLBACK);
});

test("matchEtsyTaxonomyId: leaf segment of the category path dominates", () => {
  assert.equal(matchEtsyTaxonomyId(NODES, "Cool band merch", "Music > Merch > Headphones"), 3);
  assert.equal(matchEtsyTaxonomyId(NODES, "Photocard holder", "Accessories > Keychains"), 2);
});

// ── inventory payload ──────────────────────────────────────────────────────

test("buildEtsyInventoryPayload: optionValues → property_values, price override, qty", () => {
  const { products } = buildEtsyInventoryPayload([
    { sku: "TEE-S", quantity: 3, optionValues: { Size: "S" } },
    { sku: "TEE-M", quantity: 0, price: 25, optionValues: { Size: "M" } },
  ], 18);
  assert.equal(products[0].sku, "TEE-S");
  assert.deepEqual(products[0].property_values[0], { property_name: "Size", values: ["S"] });
  assert.equal(products[0].offerings[0].price, 18, "no override → base price");
  assert.equal(products[0].offerings[0].quantity, 3);
  assert.equal(products[1].offerings[0].price, 25, "variant price override wins");
  assert.equal(products[1].offerings[0].quantity, 0);
});

test("buildEtsyInventoryPayload: falls back to a 'Regular' Size property when a variant has no options", () => {
  const { products } = buildEtsyInventoryPayload([{ sku: "X", quantity: 1 }], 10);
  assert.deepEqual(products[0].property_values, [{ property_name: "Size", values: ["Regular"] }]);
});

test("buildEtsyInventoryPayload: enforces Etsy's $0.20 price floor", () => {
  const { products } = buildEtsyInventoryPayload([{ sku: "X", quantity: 1, price: 0.05 }], 0.05);
  assert.equal(products[0].offerings[0].price, 0.2);
});

// ── create body ────────────────────────────────────────────────────────────

test("buildEtsyCreateBody: truncates the title, floors the price, carries setup ids", () => {
  const body = buildEtsyCreateBody(
    { title: "T".repeat(200), description: "" },
    { taxonomyId: 5, whenMade: "2020_2024", whoMade: "someone_else", price: 0.1, quantity: 4, shippingProfileId: 99, returnPolicyId: 77 },
  );
  assert.equal(body.title.length, 140);
  assert.equal(body.price, 0.2);
  assert.equal(body.quantity, 4);
  assert.equal(body.state, "active");
  assert.equal(body.shipping_profile_id, 99);
  assert.equal(body.return_policy_id, 77);
  assert.equal(body.description, body.title, "empty description falls back to the title");
});

// ── quantity + drift ───────────────────────────────────────────────────────

test("productTotalQuantity: sums variants, else product.quantity, else 1", () => {
  assert.equal(productTotalQuantity({ variants: [{ quantity: 2 }, { quantity: 3 }] }), 5);
  assert.equal(productTotalQuantity({ quantity: 7 }), 7);
  assert.equal(productTotalQuantity({}), 1);
});

test("etsyDriftDiff: reports title/price/quantity drift against the product doc", () => {
  const product = { title: "Wonni Title", listingPrice: 20, quantity: 2, crossPostStatus: { etsy: "active" } };
  const r = etsyDriftDiff(product, {
    listing_id: 555, title: "Etsy Title", state: "active",
    price: { amount: 2500, divisor: 100 }, quantity: 5,
  });
  assert.equal(r.hasDrift, true);
  assert.deepEqual(r.diff.map((d) => d.key), ["title", "price", "quantity"]);
  assert.equal(r.diff[1].value, 25);
  assert.equal(r.etsyData.listingId, "555");
  assert.equal(r.wonniData.quantity, 2);
});

test("etsyDriftDiff: no drift when everything matches (variant qty summed)", () => {
  const product = { title: "Same", listingPrice: 12, variants: [{ quantity: 1 }, { quantity: 2 }] };
  const r = etsyDriftDiff(product, {
    listing_id: 1, title: "Same", state: "active", price: { amount: 1200, divisor: 100 }, quantity: 3,
  });
  assert.equal(r.hasDrift, false);
  assert.deepEqual(r.diff, []);
});

test("etsyImportUpdates: maps known fields, ignores nulls and bad types", () => {
  assert.deepEqual(
    etsyImportUpdates({ title: "New", price: 9.5, quantity: 4 }),
    { title: "New", listingPrice: 9.5, quantity: 4 },
  );
  assert.deepEqual(etsyImportUpdates({ title: null, price: "10" }), {});
});

test("priceAmount: floor + 2dp rounding", () => {
  assert.equal(priceAmount(19.999), 20);
  assert.equal(priceAmount(0), 0.2);
});

test("etsyIdOf: prefers crossPostListingIds.etsy, then etsyListingId", () => {
  assert.equal(etsyIdOf({ crossPostListingIds: { etsy: "111" }, etsyListingId: "222" }), "111");
  assert.equal(etsyIdOf({ etsyListingId: "222" }), "222");
  assert.equal(etsyIdOf({}), null);
});

// ── contract envelope ──────────────────────────────────────────────────────

test("etsy contracts: productId required; legacy credentialSet accepted & ignored", () => {
  const create = RequestSchemas.etsyCreateListing;
  assert.equal(create.safeParse({ productId: "p1", credentialSet: "web" }).success, true);
  assert.equal(create.safeParse({ credentialSet: "web" }).success, false);
  const parsed = create.parse({ productId: "p1", credentialSet: "web", taxonomyId: 42 });
  assert.equal(parsed.taxonomyId, 42);
});
