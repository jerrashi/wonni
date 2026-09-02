const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");
const { downloadBuffer, isOwner } = require("./product_media");
const { listingImagesFor } = require("./platform_adapters");

// Plain secret name — Firebase v2 `secrets: []` accepts the string form.
const geminiApiKey = "GEMINI_API_KEY";
exports.geminiApiKey = geminiApiKey;

const GEMINI_MODEL = "gemini-flash-lite-latest";
const TITLE_CAP = 80;   // eBay title limit
const DESC_CAP = 1000;  // readability cap for appended text
const VALID_CONDITIONS = new Set(["new", "likenew", "good", "fair", "poor"]);

function isBlank(v) {
  if (v == null) return true;
  if (typeof v === "string") return v.trim() === "";
  if (Array.isArray(v)) return v.length === 0;
  if (typeof v === "object") return Object.keys(v).length === 0;
  return false;
}

// Which fillable fields are currently empty on the product.
function blankFields(product) {
  const out = [];
  if (isBlank(product.description)) out.push("description");
  if (isBlank(product.brand) && isBlank(product.artistName)) out.push("brand");
  if (isBlank(product.tags)) out.push("tags");
  if (isBlank(product.condition) && isBlank(product.mercariCondition)) out.push("condition");
  if (isBlank(product.category) && isBlank(product.geminiCategory)) out.push("category");
  return out;
}

const SYSTEM_PROMPT = `You are an expert e-commerce copywriter for K-pop and pop-culture collectibles sold on eBay, Etsy, Mercari and TikTok Shop.
Given a product's title, its current description (may be empty), and one photo, return ONLY a JSON object. Include ONLY the keys you are asked to fill.
- "description": a 3-6 sentence buyer-facing description. Lead with what the item IS. Factual, no marketing fluff, no price/shipping/returns, no markdown.
- "descriptionAddon": ONE extra sentence adding a detail not already in the current description (used when a description already exists).
- "titleAddon": a short keyword phrase (<= 24 characters, no leading punctuation) to append to the current title for searchability.
- "brand": the brand / artist / franchise (e.g. "BTS", "Sanrio", "Nike"). Use "Unbranded" if there is none.
- "tags": array of up to 8 short lowercase search keywords.
- "condition": exactly one of "new", "likenew", "good", "fair", "poor" — your best guess from the photo.
- "category": a short category path hint like "Collectibles > K-pop > Photocards" (a hint for a marketplace category picker, NOT an ID).
- "itemSpecifics": object of extra attributes buyers filter on, e.g. {"Type":"Photo Card","Character":"Jungkook"}. Use {} if unsure.
Return ONLY valid JSON, no code fences.`;

async function callGemini(apiKey, product, keys) {
  const genAI = new GoogleGenerativeAI(apiKey);
  const model = genAI.getGenerativeModel({ model: GEMINI_MODEL, systemInstruction: SYSTEM_PROMPT });

  const parts = [[
    `Title: ${product.title || "(none)"}`,
    product.description ? `Current description: ${String(product.description).slice(0, 600)}` : "Current description: (empty)",
    `Fill these keys: ${keys.join(", ")}`,
  ].join("\n")];

  const img = listingImagesFor(product, 1)[0];
  if (img) {
    try {
      const buf = await downloadBuffer(img);
      parts.push({ inlineData: { mimeType: img.toLowerCase().endsWith(".png") ? "image/png" : "image/jpeg", data: buf.toString("base64") } });
    } catch { /* image is best-effort */ }
  }

  const raw = (await model.generateContent(parts)).response.text().trim();
  return JSON.parse(raw.replace(/```json\s*/gi, "").replace(/```/g, "").trim());
}

