const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const https = require("https");
const { callAliexpressApi } = require("./aliexpress_auth");

// Download a remote image buffer (for re-uploading to Firebase Storage)
function downloadBuffer(url) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("https") ? https : require("http");
    mod.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return downloadBuffer(res.headers.location).then(resolve).catch(reject);
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", reject);
    }).on("error", reject);
  });
}

// Extract AliExpress item ID from a URL
function extractItemId(url) {
  const match = url.match(/\/item\/(\d+)\.html/) ?? url.match(/[?&]id=(\d+)/);
  return match?.[1] ?? null;
}

// Import a product from AliExpress — called by Chrome extension (scrapedData) or web URL paste
exports.aliexpressImportProduct = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { scrapedData, productUrl } = request.data;
    let product = scrapedData;

    // URL-paste flow: fetch richer data from AliExpress DS API
    if (!product && productUrl) {
      const itemId = extractItemId(productUrl);
      if (!itemId) throw new HttpsError("invalid-argument", "Could not extract product ID from URL.");

      const response = await callAliexpressApi("aliexpress.ds.product.get", {
        product_id: itemId,
        ship_to_country: "US",
        local_currency: "USD",
      }, uid);

      const result = response?.aliexpress_ds_product_get_response?.result;
      if (!result) throw new HttpsError("not-found", "Product not found on AliExpress.");

      const priceRange = result.ae_item_sku_info_dtos?.ae_item_sku_info_d_t_o ?? [];
      const minPrice = Math.min(...priceRange.map((s) => parseFloat(s.sku_price ?? "0"))) || 0;

      product = {
        productId: String(itemId),
        productUrl: productUrl,
        title: result.ae_item_base_info_dto?.subject ?? "",
        price: minPrice,
        images: (result.ae_multimedia_info_dto?.image_urls?.string ?? []).slice(0, 8),
        variants: (result.ae_item_sku_info_dtos?.ae_item_sku_info_d_t_o ?? []).map((s) => ({
          skuId: s.sku_id,
          skuAttr: s.sku_attr,
          price: parseFloat(s.sku_price ?? "0"),
        })),
      };
    }

    if (!product) throw new HttpsError("invalid-argument", "No product data provided.");

    const db = admin.firestore();
    const storage = admin.storage().bucket();

    // Check for existing import (idempotency)
    const existing = await db.collection("products")
      .where("userId", "==", uid)
      .where("aliexpressProductId", "==", product.productId)
      .limit(1)
      .get();
    if (!existing.empty) return { productId: existing.docs[0].id };

    // Upload images to Firebase Storage
    const storedImages = [];
    for (let i = 0; i < Math.min(product.images.length, 5); i++) {
      try {
        const buf = await downloadBuffer(product.images[i]);
        const path = `dropship/${uid}/${product.productId}/${i}.jpg`;
        const file = storage.file(path);
        await file.save(buf, { contentType: "image/jpeg", public: true });
        storedImages.push(`https://storage.googleapis.com/${storage.name}/${path}`);
      } catch {
        // Skip images that fail to download
      }
    }

    // Create Firestore product document
    const docRef = db.collection("products").doc();
    await docRef.set({
      userId: uid,
      aliexpressProductId: product.productId,
      aliexpressProductUrl: product.productUrl ?? productUrl ?? "",
      title: product.title,
      description: product.description ?? "",
      images: storedImages.length ? storedImages : product.images.slice(0, 5),
      aliexpressPrice: product.price,
      variants: product.variants ?? [],
      tiktokStatus: "draft",
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { productId: docRef.id };
  }
);
