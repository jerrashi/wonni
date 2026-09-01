const { onCall, HttpsError, onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const geminiApiKey = defineSecret("GEMINI_API_KEY");

// Model-quality tracking (spec T1): both ride back to the client and onto the
// published listing doc, so "% similar to final output by model/prompt" can be
// compared across changes. Bump PROMPT_VERSION on ANY edit to the prompt below.
const GEMINI_MODEL = "gemini-2.5-flash-lite";
const PROMPT_VERSION = "2026-08-31.1";

exports.identifyItem = onCall({
  secrets: [geminiApiKey],
  cors: true,
  memory: "512MiB",
  timeoutSeconds: 60
}, async (request) => {
  
  console.log("Processing identification request with Gemini 3.1...");
  
  const { images, userTitle, userPrice, userDescription } = request.data;

  if (!images || !Array.isArray(images) || images.length === 0) {
    throw new HttpsError("invalid-argument", "At least one image is required.");
  }

  try {
    const genAI = new GoogleGenerativeAI(geminiApiKey.value());

    const model = genAI.getGenerativeModel({ model: GEMINI_MODEL });

    let hintStr = "";
    if (userTitle) hintStr += `- User suggested title: "${userTitle}"\n`;
    if (userPrice) hintStr += `- User suggested price: $${userPrice}\n`;
    if (userDescription) hintStr += `- User suggested description: "${userDescription}"\n`;

    const prompt = `
      Identify the item in these photos. Provide a detailed identification in JSON format.
      ${hintStr ? `\nHere is some user-provided context to help you:\n${hintStr}` : ""}
      Include:
      - name: A concise, searchable product name (no length limit).
      - shortTitle: A marketplace listing title that is AT MOST 80 characters long. It must include the most important identifying details (brand, model, key attribute). If user title context is provided, incorporate relevant specifics from it while staying under 80 characters. This will be used as the cross-platform listing title.
      - brand: The brand or manufacturer.
      - category: A hierarchical category string matching common marketplace taxonomies (e.g., "Electronics > Audio > Headphones"). Be specific — this is used to fuzzy-match against platform category trees.
      - suggestedPrice: An estimated current market price in USD (numeric).
      - description: A professional product description up to 1000 chars in length.
      - condition: The item's condition. Use exactly one of: "new", "newWithoutTags", "likeNew", "good", "fair", "poor", "forParts". Priority order: (1) If the user title or description contains explicit keywords, map them directly — "sealed", "brand new", "factory sealed" → "new"; "NWT", "new with tags" → "new"; "NWOT", "new without tags" → "newWithoutTags"; "like new", "mint", "pristine", "opened never used" → "likeNew"; "used", "pre-owned" → "good". (2) If no explicit keywords, infer from photos — visible wear, scratches, yellowing → "fair" or "poor"; clean and intact → "good". Default to "good" if uncertain.
      - weightLbs: Best guess for the item's shipping weight in pounds (numeric).
      - lengthIn: Best guess for the item's shipping length in inches (numeric).
      - widthIn: Best guess for the item's shipping width in inches (numeric).
      - heightIn: Best guess for the item's shipping height in inches (numeric).
      - confidence: Your confidence score from 0.0 to 1.0.

      IMPORTANT: shortTitle must be 80 characters or fewer. Count carefully.

      Return ONLY the JSON object.
    `;

    const imageParts = images.map((base64) => ({
      inlineData: {
        data: base64,
        mimeType: "image/jpeg",
      },
    }));

    console.log(`Calling ${GEMINI_MODEL} with ${images.length} images...`);

    const result = await model.generateContent([prompt, ...imageParts]);
    const response = await result.response;
    const text = response.text();

    console.log("Gemini responded successfully.");

    const cleanedJson = text
      .replace(/```json/g, "")
      .replace(/```/g, "")
      .trim();

    // The server is the only honest source for which model/prompt produced this
    // output — stamp it on the response for the client's quality tracking.
    return { ...JSON.parse(cleanedJson), aiModel: GEMINI_MODEL, promptVersion: PROMPT_VERSION };
  } catch (error) {
    console.error("FULL ERROR DETAIL:", error);
    throw new HttpsError("internal", `Gemini Error: ${error.message}`);
  }
});

// eBay Webhook + one-time notification subscription setup
const { ebayWebhook, setupEbayNotifications } = require("./ebay_webhook");
exports.ebayWebhook = ebayWebhook;
exports.setupEbayNotifications = setupEbayNotifications;

// eBay Token Exchange
const { ebayExchangeToken } = require("./ebay_auth");
exports.ebayExchangeToken = ebayExchangeToken;

// eBay Import
const { ebayImportListing } = require("./ebay_import");
exports.ebayImportListing = ebayImportListing;

// Etsy Token Exchange
const { etsyExchangeToken } = require("./etsy_auth");
exports.etsyExchangeToken = etsyExchangeToken;

// Etsy Listing Management
const {
  etsyCreateListing,
  etsyUpdateListing,
  etsyDeleteListing,
  etsyCheckShopSetup,
  getEtsyCategories,
  suggestEtsyCategory,
  getEtsyShippingProfiles,
  getEtsyReturnPolicies,
  etsyPullSync,
  etsyImportPullSync,
} = require("./etsy_listing");
exports.etsyCreateListing = etsyCreateListing;
exports.etsyUpdateListing = etsyUpdateListing;
exports.etsyDeleteListing = etsyDeleteListing;
exports.etsyCheckShopSetup = etsyCheckShopSetup;
exports.getEtsyCategories = getEtsyCategories;
exports.suggestEtsyCategory = suggestEtsyCategory;
exports.getEtsyShippingProfiles = getEtsyShippingProfiles;
exports.getEtsyReturnPolicies = getEtsyReturnPolicies;
exports.etsyPullSync = etsyPullSync;
exports.etsyImportPullSync = etsyImportPullSync;

// eBay Listing Management
const { ebayCreateListing, ebayUpdateListing, ebayDeleteListing, ebayPullSync, ebayImportPullSync } = require("./ebay_listing");
exports.ebayCreateListing = ebayCreateListing;
exports.ebayUpdateListing = ebayUpdateListing;
exports.ebayDeleteListing = ebayDeleteListing;
exports.ebayPullSync = ebayPullSync;
exports.ebayImportPullSync = ebayImportPullSync;

// Sale cascade — decrements quantity across all platforms when a sale occurs
const { decrementAndCascade, restockAndCascade, markSoldOutAndCascade } = require("./sale_sync");
exports.decrementAndCascade = decrementAndCascade;
exports.restockAndCascade = restockAndCascade;
exports.markSoldOutAndCascade = markSoldOutAndCascade;

// Sale take-home fetch — retrieves platform-provided net payout per order
const { ebayGetOrderTakeHome, etsyGetReceiptTakeHome } = require("./sale_fetch");
exports.ebayGetOrderTakeHome = ebayGetOrderTakeHome;
exports.etsyGetReceiptTakeHome = etsyGetReceiptTakeHome;

// Sale sync — on-demand callable to check eBay + Etsy for new orders
const { syncSales } = require("./sale_poller");
exports.syncSales = syncSales;

// Saved-search alerts — notifies users in-app when a new listing matches their saved search
const { notifySavedSearchMatches } = require("./saved_search_notify");
exports.notifySavedSearchMatches = notifySavedSearchMatches;

// Account deletion (#62) — soft-delete grace period + scheduled purge
const { requestAccountDeletion, cancelAccountDeletion, purgeDeletedAccounts } = require("./account_deletion");
exports.requestAccountDeletion = requestAccountDeletion;
exports.cancelAccountDeletion = cancelAccountDeletion;
exports.purgeDeletedAccounts = purgeDeletedAccounts;

// Post to Wonni — explicit action from wonni_dropship's web UI that creates/
// updates a `listings/{productId}` doc from a dropship `products` draft
// (status: "active" from the moment it's posted — this app has no
// in-collection "draft" listings state, see firestore.rules' comment on
// `listings`). The only dropship-merge piece live here so far; the rest of
// the pipeline (AliExpress/TikTok/Weverse import, cross-posting) stays
// commented out below until it's actually wired up.
const { postToWonni } = require("./wonni_listing");
exports.postToWonni = postToWonni;

// eBay OAuth Redirect Intermediary (legacy — kept for fallback)
exports.ebayRedirect = onRequest({ cors: true }, (req, res) => {
  const code = req.query.code;
  if (code) {
    console.log(`[eBay Redirect] Code received: ${code}. Redirecting to wonni://oauth/ebay`);
    res.redirect(`wonni://oauth/ebay?code=${code}`);
  } else {
    console.error("[eBay Redirect] Error: missing code parameter");
    res.status(400).send("Missing code parameter");
  }
});

// ─────────────────────────────────────────────────────────────────────────
// Merged from wonni_dropship (Phase B backend merge), now enabling for web app:
// The dropship web client (wonni_dropship) calls these OAuth and listing functions.
// iOS doesn't use them (it has its own eBay/marketplace integrations), so they
// were originally commented out. Uncommented 2026-08-18 when setting up web/iOS
// parity for eBay cross-posting and sign-in.
// `dropship_ebay_auth.js`/`dropship_ebay_listing.js` are renamed copies of
// dropship's own `ebay_auth.js`/`ebay_listing.js` — this project already has
// its own eBay integration under `ebayExchangeToken`/`ebayCreateListing`/etc.
// above with different eBay app credentials, so the dropship functions keep
// their own `dropshipEbay*` names to avoid colliding with them.
// ─────────────────────────────────────────────────────────────────────────

const { aliexpressExchangeToken } = require("./aliexpress_auth");
const { aliexpressImportProduct } = require("./aliexpress_product");
const { weverseImportProduct } = require("./weverse_product");
const { weverseBulkImportProducts } = require("./weverse_bulk_import");
const { splitProductImage } = require("./split_image");
const { identifyProductsInImage } = require("./identify_products");
const { placeAliexpressOrder, confirmTiktokShipment, pollAliexpressTracking } = require("./aliexpress_order");
const { tiktokExchangeToken } = require("./tiktok_auth");
const { getTiktokCategories, tiktokCreateListing, tiktokUpdateListing, tiktokDeleteListing } = require("./tiktok_listing");
const { updateMercariListingStatus } = require("./mercari_listing");
const { recordMercariSale, recordMercariSalesBatch } = require("./mercari_sale");
const { detectMercariPullSyncDiff, importMercariPullSync } = require("./mercari_pull_sync");
const { syncTiktokOrders, syncTiktokOrdersScheduled } = require("./tiktok_orders");
const { disconnectPlatform, updateSettings, generateOAuthState } = require("./user_settings");
const { onProductDeleted } = require("./product_cleanup");
const { generateProductDescription: dropshipGenerateProductDescription } = require("./generate_description");
const { publishStorageObject } = require("./publish_storage_object");

module.exports = {
  ...module.exports,
  // dropship: auth
  aliexpressExchangeToken,
  tiktokExchangeToken,

  // dropship: products/listings
  aliexpressImportProduct,
  weverseImportProduct,
  weverseBulkImportProducts,
  splitProductImage,
  identifyProductsInImage,
  generateProductDescription: dropshipGenerateProductDescription,
  onProductDeleted,
  publishStorageObject,

  // dropship: TikTok Shop listings
  getTiktokCategories,
  tiktokCreateListing,
  tiktokUpdateListing,
  tiktokDeleteListing,

  // dropship: Mercari listings
  updateMercariListingStatus,
  recordMercariSale,
  recordMercariSalesBatch,
  detectMercariPullSyncDiff,
  importMercariPullSync,

  // dropship: user settings
  generateOAuthState,
  disconnectPlatform,
  updateSettings,

  // dropship: orders + fulfillment
  syncTiktokOrders,
  syncTiktokOrdersScheduled,
  placeAliexpressOrder,
  confirmTiktokShipment,
  pollAliexpressTracking,
};
