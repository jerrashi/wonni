const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { downloadBuffer, isOwner, normalizeImageUrl } = require("./product_media");

const GEMINI_MODEL = "gemini-flash-lite-latest";

// Prompt instructs Gemini to write a clean, buyer-facing Mercari / resale
// listing description for a K-pop / pop-culture merchandise item.
const SYSTEM_PROMPT = `You are an expert e-commerce copywriter specialising in K-pop merchandise and pop-culture collectibles sold on platforms like Mercari, eBay, and TikTok Shop.

Given a product title, optional existing description, and optionally one or more product images, write a concise, buyer-friendly product description (3–6 sentences).

Guidelines:
- Lead with what the item IS (e.g. "Official BTS photocard set from the Map of the Soul era.").
- Mention key details visible in the image (condition, contents, notable features) when an image is provided.
- Keep language natural and factual — no marketing fluff, no fake reviews.
- End with a brief note about condition if relevant (e.g. "Sealed / mint condition." or "Light shelf wear, no creases.").
- Do NOT include price, shipping, or seller policies.
- Output ONLY the description text — no headings, no bullet points, no markdown.`;

const geminiApiKey = "GEMINI_API_KEY";

exports.geminiApiKey = geminiApiKey;

exports.generateProductDescription = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [geminiApiKey] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, title = "", existingDescription = "", imageUrl, imageBase64 } = request.data ?? {};

    if (!title && !imageUrl && !imageBase64) {
      throw new HttpsError("invalid-argument", "Provide at least a title or an image.");
    }

    // Build the parts array for Gemini
    const parts = [];

    // Prompt text
    const promptText = [
      `Product title: ${title || "(not provided)"}`,
      existingDescription ? `Existing description (for context, may be empty or auto-generated): ${existingDescription}` : "",
      "Write the product description:",
    ]
      .filter(Boolean)
      .join("\n");

    parts.push(promptText);

    // Attach image (base64 from client, or download from URL)
    if (imageBase64) {
      // Direct base64 upload (e.g. from CreateDraftModal before the product is saved)
      if (typeof imageBase64 !== "string") throw new HttpsError("invalid-argument", "Invalid imageBase64.");
      const match = imageBase64.match(/^data:(image\/[a-zA-Z+]+);base64,(.+)$/);
      const mimeType = match ? match[1] : "image/jpeg";
      const b64data = match ? match[2] : imageBase64;
      parts.push({ inlineData: { mimeType, data: b64data } });
    } else if (imageUrl) {
      // URL from a persisted product — verify ownership if productId provided
      if (productId) {
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
      }

      try {
        const buffer = await downloadBuffer(imageUrl);
        const mimeType = imageUrl.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
        parts.push({ inlineData: { mimeType, data: buffer.toString("base64") } });
      } catch {
        // Image download failure is non-fatal — proceed without it
      }
    }


    // Call Gemini
    const apiKey = process.env.GEMINI_API_KEY ?? process.env.GOOGLE_API_KEY;
    if (!apiKey) throw new HttpsError("internal", "Gemini API key not configured.");

    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({
      model: GEMINI_MODEL,
      systemInstruction: SYSTEM_PROMPT,
    });

    let rawText;
    try {
      const result = await model.generateContent(parts);
      rawText = result.response.text().trim();
    } catch (e) {
      throw new HttpsError("internal", `Gemini error: ${e.message}`);
    }

    if (!rawText) {
      throw new HttpsError("internal", "Gemini returned an empty description.");
    }

    return { description: rawText };
  }
);
