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
const { ebayExchangeToken } = require("./ebay_auth");
const {
  ebayCreateListing,
  ebayDeleteListing,
  ebayUpdateListing,
  ebayGetListing,
  ebayGetListingDetails,
  ebaySyncListing,
  ebayPullSync,
  ebayImportPullSync,
} = require("./ebay_listing");
const { recoverEbayOfferIds } = require("./recover_ebay_offer_ids");
const { tiktokCreateListing, tiktokUpdateListing, tiktokDeleteListing, getTiktokCategories } = require("./tiktok_listing");
const { etsyExchangeToken } = require("./etsy_auth");
const {
  etsyCreateListing, etsyUpdateListing, etsyDeleteListing, etsyCheckShopSetup,
  etsyPullSync, etsyImportPullSync,
  getEtsyCategories, suggestEtsyCategory, getEtsyShippingProfiles, getEtsyReturnPolicies,
} = require("./etsy_listing");
const { updateMercariListingStatus, ensureMercariListingDetails } = require("./mercari_listing");
const { syncTiktokOrders, syncTiktokOrdersScheduled } = require("./tiktok_orders");
const { disconnectPlatform, updateSettings, generateOAuthState, updateSaleStages } = require("./user_settings");
const { onProductDeleted } = require("./product_cleanup");
const { generateProductDescription } = require("./generate_description");
const { aiAutofillListing } = require("./listing_fields");
const { enrichListing } = require("./enrichment");
const { publishStorageObject } = require("./publish_storage_object");
const {
  recordSale,
  decrementAndCascade,
  restockAndCascade,
  markSoldOutAndCascade,
  updateSaleStatus,
} = require("./sales");
const { recordMercariSalesBatch } = require("./mercari_sales");
const { syncSales, getOrderTakeHome } = require("./sale_poller");
const { postToWonni } = require("./wonni_listing");

module.exports = {
  // Auth
  aliexpressExchangeToken,
  tiktokExchangeToken,
  ebayExchangeToken,
  etsyExchangeToken,

  // Products
  aliexpressImportProduct,
  weverseImportProduct,
  weverseBulkImportProducts,
  splitProductImage,
  identifyProductsInImage,
  generateProductDescription,
  aiAutofillListing,
  enrichListing,
  onProductDeleted,
  publishStorageObject,

  // TikTok Shop listings
  getTiktokCategories,
  tiktokCreateListing,
  tiktokUpdateListing,
  tiktokDeleteListing,
  getTiktokCategories,

  // eBay listings
  ebayCreateListing,
  ebayDeleteListing,
  ebayUpdateListing,
  ebayGetListing,
  ebayGetListingDetails,
  ebaySyncListing,
  ebayPullSync,
  ebayImportPullSync,
  recoverEbayOfferIds,

  // Etsy listings
  etsyCreateListing,
  etsyUpdateListing,
  etsyDeleteListing,
  etsyCheckShopSetup,
  etsyPullSync,
  etsyImportPullSync,
  getEtsyCategories,
  suggestEtsyCategory,
  getEtsyShippingProfiles,
  getEtsyReturnPolicies,

  // Mercari listings
  updateMercariListingStatus,
  ensureMercariListingDetails,

  // User settings
  generateOAuthState,
  disconnectPlatform,
  updateSettings,
  updateSaleStages,

  // Orders + fulfillment
  syncTiktokOrders,
  syncTiktokOrdersScheduled,
  placeAliexpressOrder,
  confirmTiktokShipment,
  pollAliexpressTracking,

  // Sales + quantity cascade
  recordSale,
  decrementAndCascade,
  restockAndCascade,
  markSoldOutAndCascade,
  recordMercariSalesBatch,
  syncSales,
  getOrderTakeHome,
  updateSaleStatus,
  postToWonni,
};
