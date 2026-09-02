const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const https = require("https");
const { callAliexpressApi } = require("./aliexpress_auth");
const { geminiApiKey } = require("./gemini_identify");
const { buildNewProductDoc } = require("./product_schema");

const ALLOWED_IMAGE_HOSTS = [".alicdn.com", ".aliexpress-media.com"];
const MAX_IMAGE_BYTES = 10 * 1024 * 1024; // 10 MB

function isAllowedImageUrl(rawUrl) {
  try {
    const { protocol, hostname } = new URL(rawUrl);
    if (protocol !== "https:") return false;
    return ALLOWED_IMAGE_HOSTS.some((h) => hostname === h.slice(1) || hostname.endsWith(h));
  } catch {
    return false;
  }
}

// Download a remote image buffer (for re-uploading to Firebase Storage)
function downloadBuffer(url, depth = 0) {
  if (!isAllowedImageUrl(url)) return Promise.reject(new Error(`Disallowed image URL: ${url}`));
  if (depth > 2) return Promise.reject(new Error("Too many redirects"));
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return downloadBuffer(res.headers.location, depth + 1).then(resolve).catch(reject);
      }
      const chunks = [];
      let size = 0;
      res.on("data", (c) => {
        size += c.length;
        if (size > MAX_IMAGE_BYTES) { res.destroy(); return reject(new Error("Image too large")); }
        chunks.push(c);
      });
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

// AliExpress sku_attr is a ";"-separated list of "pid:vid#Name:Value" pairs
// (the "#Name:Value" label suffix is what carries the human-readable
// attribute — pid/vid are internal AliExpress property/value ids).
function parseSkuAttr(skuAttr) {
  if (!skuAttr || typeof skuAttr !== "string") return [];
  return skuAttr
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const labelPart = part.includes("#") ? part.slice(part.indexOf("#") + 1) : part;
      const colonIdx = labelPart.indexOf(":");
      if (colonIdx === -1) return { name: "Option", value: labelPart.trim() };
      return { name: labelPart.slice(0, colonIdx).trim() || "Option", value: labelPart.slice(colonIdx + 1).trim() };
    })
    .filter((p) => p.value);
}

// Map AliExpress SKUs (each carrying a skuAttr like "Color:Red;Size:L") into
// the product's normalized options/variants shape. Falls back to no
// options/variants (single-SKU product) if nothing structured can be parsed.
function mapAliexpressVariants(skus, productId) {
  const parsedSkus = (skus ?? []).map((s) => ({ ...s, parsed: parseSkuAttr(s.skuAttr) }));

  const dimensions = new Map(); // optionName -> ordered Set of values
  parsedSkus.forEach(({ parsed }) => {
    parsed.forEach(({ name, value }) => {
      if (!dimensions.has(name)) dimensions.set(name, new Set());
      dimensions.get(name).add(value);
    });
  });

  if (!dimensions.size) return { options: [], variants: [] };

  const options = Array.from(dimensions.entries()).map(([name, values], i) => ({
    id: `opt-${i}`,
    name,
    values: Array.from(values),
  }));

  const variants = parsedSkus.map((s, i) => {
    const optionValues = {};
    s.parsed.forEach(({ name, value }) => { optionValues[name] = value; });
    return {
      id: `v${Date.now()}${i}`,
      optionValues,
      sku: `${productId}-${i + 1}`,
      price: typeof s.price === "number" ? s.price : null,
      quantity: 1,
      sourcePrice: typeof s.price === "number" ? s.price : null,
      sourceVariantId: s.skuId ?? null,
      active: true,
    };
  });

  return { options, variants };
}

// Import a product from AliExpress — called by Chrome extension (scrapedData) or web URL paste
exports.aliexpressImportProduct = onCall(
  { timeoutSeconds: 120, memory: "512MiB", secrets: [geminiApiKey] },
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
    const { options, variants } = mapAliexpressVariants(product.variants, docRef.id);
    const finalImages = storedImages.length ? storedImages : product.images.slice(0, 5);
    const sourceImages = product.images.slice(0, 5); // Original AliExpress CDN URLs

    // AI enrichment is opt-in now — the user runs "AI autofill" (or it happens
    // as post-time gap-fill). No automatic Gemini call at import.

    // Build new schema product
    const newProduct = buildNewProductDoc({
      userId: uid,
      source: "aliexpress",
      sourceId: product.productId,
      sourceUrl: product.productUrl ?? productUrl ?? "",
      title: product.title,
      description: product.description ?? "",
      sourceCost: product.price,
      listingPrice: typeof product.listingPrice === "number" ? product.listingPrice : null,
      sourceImages,
      images: finalImages,
      options,
      variants,
      aliexpressProductId: product.productId,
      aliexpressUrl: product.productUrl ?? productUrl ?? "",
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await docRef.set(newProduct);
    return { productId: docRef.id };
  }
);
