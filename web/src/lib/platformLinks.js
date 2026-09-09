/**
 * Resolves the live listing URL for a given platform and product.
 * Falls back to active seller listings / shop dashboard if individual listing ID is not available.
 *
 * @param {string} platformId - 'wonni' | 'ebay' | 'etsy' | 'mercari' | 'tiktok'
 * @param {object} product - Product document data
 * @returns {string|null} Full URL to the live listing or platform management page
 */
export function getPlatformListingUrl(platformId, product) {
  if (!product) return null;

  switch (platformId) {
    case "ebay": {
      if (product.ebayListingUrl && product.ebayListingUrl.startsWith("http")) {
        return product.ebayListingUrl;
      }
      // eBay Item IDs are numeric strings (e.g. 147542181716)
      const itemId = product.ebayListingId || product.crossPostListingIds?.ebay;
      if (itemId && /^\d+$/.test(String(itemId).trim())) {
        return `https://www.ebay.com/itm/${String(itemId).trim()}`;
      }
      return "https://www.ebay.com/sh/lst/active";
    }
    case "etsy": {
      if (product.etsyListingUrl && product.etsyListingUrl.startsWith("http")) {
        return product.etsyListingUrl;
      }
      const id = product.etsyListingId || product.crossPostListingIds?.etsy;
      if (id && /^\d+$/.test(String(id).trim())) {
        return `https://www.etsy.com/listing/${String(id).trim()}`;
      }
      return "https://www.etsy.com/your/shops/me/dashboard";
    }
    case "mercari": {
      if (product.mercariUrl && product.mercariUrl.startsWith("http")) {
        return product.mercariUrl;
      }
      const variants = Array.isArray(product.variants) ? product.variants : [];
      const vUrl = variants.find((v) => v.mercariUrl && v.mercariUrl.startsWith("http"))?.mercariUrl;
      if (vUrl) return vUrl;
      const id = product.mercariListingId || product.crossPostListingIds?.mercari;
      if (id) {
        return `https://www.mercari.com/us/item/${String(id).trim()}`;
      }
      return "https://www.mercari.com/mypage/listings/active/";
    }
    case "tiktok": {
      if (product.tiktokListingUrl && product.tiktokListingUrl.startsWith("http")) {
        return product.tiktokListingUrl;
      }
      const id = product.tiktokListingId || product.crossPostListingIds?.tiktok;
      if (id && /^\d+$/.test(String(id).trim())) {
        return `https://shop.tiktok.com/view/product/${String(id).trim()}`;
      }
      return "https://seller-us.tiktok.com/product/list";
    }
    case "wonni": {
      if (product.wonniListingUrl || product.wonniUrl) return product.wonniListingUrl || product.wonniUrl;
      if (product.id) return `/products/${product.id}`;
      return "/";
    }
    default:
      return null;
  }
}
