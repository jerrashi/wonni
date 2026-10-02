/**
 * bulk_text_drafts.js — `bulkDraftsFromText`
 *
 * Paste a list → one fully-filled draft proposal per listing. Three stages,
 * each independently testable (see `_internal`):
 *
 *   1. parse     — ONE gemini-flash-lite call splits the text into listings.
 *                  Header lines ("wii games (CIB):") become shared context,
 *                  "bundle N: a, b, c" lines become ONE listing with
 *                  `bundleItems`, parentheticals stay attached to their item.
 *   2. price     — per listing, live eBay Browse comps (ebay_comps.js):
 *                  median asking price → `suggestedPrice` (priceSource "comps"),
 *                  else the model's estimate ("ai").
 *   3. photos    — per listing, the first comp image(s) as a stock photo
 *                  (bundles: one per component), falling back to an
 *                  AI-generated product shot saved under
 *                  users/{uid}/generated/ (public, storage.googleapis.com URL
 *                  so eBay / web / the Mercari extension can all fetch it).
 *
 * Persists nothing to Firestore — the client reviews the proposals and
 * creates the drafts itself through its normal path, so the proposals go
 * through the same photo-upload / publish pipeline as a hand-made draft.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { validated } = require("./contracts");
const { retrieveComps } = require("./ebay_comps")._internal;
const { EBAY_CLIENT_ID, EBAY_CLIENT_SECRET } = require("./ebay_auth");
const { savePublicBuffer } = require("./product_media");
const { normalizeCondition } = require("./enrichment")._internal;

const GEMINI_API_KEY = "GEMINI_API_KEY";
const PARSE_MODEL = "gemini-flash-lite-latest";
const IMAGE_MODEL = "gemini-2.5-flash-image";
const PROMPT_VERSION = "2026-10-01.1";

const COMPS_PER_QUERY = 12;
const MAX_BUNDLE_PHOTOS = 4;
const CONCURRENCY = 6;

const PARSE_SYSTEM_PROMPT = `You turn a reseller's pasted inventory list into marketplace listings (eBay, Mercari, Facebook Marketplace).

Rules for reading the list:
- A line ending in ":" that is not an item (e.g. "wii games (CIB):", "PS2 lot, all tested:") is a HEADER. It is context for every line under it: platform/system, condition ("CIB" = complete in box, "loose", "sealed"), lot notes. Headers are never listings.
- A line like "bundle 1: a, b, c" or "lot: a + b" is ONE listing containing several items (isBundle=true, bundleItems = each item). The title should name all the items ("Just Dance 4, 2015 & 2014 Wii Bundle (3 Games, CIB)").
- Every other non-empty line is ONE single-item listing.
- Text in parentheses attaches to that item only (e.g. "(in cardboard sleeve)" affects condition/description of that item alone).
- Fix obvious typos and expand abbreviations in titles. Never invent items that are not in the text.
- Keep the input order.

For each listing produce:
- "sourceText": the exact input line(s) it came from.
- "title": searchable marketplace title, <= 140 chars, includes platform/system and key condition note.
- "shortTitle": eBay title, AT MOST 80 characters.
- "bundleItems": array of item names (empty for a single item).
- "isBundle": boolean.
- "description": 3-6 factual buyer-facing sentences: what is included, system/platform, condition from the header + parentheticals. No price, shipping, returns or markdown.
- "brand": publisher/manufacturer/franchise owner, or "Unbranded".
- "category": hierarchical path hint like "Video Games & Consoles > Video Games".
- "condition": exactly one of "new", "likenew", "good", "fair", "poor". "CIB"/"complete" with no other note = "good". "sealed" = "new".
- "tags": up to 8 lowercase search tags.
- "searchQuery": a short eBay search string for comparable listings of the WHOLE listing (e.g. "Super Smash Bros Brawl Wii CIB"). For a bundle, a query for the bundle as a whole.
- "componentQueries": for a bundle, one short eBay search string per bundleItem (same order); empty array for single items.
- "suggestedPrice": your estimated USD resale asking price for the whole listing (number).
- "quantity": 1 unless the text says otherwise.

Return ONLY JSON: {"context": "<one-line summary of the header context>", "items": [ ... ]}.`;

// ── stage 1: parse ────────────────────────────────────────────────────────

function cleanJsonText(raw) {
  return String(raw).replace(/```json\s*/gi, "").replace(/```/g, "").trim();
}

/** Raw model item → the contract's DraftProposal core (no pricing/photos yet). */
function toProposalCore(item = {}) {
  const str = (v, cap) => (typeof v === "string" && v.trim() ? v.trim().slice(0, cap) : "");
  const list = (v) => (Array.isArray(v) ? v.map((s) => String(s).trim()).filter(Boolean) : []);

  const bundleItems = list(item.bundleItems);
  const isBundle = Boolean(item.isBundle) || bundleItems.length > 1;
  const title = str(item.title, 140) || bundleItems.join(", ").slice(0, 140) || str(item.sourceText, 140);
  if (!title) return null;

  const shortTitle = str(item.shortTitle, 80) || title.slice(0, 80);
  const condition = normalizeCondition(item.condition) || "good";
  const tags = list(item.tags).map((t) => t.toLowerCase()).slice(0, 8);
  const quantity = Number.isInteger(item.quantity) && item.quantity > 0 ? item.quantity : 1;
  const aiPrice = Number(item.suggestedPrice);

  return {
    title,
    shortTitle,
    description: str(item.description, 2000) || title,
    brand: str(item.brand, 60) || undefined,
    category: str(item.category, 200) || undefined,
    condition,
    tags,
    isBundle,
    bundleItems: isBundle ? bundleItems : [],
    quantity,
    sourceText: str(item.sourceText, 500) || title,
    // Search hints, consumed by stages 2/3 and stripped before returning.
    _searchQuery: str(item.searchQuery, 200) || shortTitle,
    _componentQueries: list(item.componentQueries).slice(0, MAX_BUNDLE_PHOTOS),
    _aiPrice: Number.isFinite(aiPrice) && aiPrice > 0 ? Math.round(aiPrice * 100) / 100 : undefined,
  };
}

function parseModelOutput(raw, maxItems) {
  const json = JSON.parse(cleanJsonText(raw));
  const items = Array.isArray(json.items) ? json.items : [];
  const proposals = items.map(toProposalCore).filter(Boolean).slice(0, maxItems);
  return { context: typeof json.context === "string" ? json.context.trim() : "", proposals };
}

async function parseListWithGemini(apiKey, text, maxItems) {
  const genAI = new GoogleGenerativeAI(apiKey);
  const model = genAI.getGenerativeModel({
    model: PARSE_MODEL,
    systemInstruction: PARSE_SYSTEM_PROMPT,
    generationConfig: { responseMimeType: "application/json", temperature: 0.2 },
  });
  const raw = (await model.generateContent(`Inventory list:\n\n${text}`)).response.text();
  return parseModelOutput(raw, maxItems);
}

// ── stage 2: price ────────────────────────────────────────────────────────

function median(values) {
  const nums = values.filter((n) => Number.isFinite(n) && n > 0).sort((a, b) => a - b);
  if (!nums.length) return null;
  const mid = Math.floor(nums.length / 2);
  return nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
}

/** Median of comp asking prices, rounded to whole dollars (asking prices on
 *  eBay cluster on round numbers; a $23.47 suggestion reads as noise). */
function priceFromComps(comps) {
  const med = median(comps.map((c) => c.price));
  return med == null ? null : Math.max(1, Math.round(med));
}

// ── stage 3: photos ───────────────────────────────────────────────────────

/** Browse API hands back 225 px thumbnails (`.../s-l225.jpg`); the same CDN
 *  path serves the full-size upload at `s-l1600` (verified 2026-10-01), which
 *  is what a listing photo needs. Non-eBay URLs pass through untouched. */
function fullSizeEbayImage(url) {
  if (typeof url !== "string") return url;
  return url.replace(/(\/\/i\.ebayimg\.com\/.*\/s-l)\d+(\.(?:jpg|jpeg|png|webp))$/i, "$11600$2");
}

/** Gemini image model → PNG buffer, or null when the model returned no image. */
async function generateProductImage(apiKey, proposal, { fetchImpl = fetch } = {}) {
  const subject = proposal.isBundle
    ? `${proposal.bundleItems.join(", ")} (a bundle of ${proposal.bundleItems.length} items sold together)`
    : proposal.title;
  const prompt =
    `A clean, realistic product photograph for an online marketplace listing of: ${subject}. ` +
    `Show the actual physical item(s) as they would be sold${proposal.condition === "new" ? ", new" : ", in good used condition"}, ` +
    `centered on a plain white background, soft even lighting, no people, no text overlays, no watermarks, no logos added.`;

  const res = await fetchImpl(
    `https://generativelanguage.googleapis.com/v1beta/models/${IMAGE_MODEL}:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { responseModalities: ["IMAGE"] },
      }),
    }
  );
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`image generation failed (${res.status}): ${json.error?.message ?? ""}`);
  const parts = json.candidates?.[0]?.content?.parts ?? [];
  const inline = parts.find((p) => p.inlineData?.data)?.inlineData;
  if (!inline) return null;
  return { buffer: Buffer.from(inline.data, "base64"), mimeType: inline.mimeType || "image/png" };
}

