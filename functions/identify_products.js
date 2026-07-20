const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { downloadBuffer } = require("./product_media");

const GEMINI_MODEL = "gemini-1.5-flash";

// System prompt that asks Gemini to return normalised bounding boxes (0–1000 scale).
const SYSTEM_PROMPT = `You are an e-commerce product photo analyst.
Identify every distinct product or item visible in the image.
Return ONLY valid JSON with this exact structure — no markdown, no explanation:
{
  "objects": [
    { "label": "product name", "box": [ymin, xmin, ymax, xmax] }
  ]
}
Coordinates are normalised integers from 0 to 1000 (0 = top/left edge, 1000 = bottom/right edge).
Include all clearly visible products. Label each with a short descriptive name (e.g. "T-shirt", "Keychain", "Hoodie").`;

function isOwner(product, uid) {
  return product?.userId && product.userId === uid;
}

function normalizeImageUrl(entry) {
  return typeof entry === "string" ? entry : entry?.url ?? "";
}

exports.identifyProductsInImage = onCall(
  { timeoutSeconds: 60, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, imageUrl } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!imageUrl) throw new HttpsError("invalid-argument", "Missing imageUrl.");

    // Verify product ownership and that the image belongs to this product
    const db = admin.firestore();
    const snap = await db.collection("products").doc(productId).get();
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

    // Download image buffer
    const buffer = await downloadBuffer(imageUrl);
    const mimeType = imageUrl.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
    const base64 = buffer.toString("base64");

    // Call Gemini
    const apiKey = process.env.GEMINI_API_KEY ?? process.env.GOOGLE_API_KEY;
    if (!apiKey) throw new HttpsError("internal", "Gemini API key not configured.");

    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: GEMINI_MODEL });

    let rawText;
    try {
      const result = await model.generateContent([
        SYSTEM_PROMPT,
        { inlineData: { mimeType, data: base64 } },
      ]);
      rawText = result.response.text();
    } catch (e) {
      throw new HttpsError("internal", `Gemini error: ${e.message}`);
    }

    // Parse JSON — strip any accidental markdown fences
    let parsed;
    try {
      const clean = rawText.replace(/```json\s*/g, "").replace(/```\s*/g, "").trim();
      parsed = JSON.parse(clean);
    } catch {
      throw new HttpsError("internal", `Could not parse Gemini response: ${rawText.slice(0, 200)}`);
    }

    const objects = (parsed?.objects ?? [])
      .filter((obj) => {
        const b = obj?.box;
        return (
          Array.isArray(b) &&
          b.length === 4 &&
          b.every((v) => typeof v === "number" && v >= 0 && v <= 1000)
        );
      })
      .map((obj, i) => ({
        id: `box-${i}`,
        label: String(obj.label ?? "Product").slice(0, 80),
        box: obj.box.map(Math.round), // [ymin, xmin, ymax, xmax]
      }));

    if (!objects.length) {
      throw new HttpsError("not-found", "No products were identified in this image.");
    }

    return { objects };
  }
);
