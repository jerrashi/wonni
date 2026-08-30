// Product schema transformation helper
// Converts between old and new schema formats

// New unified schema structure for all products
function buildNewProductDoc(rawData) {
  // Helper to filter out undefined values
  const cleanObject = (obj) => {
    const cleaned = {};
    for (const [key, value] of Object.entries(obj)) {
      if (value !== undefined) {
        cleaned[key] = value;
      }
    }
    return cleaned;
  };

  return cleanObject({
    // Core
    userId: rawData.userId,
    source: rawData.source, // "weverse", "aliexpress", "photo_upload", etc.
    sourceId: rawData.sourceId, // weverseSaleId, aliexpressId, etc.
    ...(rawData.sourceUrl && { sourceUrl: rawData.sourceUrl }),

    // Basic info
    title: rawData.title,
    description: rawData.description,
    category: rawData.category || null,
    brand: rawData.brand || null,
    condition: rawData.condition || "new",
    saleStatus: rawData.saleStatus || "active",
    isDraft: rawData.isDraft !== false,

    // Pricing (unified)
    sourceCost: rawData.sourceCost ?? rawData.sourcePrice ?? rawData.aliexpressPrice,
    listingPrice: rawData.listingPrice || null,

    // Images
    sourceImages: rawData.sourceImages || [], // Original source URLs (Weverse CDN, AliExpress, etc.)
    images: rawData.images || [], // Google Storage copies
    imageAssets: rawData.imageAssets || [], // Detailed metadata

    // Options and variants
    options: rawData.options || [],
    variants: (rawData.variants || []).map(v => ({
      id: v.id,
      optionValues: v.optionValues || {},
      sku: v.sku || null,
      sourceCost: v.sourceCost ?? v.sourcePrice,
      price: v.price || null,
      quantity: v.quantity || 1,
      active: v.active !== false,
      sourceVariantId: v.sourceVariantId || null,
      // Platform cross-post status
      crossPostStatus: {
        ebay: v.ebayStatus || null,
        etsy: v.etsyStatus || null,
        mercari: v.mercariStatus || null,
        tiktok: v.tiktokStatus || null,
      },
      crossPostListingIds: {
        ebay: v.ebayListingId || null,
        etsy: v.etsyListingId || null,
        mercari: v.mercariListingId || null,
        tiktok: v.tiktokListingId || null,
      },
      mercariUrl: v.mercariUrl || null,
    })),

    // Cross-post status (product level)
    crossPostStatus: {
      ebay: rawData.ebayStatus || null,
      etsy: rawData.etsyStatus || null,
      mercari: rawData.mercariStatus || null,
      tiktok: rawData.tiktokStatus || "draft",
    },
    crossPostListingIds: {
      ebay: rawData.ebayListingId || null,
      etsy: rawData.etsyListingId || null,
      mercari: rawData.mercariListingId || null,
      tiktok: rawData.tiktokListingId || null,
    },

    // Source-specific fields
    ...(rawData.source === "weverse" && {
      ...(rawData.weverseSaleId && { weverseSaleId: rawData.weverseSaleId }),
      ...(rawData.weverseArtistId && { weverseArtistId: rawData.weverseArtistId }),
      weverseInfoTable: rawData.weverseInfoTable || [],
      ...(rawData.artistName && { artistName: rawData.artistName }),
    }),
    ...(rawData.source === "aliexpress" && {
      ...(rawData.aliexpressProductId && { aliexpressProductId: rawData.aliexpressProductId }),
      ...(rawData.aliexpressUrl && { aliexpressUrl: rawData.aliexpressUrl }),
    }),

    // AI suggestions
    aiSuggestedTitle: rawData.aiSuggestedTitle || null,
    aiSuggestedPrice: rawData.aiSuggestedPrice || null,
    aiSuggestedDescription: rawData.aiSuggestedDescription || null,

    // Metadata
    importedAt: rawData.importedAt || new Date(),
    updatedAt: rawData.updatedAt || new Date(),
  });
}

// Extract source image URLs from imageAssets or fall back to images
function extractSourceImages(imageAssets, images) {
  if (Array.isArray(imageAssets) && imageAssets.length > 0) {
    return imageAssets
      .map(asset => asset.sourceUrl || asset.url)
      .filter(Boolean);
  }
  return images || [];
}

module.exports = {
  buildNewProductDoc,
  extractSourceImages,
};
