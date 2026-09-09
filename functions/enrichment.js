/**
 * enrichment.js — `enrichListing`
 *
 * ONE callable, ONE Gemini call, ONE output shape (contracts/enrichment.js
 * `ListingFields`), two entry modes:
 *
 *   mode:"draft"    { images[], hints? }        → identify a not-yet-created item
 *                                                 from photos. Persists nothing.
 *   mode:"product"  { productId, fillBlanksOnly, persist }
 *                                               → gap-fill an existing product,
 *                                                 optionally writing the blanks.
 *
 * Replaces iOS `identifyItem` (draft) + web `aiAutofillListing` (product).
 * `aiAutofillListing` stays as a thin alias until the web migration lands.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { validated } = require("./contracts");
const { downloadBuffer, isOwner } = require("./product_media");
const { resolveListingFields } = require("./listing_fields");

const GEMINI_API_KEY = "GEMINI_API_KEY";
const GEMINI_MODEL = "gemini-flash-lite-latest";
const PROMPT_VERSION = "2026-09-09.1";
const TITLE_CAP = 140;
const SHORT_TITLE_CAP = 80;

// iOS `ItemCondition` (7 values) + loose keyword output → canonical 5.
const CONDITION_MAP = {
  new: "new", newwithtags: "new", newwithouttags: "new", sealed: "new",
  likenew: "likenew", like_new: "likenew", mint: "likenew",
  good: "good", used: "good", preowned: "good",
  fair: "fair",
  poor: "poor", forparts: "poor", for_parts: "poor",
};

function normalizeCondition(raw) {
  if (typeof raw !== "string") return undefined;
  return CONDITION_MAP[raw.toLowerCase().replace(/[\s-]/g, "")] || undefined;
}

/** A raw Gemini "draft" JSON blob → the canonical ListingFields shape. */
function toListingFields(g = {}) {
  const out = {};
  const str = (v, cap) => (typeof v === "string" && v.trim() ? v.trim().slice(0, cap) : undefined);

  out.title = str(g.name ?? g.title, TITLE_CAP);
  out.shortTitle = str(g.shortTitle, SHORT_TITLE_CAP) ?? (out.title ? out.title.slice(0, SHORT_TITLE_CAP) : undefined);
  out.description = str(g.description, 2000);
  out.brand = str(g.brand, 60);
  out.category = str(g.category, 200);

  const cond = normalizeCondition(g.condition);
  if (cond) out.condition = cond;

  if (Array.isArray(g.tags) && g.tags.length) {
    out.tags = g.tags.map((t) => String(t).toLowerCase().trim()).filter(Boolean).slice(0, 8);
  }

  const price = Number(g.suggestedPrice ?? g.price);
  if (Number.isFinite(price) && price > 0) out.suggestedPrice = Math.round(price * 100) / 100;

  // iOS emits weightLbs; the contract is whole ounces.
  const oz = Number.isFinite(Number(g.weightOz)) ? Number(g.weightOz)
    : Number.isFinite(Number(g.weightLbs)) ? Number(g.weightLbs) * 16
      : undefined;
  if (oz && oz > 0) out.weightOz = Math.round(oz);

  for (const [k, src] of [["lengthIn", g.lengthIn], ["widthIn", g.widthIn], ["heightIn", g.heightIn]]) {
    const n = Number(src);
    if (Number.isFinite(n) && n > 0) out[k] = Math.round(n * 10) / 10;
  }

  if (g.itemSpecifics && typeof g.itemSpecifics === "object" && !Array.isArray(g.itemSpecifics)) {
    const specifics = {};
    for (const [k, v] of Object.entries(g.itemSpecifics)) {
      if (k && v != null && String(v).trim()) specifics[String(k)] = String(v).trim();
    }
    if (Object.keys(specifics).length) out.itemSpecifics = specifics;
  }

  const conf = Number(g.confidence);
  if (Number.isFinite(conf)) out.confidence = Math.min(1, Math.max(0, conf));

  // Drop undefined so the zod response schema stays clean.
  return Object.fromEntries(Object.entries(out).filter(([, v]) => v !== undefined));
}

/** `resolveListingFields` doc-field writes → the contract's ListingFields view. */
function writesToContract(writes = {}) {
  const map = {
    description: "description", brand: "brand", condition: "condition", tags: "tags",
    geminiCategory: "category", geminiItemSpecifics: "itemSpecifics",
  };
  const out = {};
  for (const [docKey, contractKey] of Object.entries(map)) {
    if (writes[docKey] != null) out[contractKey] = writes[docKey];
  }
  return out;
}

