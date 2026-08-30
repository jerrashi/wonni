const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { ebayRequest, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME } = require("./ebay_auth");
const { toEbayInventoryProduct, canonicalDescription, listingImagesFor, buildEbayVariations } = require("./platform_adapters");

const MARKETPLACE_ID = "EBAY_US";

// Default sell price when the user doesn't override one in the UI.
// Rough eBay economics: ~13.25% final value fee + $0.30 per order, plus you pay
// Weverse price + Weverse shipping to you + shipping to the buyer.
function computeEbaySellPrice(product) {
  const cost = product.sourcePrice ?? product.aliexpressPrice ?? 0;
  if (product.listingPrice) return product.listingPrice;
  // markup covers fees (~13.5%), ~US shipping, and margin
  return Math.ceil((cost * 1.35 + 8) * 100) / 100;
}

// First existing inventory location — eBay requires one to publish an offer.
async function getMerchantLocationKey(uid) {
  const result = await ebayRequest(uid, "GET", "/sell/inventory/v1/location?limit=1");
  const key = result?.locations?.[0]?.merchantLocationKey;
  if (!key) {
    throw new HttpsError(
      "failed-precondition",
      "No eBay inventory location found. Create one in Seller Hub (or via the Inventory API) with your ship-from address first."
    );
  }
  return key;
}

// First business policy of each type — eBay offers require all three.
async function getListingPolicies(uid) {
  const [fulfillment, payment, returns] = await Promise.all([
    ebayRequest(uid, "GET", `/sell/account/v1/fulfillment_policy?marketplace_id=${MARKETPLACE_ID}`),
    ebayRequest(uid, "GET", `/sell/account/v1/payment_policy?marketplace_id=${MARKETPLACE_ID}`),
    ebayRequest(uid, "GET", `/sell/account/v1/return_policy?marketplace_id=${MARKETPLACE_ID}`),
  ]);

  const policies = {
    fulfillmentPolicyId: fulfillment?.fulfillmentPolicies?.[0]?.fulfillmentPolicyId,
    paymentPolicyId: payment?.paymentPolicies?.[0]?.paymentPolicyId,
    returnPolicyId: returns?.returnPolicies?.[0]?.returnPolicyId,
  };

  if (!policies.fulfillmentPolicyId || !policies.paymentPolicyId || !policies.returnPolicyId) {
    throw new HttpsError(
      "failed-precondition",
      "Missing eBay business policies (shipping/payment/return). Opt in to business policies in Seller Hub and create one of each."
    );
  }
  return policies;
}

// Auto-pick a category from the title via the Taxonomy API
async function suggestCategoryId(uid, title) {
  const tree = await ebayRequest(
    uid, "GET", `/commerce/taxonomy/v1/get_default_category_tree_id?marketplace_id=${MARKETPLACE_ID}`
  );
  const treeId = tree?.categoryTreeId ?? "0";
  const suggestions = await ebayRequest(
    uid, "GET",
    `/commerce/taxonomy/v1/category_tree/${treeId}/get_category_suggestions?q=${encodeURIComponent(title.slice(0, 80))}`
  );
  const categoryId = suggestions?.categorySuggestions?.[0]?.category?.categoryId;
  if (!categoryId) throw new HttpsError("not-found", "eBay could not suggest a category for this title.");
  return categoryId;
}

