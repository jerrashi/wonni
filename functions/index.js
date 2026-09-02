const admin = require("firebase-admin");
admin.initializeApp();

const { aliexpressExchangeToken } = require("./aliexpress_auth");
const { aliexpressImportProduct } = require("./aliexpress_product");
const { weverseImportProduct } = require("./weverse_product");
const { weverseBulkImportProducts } = require("./weverse_bulk_import");
const { splitProductImage } = require("./split_image");
const { identifyProductsInImage } = require("./identify_products");
const { placeAliexpressOrder, confirmTiktokShipment, pollAliexpressTracking } = require("./aliexpress_order");
const { tiktokExchangeToken } = require("./tiktok_auth");
const { dropshipEbayExchangeToken } = require("./ebay_auth");
const {
  dropshipEbayCreateListing,
  ebayDeleteListing,
  ebayUpdateListing,
  ebayGetListingDetails,
  ebaySyncListing,
  ebayPullSync,
  ebayImportPullSync,
} = require("./ebay_listing");
const { recoverEbayOfferIds } = require("./recover_ebay_offer_ids");
const { tiktokCreateListing, tiktokUpdateListing, tiktokDeleteListing, getTiktokCategories } = require("./tiktok_listing");
const { etsyExchangeToken } = require("./etsy_auth");
const { etsyPullSync, etsyImportPullSync } = require("./etsy_listing");
const { updateMercariListingStatus, ensureMercariListingDetails } = require("./mercari_listing");
const { syncTiktokOrders, syncTiktokOrdersScheduled } = require("./tiktok_orders");
const { disconnectPlatform, updateSettings, generateOAuthState } = require("./user_settings");
const { onProductDeleted } = require("./product_cleanup");
const { generateProductDescription } = require("./generate_description");
const { aiAutofillListing } = require("./listing_fields");

module.exports = {
  // Auth
  aliexpressExchangeToken,
  tiktokExchangeToken,
  dropshipEbayExchangeToken,
  ebayExchangeToken: dropshipEbayExchangeToken,
  etsyExchangeToken,

  // Products
  aliexpressImportProduct,
  weverseImportProduct,
  weverseBulkImportProducts,
  splitProductImage,
  identifyProductsInImage,
  generateProductDescription,
  aiAutofillListing,
  onProductDeleted,

  // TikTok Shop listings
  getTiktokCategories,
  tiktokCreateListing,
  tiktokUpdateListing,
  tiktokDeleteListing,
  getTiktokCategories,

  // eBay listings
  dropshipEbayCreateListing,
  // Alias for web app compatibility (unified backend naming)
  ebayCreateListing: dropshipEbayCreateListing,
  ebayDeleteListing,
  ebayUpdateListing,
  ebayGetListingDetails,
  ebaySyncListing,
  ebayPullSync,
  ebayImportPullSync,
  recoverEbayOfferIds,

  // Etsy listings
  etsyPullSync,
  etsyImportPullSync,

  // Mercari listings
  updateMercariListingStatus,
  ensureMercariListingDetails,

  // User settings
  generateOAuthState,
  disconnectPlatform,
  updateSettings,

  // Orders + fulfillment
  syncTiktokOrders,
  syncTiktokOrdersScheduled,
  placeAliexpressOrder,
  confirmTiktokShipment,
  pollAliexpressTracking,
};
