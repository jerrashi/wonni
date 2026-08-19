const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { decrementAndCascadeInternal } = require("./sale_sync");

// Records a Mercari sale and triggers cascade (quantity decrement, relist flags).
// Called by the extension after scraping a sold item from the user's Mercari
// "in progress" listings page.
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
