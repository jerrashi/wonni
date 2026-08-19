const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

// Detects differences between live Mercari data and local synced baseline,
// downloads new photos to Storage, and returns a diff summary for the UI to approve.
// Called by the web app after scraping a live Mercari item page.
exports.detectMercariPullSyncDiff = onCall(
  { timeoutSeconds: 60 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const {
      listingId,        // docId in listings/{id} (or products/{id} for legacy)
      variantId,        // optional, for per-variant
      liveData,         // { title, description, photos: [...] } from Mercari
      syncedData,       // { title, description, images: [...] } current baseline
    } = request.data ?? {};

    if (!listingId || !liveData) {
      throw new HttpsError("invalid-argument", "Missing listingId or liveData.");
    }

    // Verify ownership
    const db = admin.firestore();
    const listingSnap = await db.collection("listings").doc(listingId).get();
    if (listingSnap.exists && listingSnap.data().userId !== uid) {
      throw new HttpsError("permission-denied", "Not your listing.");
    }

    // Detect title/description differences
    const diff = {
      titleChanged: syncedData?.title !== liveData.title,
      descriptionChanged: syncedData?.description !== liveData.description,
      photosAdded: [],
      photosRemoved: [],
    };

    // Photo comparison: find URLs in liveData not in syncedData
    const syncedUrls = new Set(syncedData?.images || []);
    const liveUrls = new Set(liveData.photos || []);

    for (const url of liveUrls) {
      if (!syncedUrls.has(url)) {
        diff.photosAdded.push(url);
      }
    }

    for (const url of syncedUrls) {
      if (!liveUrls.has(url)) {
        diff.photosRemoved.push(url);
      }
    }

    // If there are new photos, download and re-host them in Storage
    const rehostedPhotos = [];
    if (diff.photosAdded.length > 0) {
      const storage = admin.storage();
      const bucket = storage.bucket();

      for (let i = 0; i < diff.photosAdded.length; i++) {
        try {
          const originalUrl = diff.photosAdded[i];
          const response = await fetch(originalUrl, { timeout: 10000 });
          if (!response.ok) {
            console.warn(
              `[mercari_pull_sync] Failed to fetch image (${response.status}): ${originalUrl}`
            );
            rehostedPhotos.push({ original: originalUrl, rehosted: null, error: response.status });
            continue;
          }

          const buffer = await response.buffer();
          const mimeType = response.headers.get("content-type") || "image/jpeg";

          // Store in mercari-pulled-sync/{listingId}/{variantId or "default"}/{timestamp}-{index}.jpg
          const variant = variantId || "default";
          const timestamp = Date.now();
          const filename = `mercari-pulled-sync/${listingId}/${variant}/${timestamp}-${i}.jpg`;

          await bucket.file(filename).save(buffer, { metadata: { contentType: mimeType } });

          // Generate signed URL (valid for 7 days)
          const [signedUrl] = await bucket.file(filename).getSignedUrl({
            version: "v4",
            action: "read",
            expires: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7 days
          });

          rehostedPhotos.push({ original: originalUrl, rehosted: signedUrl });
        } catch (err) {
          console.error(`[mercari_pull_sync] Error re-hosting image:`, err.message);
          rehostedPhotos.push({
            original: diff.photosAdded[i],
            rehosted: null,
            error: err.message,
          });
        }
      }
    }

    return {
      ok: true,
      diff,
      rehostedPhotos,
      hasChanges:
        diff.titleChanged ||
        diff.descriptionChanged ||
        diff.photosAdded.length > 0 ||
        diff.photosRemoved.length > 0,
    };
  }
);

// Imports detected pull-sync changes into the product/variant.
// Called by the web app after user approves the diff.
exports.importMercariPullSync = onCall(
  { timeoutSeconds: 30 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const {
      listingId,
      variantId,
      importTitle,
      importDescription,
      importPhotos, // array of { original, rehosted } from detectMercariPullSyncDiff result
    } = request.data ?? {};

    if (!listingId) {
      throw new HttpsError("invalid-argument", "Missing listingId.");
    }

    const db = admin.firestore();

    // Verify ownership
    const docSnap = await db.collection("listings").doc(listingId).get();
    if (!docSnap.exists) {
      throw new HttpsError("not-found", "Listing not found.");
    }
    if (docSnap.data().userId !== uid) {
      throw new HttpsError("permission-denied", "Not your listing.");
    }

    // For per-variant: update products/{id}.variants[].
    // For legacy: update products/{id} directly.
    if (variantId) {
      // Per-variant update
      await db.collection("products").doc(listingId).update({
        [`variants`]: admin.firestore.FieldValue.arrayUnion([]), // placeholder; real update via transaction
      });

      // Use transaction to safely update the specific variant
      await db.runTransaction(async (transaction) => {
        const productSnap = await transaction.get(db.collection("products").doc(listingId));
        const product = productSnap.data();
        const variants = product.variants || [];
        const variantIdx = variants.findIndex((v) => v.id === variantId);

        if (variantIdx < 0) {
          throw new HttpsError("not-found", "Variant not found.");
        }

        const variant = variants[variantIdx];

        if (importTitle) {
          variant.title = importTitle;
          variant.mercariSyncedTitle = importTitle;
        }

        if (importDescription) {
          variant.description = importDescription;
          variant.mercariSyncedDescription = importDescription;
        }

        if (importPhotos && importPhotos.length > 0) {
          // Add rehosted photos to the variant's photo array
          const rehostedUrls = importPhotos
            .filter((p) => p.rehosted)
            .map((p) => p.rehosted);

          if (!variant.photoUrls) {
            variant.photoUrls = [];
          }

          // Prepend new photos to the front
          variant.photoUrls = [...rehostedUrls, ...variant.photoUrls];
          variant.mercariSyncedImages = variant.photoUrls;
        }

        // Mark import timestamp
        variant.mercariPullSyncedAt = admin.firestore.Timestamp.now();

        variants[variantIdx] = variant;
        transaction.update(db.collection("products").doc(listingId), { variants });
      });
    } else {
      // Legacy single-product update
      const updates = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };

      if (importTitle) {
        updates.title = importTitle;
        updates.mercariSyncedTitle = importTitle;
      }

      if (importDescription) {
        updates.description = importDescription;
        updates.mercariSyncedDescription = importDescription;
      }

      if (importPhotos && importPhotos.length > 0) {
        const rehostedUrls = importPhotos.filter((p) => p.rehosted).map((p) => p.rehosted);
        if (!docSnap.data().photoUrls) {
          updates.photoUrls = [];
        }
        updates.photoUrls = [...rehostedUrls, ...(docSnap.data().photoUrls || [])];
        updates.mercariSyncedImages = updates.photoUrls;
      }

      updates.mercariPullSyncedAt = admin.firestore.Timestamp.now();
      await db.collection("products").doc(listingId).update(updates);
    }

    return { ok: true };
  }
);
