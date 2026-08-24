const { GoogleGenerativeAI } = require("@google/generative-ai");

const { downloadBuffer, isAllowedImageUrl } = require("./product_media");

// Secret name consumed by functions that run Gemini at import time.
// Referenced in the `secrets` array of each onCall config.
const geminiApiKey = "GEMINI_API_KEY";

exports.geminiApiKey = geminiApiKey;

const GEMINI_MODEL = "gemini-2.5-flash-lite";
// Bump on any prompt-text change below — rides onto the product doc as
// `aiPromptVersion` so quality can be compared across prompt revisions,
// mirroring the same idea as the iOS app's own PROMPT_VERSION constant
// (functions/index.js in this repo, identifyItem).
const PROMPT_VERSION = "2026-08-19.1";

// Called once per product at import time. Returns a best-effort set of
// Gemini-enriched fields to merge into the Firestore product document.
// Never throws — on any failure it returns an empty object so the import
// continues without blocking.
exports.importTimeGeminiFields = async function importTimeGeminiFields({
  title = "",
  description = "",
  images = [],
} = {}) {
  try {
    const apiKey = process.env.GEMINI_API_KEY ?? process.env.GOOGLE_API_KEY;
    if (!apiKey) return {};

    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({
      model: GEMINI_MODEL,
      systemInstruction: `You are an expert e-commerce copywriter specialising in K-pop merchandise and pop-culture collectibles.
Given a product title, an optional raw description, and optionally a product image, return a JSON object with these fields:
- "suggestedTitle": a concise, buyer-friendly listing title (max 140 characters) if the provided title could be improved; omit this field entirely if the given title is already good.
- "suggestedDescription": a concise 2-4 sentence buyer-friendly listing description. Lead with what the item is; end with a brief condition note if inferable. No markdown, no bullets.
- "suggestedPrice": your best estimate of a fair resale price in USD (numeric, no currency symbol) for this item in typical used/collectible condition.
- "suggestedCategory": one of ["Photocard", "Keychain/Accessory", "Apparel", "Plushie", "Poster/Print", "Album/CD", "Light Stick", "Stationery", "Mirror/Beauty", "Collectible Figure", "Other"].
- "suggestedBrand": the inferred brand, manufacturer, or artist/group name (e.g. "BTS", "BLACKPINK", "NewJeans", "Sanrio", "Nike", "Pokemon", "HYBE", "Line Friends"), or null if truly generic/unbranded.
- "suggestedTags": up to 5 short keyword tags relevant for search (e.g. ["BTS", "official", "photocard"]).
Based on this listing data, what do you think the shipping dimensions and weight will be? Include:
- "suggestedWeightOz": your best estimate of the shipped package weight in whole ounces, including packaging.
- "suggestedLengthIn", "suggestedWidthIn", "suggestedHeightIn": your best estimate of the shipped package dimensions in whole inches.
Return ONLY valid JSON — no markdown, no explanation.`,
    });

    const parts = [];

    const promptText = [
      `Product title: ${title || "(not provided)"}`,
      description ? `Raw description (may be machine-generated): ${description.slice(0, 800)}` : "",
      "Return the enriched JSON fields:",
    ]
      .filter(Boolean)
      .join("\n");

    parts.push(promptText);

    // Attach the first usable product image if available
    const firstImage = images.find((u) => typeof u === "string" && isAllowedImageUrl(u));
    if (firstImage) {
      try {
        const buffer = await downloadBuffer(firstImage);
        const mimeType = firstImage.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg";
        parts.push({ inlineData: { mimeType, data: buffer.toString("base64") } });
      } catch {
        // Image download failure is non-fatal
      }
    }

    const result = await model.generateContent(parts);
    const rawText = result.response.text().trim();

    const clean = rawText.replace(/```json\s*/g, "").replace(/```\s*/g, "").trim();
    const parsed = JSON.parse(clean);

    return {
      // Shared with iOS's own `aiSuggested*`/`aiModel`/`aiPromptVersion` fields on
      // `products` (see UploadManager.syncProductDataAwaiting in the wonni repo) —
      // same field names regardless of which client produced the suggestion, so
      // web's "AI suggested" chip UI (ProductDetail.jsx) and postToWonni's
      // server-side aiTracking mapping both work the same way for either origin.
      ...(typeof parsed.suggestedTitle === "string" && parsed.suggestedTitle
        ? { aiSuggestedTitle: parsed.suggestedTitle.slice(0, 140) }
        : {}),
      ...(typeof parsed.suggestedDescription === "string" && parsed.suggestedDescription
        ? { aiSuggestedDescription: parsed.suggestedDescription }
        : {}),
      ...(typeof parsed.suggestedPrice === "number" && parsed.suggestedPrice > 0
        ? { aiSuggestedPrice: parsed.suggestedPrice }
        : {}),
      ...(typeof parsed.suggestedBrand === "string" && parsed.suggestedBrand && parsed.suggestedBrand.toLowerCase() !== "null" && parsed.suggestedBrand.toLowerCase() !== "unbranded"
        ? { brand: parsed.suggestedBrand.slice(0, 60), aiSuggestedBrand: parsed.suggestedBrand.slice(0, 60) }
        : {}),
      // dropship has no separate user-override UI for category — the AI
      // suggestion just becomes the product's own `category` field directly,
      // unlike title/description/price which do have a distinct "kept as
      // suggested vs. edited by the user" state worth preserving.
      ...(typeof parsed.suggestedCategory === "string" && parsed.suggestedCategory
        ? { category: parsed.suggestedCategory }
        : {}),
      ...(Array.isArray(parsed.suggestedTags) && parsed.suggestedTags.length
        ? { geminiTags: parsed.suggestedTags.slice(0, 5) }
        : {}),
      ...(typeof parsed.suggestedWeightOz === "number" && parsed.suggestedWeightOz > 0
        ? { geminiWeightOz: Math.round(parsed.suggestedWeightOz) }
        : {}),
      ...(typeof parsed.suggestedLengthIn === "number" && parsed.suggestedLengthIn > 0
        && typeof parsed.suggestedWidthIn === "number" && parsed.suggestedWidthIn > 0
        && typeof parsed.suggestedHeightIn === "number" && parsed.suggestedHeightIn > 0
        ? {
          geminiLengthIn: Math.round(parsed.suggestedLengthIn),
          geminiWidthIn: Math.round(parsed.suggestedWidthIn),
          geminiHeightIn: Math.round(parsed.suggestedHeightIn),
        }
        : {}),
      aiModel: GEMINI_MODEL,
      aiPromptVersion: PROMPT_VERSION,
    };
  } catch {
    // Never block an import on a Gemini failure
    return {};
  }
};
