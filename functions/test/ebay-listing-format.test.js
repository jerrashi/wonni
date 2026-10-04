/**
 * ebay-listing-format.test.js — validateListingFormatInput (the pure
 * validation behind ebaySetListingFormat) + buildEbayOfferPayload's format
 * handling (the AUCTION/FIXED_PRICE payload shape it builds at create time).
 * The callable itself (Firestore read/write, live-listing conflict check)
 * needs a manual smoke test — see docs/specs/2026-09-28-ebay-listing-management-api.md.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal } = require("../ebay_listing");
const { validateListingFormatInput, buildEbayOfferPayload } = _internal;

// ── validateListingFormatInput ──────────────────────────────────────────────

test("validateListingFormatInput: FIXED_PRICE is always valid, no extra fields needed", () => {
  assert.equal(validateListingFormatInput({ format: "FIXED_PRICE", hasVariations: false }), null);
  assert.equal(validateListingFormatInput({ format: "FIXED_PRICE", hasVariations: true }), null);
});

test("validateListingFormatInput: AUCTION rejected for multi-variant products", () => {
  const err = validateListingFormatInput({
    format: "AUCTION", listingDuration: "DAYS_7", auctionStartPrice: 5, hasVariations: true,
  });
  assert.match(err, /single-quantity, single-SKU/);
});

test("validateListingFormatInput: AUCTION requires a valid listingDuration", () => {
  const err = validateListingFormatInput({
    format: "AUCTION", listingDuration: "GTC", auctionStartPrice: 5, hasVariations: false,
  });
  assert.match(err, /listingDuration/);
});

test("validateListingFormatInput: AUCTION requires a positive auctionStartPrice", () => {
  assert.match(
    validateListingFormatInput({ format: "AUCTION", listingDuration: "DAYS_7", auctionStartPrice: 0, hasVariations: false }),
    /auctionStartPrice/
  );
  assert.match(
    validateListingFormatInput({ format: "AUCTION", listingDuration: "DAYS_7", hasVariations: false }),
    /auctionStartPrice/
  );
});

test("validateListingFormatInput: valid AUCTION input passes", () => {
  assert.equal(
    validateListingFormatInput({ format: "AUCTION", listingDuration: "DAYS_7", auctionStartPrice: 9.99, hasVariations: false }),
    null
  );
});

test("validateListingFormatInput: rejects an unknown format string", () => {
  assert.match(validateListingFormatInput({ format: "BEST_OFFER", hasVariations: false }), /AUCTION.*FIXED_PRICE/);
});

// ── buildEbayOfferPayload: format handling ──────────────────────────────────

const baseArgs = { sku: "sku1", price: 20, quantity: 1, categoryId: "123", description: "d", listingPolicies: {}, merchantLocationKey: "loc1" };

test("buildEbayOfferPayload: no ebayFormat defaults to FIXED_PRICE/GTC (backward compat)", () => {
  const p = buildEbayOfferPayload(baseArgs);
  assert.equal(p.format, "FIXED_PRICE");
  assert.equal(p.listingDuration, "GTC");
  assert.equal(p.pricingSummary.price.value, "20.00");
});

test("buildEbayOfferPayload: AUCTION sets auctionStartPrice + duration, not plain price", () => {
  const p = buildEbayOfferPayload({
    ...baseArgs,
    ebayFormat: { format: "AUCTION", listingDuration: "DAYS_7", auctionStartPrice: 5 },
  });
  assert.equal(p.format, "AUCTION");
  assert.equal(p.listingDuration, "DAYS_7");
  assert.equal(p.pricingSummary.auctionStartPrice.value, "5.00");
  assert.equal(p.pricingSummary.price, undefined);
});

test("buildEbayOfferPayload: AUCTION + buyItNowPrice sets pricingSummary.price as the BIN price", () => {
  const p = buildEbayOfferPayload({
    ...baseArgs,
    ebayFormat: { format: "AUCTION", listingDuration: "DAYS_7", auctionStartPrice: 5, buyItNowPrice: 25 },
  });
  assert.equal(p.pricingSummary.price.value, "25.00");
});

test("buildEbayOfferPayload: forUpdate never includes format (eBay rejects changing it on an existing offer)", () => {
  const p = buildEbayOfferPayload(
    { ...baseArgs, ebayFormat: { format: "AUCTION", listingDuration: "DAYS_7", auctionStartPrice: 5 } },
    { forUpdate: true }
  );
  assert.equal(p.format, undefined);
  assert.equal(p.sku, undefined);
  assert.equal(p.marketplaceId, undefined);
});

// ── in-place edit payloads (ebayUpdateListing / ebaySyncListing→wonni) ─────

const { buildSingleVariantEditPayloads } = require("../ebay_listing")._internal;

test("buildSingleVariantEditPayloads: an edit carries the real condition, specifics, package and new photos", () => {
  const product = {
    title: "Operation Wolf NES Game with Manual",
    description: "Cartridge with manual.",
    listingPrice: 12.99,
    quantity: 1,
    condition: "good",
    weightLbs: 0.5, lengthIn: 6, widthIn: 5, heightIn: 1,
    images: ["https://storage.googleapis.com/b/users/u/p/NEW-1.jpg", "https://storage.googleapis.com/b/users/u/p/NEW-2.jpg"],
    geminiItemSpecifics: { Platform: "Nintendo NES", "Game Name": "Operation Wolf" },
  };
  const { itemPayload, offerPayload } = buildSingleVariantEditPayloads({
    product, title: product.title, description: product.description, basePrice: 12.99,
    offer: { sku: "SKU1", categoryId: "139973" },
    existingItem: { product: { aspects: { Publisher: ["Taito"], Platform: ["old value"] } } },
    categoryAspects: [], brand: "Taito", conditionEnum: "USED_GOOD",
    listingPolicies: { fulfillmentPolicyId: "f", paymentPolicyId: "p", returnPolicyId: "r" },
    merchantLocationKey: "US_60615",
  });

  // The bugs this replaces: condition was hardcoded "NEW", aspects were sent
  // empty (wiping the live item's), and no package was sent.
  assert.equal(itemPayload.condition, "USED_GOOD");
  assert.deepEqual(itemPayload.product.aspects.Platform, ["Nintendo NES"], "our value wins");
  assert.deepEqual(itemPayload.product.aspects.Publisher, ["Taito"], "an aspect only eBay had is kept");
  assert.deepEqual(itemPayload.product.aspects["Game Name"], ["Operation Wolf"]);
  assert.deepEqual(itemPayload.product.imageUrls, product.images);
  assert.deepEqual(itemPayload.packageWeightAndSize.dimensions, { length: 6, width: 5, height: 1, unit: "INCH" });
  assert.equal(itemPayload.availability.shipToLocationAvailability.quantity, 1);

  // A full updateOffer body: no immutable create-only keys.
  assert.equal(offerPayload.pricingSummary.price.value, "12.99");
  assert.equal(offerPayload.categoryId, "139973");
  assert.equal(offerPayload.listingDescription, "Cartridge with manual.");
  assert.equal(offerPayload.merchantLocationKey, "US_60615");
  for (const key of ["sku", "marketplaceId", "format"]) assert.equal(key in offerPayload, false, key);
});

test("buildSingleVariantEditPayloads: with no policies or location to send, the keys are omitted", () => {
  const { offerPayload, itemPayload } = buildSingleVariantEditPayloads({
    product: { title: "T", listingPrice: 5, quantity: 0, images: [] },
    title: "T", description: "T", basePrice: 5,
    offer: { sku: "S", categoryId: "1" }, existingItem: null,
    categoryAspects: [], brand: "Unbranded", conditionEnum: "NEW",
    listingPolicies: null, merchantLocationKey: undefined,
  });
  assert.equal("listingPolicies" in offerPayload, false);
  assert.equal("merchantLocationKey" in offerPayload, false);
  assert.equal(offerPayload.availableQuantity, 0, "an out-of-stock edit stays at zero");
  assert.equal(itemPayload.availability.shipToLocationAvailability.quantity, 0);
});
