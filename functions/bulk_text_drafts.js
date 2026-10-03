/**
 * bulk_text_drafts.js — `bulkDraftsFromText` + `generateListingPhoto`
 *
 * Paste a list → one fully-filled draft proposal per listing. Four stages,
 * each independently testable (see `_internal`):
 *
 *   1. parse     — ONE gemini-flash-lite call splits ANY unstructured text
 *                  (list, paragraph, message, pasted table) into listings.
 *                  Group text ("wii games (CIB):") becomes shared context,
 *                  items sold together become ONE listing with `bundleItems`,
 *                  per-item notes stay attached to their item, and a price
 *                  the user wrote is captured as `userPrice`. `orderBySource`
 *                  then restores the input order if the model regrouped.
 *   2. comps     — per listing, live eBay Browse comps (ebay_comps.js).
 *                  Price precedence: the user's own price ("user", with the
 *                  comps/AI figure kept as `marketPrice`) > median asking
 *                  price ("comps") > the model's estimate ("ai").
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
const PROMPT_VERSION = "2026-10-03.1";

const COMPS_PER_QUERY = 12;
const MAX_PHOTOS = 4;
const MAX_SPECIFICS = 20;
const CONCURRENCY = 6;

const PARSE_SYSTEM_PROMPT = `You turn a reseller's notes about things they want to sell into marketplace listings (eBay, Mercari, Facebook Marketplace).

The input is ANY unstructured text: a tidy list, one long paragraph, a comma- or slash-separated run, a text message, a pasted spreadsheet or table, voice-dictated notes, or a mix. Do not rely on line breaks. Work out what the separate things for sale are from the meaning.

How to read it:
- Each distinct thing for sale is ONE listing. Items can be separated by new lines, commas, semicolons, "and", bullets, numbering, or sentences.
- Text that describes a group rather than an item ("wii games (CIB):", "all of these are tested", "everything below is PS2", a table header row, a sentence like "I have a bunch of sealed lego sets") is CONTEXT. It applies to every item it covers: platform/system, condition ("CIB" = complete in box, "loose", "sealed"), notes, and prices like "$10 each". Context is never a listing by itself.
- Items the text says are sold together ("bundle 1: a, b, c", "lot: a + b", "selling x and y together", "a with b and c included") are ONE listing: isBundle=true, bundleItems = each item. The title should name all the items ("Just Dance 4, 2015 & 2014 Wii Bundle (3 Games, CIB)"). Items merely mentioned in the same sentence are NOT a bundle unless the text says they sell together.
- Notes attached to one item (parentheses, "- missing manual", "the blue one has a scratch") affect only that item's condition/description.
- A count ("3x", "two copies of", "qty 4") is the quantity of one listing, not several listings.
- Ignore chatter that is not about an item for sale (greetings, questions, shipping remarks, signatures).
- Fix obvious typos and expand abbreviations in titles. Never invent items that are not in the text.
- ORDER: output listings in the order they first appear in the text, top to bottom. Never regroup, sort, or move bundles to the front.

Prices written by the user:
- If the text states an asking price for a listing ("$25", "25 bucks", "asking 40", "15 obo", a price column), put that number in "userPrice", in USD, for ONE unit of that listing. A bundle's stated price is the price of the whole bundle.
- A group price "each" ("$10 each", "all $5") applies to every listing it covers. A single total for several separate items that are not a bundle ("$50 for everything") is NOT a per-listing price: leave userPrice null.
- Numbers that are not asking prices (what they paid, retail/MSRP, model numbers, years, quantities) are NOT userPrice.
- No stated price: userPrice is null. Never guess userPrice.

For each listing produce:
- "sourceText": the snippet of the input it came from, copied character for character (the item's own words, not the surrounding context).
- "title": searchable marketplace title, <= 140 chars, includes platform/system and key condition note.
- "shortTitle": eBay title, AT MOST 80 characters.
- "bundleItems": array of item names (empty for a single item).
- "isBundle": boolean.
- "description": 3-6 factual buyer-facing sentences: what is included, system/platform, condition from the context + item notes. No price, shipping, returns or markdown.
- "brand": publisher/manufacturer/franchise owner, or "Unbranded".
- "category": hierarchical path hint like "Video Games & Consoles > Video Games".
- "condition": exactly one of "new", "likenew", "good", "fair", "poor". "CIB"/"complete" with no other note = "good". "sealed" = "new".
- "tags": up to 8 lowercase search tags.
- "searchQuery": a short eBay search string for comparable listings of the WHOLE listing (e.g. "Super Smash Bros Brawl Wii CIB"). For a bundle, a query for the bundle as a whole.
- "componentQueries": for a bundle, one short eBay search string per bundleItem (same order); empty array for single items.
- "userPrice": the user's stated asking price (number) or null, per the rules above.
- "suggestedPrice": your own estimated USD resale asking price for the whole listing (number), independent of userPrice.
- "quantity": 1 unless the text says otherwise.

Return ONLY JSON: {"context": "<one-line summary of the shared context, or empty>", "items": [ ... ]}.`;

// ── stage 1: parse ────────────────────────────────────────────────────────

function cleanJsonText(raw) {
  return String(raw).replace(/```json\s*/gi, "").replace(/```/g, "").trim();
}

/** A model-supplied price → positive number rounded to cents, else undefined.
 *  Tolerates "$25", "25.00 obo" and "1,200" since the model sometimes echoes
 *  the user's own formatting. */
function parsePrice(value) {
  const num = typeof value === "number"
    ? value
    : typeof value === "string" ? Number((value.replace(/,/g, "").match(/\d+(\.\d+)?/) || [])[0]) : NaN;
  return Number.isFinite(num) && num > 0 && num < 1e6 ? Math.round(num * 100) / 100 : undefined;
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
    _aiPrice: parsePrice(item.suggestedPrice),
    // A price the user wrote in the text. Always wins over comps / the estimate.
    _userPrice: parsePrice(item.userPrice),
  };
}

/** Lowercased, whitespace-collapsed — so a snippet still matches when the
 *  model normalised spacing or case while "copying" it. */
function squash(text) {
  return String(text || "").toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * Put proposals back in the order their source snippets appear in `text`.
 * The prompt already asks for input order; this is the guard for when the
 * model regroups anyway (it likes to float bundles to the top).
 *
 * Each proposal is located at the first occurrence of its `sourceText` that
 * starts at or after the previous proposal's match, so a repeated snippet
 * ("mario kart" twice) maps to successive occurrences when the model kept
 * order. If that forward scan can place everything, the model's order is
 * already right and is returned untouched. Otherwise proposals are sorted by
 * first occurrence; ones whose snippet can't be found (paraphrased) stay
 * right after the proposal they followed.
 */
function orderBySource(proposals, text) {
  const hay = squash(text);
  if (!hay || proposals.length < 2) return proposals;
  const needles = proposals.map((p) => squash(p.sourceText));

  let cursor = 0;
  let monotonic = true;
  for (const needle of needles) {
    if (!needle) continue;
    const at = hay.indexOf(needle, cursor);
    if (at >= 0) { cursor = at + 1; continue; }
    if (hay.indexOf(needle) >= 0) { monotonic = false; break; }
  }
  if (monotonic) return proposals;

  let last = -1;
  const keyed = proposals.map((p, i) => {
    const at = needles[i] ? hay.indexOf(needles[i]) : -1;
    if (at >= 0) last = at;
    return { p, i, pos: at >= 0 ? at : last };
  });
  keyed.sort((x, y) => x.pos - y.pos || x.i - y.i);
  return keyed.map((k) => k.p);
}

function parseModelOutput(raw, maxItems, text = "") {
  const json = JSON.parse(cleanJsonText(raw));
  const items = Array.isArray(json.items) ? json.items : [];
  // Order first, cap second, so a long list loses its tail, not random items.
  const proposals = orderBySource(items.map(toProposalCore).filter(Boolean), text).slice(0, maxItems);
  return { context: typeof json.context === "string" ? json.context.trim() : "", proposals };
}

async function parseListWithGemini(apiKey, text, maxItems) {
  const genAI = new GoogleGenerativeAI(apiKey);
  const model = genAI.getGenerativeModel({
    model: PARSE_MODEL,
    systemInstruction: PARSE_SYSTEM_PROMPT,
    generationConfig: { responseMimeType: "application/json", temperature: 0.2 },
  });
  const raw = (await model.generateContent(`Text from the seller:\n\n${text}`)).response.text();
  return parseModelOutput(raw, maxItems, text);
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
  const { _searchQuery, _componentQueries, _aiPrice, _userPrice, ...proposal } = core;

  // 2. price — the user's own price always wins; comps still run because the
  // sell-similar details and photos come from them, and the market figure is
  // returned alongside so the review list can show both.
  const comps = await safeComps(_searchQuery, deps);
  const compPrice = priceFromComps(comps);
  if (_userPrice) {
    proposal.suggestedPrice = _userPrice;
    proposal.priceSource = "user";
    const market = compPrice ?? _aiPrice;
    if (market) {
      proposal.marketPrice = market;
      proposal.marketPriceSource = compPrice != null ? "comps" : "ai";
    }
  } else if (compPrice != null) {
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
  parsePrice,
  orderBySource,
  parseModelOutput,
  parseListWithGemini,
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
