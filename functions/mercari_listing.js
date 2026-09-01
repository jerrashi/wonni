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

    const { productId, status, listingId, url, category, error: outcomeError } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!status) throw new HttpsError("invalid-argument", "Missing status.");

    const db = admin.firestore();
    const ref = db.collection("products").doc(productId);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    if (snap.data()?.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const update = {
      "crossPostStatus.mercari": status,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (listingId) {
      update["crossPostListingIds.mercari"] = listingId;
    }
    if (url) {
      update["crossPostUrls.mercari"] = url;
    }
    if (outcomeError) {
      update["crossPostErrors.mercari"] = outcomeError;
    }
    if (status === "active") {
      // Clear any stale error on success
      update["crossPostErrors.mercari"] = admin.firestore.FieldValue.delete();
    }

    await ref.update(update);
    return { ok: true };
  }
);

// Called by the web app to fetch and cache the canonical listing details
// (title, description, images, price) needed by the Mercari cross-post form.
// Returns the merged payload so the caller can prefill the form without
// re-reading Firestore from the client.
exports.ensureMercariListingDetails = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const snap = await db.collection("products").doc(productId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product?.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    return {
      productId,
      title: product.title ?? "",
      description: product.description ?? "",
      images: product.images ?? [],
      listingPrice: product.listingPrice ?? null,
      sourcePrice: product.sourceCost ?? null,
      listingStatus: product.crossPostStatus?.mercari ?? "draft",
      listingUrl: product.crossPostUrls?.mercari ?? null,
      listingId: product.crossPostListingIds?.mercari ?? null,
    };
  }
);