// One-click list a product draft on eBay: inventory item → offer → publish
exports.dropshipEbayCreateListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME], timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, sellPrice, quantity, credentialSet } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    // credentialSet is passed by web app but not used in the unified backend yet;
    // both iOS and web currently route through the same eBay credentials

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (product.ebayStatus === "active" && product.ebayListingId) {
      return { listingId: product.ebayListingId, alreadyListed: true };
    }

    const sku = productId; // Firestore doc ID doubles as the parent eBay SKU
    const title = (product.title ?? "").slice(0, 80); // eBay title limit
    const description = canonicalDescription(product);
    const basePrice = typeof sellPrice === "number" && sellPrice > 0
      ? sellPrice
      : computeEbaySellPrice(product);

    const [merchantLocationKey, listingPolicies, categoryId] = await Promise.all([
      getMerchantLocationKey(uid),
      getListingPolicies(uid),
      suggestCategoryId(uid, title),
    ]);

    // Check if product has variants
    const variationData = buildEbayVariations(product);
    const hasVariations = variationData !== null;

    // 1. Inventory item (idempotent PUT keyed by SKU)
    const inventoryPayload = {
      product: toEbayInventoryProduct(product, { imageLimit: 12, title }),
      condition: "NEW",
    };

    if (hasVariations) {
      // Multi-variant: include variations with individual SKUs and prices
      inventoryPayload.variations = variationData.variations.map((v) => ({
        sku: v.sku,
        price: v.price ? { value: v.price.toFixed(2), currency: "USD" } : undefined,
        quantity: v.quantity,
        itemSpecifics: Object.entries(v.itemSpecifics).reduce((acc, [key, val]) => {
          acc[key] = [val]; // eBay expects array of strings
          return acc;
        }, {}),
      }));
      // Add item-specific names (aspect names) for variation dimensions
      inventoryPayload.product.aspects = variationData.itemSpecifics;
    } else {
      // Single variant: use simple availability
      const qty = Number.isInteger(quantity) && quantity > 0 ? quantity : 1;
      inventoryPayload.availability = { shipToLocationAvailability: { quantity: qty } };
    }

    await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, inventoryPayload);

    // 2. Offer — reuse existing unpublished offer for this SKU if one exists
    let offerId;
    try {
      const offerPayload = {
        sku,
        marketplaceId: MARKETPLACE_ID,
        format: "FIXED_PRICE",
        categoryId,
        listingDescription: description,
        listingPolicies,
        merchantLocationKey,
      };

      if (hasVariations) {
        // Multi-variant pricing: each SKU gets its own price from the variations data
        offerPayload.pricingSummary = {
          priceType: "FIXED_PRICE",
          minimumAdvertisedPrice: { value: basePrice.toFixed(2), currency: "USD" },
        };
        offerPayload.variations = variationData.variations.map((v) => ({
          sku: v.sku,
          price: { value: (v.price ?? basePrice).toFixed(2), currency: "USD" },
          availableQuantity: v.quantity,
        }));
      } else {
        // Single variant
        const qty = Number.isInteger(quantity) && quantity > 0 ? quantity : 1;
        offerPayload.availableQuantity = qty;
        offerPayload.pricingSummary = { price: { value: basePrice.toFixed(2), currency: "USD" } };
      }

      const created = await ebayRequest(uid, "POST", "/sell/inventory/v1/offer", offerPayload);
      offerId = created?.offerId;
    } catch (e) {
      // 25002 = offer already exists for this SKU/marketplace
      if (e.ebayErrors?.some((err) => err.errorId === 25002)) {
        const existing = await ebayRequest(
          uid, "GET", `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}&marketplace_id=${MARKETPLACE_ID}`
        );
        offerId = existing?.offers?.[0]?.offerId;
      } else {
        throw new HttpsError("internal", e.message);
      }
    }
    if (!offerId) throw new HttpsError("internal", "Could not create or find eBay offer.");

    // 3. Publish
    let published;
    try {
      published = await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);
    } catch (e) {
      throw new HttpsError("internal", e.message);
    }

    const listingId = published?.listingId;
    const updatePayload = {
      ebayListingId: listingId ?? null,
      ebayOfferId: offerId,
      ebayStatus: "active",
      ebaySellPrice: basePrice,
      ebayCategoryId: categoryId,
      ebayHasVariations: hasVariations,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    // If multi-variant, mark all active variants as posted
    if (hasVariations) {
      const variantUpdates = {};
      variationData.variations.forEach((v, index) => {
        variantUpdates[`variants.${index}.ebayStatus`] = "active";
        variantUpdates[`variants.${index}.ebayVariantSku`] = v.sku;
      });
      Object.assign(updatePayload, variantUpdates);
    }

    await docRef.update(updatePayload);

    return { listingId, offerId, price: basePrice, categoryId, hasVariations };
  }
);
