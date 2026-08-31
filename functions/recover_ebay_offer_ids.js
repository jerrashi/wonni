const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { ebayRequest, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME } = require("./ebay_auth");

const MARKETPLACE_ID = "EBAY_US";

// Recover offerId for existing eBay listings by querying eBay's offer API
// Called manually after the schema migration: firebaseTools.connect({ projectId: "wonni-app" }); await callFunction("recoverEbayOfferIds")({})
exports.recoverEbayOfferIds = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME], timeoutSeconds: 300, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const db = admin.firestore();

    // Find all products owned by this user with existing eBay listings
    const snaps = await db.collection("products")
      .where("userId", "==", uid)
      .where("crossPostStatus.ebay", "==", "active")
      .get();

    if (snaps.empty) {
      return { recovered: 0, failed: 0, message: "No active eBay listings found for this user." };
    }

    let recovered = 0;
    let failed = 0;
    const failedProducts = [];

    for (const snap of snaps.docs) {
      const product = snap.data();
      const productId = snap.id;
      const sku = productId; // SKU matches the product docId
      const currentOfferId = product.crossPostListingIds?.ebay;

      // Skip if offerId already looks valid (48-char hex string)
      if (currentOfferId && /^[a-f0-9]{48}$/.test(currentOfferId)) {
        console.log(`Product ${productId}: offerId already valid, skipping.`);
        recovered++;
        continue;
      }

      try {
        // Query eBay for all offers with this SKU
        const offerResult = await ebayRequest(
          uid,
          "GET",
          `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}&marketplace_id=${MARKETPLACE_ID}`
        );

        const offers = offerResult?.offers || [];
        if (offers.length === 0) {
          console.warn(`Product ${productId}: No offers found on eBay for SKU ${sku}.`);
          failed++;
          failedProducts.push({ productId, reason: "No offer found on eBay" });
          continue;
        }

        // Use the first published offer if available, otherwise any offer
        const publishedOffer = offers.find((o) => o.status === "PUBLISHED");
        const targetOffer = publishedOffer || offers[0];
        const offerId = targetOffer?.offerId;

        if (!offerId) {
          console.warn(`Product ${productId}: Offer exists but has no offerId.`);
          failed++;
          failedProducts.push({ productId, reason: "Offer has no offerId" });
          continue;
        }

        // Update the product with the correct offerId
        await snap.ref.update({
          "crossPostListingIds.ebay": offerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        console.log(`Product ${productId}: Recovered offerId ${offerId}`);
        recovered++;
      } catch (error) {
        console.error(`Product ${productId}: Error recovering offerId: ${error.message}`);
        failed++;
        failedProducts.push({ productId, reason: error.message });
      }
    }

    return {
      recovered,
      failed,
      failedProducts: failedProducts.length > 0 ? failedProducts : undefined,
      message: `Recovery complete: ${recovered} recovered, ${failed} failed.`,
    };
  }
);
