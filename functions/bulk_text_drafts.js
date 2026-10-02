/**
 * bulk_text_drafts.js — `bulkDraftsFromText` + `generateListingPhoto`
 *
 * Paste a list → one fully-filled draft proposal per listing. Four stages,
 * each independently testable (see `_internal`):
 *
 *   1. parse     — ONE gemini-flash-lite call splits the text into listings.
 *                  Header lines ("wii games (CIB):") become shared context,
 *                  "bundle N: a, b, c" lines become ONE listing with
 *                  `bundleItems`, parentheticals stay attached to their item.
 *   2. comps     — per listing, live eBay Browse comps (ebay_comps.js):
 *                  median asking price → `suggestedPrice` (priceSource "comps"),
 *                  else the model's estimate ("ai").
 *   3. similar   — the "sell similar" half: Browse `getItem` on the best-
 *                  matching comp gives its eBay category id, condition id,
 *                  ePID and item specifics, which ride on the proposal so the
 *                  eBay create path reuses them instead of guessing
 *                  (`product.ebayCategoryId`, `product.geminiItemSpecifics`).
 *   4. photos    — in priority order, agreed 2026-10-01:
 *                    (a) the best comp's own photos (eBay sellers' photos;
 *                        bundles get one photo per component),
 *                    (b) Google Programmable Search image results, when the
 *                        GOOGLE_CSE_KEY / GOOGLE_CSE_CX secrets are set,
 *                    (c) nothing — the client shows a placeholder and asks the
 *                        user, once, whether AI-generated photos are OK; only
 *                        then does it call `generateListingPhoto`.
 *                  eBay's Catalog API (official stock photos) would sit at the
 *                  top of this list but the keyset is not granted the
 *                  commerce.catalog.readonly scope (checked 2026-10-01).
 *
 * Persists nothing to Firestore — the client reviews the proposals and
 * creates the drafts itself through its normal path, so the proposals go
 * through the same photo-upload / publish pipeline as a hand-made draft.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const { validated } = require("./contracts");
const { retrieveComps, retrieveCompDetail, fullSizeEbayImage } = require("./ebay_comps")._internal;
const { EBAY_CLIENT_ID, EBAY_CLIENT_SECRET } = require("./ebay_auth");
const { savePublicBuffer } = require("./product_media");
const { normalizeCondition } = require("./enrichment")._internal;

const GEMINI_API_KEY = "GEMINI_API_KEY";
const GOOGLE_CSE_KEY = "GOOGLE_CSE_KEY";
const GOOGLE_CSE_CX = "GOOGLE_CSE_CX";
const PARSE_MODEL = "gemini-flash-lite-latest";
const IMAGE_MODEL = "gemini-2.5-flash-image";
const PROMPT_VERSION = "2026-10-01.2";

const COMPS_PER_QUERY = 12;
const MAX_PHOTOS = 4;
const MAX_SPECIFICS = 20;
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
    // Search hints, consumed by stages 2-4 and stripped before returning.
    _searchQuery: str(item.searchQuery, 200) || shortTitle,
    _componentQueries: list(item.componentQueries).slice(0, MAX_PHOTOS),
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

// ── stage 3: "sell similar" ───────────────────────────────────────────────

const STOP_WORDS = new Set(["the", "a", "an", "and", "of", "for", "with", "cib", "complete", "in", "box", "tested", "game", "games"]);

function tokens(text) {
  return new Set(
    String(text || "")
      .toLowerCase()
      .replace(/[^a-z0-9 ]+/g, " ")
      .split(/\s+/)
      .filter((t) => t && !STOP_WORDS.has(t))
  );
}

/** The comp whose title best matches the query — most shared words, ties to
 *  the earlier (eBay-ranked) result — so a bundle search doesn't latch onto a
 *  single-game listing or a different platform. Must have a photo. */
function pickBestComp(comps, query) {
  const want = tokens(query);
  let best = null;
  let bestScore = -1;
  for (const comp of comps) {
    if (!comp.imageUrl) continue;
    const have = tokens(comp.title);
    let score = 0;
    for (const t of want) if (have.has(t)) score++;
    if (score > bestScore) { best = comp; bestScore = score; }
  }
  return best;
}

