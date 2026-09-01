function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function listingImagesFor(product, limit) {
  let images = [];
  if (Array.isArray(product.listingImages) && product.listingImages.length) {
    images = product.listingImages;
  } else if (Array.isArray(product.imageAssets) && product.imageAssets.length) {
    images = product.imageAssets.map(a => typeof a === "string" ? a : a?.url).filter(Boolean);
  } else if (Array.isArray(product.photoPaths) && product.photoPaths.length) {
    images = product.photoPaths;
  } else if (Array.isArray(product.images) && product.images.length) {
    images = product.images.map(img => typeof img === "string" ? img : img?.url).filter(Boolean);
  }

  images = images.map(img => {
    if (!img) return "";
    if (typeof img === "object") img = img.url || "";
    if (typeof img !== "string") return "";
    if (img.startsWith("http://") || img.startsWith("https://") || img.startsWith("data:")) return img;
    return `https://firebasestorage.googleapis.com/v0/b/wonni-app.firebasestorage.app/o/${encodeURIComponent(img)}?alt=media`;
  }).filter(Boolean);

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

// Build eBay item variations from product variants/options.
// Returns { itemSpecifics, variations } for multi-variant inventory items.
function buildEbayVariations(product) {
  const variants = Array.isArray(product.variants) ? product.variants : [];
  const options = Array.isArray(product.options) ? product.options : [];

  if (variants.length === 0 || options.length === 0) {
    return null;
  }

  // Collect option names (eBay calls these "item specifics")
  const itemSpecifics = options.reduce((acc, opt) => {
    acc[opt.name] = opt.values || [];
    return acc;
  }, {});

  // Build variation entries: each has its own SKU, price, quantity, and option values
  const ebayVariations = variants
    .filter((v) => v.active !== false)
    .map((variant, index) => {
      const variantSku = variant.sku || `${product.id}-${index}`;
      const variantPrice = variant.price ?? product.listingPrice ?? null;
      const variantQty = typeof variant.quantity === "number" && variant.quantity >= 0
        ? variant.quantity
        : (variant.quantity != null && !isNaN(variant.quantity) ? Math.max(0, Number(variant.quantity)) : 0);

      return {
        sku: variantSku.slice(0, 64), // eBay SKU limit
        price: variantPrice,
        quantity: variantQty,
        itemSpecifics: variant.optionValues || {}, // e.g., { "Size": "M", "Color": "Red" }
      };
    });

  return ebayVariations.length > 0 ? { itemSpecifics, variations: ebayVariations } : null;
}

module.exports = {
  listingImagesFor,
  canonicalDescription,
  toEbayInventoryProduct,
  toTiktokProductPayload,
  toEtsyDraftListing,
  buildEbayVariations,
};
