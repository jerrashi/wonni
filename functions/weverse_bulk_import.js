const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { downloadBuffer, savePublicBuffer } = require("./product_media");
const { fetchWeverseSale, validateSaleForImport, mapSaleToProduct, parseWeverseUrl } = require("./weverse_product");

const BATCH_SIZE_LIMIT = 25;
const CONCURRENCY_CHUNK_SIZE = 4;

function chunkArray(array, size) {
  const chunks = [];
  for (let i = 0; i < array.length; i += size) {
    chunks.push(array.slice(i, i + size));
  }
  return chunks;
}

// Bulk import a list of Weverse items (up to 25 per request).
// Expects: { items: [{ productUrl, saleId, title }] }
exports.weverseBulkImportProducts = onCall(
  { timeoutSeconds: 120, memory: "1GiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const rawItems = request.data?.items;
    if (!Array.isArray(rawItems) || rawItems.length === 0) {
      throw new HttpsError("invalid-argument", "Missing items array.");
    }
    if (rawItems.length > BATCH_SIZE_LIMIT) {
      throw new HttpsError("invalid-argument", `Batch size exceeds limit of ${BATCH_SIZE_LIMIT}.`);
    }

    const db = admin.firestore();
    const storage = admin.storage().bucket();

    // Collect existing drafts for this user to avoid duplicates
    const existingSnap = await db
      .collection("products")
      .where("userId", "==", uid)
      .where("source", "==", "weverse")
      .get();

    const existingSaleIds = new Set(
      existingSnap.docs.map((doc) => doc.data().weverseSaleId).filter(Boolean)
    );

    const importedProductIds = [];
    const existingProductIds = [];
    const errors = [];

    // Process items in concurrency chunks of 4 to prevent server spikes
    const itemChunks = chunkArray(rawItems, CONCURRENCY_CHUNK_SIZE);

    for (const chunk of itemChunks) {
      await Promise.all(
        chunk.map(async (item) => {
          let saleId;
          try {
            const parsed = parseWeverseUrl(item.productUrl ?? "");
            saleId = parsed?.saleId ?? item.saleId;
            if (!saleId || !parsed) {
              errors.push({ title: item.title ?? item.productUrl, error: "Invalid Weverse URL." });
              return;
            }

            if (existingSaleIds.has(saleId)) {
              existingProductIds.push(saleId);
              return;
            }
            // Claim the saleId synchronously (before any await) so a duplicate
            // saleId in the same concurrency chunk can't both pass this check.
            existingSaleIds.add(saleId);

            const sale = await fetchWeverseSale(parsed.url, saleId);
            const verdict = validateSaleForImport(sale);
            if (!verdict.ok) {
              errors.push({ title: sale.name ?? item.title, error: verdict.reason ?? "Cannot be imported." });
              return;
            }

            const product = mapSaleToProduct(sale, parsed.url);

            // Re-host images in Firebase Storage
            const storedImages = [];
            const storedImageAssets = [];
            for (let i = 0; i < product.imageAssets.length; i++) {
              try {
                const sourceAsset = product.imageAssets[i];
                const buffer = await downloadBuffer(sourceAsset.url);
                const ext = sourceAsset.url.endsWith(".png") ? "png" : "jpg";
                const path = `dropship/${uid}/weverse-${saleId}/${i}.${ext}`;
                const file = storage.file(path);
                const storedUrl = await savePublicBuffer(
                  storage.name,
                  file,
                  buffer,
                  ext === "png" ? "image/png" : "image/jpeg"
                );
                storedImages.push(storedUrl);
                storedImageAssets.push({ ...sourceAsset, url: storedUrl, sourceUrl: sourceAsset.url });
              } catch {
                // Skip failed image downloads
              }
            }

            const docRef = db.collection("products").doc();
            await docRef.set({
              userId: uid,
              source: "weverse",
              weverseSaleId: saleId,
              title: product.title,
              description: product.description,
              weverseInfoTable: product.infoTable,
              images: storedImages.length ? storedImages : product.images,
              imageAssets: storedImageAssets.length ? storedImageAssets : product.imageAssets,
              listingImages: storedImages.length ? storedImages : product.images,
              price: product.price,
              aliexpressPrice: product.price,
              variants: product.variants,
              artistName: product.artistName,
              saleStatus: product.saleStatus,
              preOrder: product.preOrder,
              sourceUrl: parsed.url,
              tiktokStatus: "draft",
              importedAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            importedProductIds.push(docRef.id);
          } catch (err) {
            // Release the claim so this saleId isn't misreported as "existing"
            // when it never actually got created.
            existingSaleIds.delete(saleId);
            errors.push({ title: item.title ?? item.saleId, error: err.message ?? "Import failed." });
          }
        })
      );
    }

    return {
      importedCount: importedProductIds.length,
      existingCount: existingProductIds.length,
      productIds: importedProductIds,
      errors,
    };
  }
);