/** Seller-supplied aspects worth carrying onto the draft. Drops the ones that
 *  are either per-seller noise or re-derived at post time. */
const SKIPPED_ASPECTS = new Set(["country of origin", "country/region of manufacture", "mpn", "custom bundle", "modified item", "item height", "item length", "item width", "item weight", "unit quantity", "unit type"]);
/** Identity of ONE item — wrong on a bundle, whose best comp is some other
 *  lot (live run 2026-10-01: a 3-game Just Dance bundle inherited
 *  "Game Name: Just Dance 1, 2, 3, 2015"). Platform/publisher/genre still hold. */
const SINGLE_ITEM_ASPECTS = new Set(["game name", "upc", "ean", "isbn", "gtin", "release year", "release date", "model", "model number", "edition", "sku"]);
function usefulSpecifics(aspects = {}, { isBundle = false } = {}) {
  const out = {};
  for (const [name, value] of Object.entries(aspects)) {
    if (SKIPPED_ASPECTS.has(name.toLowerCase())) continue;
    if (isBundle && SINGLE_ITEM_ASPECTS.has(name.toLowerCase())) continue;
    if (Object.keys(out).length >= MAX_SPECIFICS) break;
    out[name] = value;
  }
  return out;
}

// ── stage 4: photos ───────────────────────────────────────────────────────

/** Google Programmable Search image results for `query`. Returns [] (never
 *  throws) when the CSE secrets aren't configured or the call fails. */
