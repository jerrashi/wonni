const { GoogleGenerativeAI } = require("@google/generative-ai");

const { downloadBuffer, isAllowedImageUrl } = require("./product_media");

// Secret name consumed by functions that run Gemini at import time.
// Referenced in the `secrets` array of each onCall config.
const geminiApiKey = "GEMINI_API_KEY";

exports.geminiApiKey = geminiApiKey;

const GEMINI_MODEL = "gemini-2.5-flash-lite";

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
- "suggestedDescription": a concise 2-4 sentence buyer-friendly listing description. Lead with what the item is; end with a brief condition note if inferable. No markdown, no bullets.
- "suggestedCategory": one of ["Photocard", "Keychain/Accessory", "Apparel", "Plushie", "Poster/Print", "Album/CD", "Light Stick", "Stationery", "Mirror/Beauty", "Collectible Figure", "Other"].
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
      ...(typeof parsed.suggestedDescription === "string" && parsed.suggestedDescription
        ? { geminiDescription: parsed.suggestedDescription }
        : {}),
      ...(typeof parsed.suggestedCategory === "string" && parsed.suggestedCategory
        ? { geminiCategory: parsed.suggestedCategory }
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
    };
  } catch {
    // Never block an import on a Gemini failure
    return {};
  }
};
