"use strict";

/**
 * Etsy inventory payloads + splitting one Wonni product across several Etsy
 * listings. No dependency on sales.js / etsy_listing.js (both import this), so
 * the sale cascade builds the very same payload the create path does.
 */

const { HttpsError } = require("firebase-functions/v2/https");
const { variantPriceOr } = require("./platform_adapters");
const { planVariantGroups } = require("./ebay_variant_groups");

const ETSY_MIN_PRICE = 0.2;

function priceAmount(raw) {
  return Math.max(ETSY_MIN_PRICE, Math.round(Number(raw) * 100) / 100);
}

// Etsy's custom variation property ids (the user-named ones: "Series", "Issue"…).
// A third type needs `max_variations_supported=3`, still a developer preview
// (2026-08), so we cap at two — same as the web editor.
const ETSY_CUSTOM_PROPERTY_IDS = [513, 514];
// Max products (variant combinations) per listing, by Etsy's developer docs
// (verified 2026-11-11): 70 with one variation type, 4,900 with two — but only
// 400 once price / quantity / SKU varies by ALL properties.
const ETSY_MAX_PRODUCTS = { one: 70, two: 4900, twoVaryingAll: 400 };

const distinctCount = (list) => new Set(list.map((x) => JSON.stringify(x))).size;

/** One normalised row per variant: its (name, value) pairs, price and quantity. */
function etsyRows(variations, basePrice, sharedQuantity) {
  return variations.map((v) => {
    let pairs = [];
    const attrs = v.attributes || [];
    if (attrs.length) {
      pairs = attrs.filter((a) => a.name && a.value).map((a) => [a.name, String(a.value)]);
    } else if (v.optionValues && Object.keys(v.optionValues).length) {
      pairs = Object.entries(v.optionValues)
        .filter(([n, val]) => n && val)
        .map(([n, val]) => [n, (Array.isArray(val) ? val : [val]).map(String).join(", ")]);
    } else if (v.name) {
      pairs = [["Size", String(v.name)]];
    }
    if (!pairs.length) pairs = [["Size", "Regular"]];
    return {
      v, pairs,
      price: priceAmount(variantPriceOr(v, basePrice)),
      qty: sharedQuantity !== null && sharedQuantity !== undefined ? sharedQuantity
        : Number.isFinite(Number(v.quantity)) && Number(v.quantity) >= 0 ? Number(v.quantity) : 1,
    };
  });
}

/** Which properties exist and which of price/quantity/SKU differ per combination,
 *  and the Etsy product limit that implies. */
function etsyShape(rows) {
  const names = [];
  for (const r of rows) for (const [n] of r.pairs) if (!names.includes(n)) names.push(n);
  const realSkus = rows.map((r) => r.v.sku).filter(Boolean);
  const priceVaries = distinctCount(rows.map((r) => r.price)) > 1;
  const qtyVaries = distinctCount(rows.map((r) => r.qty)) > 1;
  // Per-combination SKUs only when the variants carry distinct ones; a missing
  // SKU stays blank (Etsy allows it) instead of an invented SKU_n.
  const skuVaries = realSkus.length > 0 && distinctCount(realSkus) > 1;
  const anyAll = priceVaries || qtyVaries || skuVaries;
  const limit = names.length <= 1 ? ETSY_MAX_PRODUCTS.one
    : anyAll ? ETSY_MAX_PRODUCTS.twoVaryingAll : ETSY_MAX_PRODUCTS.two;
  return { names, priceVaries, qtyVaries, skuVaries, anyAll, limit };
}

function assertEtsyTypes(names) {
  if (names.length > ETSY_CUSTOM_PROPERTY_IDS.length) {
    throw new HttpsError("failed-precondition",
      `Etsy supports at most ${ETSY_CUSTOM_PROPERTY_IDS.length} variation types per listing; this product has ${names.length}.`);
  }
}

/** Max variant combinations ONE Etsy listing can hold for these variants. */
function etsyGroupLimit(variations, basePrice = 0, { sharedQuantity = null } = {}) {
  const shape = etsyShape(etsyRows(variations, basePrice, sharedQuantity));
  assertEtsyTypes(shape.names);
  return shape.limit;
}

/** Etsy `PUT /listings/{id}/inventory` payload from product variants.
 *
 *  Each variation type is a custom property (513 / 514) carrying its name.
 *  `*_on_property` tells Etsy which properties drive price / quantity / SKU:
 *  empty = uniform across every product (e.g. a shared quantity pool at one
 *  price), all property ids = differs per combination. Etsy requires the
 *  fields to be all-or-empty together, which is what this produces. */
function buildEtsyInventoryPayload(variations = [], basePrice = 0, readinessStateId = null, { sharedQuantity = null } = {}) {
  const rows = etsyRows(variations, basePrice, sharedQuantity);
  const shape = etsyShape(rows);
  const { names, priceVaries, qtyVaries, skuVaries, anyAll, limit } = shape;
  assertEtsyTypes(names);
  const idFor = Object.fromEntries(names.map((n, i) => [n, ETSY_CUSTOM_PROPERTY_IDS[i]]));
  const allIds = names.map((n) => idFor[n]);

  if (rows.length > limit) {
    throw new HttpsError("failed-precondition",
      `Etsy allows at most ${limit} variant combinations on this kind of listing (${rows.length} here). `
      + (names.length > 1 && anyAll
        ? "Giving every combination its own price/quantity/SKU lowers the limit to 400; a shared quantity and one price allows 4,900."
        : "Reduce the variants or post them as separate listings."));
  }

  const products = rows.map((r) => ({
    ...(r.v.sku ? { sku: r.v.sku } : {}),
    property_values: r.pairs.map(([n, val]) => ({
      property_id: idFor[n], property_name: n, scale_id: null, value_ids: [], values: [val],
    })),
    offerings: [{ price: r.price, quantity: r.qty, is_enabled: true, ...(readinessStateId ? { readiness_state_id: readinessStateId } : {}) }],
  }));
  return {
    products,
    price_on_property: priceVaries ? allIds : [],
    quantity_on_property: qtyVaries ? allIds : [],
    sku_on_property: skuVaries ? allIds : [],
    readiness_state_on_property: [],
  };
}

/**
 * Plan the Etsy listings for a product: one listing per `etsyGroupLimit`
 * combinations, a primary-option value (a series) kept whole where it fits.
 * Same engine as eBay's (`planVariantGroups`); only the pointers differ — an
 * Etsy variant remembers its listing in `etsyGroupKey`. Variants of a product
 * already on Etsy but without a key were posted to the single legacy listing.
 *
 * @param items   [{v, i}] active variants
 * @param options product.options
 * @param legacyPosted  true when the product already has an Etsy listing
 */
function planEtsyListings(items, options, { productId, basePrice = 0, sharedQuantity = null, legacyPosted = false } = {}) {
  const limit = etsyGroupLimit(items.map((x) => x.v), basePrice, { sharedQuantity });
  return planVariantGroups(items, options, {
    productId,
    limits: { maxVariations: limit, maxDimensions: ETSY_CUSTOM_PROPERTY_IDS.length, maxValuesPerAspect: Infinity },
    keyField: "etsyGroupKey",
    postedField: "etsyGroupKey",
    legacyPosted,
  });
}

module.exports = {
  ETSY_MIN_PRICE, ETSY_CUSTOM_PROPERTY_IDS, ETSY_MAX_PRODUCTS,
  priceAmount, etsyRows, etsyShape, etsyGroupLimit, buildEtsyInventoryPayload, planEtsyListings,
};