async function saveGeneratedImage(uid, index, image) {
  const bucket = admin.storage().bucket();
  const ext = image.mimeType === "image/jpeg" ? "jpg" : "png";
  const path = `users/${uid}/generated/${Date.now()}-${index}.${ext}`;
  return savePublicBuffer(bucket.name, bucket.file(path), image.buffer, image.mimeType);
}

// ── orchestration ─────────────────────────────────────────────────────────

/** Run `fn` over `items` with at most `limit` in flight, preserving order. */
async function mapWithConcurrency(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

async function safeComps(query, deps) {
  if (!query) return [];
  try {
    return await deps.comps({ title: query, limit: COMPS_PER_QUERY });
  } catch (e) {
    console.warn(`[bulkDraftsFromText] comps failed for "${query}": ${e.message}`);
    return [];
  }
}

/**
 * Price + photo one proposal. `deps` is injectable for tests:
 *   comps({title, limit}) → [{price, imageUrl, title, itemWebUrl}]
 *   generate(proposal)    → https URL | null
 */
async function enrichProposal(core, photoSource, deps) {
  const { _searchQuery, _componentQueries, _aiPrice, ...proposal } = core;

  const comps = await safeComps(_searchQuery, deps);
  const compPrice = priceFromComps(comps);
  if (compPrice != null) {
    proposal.suggestedPrice = compPrice;
    proposal.priceSource = "comps";
  } else if (_aiPrice) {
    proposal.suggestedPrice = _aiPrice;
    proposal.priceSource = "ai";
  } else {
    proposal.priceSource = "none";
  }
  proposal.comps = comps.slice(0, 5).map((c) => ({ title: c.title, price: c.price, itemWebUrl: c.itemWebUrl }));

  proposal.imageUrls = [];
  proposal.imageSource = "none";

  if (photoSource === "ebay") {
    // Bundle: one photo per component, so the cover shows what's in the lot.
    // Single: the best-matching comp's photo.
    const queries = proposal.isBundle && _componentQueries.length ? _componentQueries : [];
    const componentComps = queries.length
      ? await mapWithConcurrency(queries, 2, (q) => safeComps(q, deps))
      : [];
    const urls = [];
    for (const list of componentComps) {
      const hit = list.find((c) => c.imageUrl);
      const url = hit && fullSizeEbayImage(hit.imageUrl);
      if (url && !urls.includes(url)) urls.push(url);
    }
    if (!urls.length) {
      const hit = comps.find((c) => c.imageUrl);
      if (hit) urls.push(fullSizeEbayImage(hit.imageUrl));
    }
    if (urls.length) {
      proposal.imageUrls = urls.slice(0, MAX_BUNDLE_PHOTOS);
      proposal.imageSource = "ebay";
    }
  }

  if (photoSource !== "none" && !proposal.imageUrls.length && deps.generate) {
    try {
      const url = await deps.generate(proposal);
      if (url) {
        proposal.imageUrls = [url];
        proposal.imageSource = "generated";
      }
    } catch (e) {
      console.warn(`[bulkDraftsFromText] image generation failed for "${proposal.title}": ${e.message}`);
    }
  }

  return proposal;
}

async function buildDrafts({ text, maxItems, photoSource }, deps) {
  const { context, proposals } = await deps.parse(text, maxItems);
  const drafts = await mapWithConcurrency(proposals, CONCURRENCY, (core) => enrichProposal(core, photoSource, deps));
  return { context, drafts, aiModel: PARSE_MODEL, aiPromptVersion: PROMPT_VERSION };
}

exports.bulkDraftsFromText = onCall(
  { secrets: [GEMINI_API_KEY, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 300, memory: "1GiB" },
  validated("bulkDraftsFromText", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) throw new HttpsError("failed-precondition", "AI is not configured.");

    const deps = {
      parse: async (text, maxItems) => {
        try {
          return await parseListWithGemini(apiKey, text, maxItems);
        } catch (e) {
          console.error(`[bulkDraftsFromText] parse failed: ${e.message}`);
          throw new HttpsError("internal", `Could not read the list: ${e.message}`);
        }
      },
      comps: retrieveComps,
      generate: async (proposal) => {
        const image = await generateProductImage(apiKey, proposal);
        return image ? saveGeneratedImage(uid, Math.floor(Math.random() * 1e6), image) : null;
      },
    };
    return buildDrafts(data, deps);
  })
);

exports._internal = {
  toProposalCore,
  parseModelOutput,
  priceFromComps,
  median,
  enrichProposal,
  buildDrafts,
  mapWithConcurrency,
  fullSizeEbayImage,
  PARSE_SYSTEM_PROMPT,
};
