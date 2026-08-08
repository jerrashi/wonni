// Shared field-name mapping between dropship's internal working shape
// (options/variants with `optionValues` dicts, one flat status field per
// platform: ebayStatus/tiktokStatus/mercariStatus) and the `listings`
// collection's shared shape (wonni-app's `UserListing` Swift struct,
// `~/Documents/GitHub/wonni/wonni/wonni/Models/UserListing.swift`) that both
// products now read/write. Centralized here so every import/cross-post
// function converts the same way instead of re-deriving the mapping.

// { Size: "L", Color: "Red" } -> [{ name: "Size", value: "L" }, ...]
function optionValuesToAttributes(optionValues) {
  return Object.entries(optionValues ?? {}).map(([name, value]) => ({ name, value }));
}

// Inverse of optionValuesToAttributes.
function attributesToOptionValues(attributes) {
  const out = {};
  (attributes ?? []).forEach(({ name, value }) => { out[name] = value; });
  return out;
}

// dropship variant -> UserListing.ListingVariation. Mercari posts one
// listing per variant (no variant concept on Mercari itself), so its
// status/id/url ride on the variation, not the parent listing.
function variantToVariation(v) {
  const crossPostStatus = {};
  const crossPostListingIds = {};
  if (v.mercariStatus) crossPostStatus.mercari = v.mercariStatus;
  if (v.mercariListingId) crossPostListingIds.mercari = v.mercariListingId;
  if (v.mercariUrl) crossPostListingIds.mercariUrl = v.mercariUrl;

  return {
    id: v.id,
    attributes: optionValuesToAttributes(v.optionValues),
    price: typeof v.price === "number" ? v.price : null,
    quantity: typeof v.quantity === "number" ? v.quantity : null,
    sku: v.sku ?? null,
    ...(Object.keys(crossPostStatus).length ? { crossPostStatus } : {}),
    ...(Object.keys(crossPostListingIds).length ? { crossPostListingIds } : {}),
  };
}

// UserListing.ListingVariation -> dropship variant.
function variationToVariant(variation) {
  return {
    id: variation.id,
    optionValues: attributesToOptionValues(variation.attributes),
    price: variation.price ?? null,
    quantity: variation.quantity ?? null,
    sku: variation.sku ?? null,
    mercariStatus: variation.crossPostStatus?.mercari ?? null,
    mercariListingId: variation.crossPostListingIds?.mercari ?? null,
    mercariUrl: variation.crossPostListingIds?.mercariUrl ?? null,
  };
}

// dropship's product/import fields -> a new `listings/{id}` doc (UserListing shape).
// Callers still set userId, aliexpress/weverse-specific import fields (e.g.
// aliexpressProductId), and photoPaths/images separately — this only maps
// the fields that are the same concept under a different name.
function toListingFields({ title, description, images, options, variants }) {
  return {
    customTitle: title ?? null,
    customDescription: description ?? null,
    photoPaths: images ?? [],
    coverPhotoPath: images?.[0] ?? null,
    variations: (variants ?? []).map(variantToVariation),
    // dropship's `options` array (ordered dimension names + every allowed
    // value, including values with no variant yet) has no equivalent field
    // in UserListing — `variations[].attributes` only carries names/values
    // that already exist on a real variant, so ordering/unused values would
    // be lost without this. Stored verbatim under dropship's own field name
    // so a future ProductDetail.jsx migration can read it straight back;
    // Firestore's Codable decoding on iOS silently ignores fields it
    // doesn't declare, so this is invisible to (and never displayed by) the
    // iOS app — exactly the "optional, not lost, not shown" the field
    // should be.
    options: options ?? [],
    currency: "USD",
    // Dropshipped imports are always new stock — there's no used-condition
    // concept in this pipeline today.
    condition: "new",
    // Draft = private to the owner under wonni-app's firestore.rules
    // (`listings/{listingId}`: non-draft is world-readable). dropship
    // listings aren't meant to appear in wonni-app's own browse/marketplace
    // UI — "draft" here means "not a wonni-app marketplace listing", not
    // "unfinished" — it only reflects cross-post status on external
    // platforms via crossPostStatus/crossPostListingIds.
    status: "draft",
    sourceAssetIdentifiers: [],
    geminiIdentificationConfirmed: false,
  };
}

module.exports = {
  optionValuesToAttributes,
  attributesToOptionValues,
  variantToVariation,
  variationToVariant,
  toListingFields,
};
