const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { decrementAndCascadeInternal } = require("./sale_sync");

// Batch-records multiple Mercari sales from extension sold-detection.
// Matches Mercari item IDs to user's listings, then records each sale.
// Called by the extension background after scraping sold items.
exports.recordMercariSalesBatch = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { items } = request.data ?? {};
    if (!Array.isArray(items) || items.length === 0) {
      throw new HttpsError("invalid-argument", "No items to record.");
    }

    const db = admin.firestore();
    const results = [];

    for (const item of items) {
      try {
        const { mercariItemId, priceSoldFor, takeHome, soldDate, title } = item;
        if (!mercariItemId || typeof priceSoldFor !== "number") {
          results.push({ mercariItemId, success: false, error: "Missing required fields" });
          continue;
        }

        // Find the listing that has this Mercari item ID
        const listingsSnap = await db
          .collection("listings")
          .where("userId", "==", uid)
          .where("crossPostListingIds.mercari", "==", mercariItemId)
          .limit(1)
          .get();

        let listingId = null;
        if (!listingsSnap.empty) {
          listingId = listingsSnap.docs[0].id;
        } else {
          // Also check products collection as fallback (legacy single-product flow)
          const productsSnap = await db
            .collection("products")
            .where("userId", "==", uid)
            .where("listingId.mercari", "==", mercariItemId)
            .limit(1)
            .get();

          if (!productsSnap.empty) {
            listingId = productsSnap.docs[0].id;
          }
        }

        if (!listingId) {
          results.push({
            mercariItemId,
            success: false,
            error: "No matching listing found",
          });
          continue;
        }

        // Record the sale using the existing recordMercariSale logic
        const saleId = `${mercariItemId}-${mercariItemId}`; // dedupe by item ID
        const saleRef = db.collection("sales").doc(saleId);

        const saleData = {
          userId: uid,
          listingId,
          listingTitle: title ?? null,
          platform: "mercari",
          platformOrderId: mercariItemId,
          platformSaleId: mercariItemId,
          priceSoldFor,
          takeHome: takeHome ?? null,
          status: "pending",
          soldAt: soldDate
            ? admin.firestore.Timestamp.fromDate(new Date(soldDate))
            : admin.firestore.Timestamp.now(),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };

        await saleRef.set(saleData, { merge: true });

        // Trigger cascade
        try {
          await decrementAndCascadeInternal(listingId, "mercari", db);
          results.push({ mercariItemId, success: true });
        } catch (err) {
          console.error(`[recordMercariSalesBatch] Cascade failed for ${listingId}:`, err.message);
          results.push({ mercariItemId, success: true, warning: "Sale recorded but cascade failed" });
        }
      } catch (err) {
        results.push({ mercariItemId: item.mercariItemId, success: false, error: err.message });
      }
    }

    return { ok: true, results };
  }
);

// Records a Mercari sale and triggers cascade (quantity decrement, relist flags).
// Called by the web app after matching a sold item to a listing.
// Also used by recordMercariSalesBatch for individual items.
//
// This function:
// 1. Writes a new sales/{id} doc with Mercari sale details
// 2. Calls decrementAndCascadeInternal to decrement the listing's quantity and set
//    pendingMercariRelist/pendingMercariDeactivation flags
// 3. Dedupes by platformOrderId (Mercari item id) — re-running for the same
//    item is idempotent (overwrites the doc)
exports.recordMercariSale = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const {
      mercariItemId,       // Mercari's item id (platformSaleId)
      mercariOrderId,      // Mercari's order/transaction id (platformOrderId) — for deduping
      listingTitle,
      thumbnailUrl,
      priceSoldFor,
      takeHome,
      soldAt,              // ISO timestamp
      buyerName,
      buyerAddress,        // { name, phone, address, city, state, zip, country }
      trackingNumber,
      carrier,
      listingId,           // documentId in listings/{id} — matched by the extension
    } = request.data ?? {};

    if (!mercariItemId) throw new HttpsError("invalid-argument", "Missing mercariItemId.");
    if (!mercariOrderId) throw new HttpsError("invalid-argument", "Missing mercariOrderId.");
    if (!listingId) throw new HttpsError("invalid-argument", "Missing listingId.");
    if (typeof priceSoldFor !== "number") throw new HttpsError("invalid-argument", "Missing or invalid priceSoldFor.");

    const db = admin.firestore();

    // Verify the user owns this listing
    const listingSnap = await db.collection("listings").doc(listingId).get();
    if (!listingSnap.exists) throw new HttpsError("not-found", "Listing not found.");
    if (listingSnap.data().userId !== uid) throw new HttpsError("permission-denied", "Not your listing.");

    // Write or update the sale doc (deduped by mercariOrderId-mercariItemId)
    const saleId = `${mercariOrderId}-${mercariItemId}`;
    const saleRef = db.collection("sales").doc(saleId);

    const saleData = {
      userId: uid,
      listingId,
      listingTitle: listingTitle ?? null,
      thumbnailUrl: thumbnailUrl ?? null,
      platform: "mercari",
      platformOrderId: mercariOrderId,
      platformSaleId: mercariItemId,
      priceSoldFor,
      takeHome: takeHome ?? null,
      buyerName: buyerName ?? null,
      buyerAddress: buyerAddress ?? null,
      trackingNumber: trackingNumber ?? null,
      carrier: carrier ?? null,
      status: "pending",
      soldAt: soldAt ? admin.firestore.Timestamp.fromDate(new Date(soldAt)) : admin.firestore.Timestamp.now(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await saleRef.set(saleData, { merge: true });

    // Trigger cascade: decrement quantity, cascade to eBay/Etsy if cross-posted,
    // set pendingMercariRelist or pendingMercariDeactivation flags.
    // This runs best-effort — if it fails, the sale is still recorded and the
    // user can manually trigger relist via the web UI.
    try {
      await decrementAndCascadeInternal(listingId, "mercari", db);
      console.log(`[recordMercariSale] Cascade triggered for ${listingId}`);
    } catch (err) {
      console.error(`[recordMercariSale] Cascade failed for ${listingId}:`, err.message);
    }

    return { ok: true, saleId };
  }
);
