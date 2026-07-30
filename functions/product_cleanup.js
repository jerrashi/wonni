const { onDocumentDeleted } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

// Triggered whenever a product document is deleted. Cleans up any orphaned
// files in Firebase Storage that belonged to that product (split images,
// crop edits, draft photos) so storage costs don't accumulate over time.
exports.onProductDeleted = onDocumentDeleted(
  "products/{productId}",
  async (event) => {
    const product = event.data?.data();
    const productId = event.params.productId;
    const uid = product?.userId;
    if (!uid) return;

    const storage = admin.storage().bucket();

    // Collect all image URLs stored under Firebase Storage for this product
    const allImageUrls = [
      ...(Array.isArray(product.images) ? product.images : []),
      ...(Array.isArray(product.imageAssets) ? product.imageAssets.map((a) => (typeof a === "string" ? a : a?.url ?? "")) : []),
    ].filter((url) => typeof url === "string" && url.includes("storage.googleapis.com"));

    // Derive storage paths from public URLs and delete them
    const deletions = allImageUrls.map(async (url) => {
      try {
        // Public URLs: https://storage.googleapis.com/<bucket>/<path>
        const match = url.match(/storage\.googleapis\.com\/[^/]+\/(.+)$/);
        if (!match) return;
        const filePath = decodeURIComponent(match[1]);
        await storage.file(filePath).delete({ ignoreNotFound: true });
      } catch {
        // Non-fatal — best-effort cleanup only
      }
    });

    // Also delete the entire dropship/<uid>/...<productId> directory tree
    try {
      const prefix = `dropship/${uid}/`;
      const [files] = await storage.getFiles({ prefix });
      const productFiles = files.filter((f) => f.name.includes(productId));
      await Promise.all(productFiles.map((f) => f.delete({ ignoreNotFound: true }).catch(() => {})));
    } catch {
      // Non-fatal
    }

    await Promise.all(deletions);
  }
);
