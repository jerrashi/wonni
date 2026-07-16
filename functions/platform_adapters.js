function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function listingImagesFor(product, limit) {
  const images = Array.isArray(product.listingImages) && product.listingImages.length
    ? product.listingImages
    : Array.isArray(product.images)
      ? product.images
      : [];
  return typeof limit === "number" ? images.slice(0, limit) : images;
}

function canonicalDescription(product) {
  return cleanText(product.description) || cleanText(product.title);
}

function toEbayInventoryProduct(product, { imageLimit = 12, title } = {}) {
  return {
    title: cleanText(title ?? product.title).slice(0, 80),
    description: canonicalDescription(product),
    imageUrls: listingImagesFor(product, imageLimit),
    aspects: product.ebayAspects ?? {},
  };
}

function toTiktokProductPayload(product, { titleOverride, price, categoryId } = {}) {
  return {
    title: cleanText(titleOverride ?? product.title).slice(0, 255),
    description: canonicalDescription(product),
    category_id: categoryId,
    images: listingImagesFor(product, 9),
    price,
    attributes: product.tiktokAttributes ?? [],
  };
}

function toEtsyDraftListing(product, { taxonomyId, price, quantity = 1 } = {}) {
  return {
    title: cleanText(product.title).slice(0, 140),
    description: canonicalDescription(product),
    quantity,
    price,
    who_made: product.etsyWhoMade ?? "i_did",
    when_made: product.etsyWhenMade ?? "made_to_order",
    taxonomy_id: taxonomyId,
    image_ids: [],
    properties: product.etsyProperties ?? [],
  };
}

module.exports = {
  listingImagesFor,
  canonicalDescription,
  toEbayInventoryProduct,
  toTiktokProductPayload,
  toEtsyDraftListing,
};
