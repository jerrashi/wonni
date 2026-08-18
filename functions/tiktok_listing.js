const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const { refreshTiktokToken, tiktokHeaders, makeHttpsRequest, TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");
const { listingImagesFor, toTiktokProductPayload } = require("./platform_adapters");

const TT_API_HOST = "open-api.tiktokglobalshop.com";

async function tiktokRequest(method, path, body, uid) {
  const { accessToken, shopId, shopCipher } = await refreshTiktokToken(uid);
  const appKey = TT_APP_KEY.value();
  const appSecret = TT_APP_SECRET.value();
  const bodyStr = body ? JSON.stringify(body) : "";
  const params = { shop_id: shopId, shop_cipher: shopCipher };
  const headers = tiktokHeaders(appKey, appSecret, accessToken, path, params, bodyStr);
  const qs = new URLSearchParams(params).toString();

  const result = await makeHttpsRequest(
    {
      hostname: TT_API_HOST,
      path: `${path}?${qs}`,
      method,
      headers: { ...headers, "Content-Length": Buffer.byteLength(bodyStr) },
    },
    bodyStr || undefined
  );

  return JSON.parse(result.body);
}

// Upload image URL to TikTok and return uri reference
async function uploadImageToTiktok(imageUrl, uid) {
  const response = await tiktokRequest("POST", "/api/products/202309/images/upload", {
    url: imageUrl,
  }, uid);
  return response?.data?.img_id ?? null;
}

// Fetch and flatten TikTok Shop leaf categories for the connected shop
exports.getTiktokCategories = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const response = await tiktokRequest("GET", "/api/product/202309/categories", null, uid);
    if (response.code !== 0) throw new HttpsError("internal", `TikTok error: ${response.message}`);

    function flatten(cats, path = []) {
      const result = [];
      for (const cat of cats ?? []) {
        const breadcrumb = [...path, cat.name];
        if (cat.is_leaf || !cat.children?.length) {
          result.push({ id: String(cat.id), name: breadcrumb.join(" > ") });
        } else {
          result.push(...flatten(cat.children, breadcrumb));
        }
      }
      return result;
    }

    return { categories: flatten(response.data?.category_list) };
  }
);

exports.tiktokCreateListing = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET], timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, title: titleOverride, sellPrice, categoryId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!categoryId) throw new HttpsError("invalid-argument", "Missing categoryId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
    if (product.tiktokStatus === "active") return { tiktokProductId: product.tiktokProductId };

    // Upload images
    const imgIds = [];
    for (const imgUrl of listingImagesFor(product, 9)) {
      const id = await uploadImageToTiktok(imgUrl, uid);
      if (id) imgIds.push({ img_id: id });
    }
    if (!imgIds.length) throw new HttpsError("internal", "No images could be uploaded to TikTok.");

    const finalPrice = sellPrice
      ?? product.listingPrice
      ?? product.aliexpressPrice * 2.5;

    const { images: _ignoredImages, ...basePayload } = toTiktokProductPayload(product, {
      titleOverride,
      categoryId,
    });

    const payload = {
      ...basePayload,
      main_images: imgIds,
      skus: [
        {
          sales_attributes: [],
          price: {
            amount: String(parseFloat(finalPrice).toFixed(2)),
            currency: "USD",
          },
          inventory: [{ warehouse_id: "default", quantity: 999 }],
          identifier_code: { type: 1, code: productId },
        },
      ],
      package_weight: { value: "0.5", unit: "KILOGRAM" },
      package_dimensions: { length: "20", width: "15", height: "5", unit: "CENTIMETER" },
    };

    const response = await tiktokRequest("POST", "/api/products/202309/products", payload, uid);

    if (response.code !== 0) {
      throw new HttpsError("internal", `TikTok listing failed: ${response.message}`);
    }

    const tiktokProductId = response.data?.product_id;
    await docRef.update({
      tiktokProductId,
      tiktokStatus: "active",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { tiktokProductId };
  }
);

exports.tiktokUpdateListing = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, updates } = request.data;
    const snap = await admin.firestore().collection("products").doc(productId).get();
    if (!snap.exists || snap.data().userId !== uid) throw new HttpsError("not-found", "Product not found.");

    const { tiktokProductId } = snap.data();
    if (!tiktokProductId) throw new HttpsError("failed-precondition", "Not listed on TikTok yet.");

    const response = await tiktokRequest(
      "PUT",
      `/api/products/202309/products/${tiktokProductId}`,
      updates,
      uid
    );

    if (response.code !== 0) throw new HttpsError("internal", `TikTok update failed: ${response.message}`);
    return { success: true };
  }
);

exports.tiktokDeleteListing = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    const ref = admin.firestore().collection("products").doc(productId);
    const snap = await ref.get();
    if (!snap.exists || snap.data().userId !== uid) throw new HttpsError("not-found", "Product not found.");

    const { tiktokProductId } = snap.data();
    if (tiktokProductId) {
      await tiktokRequest("DELETE", "/api/products/202309/products", { product_ids: [tiktokProductId] }, uid);
    }

    await ref.update({ tiktokStatus: "inactive", updatedAt: admin.firestore.FieldValue.serverTimestamp() });
    return { success: true };
  }
);

module.exports = { ...module.exports, tiktokRequest };
