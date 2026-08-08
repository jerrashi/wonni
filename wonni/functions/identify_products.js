const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { downloadBuffer, isOwner, normalizeImageUrl } = require("./product_media");

const GEMINI_MODEL = "gemini-flash-lite-latest";

// System prompt that asks Gemini to return normalised bounding boxes (0–1000 scale) and extracted product titles and prices.
const SYSTEM_PROMPT = `You are an expert e-commerce product photo and merchandise list analyst.
Analyze the image to detect every distinct product, item, card, or listed merchandise entry visible (e.g. merchandise posters, pop-up store flyers, binder pages, flat-lays).
For each item:
1. "box": Return normalized bounding box coordinates [ymin, xmin, ymax, xmax] as integers from 0 to 1000. The box should bound the product image and its title/price label together.
2. "label": Extract the exact printed product title/name if visible (e.g. "Mug", "Shoulder Bag", "Link Keychain", "BTS OFFICIAL LIGHT STICK").
3. "price": Extract the price as a number if visible (e.g. 25.00 for "$25" or "$25.00", 100 for "$100.00"). If no price is visible, set to null.

Return ONLY valid JSON with this exact structure — no markdown, no explanation:
{
  "objects": [
    { "label": "Product Title", "price": 25.00, "box": [ymin, xmin, ymax, xmax] }
  ]
}`;

exports.identifyProductsInImage = onCall(
  { timeoutSeconds: 60, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, imageUrl, imageBase64 } = request.data ?? {};
    let mimeType = "image/jpeg";
    let base64 = "";

    if (imageBase64) {
      if (typeof imageBase64 !== "string") throw new HttpsError("invalid-argument", "Invalid imageBase64.");
      const match = imageBase64.match(/^data:(image\/[a-zA-Z+]+);base64,(.+)$/);
      if (match) {
        mimeType = match[1];
        base64 = match[2];
      } else {
        base64 = imageBase64;
      }
    } else if (imageUrl) {
      if (!productId) throw new HttpsError("invalid-argument", "Missing productId for imageUrl lookup.");
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

      const buffer = await downloadBuffer(imageUrl);
      mimeType = imageUrl.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
      base64 = buffer.toString("base64");
    } else {
      throw new HttpsError("invalid-argument", "Must provide either imageBase64 or (productId and imageUrl).");
    }

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
          b.every((v) => typeof v === "number" && v >= 0 && v <= 1000) &&
          b[0] < b[2] && // ymin < ymax
          b[1] < b[3]    // xmin < xmax
        );
      })
      .map((obj, i) => ({
        id: `box-${i}`,
        label: String(obj.label ?? "Product").slice(0, 80),
        price: typeof obj.price === "number" && !isNaN(obj.price) ? obj.price : null,
        box: obj.box.map(Math.round), // [ymin, xmin, ymax, xmax]
      }));

    if (!objects.length) {
      throw new HttpsError("not-found", "No products were identified in this image.");
    }

    return { objects };
  }
);
