// Schema compatibility layer - reads both old and new schemas
// Allows gradual migration without breaking the UI

export function getSourceCost(product) {
  // New schema
  if (product.sourceCost !== undefined) return product.sourceCost;
  // Old schema
  if (product.sourcePrice !== undefined) return product.sourcePrice;
  if (product.aliexpressPrice !== undefined) return product.aliexpressPrice;
  return null;
}

export function getSourceImages(product) {
  // New schema: preserved source URLs
  if (product.sourceImages && product.sourceImages.length > 0) {
    return product.sourceImages;
  }
  // Fallback to regular images
  return product.images || [];
}

export function getCrossPostStatus(product, platform) {
  // New schema
  if (product.crossPostStatus?.[platform]) {
    return product.crossPostStatus[platform];
  }
  // Old schema: map platform-specific fields
  const statusMap = {
    ebay: product.ebayStatus,
    etsy: product.etsyStatus,
    mercari: product.mercariStatus || product.listingStatus?.mercari,
    tiktok: product.tiktokStatus,
  };
  return statusMap[platform] || null;
}

export function getCrossPostListingId(product, platform) {
  // New schema
  if (product.crossPostListingIds?.[platform]) {
    return product.crossPostListingIds[platform];
  }
  // Old schema: map platform-specific fields
  const idMap = {
    ebay: product.ebayListingId,
    etsy: product.etsyListingId,
    mercari: product.mercariListingId || product.listingId?.mercari,
    tiktok: product.tiktokListingId,
  };
  return idMap[platform] || null;
}

export function isPostedToPlatform(product, platform) {
  const status = getCrossPostStatus(product, platform);
  const listingId = getCrossPostListingId(product, platform);
  return status === "active" || !!listingId;
}

export function getAllPostedPlatforms(product) {
  const platforms = ["ebay", "etsy", "mercari", "tiktok"];
  return platforms.filter(p => isPostedToPlatform(product, p));
}
