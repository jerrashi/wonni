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
// UserListing.ShippingInfo — built from products' own flat shipping fields
// (matching how iOS's Item stores them during drafting too; only the final
// published listing nests them). Defaults match Item's own init defaults
// exactly (Models/Listing.swift) so a product looks the same regardless of
// which client created it.
function toShippingInfo({ buyerPaysShipping, handlingFee, estimatedShippingDays, handlingTimeDays, weightLbs, lengthIn, widthIn, heightIn }) {
  const packageDimensions = (lengthIn != null && widthIn != null && heightIn != null)
    ? { lengthIn, widthIn, heightIn }
    : null;
  return {
    buyerPaysShipping: buyerPaysShipping ?? true,
    handlingFee: handlingFee ?? 0,
    estimatedShippingDays: estimatedShippingDays ?? 3,
    weightLbs: weightLbs ?? null,
    packageDimensions,
    handlingTimeDays: handlingTimeDays ?? null,
  };
}

// UserListing.AIQualityTracking — only built if the product actually carries
// an AI suggestion (either origin: dropship's gemini_identify.js or iOS's
// on-device Gemini call both write products.aiSuggestedTitle/Description/
// Price under the same field names). `titleEdited`/etc. mirror exactly what
// AIQualityTracking.from(...) computes client-side in UploadManager.swift.
function toAITracking({ title, description, price, aiSuggestedTitle, aiSuggestedDescription, aiSuggestedPrice, aiModel, aiPromptVersion }) {
  if (!aiSuggestedTitle && !aiSuggestedDescription && aiSuggestedPrice == null) return null;
  return {
    aiSuggestedTitle: aiSuggestedTitle ?? null,
    aiSuggestedDescription: aiSuggestedDescription ?? null,
    aiSuggestedPrice: aiSuggestedPrice ?? null,
    // visionTitle/undoCount are iOS on-device-Vision-framework and
    // "Undo AI edit"-button concepts specifically — dropship's import flow
    // has no equivalent, so these stay their Swift-default values (nil/0)
    // for a dropship-originated product rather than being invented here.
    visionTitle: null,
    visionTitleAccepted: false,
    aiModel: aiModel ?? null,
    promptVersion: aiPromptVersion ?? null,
    titleEdited: !!(aiSuggestedTitle && title && title !== aiSuggestedTitle),
    descriptionEdited: !!(aiSuggestedDescription && description && description !== aiSuggestedDescription),
    priceEdited: !!(aiSuggestedPrice != null && price != null && price !== aiSuggestedPrice),
    undoCount: 0,
  };
}

function toListingFields({
  title, description, price, images, options, variants, condition, category, brand,
  aiSuggestedTitle, aiSuggestedDescription, aiSuggestedPrice, aiModel, aiPromptVersion,
  buyerPaysShipping, handlingFee, estimatedShippingDays, handlingTimeDays,
  weightLbs, lengthIn, widthIn, heightIn, tags, personalNote,
}) {
  const aiTracking = toAITracking({ title, description, price, aiSuggestedTitle, aiSuggestedDescription, aiSuggestedPrice, aiModel, aiPromptVersion });
  return {
    customTitle: title ?? null,
    customDescription: description ?? null,
    price: typeof price === "number" ? price : null,
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
    // Prefer the product's own condition (iOS's rich per-item condition,
    // e.g. "good"/"likeNew", already synced onto `products.condition` by
    // UploadManager.syncProductData) — dropship's own imports never set
    // this today, so "new" stays the right fallback for that pipeline
    // specifically (dropshipped imports are always new stock).
    condition: condition ?? "new",
    ...(category ? { category } : {}),
    ...(brand ? { brand } : {}),
    ...(tags?.length ? { tags } : {}),
    ...(personalNote ? { personalNote } : {}),
    shippingInfo: toShippingInfo({ buyerPaysShipping, handlingFee, estimatedShippingDays, handlingTimeDays, weightLbs, lengthIn, widthIn, heightIn }),
    ...(aiTracking ? { aiTracking } : {}),
    // No `status` here deliberately: wonni-app's `listings` collection has
    // no in-collection "draft" state (every query — home feed, search, even
    // the owner's own "My Listings" — filters to status == "active"/"sold";
    // its own firestore.rules comment says "Drafts live only in SwiftData
    // until publish"). So this mapping only ever runs from `postToWonni`
    // (functions/wonni_listing.js), which sets `status: "active"` itself at
    // the moment of the user's explicit "Post to Wonni" action — dropship's
    // own `products` collection is the one and only draft store.
    sourceAssetIdentifiers: [],
    geminiIdentificationConfirmed: false,
  };
}

// ── listings/{id} (UserListing) → products/{id} — one-shot migration mapper ──
// (BACKEND.md step 7 — retire the iOS per-user `listings/{uuid}` model). Pure;
// unit-tested. The Cloud Functions runtime never calls this — only
// scripts/migrate_listings_to_products.js does.