// Resolve fillable fields for a product with ONE Gemini call.
// Returns { writes, suggestions }:
//   writes       — safe values for blank fields; callers may persist directly.
//   suggestions  — proposed { title, description } that APPEND to existing
//                  user text (need consent via the aiSuggested* chip UI).
// Never throws — a Gemini failure yields empty results.
async function resolveListingFields(product, { apiKey } = {}) {
  apiKey = apiKey || process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
  const blanks = blankFields(product);

  const titleAppendable = !isBlank(product.title) && String(product.title).trim().length < TITLE_CAP - 4;
  const descAppendable = !blanks.includes("description")
    && !isBlank(product.description) && String(product.description).trim().length < DESC_CAP - 20;

  const keys = new Set(blanks);
  if (titleAppendable) keys.add("titleAddon");
  if (descAppendable) keys.add("descriptionAddon");
  if (keys.size === 0 || !apiKey) return { writes: {}, suggestions: {} };

  let g;
  try {
    g = await callGemini(apiKey, product, [...keys]);
  } catch (e) {
    console.warn("[resolveListingFields] Gemini failed:", e.message);
    return { writes: {}, suggestions: {} };
  }

  const writes = {};
  const suggestions = {};

  if (blanks.includes("description") && typeof g.description === "string" && g.description.trim()) {
    writes.description = g.description.trim();
  } else if (descAppendable && typeof g.descriptionAddon === "string" && g.descriptionAddon.trim()) {
    const merged = `${String(product.description).trim()} ${g.descriptionAddon.trim()}`;
    if (merged.length <= DESC_CAP) suggestions.description = merged;
  }

  if (titleAppendable && typeof g.titleAddon === "string" && g.titleAddon.trim()) {
    const addon = g.titleAddon.trim().replace(/^[\s,.;:–-]+/, "");
    const merged = `${String(product.title).trim()} ${addon}`;
    if (merged.length <= TITLE_CAP) suggestions.title = merged;
  }

  if (blanks.includes("brand") && typeof g.brand === "string" && g.brand.trim()) {
    writes.brand = g.brand.trim();
  }

  if (blanks.includes("condition") && VALID_CONDITIONS.has(g.condition)) {
    writes.condition = g.condition;
    writes.mercariCondition = g.condition;
  }

  if (blanks.includes("tags") && Array.isArray(g.tags) && g.tags.length) {
    writes.tags = g.tags.map((t) => String(t).toLowerCase().trim()).filter(Boolean).slice(0, 8);
  }

  if (blanks.includes("category") && typeof g.category === "string" && g.category.trim()) {
    // A hint only — each platform's create fn resolves it to a real id via
    // that platform's taxonomy API (user input > platform API > this hint).
    writes.geminiCategory = g.category.trim();
  }

  if (g.itemSpecifics && typeof g.itemSpecifics === "object" && Object.keys(g.itemSpecifics).length) {
    writes.geminiItemSpecifics = g.itemSpecifics;
  }

  return { writes, suggestions };
}

// Post-time gap-fill: persist resolved values for blank fields and merge them
// into the in-memory product so the caller lists with complete data.
async function fillBlankFieldsInline(product, productId) {
  try {
    const { writes } = await resolveListingFields(product);
    if (Object.keys(writes).length) {
      await admin.firestore().collection("products").doc(productId).update({
        ...writes,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      Object.assign(product, writes);
    }
  } catch (e) {
    console.warn("[fillBlankFieldsInline] skipped:", e.message);
  }
  return product;
}

// "AI autofill" button. Fills blank fields on the doc directly, and stages
// append-style title/description proposals as aiSuggested* for the chip UI.
exports.aiAutofillListing = onCall(
  { secrets: [geminiApiKey], timeoutSeconds: 60, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const { productId } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const ref = db.collection("products").doc(productId);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = snap.data();
    if (!isOwner(product, uid)) throw new HttpsError("permission-denied", "Not your product.");

    const { writes, suggestions } = await resolveListingFields(product);

    const update = { ...writes };
    if (suggestions.title) update.aiSuggestedTitle = suggestions.title;
    if (suggestions.description) update.aiSuggestedDescription = suggestions.description;
    if (Object.keys(update).length) {
      update.updatedAt = admin.firestore.FieldValue.serverTimestamp();
      await ref.update(update);
    }

    return {
      filled: Object.keys(writes),
      suggestions,
      noop: Object.keys(update).length === 0,
    };
  }
);

exports.resolveListingFields = resolveListingFields;
exports.fillBlankFieldsInline = fillBlankFieldsInline;