const DRAFT_SYSTEM_PROMPT = `You identify second-hand and collectible items (especially K-pop / pop-culture merch) for resale on eBay, Etsy, Mercari and TikTok Shop.
Given photos and optional user hints, return ONLY a JSON object (no code fences) with these keys:
- "name": concise searchable product name.
- "shortTitle": a marketplace listing title, AT MOST 80 characters — brand + model + key attribute.
- "brand": brand / artist / franchise, or "Unbranded".
- "category": hierarchical path like "Collectibles > K-pop > Photocards" (a hint, not an id).
- "suggestedPrice": estimated current USD resale price (number).
- "description": 3-6 factual buyer-facing sentences, no marketing fluff, no price/shipping/returns, no markdown.
- "condition": exactly one of "new", "likenew", "good", "fair", "poor" — best guess from the photos and hints.
- "weightOz": estimated shipping weight in ounces (number).
- "lengthIn","widthIn","heightIn": estimated shipping box dimensions in inches (numbers).
- "itemSpecifics": object of attributes buyers filter on, e.g. {"Type":"Photo Card","Member":"Jungkook"}. {} if unsure.
- "confidence": 0.0-1.0.
Count the shortTitle characters carefully — 80 max.`;

/** base64 string or data: URI or https URL → a Gemini inlineData part. */
async function toInlineData(image) {
  if (/^https?:\/\//i.test(image)) {
    const buf = await downloadBuffer(image);
    const mime = image.toLowerCase().includes(".png") ? "image/png" : "image/jpeg";
    return { inlineData: { mimeType: mime, data: buf.toString("base64") } };
  }
  const m = /^data:(image\/[a-z.+-]+);base64,(.*)$/i.exec(image);
  if (m) return { inlineData: { mimeType: m[1], data: m[2] } };
  return { inlineData: { mimeType: "image/jpeg", data: image } };
}

async function identifyDraft(apiKey, images, hints = {}) {
  const genAI = new GoogleGenerativeAI(apiKey);
  const model = genAI.getGenerativeModel({ model: GEMINI_MODEL, systemInstruction: DRAFT_SYSTEM_PROMPT });

  const hintLines = [];
  if (hints.title) hintLines.push(`User title hint: "${hints.title}"`);
  if (hints.price != null) hintLines.push(`User price hint: $${hints.price}`);
  if (hints.description) hintLines.push(`User description hint: "${String(hints.description).slice(0, 400)}"`);

  const parts = [hintLines.length ? hintLines.join("\n") : "Identify the item in these photos."];
  for (const image of images.slice(0, 8)) {
    try { parts.push(await toInlineData(image)); } catch (e) {
      console.warn(`[enrichListing] image skipped: ${e.message}`);
    }
  }

  const raw = (await model.generateContent(parts)).response.text().trim();
  const json = JSON.parse(raw.replace(/```json\s*/gi, "").replace(/```/g, "").trim());
  return toListingFields(json);
}

// ── the callable ──────────────────────────────────────────────────────────

exports.enrichListing = onCall(
  { secrets: [GEMINI_API_KEY], timeoutSeconds: 60, memory: "512MiB" },
  validated("enrichListing", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) throw new HttpsError("failed-precondition", "AI is not configured.");

    const base = { proposals: {}, applied: [], aiModel: GEMINI_MODEL, aiPromptVersion: PROMPT_VERSION };

    if (data.mode === "draft") {
      let suggested;
      try {
        suggested = await identifyDraft(apiKey, data.images, data.hints);
      } catch (e) {
        console.error(`[enrichListing] draft failed: ${e.message}`);
        throw new HttpsError("internal", `Identification failed: ${e.message}`);
      }
      return { ...base, suggested, writes: {} };
    }

    // mode === "product"
    const db = admin.firestore();
    const ref = db.collection("products").doc(data.productId);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = snap.data();
    if (!isOwner(product, uid)) throw new HttpsError("permission-denied", "Not your product.");

    const { writes, suggestions } = await resolveListingFields(product, { apiKey });
    const contractWrites = writesToContract(writes);
    const applied = [];

    if (data.persist && Object.keys(writes).length) {
      await ref.update({ ...writes, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
      applied.push(...Object.keys(writes));
    }

    return {
      ...base,
      suggested: { ...contractWrites, ...(suggestions.title ? { title: suggestions.title } : {}) },
      writes: contractWrites,
      proposals: {
        ...(suggestions.title ? { title: suggestions.title } : {}),
        ...(suggestions.description ? { description: suggestions.description } : {}),
      },
      applied,
    };
  }),
);

exports._internal = { normalizeCondition, toListingFields, writesToContract, toInlineData };
