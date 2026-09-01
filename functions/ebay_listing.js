const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { ebayRequest, ebayApiHost, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_ENV } = require("./ebay_auth");
const { toEbayInventoryProduct, canonicalDescription, listingImagesFor, buildEbayVariations } = require("./platform_adapters");

const MARKETPLACE_ID = "EBAY_US";

// Default sell price when the user doesn't override one in the UI.
// Rough eBay economics: ~13.25% final value fee + $0.30 per order, plus you pay
// Weverse price + Weverse shipping to you + shipping to the buyer.
function computeEbaySellPrice(product) {
  const cost = product.sourceCost ?? 0;
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
async function getListingPolicies(uid, handlingTimeDays) {
  const [fulfillment, payment, returns] = await Promise.all([
    ebayRequest(uid, "GET", `/sell/account/v1/fulfillment_policy?marketplace_id=${MARKETPLACE_ID}`),
    ebayRequest(uid, "GET", `/sell/account/v1/payment_policy?marketplace_id=${MARKETPLACE_ID}`),
    ebayRequest(uid, "GET", `/sell/account/v1/return_policy?marketplace_id=${MARKETPLACE_ID}`),
  ]);

  const fulfillmentPolicies = fulfillment?.fulfillmentPolicies || [];
  let matchingFulfillment = null;

  if (typeof handlingTimeDays === "number" && handlingTimeDays > 0) {
    matchingFulfillment = fulfillmentPolicies.find(
      (p) => p.handlingTime?.value === handlingTimeDays && p.handlingTime?.unit === "DAY"
    );
  }

  const fulfillmentPolicyId = matchingFulfillment?.fulfillmentPolicyId
    || fulfillmentPolicies[0]?.fulfillmentPolicyId;
  const paymentPolicyId = payment?.paymentPolicies?.[0]?.paymentPolicyId;
  const returnPolicyId = returns?.returnPolicies?.[0]?.returnPolicyId;

  if (!fulfillmentPolicyId || !paymentPolicyId || !returnPolicyId) {
    throw new HttpsError(
      "failed-precondition",
      "Missing eBay business policies (shipping/payment/return). Opt in to business policies in Seller Hub and create one of each."
    );
  }
  return { fulfillmentPolicyId, paymentPolicyId, returnPolicyId };
}

// Resiliently resolve the eBay Offer ID for a product.
// Recovers automatically if the stored ID is a 12-digit listing ID (e.g. 147542181716), draft ID, or if offer moved.
async function resolveEbayOffer(uid, product, productId) {
  const storedId = String(product?.crossPostListingIds?.ebay || product?.ebayListingId || "").trim();

  // 1. If storedId is a 12-digit listing ID, attempt bulk_migrate_listing to convert/retrieve its Inventory API offer
  if (storedId && /^\d{12}$/.test(storedId)) {
    try {
      console.log(`[resolveEbayOffer] Attempting bulk_migrate_listing for listingId=${storedId}`);
      const migrateRes = await ebayRequest(uid, "POST", "/sell/inventory/v1/bulk_migrate_listing", {
        requests: [{ listingId: storedId }],
      });
      console.log(`[resolveEbayOffer] bulk_migrate_listing response:`, JSON.stringify(migrateRes));
      const resp = migrateRes?.responses?.[0];
      const migratedOfferId = resp?.offers?.[0]?.offerId || resp?.offerId;
      if (migratedOfferId) {
        console.log(`[resolveEbayOffer] Successfully migrated listingId=${storedId} to offerId=${migratedOfferId}`);
        const offer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${migratedOfferId}`);
        const docRef = admin.firestore().collection("products").doc(productId);
        await docRef.update({
          "crossPostListingIds.ebay": migratedOfferId,
          ebayListingId: storedId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { offer, offerId: migratedOfferId, sku: offer?.sku || resp?.inventoryItemGroupKey || productId };
      }
    } catch (migErr) {
      console.warn(`[resolveEbayOffer] bulk_migrate_listing for ${storedId} failed (${migErr.message}). Continuing with search...`);
    }
  }

  // 2. If storedId is present and not a 12-digit listing ID, try fetching it directly as an offerId
  if (storedId && !/^\d{12}$/.test(storedId)) {
    try {
      const offer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${storedId}`);
      if (offer && offer.offerId) {
        return { offer, offerId: offer.offerId, sku: offer.sku || productId };
      }
    } catch (err) {
      console.log(`[resolveEbayOffer] Direct fetch of offer ${storedId} failed (${err.message}). Searching by candidate SKUs...`);
    }
  }

  // 3. Build list of candidate SKUs to query (productId, draftId, listingId, product.sku, variant SKUs)
  const candidateSkus = new Set();
  if (productId) {
    candidateSkus.add(productId);
    candidateSkus.add(`wonni_${productId}`);
  }
  if (product?.draftId) {
    candidateSkus.add(product.draftId);
    candidateSkus.add(`wonni_${product.draftId}`);
  }
  if (product?.listingId) {
    candidateSkus.add(product.listingId);
    candidateSkus.add(`wonni_${product.listingId}`);
  }
  if (product?.sourceListingId) {
    candidateSkus.add(product.sourceListingId);
    candidateSkus.add(`wonni_${product.sourceListingId}`);
  }
  if (product?.sku) {
    candidateSkus.add(product.sku);
    candidateSkus.add(`wonni_${product.sku}`);
  }
  if (Array.isArray(product?.variants)) {
    product.variants.forEach((v) => {
      if (v.sku) candidateSkus.add(v.sku);
      if (v.ebayVariantSku) candidateSkus.add(v.ebayVariantSku);
    });
  }

  for (const querySku of candidateSkus) {
    // 3a. Check by single SKU
    try {
      const result = await ebayRequest(
        uid,
        "GET",
        `/sell/inventory/v1/offer?sku=${encodeURIComponent(querySku)}&marketplace_id=${MARKETPLACE_ID}`
      );
      const offers = result?.offers || [];
      if (offers.length > 0) {
        const targetOffer = (storedId && offers.find((o) => o.listingId === storedId || o.offerId === storedId))
          || offers.find((o) => o.status === "PUBLISHED")
          || offers[0];

        if (targetOffer?.offerId) {
          console.log(`[resolveEbayOffer] Recovered offerId=${targetOffer.offerId} (listingId=${targetOffer.listingId}) for SKU ${querySku}`);
          const docRef = admin.firestore().collection("products").doc(productId);
          await docRef.update({
            "crossPostListingIds.ebay": targetOffer.offerId,
            ebayListingId: targetOffer.listingId || (storedId && /^\d{12}$/.test(storedId) ? storedId : null),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          return { offer: targetOffer, offerId: targetOffer.offerId, sku: targetOffer.sku || querySku };
        }
      }
    } catch (skuErr) {
      console.warn(`[resolveEbayOffer] Error querying offers for SKU ${querySku}:`, skuErr.message);
    }

    // 3b. Check by inventory_item_group_key (for multi-variation listings)
    try {
      const groupResult = await ebayRequest(
        uid,
        "GET",
        `/sell/inventory/v1/offer?inventory_item_group_key=${encodeURIComponent(querySku)}&marketplace_id=${MARKETPLACE_ID}`
      );
      const groupOffers = groupResult?.offers || [];
      if (groupOffers.length > 0) {
        const targetOffer = (storedId && groupOffers.find((o) => o.listingId === storedId || o.offerId === storedId))
          || groupOffers.find((o) => o.status === "PUBLISHED")
          || groupOffers[0];

        if (targetOffer?.offerId) {
          console.log(`[resolveEbayOffer] Recovered offerId=${targetOffer.offerId} (listingId=${targetOffer.listingId}) for inventory_item_group_key ${querySku}`);
          const docRef = admin.firestore().collection("products").doc(productId);
          await docRef.update({
            "crossPostListingIds.ebay": targetOffer.offerId,
            ebayListingId: targetOffer.listingId || (storedId && /^\d{12}$/.test(storedId) ? storedId : null),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          return { offer: targetOffer, offerId: targetOffer.offerId, sku: targetOffer.sku || querySku, inventoryItemGroupKey: querySku };
        }
      }
    } catch (groupErr) {
      console.warn(`[resolveEbayOffer] Error querying offers for groupKey ${querySku}:`, groupErr.message);
    }
  }

  // 4. Query user's offers from eBay (up to 100) and find by storedId (listingId or offerId) or title match
  try {
    const allOffersRes = await ebayRequest(
      uid,
      "GET",
      `/sell/inventory/v1/offer?format=FIXED_PRICE&limit=100`
    );
    const allOffers = allOffersRes?.offers || [];
    if (allOffers.length > 0) {
      const matchedOffer = (storedId && allOffers.find((o) => o.listingId === storedId || o.offerId === storedId))
        || (product?.title && allOffers.find((o) => o.title?.toLowerCase() === product.title.trim().toLowerCase()))
        || (product?.title && allOffers.find((o) => o.title && (product.title.toLowerCase().includes(o.title.toLowerCase().slice(0, 20)) || o.title.toLowerCase().includes(product.title.toLowerCase().slice(0, 20)))));

      if (matchedOffer?.offerId) {
        console.log(`[resolveEbayOffer] Recovered offerId=${matchedOffer.offerId} (listingId=${matchedOffer.listingId}, SKU=${matchedOffer.sku}) from user offer list`);
        const docRef = admin.firestore().collection("products").doc(productId);
        await docRef.update({
          "crossPostListingIds.ebay": matchedOffer.offerId,
          ebayListingId: matchedOffer.listingId || (storedId && /^\d{12}$/.test(storedId) ? storedId : null),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { offer: matchedOffer, offerId: matchedOffer.offerId, sku: matchedOffer.sku || productId };
      }
    }
  } catch (allErr) {
    console.warn("[resolveEbayOffer] Error fetching user offers list:", allErr.message);
  }

  throw new HttpsError(
    "not-found",
    `No eBay offer found for product ${productId} (stored ID: ${storedId || "none"}).`
  );
}

// Fetch an application-level access token (Client Credentials grant).
// The Taxonomy API is a public lookup API that only needs an app token —
// it does NOT require a user-scoped OAuth token and has no dedicated user scope.
async function getEbayAppToken() {
  const creds = `${EBAY_CLIENT_ID.value()}:${EBAY_CLIENT_SECRET.value()}`;
  const host = ebayApiHost();
  const response = await fetch(`https://${host}/identity/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(creds).toString("base64")}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      scope: "https://api.ebay.com/oauth/api_scope",
    }).toString(),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.access_token) {
    throw new Error(`eBay app token error (${response.status}): ${json.error_description ?? JSON.stringify(json)}`);
  }
  return json.access_token;
}

// Auto-pick a category from the title via the Taxonomy API (uses app token, no user scope needed)
async function suggestCategoryId(uid, title) {
  const appToken = await getEbayAppToken();
  const host = ebayApiHost();

  async function taxonomyFetch(path) {
    const res = await fetch(`https://${host}${path}`, {
      headers: { Authorization: `Bearer ${appToken}`, Accept: "application/json" },
    });
    if (!res.ok) {
      const detail = await res.json().catch(() => ({}));
      throw new Error(`eBay taxonomy ${path} failed (${res.status}): ${detail?.errors?.[0]?.message ?? JSON.stringify(detail)}`);
    }
    return res.json();
  }

  const tree = await taxonomyFetch(`/commerce/taxonomy/v1/get_default_category_tree_id?marketplace_id=${MARKETPLACE_ID}`);
  const treeId = tree?.categoryTreeId ?? "0";
  const suggestions = await taxonomyFetch(
    `/commerce/taxonomy/v1/category_tree/${treeId}/get_category_suggestions?q=${encodeURIComponent(title.slice(0, 80))}`
  );
  const categoryId = suggestions?.categorySuggestions?.[0]?.category?.categoryId;
  if (!categoryId) throw new HttpsError("not-found", "eBay could not suggest a category for this title.");
  return categoryId;
}

// One-click list a product draft on eBay: inventory item → offer → publish
exports.dropshipEbayCreateListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, sellPrice, quantity, credentialSet } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (product.crossPostStatus?.ebay === "active") {
      return { listingId: product.crossPostListingIds?.ebay, alreadyListed: true };
    }

    const sku = productId; // Firestore doc ID doubles as the parent eBay SKU
    const title = (product.title ?? "").slice(0, 80); // eBay title limit
    const description = canonicalDescription(product);
    const basePrice = typeof sellPrice === "number" && sellPrice > 0
      ? sellPrice
      : computeEbaySellPrice(product);

    const [merchantLocationKey, listingPolicies, categoryId] = await Promise.all([
      getMerchantLocationKey(uid),
      getListingPolicies(uid, product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays),
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
        price: v.price ? { value: Number(v.price).toFixed(2), currency: "USD" } : undefined,
        quantity: typeof v.quantity === "number" ? Math.max(0, v.quantity) : 0,
        itemSpecifics: Object.entries(v.itemSpecifics).reduce((acc, [key, val]) => {
          acc[key] = Array.isArray(val) ? val : [val];
          return acc;
        }, {}),
      }));
      // Put item specifics (option names and possible values) into aspects
      inventoryPayload.product.aspects = variationData.itemSpecifics;
    } else {
      // Single-variant
      const itemQty = typeof quantity === "number" && quantity > 0
        ? quantity
        : (typeof product.quantity === "number" && product.quantity > 0 ? product.quantity : 1);
      inventoryPayload.availability = { shipToLocationAvailability: { quantity: itemQty } };
    }

    await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, inventoryPayload);

    // 2. Offer — reuse existing unpublished offer for this SKU if one exists
    let offerId;
    const offerPayload = {
      sku,
      marketplaceId: MARKETPLACE_ID,
      format: "FIXED_PRICE",
      availableQuantity: hasVariations ? 0 : (typeof quantity === "number" ? quantity : (product.quantity ?? 1)),
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
        availableQuantity: typeof v.quantity === "number" ? Math.max(0, v.quantity) : 0,
      }));
    } else {
      // Single-variant pricing
      offerPayload.pricingSummary = { price: { value: basePrice.toFixed(2), currency: "USD" } };
    }

    try {
      const created = await ebayRequest(uid, "POST", "/sell/inventory/v1/offer", offerPayload);
      offerId = created.offerId;
    } catch (e) {
      // 25002 = offer already exists for this SKU/marketplace
      if (e.ebayErrors?.some((err) => err.errorId === 25002)) {
        const existing = await ebayRequest(
          uid, "GET", `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}&marketplace_id=${MARKETPLACE_ID}`
        );
        offerId = existing?.offers?.[0]?.offerId;
        if (!offerId) throw e;
      } else {
        throw e;
      }
    }

    // 3. Publish offer → creates the live eBay listing
    const published = await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);
    const listingId = published?.listingId ?? offerId;

    // 4. Update Firestore product document
    const updatePayload = {
      "crossPostStatus.ebay": "active",
      "crossPostListingIds.ebay": offerId,
      ebayListingId: listingId,
      ebayHasVariations: hasVariations,
      ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    // If multi-variant, also tag variants with their eBay SKUs
    if (hasVariations && Array.isArray(product.variants)) {
      const variantUpdates = {};
      variationData.variations.forEach((v, index) => {
        variantUpdates[`variants.${index}.ebayVariantSku`] = v.sku;
      });
      Object.assign(updatePayload, variantUpdates);
    }

    await docRef.update(updatePayload);

    return { listingId, offerId, alreadyListed: false, hasVariations };
  }
);

