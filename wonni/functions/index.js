const { onCall, HttpsError, onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const geminiApiKey = defineSecret("GEMINI_API_KEY");

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
    
    // Updated to the latest stable model
    const model = genAI.getGenerativeModel({ model: "gemini-3.1-flash-lite" });

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

    console.log(`Calling gemini-3.1-flash-lite with ${images.length} images...`);
    
    const result = await model.generateContent([prompt, ...imageParts]);
    const response = await result.response;
    const text = response.text();

    console.log("Gemini 3.1 responded successfully.");

    const cleanedJson = text
      .replace(/```json/g, "")
      .replace(/```/g, "")
      .trim();

    return JSON.parse(cleanedJson);
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
const { etsyCreateListing, etsyUpdateListing, etsyDeleteListing, etsyCheckShopSetup } = require("./etsy_listing");
exports.etsyCreateListing = etsyCreateListing;
exports.etsyUpdateListing = etsyUpdateListing;
exports.etsyDeleteListing = etsyDeleteListing;
exports.etsyCheckShopSetup = etsyCheckShopSetup;

// eBay Listing Management
const { ebayCreateListing, ebayUpdateListing, ebayDeleteListing } = require("./ebay_listing");
exports.ebayCreateListing = ebayCreateListing;
exports.ebayUpdateListing = ebayUpdateListing;
exports.ebayDeleteListing = ebayDeleteListing;

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
