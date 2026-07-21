const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const {
  downloadBuffer,
  savePublicBuffer,
  splitImageBuffer,
  isOwner,
  normalizeImageUrl,
} = require("./product_media");

exports.splitProductImage = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, imageUrl, sliceHeight, slicePoints } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!imageUrl) throw new HttpsError("invalid-argument", "Missing imageUrl.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (!isOwner(product, uid)) throw new HttpsError("permission-denied", "Not your product.");

    const allowedImages = [
      ...(Array.isArray(product.imageAssets) ? product.imageAssets.map(normalizeImageUrl) : []),
      ...(Array.isArray(product.images) ? product.images.map(normalizeImageUrl) : []),
    ].filter(Boolean);
    if (!allowedImages.includes(imageUrl)) {
      throw new HttpsError("invalid-argument", "That image does not belong to this product.");
    }

    const buffer = await downloadBuffer(imageUrl);
    const splitResult = await splitImageBuffer(buffer, sliceHeight, slicePoints);

    const storage = admin.storage().bucket();
    const sourceImageName = imageUrl.split("/").pop()?.split("?")[0] ?? `image-${Date.now()}`;
    const baseName = sourceImageName.replace(/\.[^.]+$/, "");
    const ext = "png";

    const slices = [];
    for (let i = 0; i < splitResult.slices.length; i++) {
      const slice = splitResult.slices[i];
      const path = `dropship/${uid}/split/${productId}/${baseName}-${i + 1}.${ext}`;
      const file = storage.file(path);
      const url = await savePublicBuffer(storage.name, file, slice.buffer, slice.mimeType);
      slices.push({
        url,
        width: slice.width,
        height: slice.height,
        top: slice.top,
        kind: "split",
      });
    }

    return {
      sourceImage: imageUrl,
      width: splitResult.width,
      height: splitResult.height,
      slices,
    };
  }
);
