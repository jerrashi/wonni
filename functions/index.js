const admin = require("firebase-admin");
admin.initializeApp();

const { aliexpressExchangeToken } = require("./aliexpress_auth");
const { aliexpressImportProduct } = require("./aliexpress_product");
const { placeAliexpressOrder, confirmTiktokShipment, pollAliexpressTracking } = require("./aliexpress_order");
const { tiktokExchangeToken } = require("./tiktok_auth");
const { tiktokCreateListing, tiktokUpdateListing, tiktokDeleteListing } = require("./tiktok_listing");
const { syncTiktokOrders, syncTiktokOrdersScheduled } = require("./tiktok_orders");
const { disconnectPlatform, updateSettings } = require("./user_settings");

module.exports = {
  // Auth
  aliexpressExchangeToken,
  tiktokExchangeToken,

  // Products
  aliexpressImportProduct,

  // TikTok Shop listings
  tiktokCreateListing,
  tiktokUpdateListing,
  tiktokDeleteListing,

  // User settings
  disconnectPlatform,
  updateSettings,

  // Orders + fulfillment
  syncTiktokOrders,
  syncTiktokOrdersScheduled,
  placeAliexpressOrder,
  confirmTiktokShipment,
  pollAliexpressTracking,
};
