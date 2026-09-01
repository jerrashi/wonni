const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { getValidEtsyToken } = require("./etsy_auth");

// Fetch all active listings from Etsy shop and compare with local product
exports.etsyPullSync = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { productId } = request.data;
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

  try {
    const accessToken = await getValidEtsyToken(uid);

    // Get user's Etsy shop ID
    const userRef = admin.firestore().doc(`users/${uid}/integrations/etsy`);
    const userSnap = await userRef.get();
    const shopId = userSnap.data()?.shopId;

    if (!shopId) throw new Error("Shop ID not found.");

    // Fetch all listings from Etsy for this shop
    const listingsResponse = await fetch(
      `https://openapi.etsy.com/v3/application/shops/${shopId}/listings?` +
      new URLSearchParams({ status: "active", limit: 100 }).toString(),
      {
        headers: { Authorization: `Bearer ${accessToken}` },
      }
    );

    if (!listingsResponse.ok) {
      throw new Error(`Etsy listings fetch failed (${listingsResponse.status})`);
    }

    const listingsData = await listingsResponse.json();
    const etsyListings = listingsData.results || [];

    // Get local product to find Etsy listing ID
    const productRef = admin.firestore().doc(`users/${uid}/products/${productId}`);
    const productSnap = await productRef.get();
    const product = productSnap.data();

    if (!product) throw new Error("Product not found.");

    const etsyListingId = product.etsyListingId || product.crossPostListingIds?.etsy;
    if (!etsyListingId) {
      return { etsyData: null, diff: [], isLive: false };
    }

    // Find the matching Etsy listing
    const etsyListing = etsyListings.find((l) => l.listing_id == etsyListingId);

    if (!etsyListing) {
      return { etsyData: null, diff: [], isLive: false, message: "Listing not found on Etsy" };
    }

    // Extract comparable fields
    const etsyData = {
      title: etsyListing.title,
      description: etsyListing.description,
      price: etsyListing.price?.amount,
      currency: etsyListing.price?.currency_code,
      quantity: etsyListing.quantity,
      tags: etsyListing.tags,
      category: etsyListing.category_id,
      images: etsyListing.images || [],
      state: etsyListing.state,
    };

    // Compute diff against local product
    const diff = [];
    if (etsyData.title !== product.title) {
      diff.push({ field: "title", local: product.title, etsy: etsyData.title });
    }
    if (etsyData.description !== product.description) {
      diff.push({ field: "description", local: product.description, etsy: etsyData.description });
    }
    if (etsyData.price !== product.price) {
      diff.push({ field: "price", local: product.price, etsy: etsyData.price });
    }
    if (etsyData.quantity !== product.quantity) {
      diff.push({ field: "quantity", local: product.quantity, etsy: etsyData.quantity });
    }

    return {
      etsyData,
      diff,
      isLive: etsyListing.state === "active",
      lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
  } catch (e) {
    console.error("Etsy pull sync error:", e);
    throw new HttpsError("internal", e.message || "Failed to sync with Etsy");
  }
});

// Import/apply pulled Etsy data into local product
exports.etsyImportPullSync = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { productId, fields } = request.data;
  if (!productId || !fields) {
    throw new HttpsError("invalid-argument", "Missing productId or fields.");
  }

  try {
    const productRef = admin.firestore().doc(`users/${uid}/products/${productId}`);
    const updateData = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };

    // Whitelist allowed fields to update
    const allowedFields = ["title", "description", "price", "quantity"];
    for (const field of allowedFields) {
      if (field in fields) {
        updateData[field] = fields[field];
      }
    }

    await productRef.update(updateData);

    return { success: true, updatedFields: Object.keys(updateData) };
  } catch (e) {
    console.error("Etsy import pull sync error:", e);
    throw new HttpsError("internal", e.message || "Failed to update product with Etsy data");
  }
});