// Delete an eBay listing: withdraw offer and delete inventory item
exports.ebayDeleteListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, force } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const storedId = product.crossPostListingIds?.ebay;
    if (!storedId) {
      throw new HttpsError("failed-precondition", "No eBay listing found.");
    }

    // force=true: user has confirmed they already ended the listing on eBay manually —
    // skip the API call entirely and just clear the Firestore record.
    if (!force) {
      try {
        // Resolve to a real offer ID (handles legacy listing IDs stored in crossPostListingIds.ebay)
        let offerId;
        try {
          const resolved = await resolveEbayOffer(uid, product, productId);
          offerId = resolved.offerId;
        } catch (resolveErr) {
          // Can't find an offer — surface this to the client so the UI can offer the manual fallback
          throw new HttpsError(
            "not-found",
            `No eBay offer found for this listing (stored ID: ${storedId}). If you have already ended the listing manually on eBay, you can mark it as removed here.`
          );
        }

        if (offerId) {
          // Withdraw the offer — ends the live listing on eBay but keeps
          // the offer record in Seller Hub so the seller has a history of it.
          try {
            await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/withdraw`);
          } catch (withdrawErr) {
            // 25702 = offer not published, nothing to withdraw — ok to continue
            const code = withdrawErr.ebayErrors?.[0]?.errorId;
            if (code !== 25702 && code !== 404) {
              throw withdrawErr;
            }
          }
        }
      } catch (e) {
        if (e instanceof HttpsError) throw e;
        const errorMsg = e.ebayErrors?.map((err) => `${err.errorId}: ${err.message}`).join("; ") || e.message;
        throw new HttpsError("internal", `Failed to delete eBay listing: ${errorMsg}`);
      }
    } // end if (!force)

    // Clear all eBay fields from product
    await docRef.update({
      "crossPostStatus.ebay": admin.firestore.FieldValue.delete(),
      "crossPostListingIds.ebay": admin.firestore.FieldValue.delete(),
      ebayListingId: admin.firestore.FieldValue.delete(),
      ebayListingUrl: admin.firestore.FieldValue.delete(),
      ebayHasVariations: admin.firestore.FieldValue.delete(),
      ebayLastSyncedAt: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Also clear variant-level eBay fields if multi-variant
    if (product.ebayHasVariations && Array.isArray(product.variants)) {
      const batch = db.batch();
      product.variants.forEach((v, index) => {
        batch.update(docRef, {
          [`variants.${index}.crossPostStatus.ebay`]: admin.firestore.FieldValue.delete(),
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
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 30, memory: "256MiB" },
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

    try {
      const { offer, sku } = await resolveEbayOffer(uid, product, productId);

      let inventory = null;
      if (sku) {
        try {
          inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
        } catch {
          // Ignore inventory fetch error for multi-variant items
        }
      }

      const wonniPhotos = listingImagesFor(product);

      return {
        wonni: {
          title: product.title ?? "",
          description: canonicalDescription(product),
          price: product.listingPrice ?? computeEbaySellPrice(product),
          quantity: product.variants?.reduce((sum, v) => sum + (v.quantity ?? 0), 0) ?? (product.quantity ?? 1),
          photoCount: wonniPhotos.length,
          handlingTimeDays: product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays ?? null,
        },
        ebay: {
          title: offer?.title || inventory?.product?.title || "",
          description: offer?.listingDescription ?? "",
          price: offer?.pricingSummary?.price?.value
            ? parseFloat(offer.pricingSummary.price.value)
            : (offer?.pricingSummary?.minimumAdvertisedPrice?.value ? parseFloat(offer.pricingSummary.minimumAdvertisedPrice.value) : null),
          quantity: inventory?.availability?.shipToLocationAvailability?.quantity ?? (offer?.availableQuantity ?? 0),
          photoCount: inventory?.product?.imageUrls?.length ?? 0,
          offerId: offer?.offerId,
          listingId: offer?.listingId,
        },
      };
    } catch (e) {
      throw new HttpsError("internal", `Failed to fetch eBay listing: ${e.message}`);
    }
  }
);

// Sync bidirectional: apply chosen version (wonni or ebay) to the other platform
exports.ebaySyncListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
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

    try {
      const { offer, offerId, sku } = await resolveEbayOffer(uid, product, productId);

      if (applyFrom === "wonni") {
        // Push Wonni version to eBay (title, description, price, photos, shipping/handling time, variation quantities)
        const title = (product.title ?? "").slice(0, 80);
        const description = canonicalDescription(product);
        const basePrice = product.listingPrice ?? computeEbaySellPrice(product);

        const variationData = buildEbayVariations(product);
        const hasVariations = variationData !== null;

        const inventoryPayload = {
          product: toEbayInventoryProduct(product, { imageLimit: 12, title }),
          condition: "NEW",
        };

        if (hasVariations) {
          inventoryPayload.variations = variationData.variations.map((v) => ({
            sku: v.sku,
            price: v.price ? { value: Number(v.price).toFixed(2), currency: "USD" } : undefined,
            quantity: typeof v.quantity === "number" ? Math.max(0, v.quantity) : 0,
            itemSpecifics: Object.entries(v.itemSpecifics).reduce((acc, [key, val]) => {
              acc[key] = Array.isArray(val) ? val : [val];
              return acc;
            }, {}),
          }));
          inventoryPayload.product.aspects = variationData.itemSpecifics;
        } else {
          const qty = typeof product.quantity === "number" && product.quantity >= 0 ? product.quantity : 1;
          inventoryPayload.availability = { shipToLocationAvailability: { quantity: qty } };
        }

        await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, inventoryPayload);

        // Re-resolve policies for handling time updates
        const handlingTimeDays = product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays;
        let listingPolicies = null;
        try {
          listingPolicies = await getListingPolicies(uid, handlingTimeDays);
        } catch (polErr) {
          console.warn("[ebaySyncListing] Retaining existing listing policies:", polErr.message);
        }

        const offerPatchPayload = {
          listingDescription: description,
        };
        if (listingPolicies) {
          offerPatchPayload.listingPolicies = listingPolicies;
        }

        if (hasVariations) {
          offerPatchPayload.pricingSummary = {
            priceType: "FIXED_PRICE",
            minimumAdvertisedPrice: { value: basePrice.toFixed(2), currency: "USD" },
          };
          offerPatchPayload.variations = variationData.variations.map((v) => ({
            sku: v.sku,
            price: { value: (v.price ?? basePrice).toFixed(2), currency: "USD" },
            availableQuantity: typeof v.quantity === "number" ? Math.max(0, v.quantity) : 0,
          }));
        } else {
          const qty = typeof product.quantity === "number" && product.quantity >= 0 ? product.quantity : 1;
          offerPatchPayload.availableQuantity = qty;
          offerPatchPayload.pricingSummary = { price: { value: basePrice.toFixed(2), currency: "USD" } };
        }

        await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${offerId}`, offerPatchPayload);

        // Re-publish existing offer to apply changes in-place
        await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);
      } else {
        // Pull eBay version to Wonni
        const inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);

        const updatePayload = {
          title: offer?.title ?? product.title,
          description: offer?.listingDescription ?? product.description,
          listingPrice: offer?.pricingSummary?.price?.value
            ? parseFloat(offer.pricingSummary.price.value)
            : product.listingPrice,
        };

        if (inventory?.availability?.shipToLocationAvailability?.quantity != null) {
          if (product.ebayHasVariations && Array.isArray(product.variants)) {
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

// Update an eBay listing with current Wonni product data (title, description, price, images, variations/quantities, shipping)
exports.ebayUpdateListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
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

    try {
      const { offerId, sku } = await resolveEbayOffer(uid, product, productId);

      const title = (product.title ?? "").slice(0, 80);
      const description = canonicalDescription(product);
      const basePrice = product.listingPrice ?? computeEbaySellPrice(product);

      // Check if product has variants
      const variationData = buildEbayVariations(product);
      const hasVariations = variationData !== null;

      // 1. Update inventory item in-place via idempotent PUT
      const inventoryPayload = {
        product: toEbayInventoryProduct(product, { imageLimit: 12, title }),
        condition: "NEW",
      };

      if (hasVariations) {
        inventoryPayload.variations = variationData.variations.map((v) => ({
          sku: v.sku,
          price: v.price ? { value: Number(v.price).toFixed(2), currency: "USD" } : undefined,
          quantity: typeof v.quantity === "number" ? Math.max(0, v.quantity) : 0,
          itemSpecifics: Object.entries(v.itemSpecifics).reduce((acc, [key, val]) => {
            acc[key] = Array.isArray(val) ? val : [val];
            return acc;
          }, {}),
        }));
        inventoryPayload.product.aspects = variationData.itemSpecifics;
      } else {
        const qty = typeof product.quantity === "number" && product.quantity >= 0 ? product.quantity : 1;
        inventoryPayload.availability = { shipToLocationAvailability: { quantity: qty } };
      }

      await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, inventoryPayload);

      // Re-resolve policies for handling time updates
      const handlingTimeDays = product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays;
      let listingPolicies = null;
      try {
        listingPolicies = await getListingPolicies(uid, handlingTimeDays);
      } catch (polErr) {
        console.warn("[ebayUpdateListing] Retaining existing listing policies:", polErr.message);
      }

      // 2. Update the existing offer in-place (PATCH)
      const offerPatchPayload = {
        listingDescription: description,
      };
      if (listingPolicies) {
        offerPatchPayload.listingPolicies = listingPolicies;
      }

      if (hasVariations) {
        offerPatchPayload.pricingSummary = {
          priceType: "FIXED_PRICE",
          minimumAdvertisedPrice: { value: basePrice.toFixed(2), currency: "USD" },
        };
        offerPatchPayload.variations = variationData.variations.map((v) => ({
          sku: v.sku,
          price: { value: (v.price ?? basePrice).toFixed(2), currency: "USD" },
          availableQuantity: typeof v.quantity === "number" ? Math.max(0, v.quantity) : 0,
        }));
      } else {
        const qty = typeof product.quantity === "number" && product.quantity >= 0 ? product.quantity : 1;
        offerPatchPayload.availableQuantity = qty;
        offerPatchPayload.pricingSummary = { price: { value: basePrice.toFixed(2), currency: "USD" } };
      }

      await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${offerId}`, offerPatchPayload);

      // 3. Re-publish the existing offer to apply changes to the live listing without deleting/recreating
      await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);

      // Update last-synced timestamp
      await docRef.update({
        ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { success: true };
    } catch (e) {
      throw new HttpsError("internal", `Failed to update eBay listing: ${e.message}`);
    }
  }
);

// Pull sync: check eBay listing drift against local Wonni product
exports.ebayPullSync = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 30, memory: "256MiB" },
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

    try {
      const { offer, sku } = await resolveEbayOffer(uid, product, productId);
      let inventory = null;
      if (sku) {
        try {
          inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
        } catch (_) {}
      }

      const ebayTitle = offer?.title || inventory?.product?.title || "";
      const ebayPrice = offer?.pricingSummary?.price?.value
        ? parseFloat(offer.pricingSummary.price.value)
        : (offer?.pricingSummary?.minimumAdvertisedPrice?.value ? parseFloat(offer.pricingSummary.minimumAdvertisedPrice.value) : null);
      const ebayQuantity = inventory?.availability?.shipToLocationAvailability?.quantity ?? (offer?.availableQuantity ?? 0);

      const localTitle = product.title ?? "";
      const localPrice = product.listingPrice ?? computeEbaySellPrice(product);
      const localQuantity = product.variants?.reduce((sum, v) => sum + (v.quantity ?? 0), 0) ?? (product.quantity ?? 1);

      const diff = [];
      if (ebayTitle && ebayTitle !== localTitle) {
        diff.push({ field: "title", local: localTitle, ebay: ebayTitle });
      }
      if (ebayPrice != null && Math.abs(ebayPrice - localPrice) > 0.01) {
        diff.push({ field: "price", local: localPrice, ebay: ebayPrice });
      }
      if (ebayQuantity != null && ebayQuantity !== localQuantity) {
        diff.push({ field: "quantity", local: localQuantity, ebay: ebayQuantity });
      }

      const hasDrift = diff.length > 0;

      return {
        hasDrift,
        diff,
        ebayData: {
          title: ebayTitle,
          price: ebayPrice,
          quantity: ebayQuantity,
          offerId: offer?.offerId,
          listingId: offer?.listingId,
        },
        lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
    } catch (e) {
      console.warn("eBay pull sync check error:", e.message);
      return { hasDrift: false, diff: [], error: e.message };
    }
  }
);

// Import pull sync changes into local Wonni product
exports.ebayImportPullSync = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { productId, fields } = request.data;
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
  if (!fields || typeof fields !== "object") throw new HttpsError("invalid-argument", "Missing fields to update.");

  const db = admin.firestore();
  const docRef = db.collection("products").doc(productId);
  const snap = await docRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

  const updatePayload = {
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (fields.title) updatePayload.title = fields.title;
  if (typeof fields.price === "number") updatePayload.listingPrice = fields.price;
  if (typeof fields.quantity === "number") {
    if (product.ebayHasVariations && Array.isArray(product.variants)) {
      const batch = db.batch();
      product.variants.forEach((v, index) => {
        batch.update(docRef, { [`variants.${index}.quantity`]: Math.max(0, fields.quantity) });
      });
      await batch.commit();
    } else {
      updatePayload.quantity = fields.quantity;
    }
  }

  await docRef.update(updatePayload);
  return { success: true };
});

module.exports = {
  dropshipEbayCreateListing: exports.dropshipEbayCreateListing,
  ebayDeleteListing: exports.ebayDeleteListing,
  ebayUpdateListing: exports.ebayUpdateListing,
  ebayGetListingDetails: exports.ebayGetListingDetails,
  ebaySyncListing: exports.ebaySyncListing,
  ebayPullSync: exports.ebayPullSync,
  ebayImportPullSync: exports.ebayImportPullSync,
};