async function googleImages(query, { key, cx, fetchImpl = fetch } = {}) {
  // The secrets exist as "unset" placeholders until a Programmable Search
  // Engine is configured (BACKEND.md), so deploy can bind them either way.
  const configured = (v) => typeof v === "string" && v.trim() && v.trim().toLowerCase() !== "unset";
  if (!configured(key) || !configured(cx) || !query) return [];
  try {
    const params = new URLSearchParams({
      key, cx, q: query, searchType: "image", num: "5", imgType: "photo", safe: "active", imgSize: "large",
    });
    const res = await fetchImpl(`https://www.googleapis.com/customsearch/v1?${params}`);
    const json = await res.json().catch(() => ({}));
    if (!res.ok) {
      console.warn(`[bulkDraftsFromText] google images failed (${res.status}): ${json.error?.message ?? ""}`);
      return [];
    }
    return (json.items ?? [])
      .map((it) => it.link)
      .filter((u) => typeof u === "string" && /^https:\/\//i.test(u))
      .slice(0, MAX_PHOTOS);
  } catch (e) {
    console.warn(`[bulkDraftsFromText] google images failed: ${e.message}`);
    return [];
  }
}

/** Gemini image model → PNG buffer, or null when the model returned no image. */
async function generateProductImage(apiKey, { title, bundleItems = [], condition }, { fetchImpl = fetch } = {}) {
  const subject = bundleItems.length > 1
    ? `${bundleItems.join(", ")} (a bundle of ${bundleItems.length} items sold together)`
    : title;
  const prompt =
    `A clean, realistic product photograph for an online marketplace listing of: ${subject}. ` +
    `Show the actual physical item(s) as they would be sold${condition === "new" ? ", new" : ", in good used condition"}, ` +
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

async function saveGeneratedImage(uid, image) {
  const bucket = admin.storage().bucket();
  const ext = image.mimeType === "image/jpeg" ? "jpg" : "png";
  const path = `users/${uid}/generated/${Date.now()}-${Math.floor(Math.random() * 1e6)}.${ext}`;
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

async function safeDetail(itemId, deps) {
  if (!itemId || !deps.detail) return null;
  try {
    return await deps.detail(itemId);
  } catch (e) {
    console.warn(`[bulkDraftsFromText] comp detail failed for ${itemId}: ${e.message}`);
    return null;
  }
}

/**
 * Price, "sell similar" details and photos for one proposal. `deps` is
 * injectable for tests:
 *   comps({title, limit}) → [{itemId, title, price, imageUrl, itemWebUrl}]
 *   detail(itemId)        → retrieveCompDetail shape | null
 *   google(query)         → [https url]
 */
async function enrichProposal(core, deps) {
  const { _searchQuery, _componentQueries, _aiPrice, ...proposal } = core;

  // 2. price
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

  // 3. sell similar — category / condition / specifics from the best comp
  const best = pickBestComp(comps, _searchQuery);
  const detail = best ? await safeDetail(best.itemId, deps) : null;
  if (detail) {
    proposal.similarItemId = detail.itemId;
    if (detail.categoryId) proposal.ebayCategoryId = String(detail.categoryId);
    if (detail.conditionId) proposal.ebayConditionId = String(detail.conditionId);
    if (detail.epid) proposal.epid = String(detail.epid);
    const specifics = usefulSpecifics(detail.aspects, { isBundle: proposal.isBundle });
    if (Object.keys(specifics).length) proposal.itemSpecifics = specifics;
  }

  // 4. photos — (a) comp photos
  const urls = [];
  if (proposal.isBundle && _componentQueries.length) {
    // One photo per component so the cover shows what's in the lot.
    const perComponent = await mapWithConcurrency(_componentQueries, 2, async (q) => {
      const list = await safeComps(q, deps);
      return pickBestComp(list, q);
    });
    for (const hit of perComponent) {
      const url = hit && fullSizeEbayImage(hit.imageUrl);
      if (url && !urls.includes(url)) urls.push(url);
    }
  }
  if (!urls.length && detail?.images?.length) {
    urls.push(...detail.images.slice(0, MAX_PHOTOS));
  }
  if (!urls.length && best?.imageUrl) {
    urls.push(fullSizeEbayImage(best.imageUrl));
  }
  if (urls.length) {
    proposal.imageUrls = urls.slice(0, MAX_PHOTOS);
    proposal.imageSource = "ebay";
  } else {
    // (b) Google
    const fromGoogle = deps.google ? await deps.google(_searchQuery) : [];
    if (fromGoogle.length) {
      proposal.imageUrls = fromGoogle.slice(0, MAX_PHOTOS);
      proposal.imageSource = "google";
    } else {
      // (c) nothing — the client asks before generating.
      proposal.imageUrls = [];
      proposal.imageSource = "none";
    }
  }

  return proposal;
}

async function buildDrafts({ text, maxItems }, deps) {
  const { context, proposals } = await deps.parse(text, maxItems);
  const drafts = await mapWithConcurrency(proposals, CONCURRENCY, (core) => enrichProposal(core, deps));
  return { context, drafts, aiModel: PARSE_MODEL, aiPromptVersion: PROMPT_VERSION };
}

exports.bulkDraftsFromText = onCall(
  { secrets: [GEMINI_API_KEY, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, GOOGLE_CSE_KEY, GOOGLE_CSE_CX], timeoutSeconds: 300, memory: "1GiB" },
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
      detail: retrieveCompDetail,
      google: (query) => googleImages(query, { key: process.env.GOOGLE_CSE_KEY, cx: process.env.GOOGLE_CSE_CX }),
    };
    return buildDrafts(data, deps);
  })
);

// Consent-gated: the client only calls this after the user has said, once,
// that AI-generated photos are acceptable for listings nothing else covered.
exports.generateListingPhoto = onCall(
  { secrets: [GEMINI_API_KEY], timeoutSeconds: 60, memory: "512MiB" },
  validated("generateListingPhoto", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) throw new HttpsError("failed-precondition", "AI is not configured.");

    let image;
    try {
      image = await generateProductImage(apiKey, data);
    } catch (e) {
      console.error(`[generateListingPhoto] failed for "${data.title}": ${e.message}`);
      throw new HttpsError("internal", e.message);
    }
    if (!image) return { url: null };
    return { url: await saveGeneratedImage(uid, image) };
  })
);

exports._internal = {
  toProposalCore,
  parseModelOutput,
  priceFromComps,
  median,
  pickBestComp,
  usefulSpecifics,
  googleImages,
  enrichProposal,
  buildDrafts,
  mapWithConcurrency,
  PARSE_SYSTEM_PROMPT,
};
