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

// Delete an eBay listing: withdraw offer and delete inventory item
exports.ebayDeleteListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (!product.ebayListingId && !product.ebayOfferId) {
      throw new HttpsError("failed-precondition", "No eBay listing to delete.");
    }
    const offerId = product.ebayOfferId;
    if (!offerId) throw new HttpsError("failed-precondition", "eBay offer ID not found. Listing may not be fully published.");

    try {
      // 1. Withdraw the offer (makes it inactive)
      try {
        await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/withdraw`);
      } catch (withdrawErr) {
        // 404 = offer doesn't exist (already deleted) — ok to continue
        // 25013 = offer already inactive — ok to continue
        if (!withdrawErr.ebayErrors?.some((err) => err.errorId === 404 || err.errorId === 25013)) {
          throw withdrawErr;
        }
      }

      // 2. Delete the inventory item
      const sku = productId;
      try {
        await ebayRequest(uid, "DELETE", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
      } catch (inventoryErr) {
        // 404 = item doesn't exist — ok to continue
        if (!inventoryErr.ebayErrors?.some((err) => err.errorId === 404)) {
          throw inventoryErr;
        }
      }
    } catch (e) {
      const errorMsg = e.ebayErrors?.map((err) => `${err.errorId}: ${err.message}`).join("; ") || e.message;
      throw new HttpsError("internal", `Failed to delete eBay listing: ${errorMsg}`);
    }

    // 3. Clear eBay fields from product
    await docRef.update({
      ebayStatus: null,
      ebayListingId: admin.firestore.FieldValue.delete(),
      ebayOfferId: admin.firestore.FieldValue.delete(),
      ebaySellPrice: admin.firestore.FieldValue.delete(),
      ebayCategoryId: admin.firestore.FieldValue.delete(),
      ebayHasVariations: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Also clear variant-level eBay fields if multi-variant
    if (product.ebayHasVariations && Array.isArray(product.variants)) {
      const batch = db.batch();
      product.variants.forEach((v, index) => {
        batch.update(docRef, {
          [`variants.${index}.ebayStatus`]: admin.firestore.FieldValue.delete(),
          [`variants.${index}.ebayVariantSku`]: admin.firestore.FieldValue.delete(),
        });
      });
      await batch.commit();
    }

    return { success: true };
  }
);

// Fetch current eBay listing details for comparison/sync
exports.ebayGetListingDetails = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME], timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const snap = await db.collection("products").doc(productId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (!product.ebayOfferId) throw new HttpsError("failed-precondition", "No eBay listing found.");

    try {
      const offer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${product.ebayOfferId}`);
      const sku = product.ebayHasVariations ? null : productId; // Only fetch single-variant inventory
      let inventory = null;

      if (sku && !product.ebayHasVariations) {
        inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
      }

      return {
        wonni: {
          title: product.title ?? "",
          description: canonicalDescription(product),
          price: product.listingPrice ?? computeEbaySellPrice(product),
          quantity: product.variants?.reduce((sum, v) => sum + (v.quantity ?? 0), 0) ?? 1,
        },
        ebay: {
          title: offer?.title ?? "",
          description: offer?.listingDescription ?? "",
          price: offer?.pricingSummary?.price?.value
            ? parseFloat(offer.pricingSummary.price.value)
            : null,
          quantity: inventory?.availability?.shipToLocationAvailability?.quantity ?? 0,
        },
      };
    } catch (e) {
      throw new HttpsError("internal", `Failed to fetch eBay listing: ${e.message}`);
    }
  }
);

// Sync bidirectional: apply chosen version (wonni or ebay) to the other platform
exports.ebaySyncListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, applyFrom } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!["wonni", "ebay"].includes(applyFrom)) throw new HttpsError("invalid-argument", "applyFrom must be 'wonni' or 'ebay'.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (!product.ebayOfferId) throw new HttpsError("failed-precondition", "No eBay listing found.");

    try {
      if (applyFrom === "wonni") {
        // Push Wonni version to eBay
        const title = (product.title ?? "").slice(0, 80);
        const description = canonicalDescription(product);
        const price = product.listingPrice ?? computeEbaySellPrice(product);

        await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${product.ebayOfferId}`, {
          listingDescription: description,
        });

        // Update inventory
        const sku = productId;
        const qty = product.variants?.reduce((sum, v) => sum + (v.quantity ?? 0), 0) ?? 1;
        await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, {
          product: toEbayInventoryProduct(product, { imageLimit: 12, title }),
          condition: "NEW",
          availability: { shipToLocationAvailability: { quantity: qty } },
        });

        // Re-publish
        await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${product.ebayOfferId}/publish`);
      } else {
        // Pull eBay version to Wonni
        const offer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${product.ebayOfferId}`);
        const sku = productId;
        const inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);

        const updatePayload = {
          title: offer?.title ?? product.title,
          description: offer?.listingDescription ?? product.description,
          listingPrice: offer?.pricingSummary?.price?.value
            ? parseFloat(offer.pricingSummary.price.value)
            : product.listingPrice,
        };

        if (inventory?.availability?.shipToLocationAvailability?.quantity != null) {
          // Update variant quantities if multi-variant
          if (product.ebayHasVariations && Array.isArray(product.variants)) {
            const totalQty = inventory.availability.shipToLocationAvailability.quantity;
            const batch = db.batch();
            product.variants.forEach((v, index) => {
              batch.update(docRef, {
                [`variants.${index}.quantity`]: Math.max(0, v.quantity ?? 0),
              });
            });
            await batch.commit();
          } else {
            updatePayload.quantity = inventory.availability.shipToLocationAvailability.quantity;
          }
        }

        await docRef.update(updatePayload);
      }

      // Update sync timestamp
      await docRef.update({
        ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { success: true };
    } catch (e) {
      throw new HttpsError("internal", `Failed to sync listing: ${e.message}`);
    }
  }
);

// Update an eBay listing with current Wonni product data (title, description, price, images)
exports.ebayUpdateListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (!product.ebayOfferId) throw new HttpsError("failed-precondition", "No eBay listing to update.");

    const offerId = product.ebayOfferId;
    const title = (product.title ?? "").slice(0, 80);
    const description = canonicalDescription(product);
    const price = product.listingPrice ?? computeEbaySellPrice(product);

    try {
      // eBay: Update offer with new title, description, pricing
      // Note: inventory item updates are done via PUT (idempotent), not PATCH
      await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${offerId}`, {
        listingDescription: description,
      });

      // Update pricing in offer (note: this may vary by SKU for multi-variant listings)
      const updatedOffer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${offerId}`);
      if (updatedOffer?.pricingSummary) {
        await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${offerId}`, {
          pricingSummary: updatedOffer.pricingSummary.priceType === "FIXED_PRICE"
            ? { price: { value: price.toFixed(2), currency: "USD" } }
            : updatedOffer.pricingSummary,
        });
      }

      // Re-publish to apply changes
      await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);
    } catch (e) {
      throw new HttpsError("internal", `Failed to update eBay listing: ${e.message}`);
    }

    // Update last-synced timestamp
    await docRef.update({
      ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);
