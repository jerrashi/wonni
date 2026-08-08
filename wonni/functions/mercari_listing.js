const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

// Called by the Chrome extension background script via reportMercariStatus()
// after each listing attempt. Updates the product document's listingStatus,
// listingUrl, and listingId fields so the web app reflects the live state.
exports.updateMercariListingStatus = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const {
      productId, variantId, status, listingId, url, category, error: outcomeError,
      syncedTitle, syncedDescription, syncedPrice, syncedImages,
    } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!status) throw new HttpsError("invalid-argument", "Missing status.");

    const db = admin.firestore();
    const ref = db.collection("products").doc(productId);
    // Mirrored into the shared `listings` doc (see aliexpress_product.js's
    // dual-write comment for why both collections exist during migration).
    const listingRef = db.collection("listings").doc(productId);

    if (variantId) {
      // One Mercari listing per variant — update just that variant's entry in
      // the `variants` array (and the mirrored `variations` array). Runs in a
      // transaction (read-modify-write the whole array) so a concurrent edit
      // elsewhere (e.g. the user changing a price) can't get clobbered by
      // this write racing it.
      await db.runTransaction(async (tx) => {
        const [snap, listingSnap] = await Promise.all([tx.get(ref), tx.get(listingRef)]);
        if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
        const product = snap.data();
        if (product?.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

        const variants = Array.isArray(product.variants) ? [...product.variants] : [];
        const idx = variants.findIndex((v) => v?.id === variantId);
        if (idx === -1) throw new HttpsError("not-found", "Variant not found.");

        const variant = { ...variants[idx], mercariStatus: status };
        if (listingId) variant.mercariListingId = listingId;
        if (url) variant.mercariUrl = url;
        if (outcomeError) variant.mercariError = outcomeError;
        if (status === "active") {
          delete variant.mercariError;
          if (typeof syncedTitle === "string") variant.mercariSyncedTitle = syncedTitle;
          if (typeof syncedPrice === "number") variant.mercariSyncedPrice = syncedPrice;
          if (Array.isArray(syncedImages)) variant.mercariSyncedImages = syncedImages;
        }
        variants[idx] = variant;

        tx.update(ref, { variants, updatedAt: admin.firestore.FieldValue.serverTimestamp() });

        if (listingSnap.exists) {
          const variations = Array.isArray(listingSnap.data().variations)
            ? [...listingSnap.data().variations]
            : [];
          const vIdx = variations.findIndex((v) => v?.id === variantId);
          if (vIdx !== -1) {
            const variation = { ...variations[vIdx] };
            variation.crossPostStatus = { ...variation.crossPostStatus, mercari: status };
            const listingIds = { ...variation.crossPostListingIds };
            if (listingId) listingIds.mercari = listingId;
            if (url) listingIds.mercariUrl = url;
            variation.crossPostListingIds = listingIds;
            variations[vIdx] = variation;
            tx.update(listingRef, { variations, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
          }
        }
      });

      return { ok: true };
    }

    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    if (snap.data()?.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const update = {
      "listingStatus.mercari": status,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (listingId) update["listingId.mercari"] = listingId;
    if (url) update["listingUrl.mercari"] = url;
    if (category) update["listingCategory.mercari"] = category;
    if (outcomeError) update["listingError.mercari"] = outcomeError;
    if (status === "active") {
      // Clear any stale error on success
      update["listingError.mercari"] = admin.firestore.FieldValue.delete();
      // Snapshot what was just pushed — the baseline the next sync diffs against,
      // so a push only touches Mercari fields that actually changed since.
      if (typeof syncedTitle === "string") update.mercariSyncedTitle = syncedTitle;
      if (typeof syncedDescription === "string") update.mercariSyncedDescription = syncedDescription;
      if (typeof syncedPrice === "number") update.mercariSyncedPrice = syncedPrice;
      if (Array.isArray(syncedImages)) update.mercariSyncedImages = syncedImages;
    }

    await ref.update(update);
    await listingRef.set({
      crossPostStatus: { mercari: status },
      ...(listingId || url ? { crossPostListingIds: { ...(listingId ? { mercari: listingId } : {}), ...(url ? { mercariUrl: url } : {}) } } : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true };
  }
);