// iOS ListingStatus / crossPostStatus "posted" → canonical values.
const CROSSPOST_STATUS_MAP = { posted: "active", active: "active", failed: "failed", draft: "draft", inactive: "inactive", sold: "sold" };
function normalizeCrossPostStatus(map) {
  const out = {};
  for (const [k, v] of Object.entries(map || {})) {
    if (v == null) continue;
    out[k] = CROSSPOST_STATUS_MAP[String(v).toLowerCase()] || String(v);
  }
  return out;
}

// iOS ItemCondition (7-value) / keyword → canonical new|likenew|good|fair|poor.
const CONDITION_MAP = {
  new: "new", newwithtags: "new", newwithouttags: "new", sealed: "new",
  likenew: "likenew", like_new: "likenew", mint: "likenew",
  good: "good", used: "good", preowned: "good",
  fair: "fair", poor: "poor", forparts: "poor", for_parts: "poor",
};
function normalizeCondition(raw) {
  if (typeof raw !== "string") return null;
  return CONDITION_MAP[raw.toLowerCase().replace(/[\s-]/g, "")] || null;
}

/**
 * Build the `products/{id}` doc for a `listings/{id}` (UserListing). `id` is
 * reused verbatim so the marketplace `listings/{id}` doc and everything keyed
 * off it (Sale.listingId, eBay SKU `wonni_${id}`) still line up.
 * Returns a plain object — the script stamps server timestamps + merges.
 */
function listingDocToProduct(listing, id) {
  const status = listing.status || "active";           // "active" | "sold" | "draft"
  const isDraft = status === "draft";
  const variations = Array.isArray(listing.variations) ? listing.variations : [];
  const ship = listing.shippingInfo || {};
  const dims = ship.packageDimensions || {};

  const crossPostStatus = normalizeCrossPostStatus(listing.crossPostStatus);
  const crossPostListingIds = { ...(listing.crossPostListingIds || {}) };
  // The listing IS the live Wonni marketplace entry.
  if (!isDraft) {
    crossPostStatus.wonni = status === "sold" ? "sold" : "active";
    crossPostListingIds.wonni = id;
  }

  return {
    userId: listing.userId,
    source: "ios-listing",
    sourceId: id,

    title: listing.customTitle || "",
    description: listing.customDescription || "",
    category: listing.category || null,
    brand: listing.brand || null,
    condition: normalizeCondition(listing.condition) || "good",
    saleStatus: status === "sold" ? "sold" : "active",
    isDraft,

    listingPrice: typeof listing.price === "number" ? listing.price : null,
    quantity: typeof listing.quantity === "number" ? listing.quantity : 1,

    images: Array.isArray(listing.photoPaths) ? listing.photoPaths : [],
    options: Array.isArray(listing.options) ? listing.options : [],
    variants: variations.map((v) => {
      const mapped = variationToVariant(v);
      return {
        id: mapped.id,
        optionValues: mapped.optionValues,
        sku: mapped.sku,
        price: mapped.price,
        quantity: typeof mapped.quantity === "number" ? mapped.quantity : 1,
        active: true,
        crossPostStatus: normalizeCrossPostStatus(v.crossPostStatus),
        crossPostListingIds: { ...(v.crossPostListingIds || {}) },
      };
    }),

    crossPostStatus,
    crossPostListingIds,

    // Flat shipping fields (dropship product shape — read by
    // ebayPackageWeightAndSize / listing_shape.toShippingInfo).
    ...(typeof ship.weightLbs === "number" && ship.weightLbs > 0 ? { weightLbs: ship.weightLbs } : {}),
    ...(typeof ship.handlingFee === "number" ? { handlingFee: ship.handlingFee } : {}),
    ...(typeof ship.estimatedShippingDays === "number" ? { estimatedShippingDays: ship.estimatedShippingDays } : {}),
    ...(typeof ship.buyerPaysShipping === "boolean" ? { buyerPaysShipping: ship.buyerPaysShipping } : {}),
    ...(typeof dims.lengthIn === "number" ? { lengthIn: dims.lengthIn } : {}),
    ...(typeof dims.widthIn === "number" ? { widthIn: dims.widthIn } : {}),
    ...(typeof dims.heightIn === "number" ? { heightIn: dims.heightIn } : {}),

    ...(Array.isArray(listing.tags) && listing.tags.length ? { tags: listing.tags } : {}),
    ...(listing.personalNote ? { personalNote: listing.personalNote } : {}),
    ...(listing.pendingMercariDeactivation ? { pendingMercariDeactivation: true } : {}),
    ...(listing.pendingMercariRelist ? { pendingMercariRelist: true } : {}),
    ...(listing.aiSuggestedTitle ? { aiSuggestedTitle: listing.aiSuggestedTitle } : {}),
    ...(listing.aiSuggestedDescription ? { aiSuggestedDescription: listing.aiSuggestedDescription } : {}),

    migratedFromListing: true,
  };
}

module.exports = {
  optionValuesToAttributes,
  attributesToOptionValues,
  variantToVariation,
  variationToVariant,
  toListingFields,
  listingDocToProduct,
  normalizeCondition,
  normalizeCrossPostStatus,
};
