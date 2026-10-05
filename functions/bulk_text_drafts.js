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
 *                  Each listing also gets `included` — what physically comes
 *                  with it (complete / partial / loose / sealed / packaging /
 *                  unknown) — and `media` (disc / cartridge / other).
 *                  Invalid JSON from the model is retried once, then salvaged
 *                  item by item (`salvageItems`).
 *   2. comps     — per listing, live eBay Browse comps (ebay_comps.js).
 *                  Price precedence: the user's own price ("user", with the
 *                  comps/AI figure kept as `marketPrice`) > lowest comparable
 *                  asking price ("comps") > the model's estimate ("ai").
 *                  "Comparable" includes being in the same `included` state:
 *                  a boxed copy is never priced against loose cartridges.
 *                  The matching rules live in comp_match.js — read its header
 *                  first; README § "Drafts from a List" has the overview.
 *   3. similar   — the "sell similar" half: Browse `getItem` on the best-
 *                  matching comp gives its eBay category id, condition id,
 *                  ePID and item specifics, which ride on the proposal so the
 *                  eBay create path reuses them instead of guessing
 *                  (`product.ebayCategoryId`, `product.geminiItemSpecifics`).
 *   4. photos    — in priority order, agreed 2026-10-01:
 *                    (a) the photos of the best comp that is IN THE SAME
 *                        STATE as our listing (`choosePhotoComp`; bundles get
 *                        one photo per component). A "cartridge only" listing
 *                        never gets a boxed copy's photo — no match, no photo,
 *                    (b) Google Programmable Search image results, when the
 *                        GOOGLE_CSE_KEY / GOOGLE_CSE_CX secrets are set,
 *                    (c) nothing — the client draws a placeholder card (a disc
 *                        or cartridge shape for a loose disc / cartridge) and asks the
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
const { normalizeCondition, toListingFields } = require("./enrichment")._internal;
const { classifyIncluded, normalizeIncluded, matchLevel, descriptionConfirms } = require("./comp_match");

const GEMINI_API_KEY = "GEMINI_API_KEY";
const GOOGLE_CSE_KEY = "GOOGLE_CSE_KEY";
const GOOGLE_CSE_CX = "GOOGLE_CSE_CX";
const PARSE_MODEL = "gemini-flash-lite-latest";
const IMAGE_MODEL = "gemini-2.5-flash-image";
const PROMPT_VERSION = "2026-10-04.1";

// 25, not 12: the price is the LOWEST comparable listing, so a wider sample of
// eBay's best matches matters more than it did for a median.
// 50 is the most one Browse search returns that we read. A plain search mixes
// loose, boxed and sealed copies, so the wider net is what gives comp_match.js
// enough listings in the SAME state as ours to price and photograph from.
const COMPS_PER_QUERY = 50;
// Full-detail lookups allowed per listing while looking for a photo whose
// description confirms the same state (see comp_match.js).
const MAX_DETAIL_CHECKS = 3;
const MAX_PHOTOS = 4;
const MAX_SPECIFICS = 20;
const CONCURRENCY = 6;
// The parse is one call over the whole text. Measured 2026-10-03: 150 items →
// ~32k output tokens in ~75 s, so the model's 65k output ceiling is ~300 items.
// Past it the JSON is cut mid-item; `salvageItems` keeps the complete ones and
// `unparsedTail` hands the rest of the text back to the client.
const MAX_OUTPUT_TOKENS = 65536;
const MAX_PARSED_ITEMS = 400;

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
- "included": what the seller's text SAYS physically comes with the listing. Exactly one of:
  "complete" = the text says every original part is there ("CIB", "complete", "complete in box", "disc + manual + case", "with box and manual");
  "partial" = original case or box but the text says something is missing ("no manual");
  "loose" = the item alone ("cartridge only", "cart only", "disc only", "loose", "no box", "no case", a disc in a generic or replacement case);
  "sealed" = factory sealed / unopened / new in box;
  "packaging" = only a box, case or manual, not the item itself;
  "unknown" = the text does not say.
  Words from the group context count ("game boy stuff, cartridge only:" makes every item under it "loose"). Do NOT infer it from the kind of item or from the condition: an item with no such words is "unknown", and so is anything that never had a box worth mentioning (trading cards, clothing, most electronics).
- "media": "disc" for a disc-based game, movie or album, "cartridge" for a cartridge game, otherwise "other".
- "searchQuery": a short eBay search string that IDENTIFIES the item: name, platform/system, model or edition (e.g. "Super Smash Bros Brawl Wii"). Do NOT put what is included or the condition in it (no "CIB", "cartridge only", "sealed", "tested"): that goes in "included". For a bundle, a query for the bundle as a whole.
- "componentQueries": for a bundle, one short eBay search string per bundleItem (same order, same rule: identity only); empty array for single items.
- "userPrice": the user's stated asking price (number) or null, per the rules above.
- "suggestedPrice": your own estimated USD resale asking price for the whole listing (number), independent of userPrice.
- "quantity": 1 unless the text says otherwise.
- "weightOz": estimated shipping weight of the packed listing in ounces (number). For a bundle or quantity > 1 listing, ONE unit of the listing as it ships (the whole bundle).
- "lengthIn", "widthIn", "heightIn": estimated shipping box or mailer dimensions in inches (numbers).

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

/** weightOz / lengthIn / widthIn / heightIn via enrichListing's own normaliser. */
function shippingFields(item) {
  const { weightOz, lengthIn, widthIn, heightIn } = toListingFields({
    weightOz: item.weightOz, weightLbs: item.weightLbs,
    lengthIn: item.lengthIn, widthIn: item.widthIn, heightIn: item.heightIn,
  });
  return Object.fromEntries(Object.entries({ weightOz, lengthIn, widthIn, heightIn }).filter(([, v]) => v !== undefined));
}

/**
 * A parsed-but-not-yet-enriched core → the plain shape the client holds and
 * sends back in `pendingItems` for the next batch (contract `PendingItemSchema`).
 * It is deliberately the same shape the model emits, so `toProposalCore`
 * reads it back with no second code path.
 */
function toPendingItem(core) {
  const { _searchQuery, _componentQueries, _aiPrice, _userPrice, ...rest } = core;
  return {
    ...rest,
    searchQuery: _searchQuery,
    componentQueries: _componentQueries,
    ...(_aiPrice ? { suggestedPrice: _aiPrice } : {}),
    ...(_userPrice ? { userPrice: _userPrice } : {}),
  };
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
    // What physically comes with it (comp_match.js). The model reads it from
    // the text + shared context; when it gave nothing usable, the item's own
    // words are classified the same way a comp's title is.
    included: normalizeIncluded(item.included) !== "unknown"
      ? normalizeIncluded(item.included)
      : classifyIncluded(`${str(item.sourceText, 500)} ${title}`),
    // Drives the shape of the client's placeholder card when no photo matched.
    media: ["disc", "cartridge"].includes(item.media) ? item.media : "other",
    // Shipping estimates — same normalisation as the photo path (enrichListing),
    // so a list-made draft carries every field a photo-identified one does and
    // never needs a second AI pass.
    ...shippingFields(item),
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

/**
 * The usable item objects from a model response that is not valid JSON —
 * either cut off mid-item (output-token ceiling on a very long list) or
 * malformed in the middle (the model sometimes leaves a quote unescaped: one
 * bad character used to fail the whole list with "INTERNAL", seen live
 * 2026-10-05).
 *
 * Items are flat objects, so the array is split on the `}, {` between them and
 * each piece is parsed alone: one broken item cannot take its neighbours down
 * (a brace/quote counter can, because a stray quote flips its string state for
 * the rest of the text). `lost` = the `sourceText` of every piece that would
 * not parse, so the caller can hand those words back to the user.
 */
function salvageItems(raw) {
  const text = cleanJsonText(raw);
  const start = text.search(/"items"\s*:\s*\[/);
  if (start < 0) return { context: "", items: [], lost: [] };
  const contextMatch = /"context"\s*:\s*("(?:[^"\\]|\\.)*")/.exec(text);
  let context = "";
  try { context = contextMatch ? JSON.parse(contextMatch[1]) : ""; } catch { context = ""; }

  const body = text.slice(text.indexOf("[", start) + 1);
  const pieces = body.split(/\}\s*,\s*\{(?=\s*")/);
  const items = [];
  const lost = [];
  pieces.forEach((piece, i) => {
    let chunk = piece.trim();
    if (i > 0) chunk = `{${chunk}`;
    if (i < pieces.length - 1) chunk = `${chunk}}`;
    else chunk = chunk.replace(/\]\s*\}?\s*$/, "").trim(); // the array's and root object's own closers
    if (!chunk) return;
    try {
      const parsed = JSON.parse(chunk);
      if (parsed && typeof parsed === "object") items.push(parsed);
    } catch {
      const source = /"sourceText"\s*:\s*("(?:[^"\\]|\\.)*")/.exec(chunk);
      try { if (source) lost.push(JSON.parse(source[1])); } catch { /* nothing recoverable */ }
    }
  });
  return { context, items, lost };
}

/**
 * The part of `text` after the last proposal that could be located in it —
 * what a truncated parse never got to. Snippets are matched in order, case-
 * and whitespace-insensitively, each from where the previous one ended.
 * Returns "" when nothing can be located (better to hand back nothing than
 * to make the client re-list items it already has).
 */
function unparsedTail(text, proposals) {
  let cursor = 0;
  let found = false;
  for (const p of proposals) {
    const words = String(p.sourceText || "").trim().split(/\s+/).filter(Boolean);
    if (!words.length) continue;
    const pattern = new RegExp(words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\s+"), "i");
    const match = pattern.exec(text.slice(cursor));
    if (match) { cursor += match.index + match[0].length; found = true; }
  }
  return found ? text.slice(cursor).trim() : "";
}

/**
 * Model output → ordered proposal cores.
 *   truncated — the response hit the output ceiling: complete items are
 *               salvaged and `unparsedText` is the tail of the input they did
 *               not cover.
 *   malformed — the caller already retried and the JSON is still invalid:
 *               every item that parses alone is kept and `unparsedText` is
 *               the source words of the ones that did not.
 * With neither flag a JSON error is thrown, so the caller can retry.
 */
function parseModelOutput(raw, maxItems, text = "", { truncated = false, malformed = false } = {}) {
  let json;
  let lost = [];
  try {
    json = JSON.parse(cleanJsonText(raw));
  } catch (e) {
    if (!truncated && !malformed) throw e;
    json = salvageItems(raw);
    lost = json.lost || [];
    if (!json.items.length) throw e;
  }
  const items = Array.isArray(json.items) ? json.items : [];
  // Order first, cap second, so a long list loses its tail, not random items.
  const proposals = orderBySource(items.map(toProposalCore).filter(Boolean), text).slice(0, maxItems);
  const unparsed = truncated ? unparsedTail(text, proposals) : lost.join("\n");
  return {
    context: typeof json.context === "string" ? json.context.trim() : "",
    proposals,
    unparsedText: unparsed,
  };
}

/** `context` = shared context carried over from an earlier part of the same
 *  text, when the client is continuing after a truncated parse. */
async function parseListWithGemini(apiKey, text, maxItems, context = "", { generate } = {}) {
  const carried = context ? `Context that applies to this text (from earlier in the same notes): ${context}\n\n` : "";
  const prompt = `${carried}Text from the seller:\n\n${text}`;
  // `generate` is injectable for tests: (prompt, attempt) → { raw, truncated }.
  const ask = generate || (async (input, attempt) => {
    const model = new GoogleGenerativeAI(apiKey).getGenerativeModel({
      model: PARSE_MODEL,
      systemInstruction: PARSE_SYSTEM_PROMPT,
      // A retry runs slightly warmer so it does not repeat the same bad output.
      generationConfig: { responseMimeType: "application/json", temperature: attempt ? 0.4 : 0.2, maxOutputTokens: MAX_OUTPUT_TOKENS },
    });
    const response = (await model.generateContent(input)).response;
    return { raw: response.text(), truncated: response.candidates?.[0]?.finishReason === "MAX_TOKENS" };
  });

  // Invalid JSON that was NOT cut off is the model's own slip: ask once more,
  // and if the second answer is bad too, keep every item that parses alone.
  let parsed;
  for (let attempt = 0; attempt < 2 && !parsed; attempt++) {
    const { raw, truncated } = await ask(prompt, attempt);
    try {
      parsed = parseModelOutput(raw, maxItems, text, { truncated, malformed: attempt === 1 });
    } catch (e) {
      if (attempt === 1) throw e;
      console.warn(`[bulkDraftsFromText] model returned invalid JSON, retrying: ${e.message}`);
    }
  }
  return { ...parsed, context: parsed.context || context };
}

// ── stage 2: price ────────────────────────────────────────────────────────

function median(values) {
  const nums = values.filter((n) => Number.isFinite(n) && n > 0).sort((a, b) => a - b);
  if (!nums.length) return null;
  const mid = Math.floor(nums.length / 2);
  return nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
}

const COMPARABLE_MATCH = 0.8;   // share of the query's words a comp title must contain
const OUTLIER_FLOOR = 0.5;      // a "lowest" under half the comparable median is noise

/**
 * Comps that are the same thing as our listing, in the same state:
 *   - enough shared title words, and every model / set number in the query;
 *   - not a different item (repro, graded, for parts…) and not in a state
 *     that contradicts ours — `matchLevel` in comp_match.js;
 *   - when our state is unknown, a comp that says it is loose, partial or
 *     packaging is dropped too (the long-standing rule: an unqualified listing
 *     is not priced against "disc only").
 * When our state is known, only comps that explicitly state the SAME state
 * are returned: a boxed copy is priced against boxed copies, not against
 * silent titles that are mostly loose cartridges.
 */
function comparableComps(comps, query, included = "unknown") {
  const want = tokens(query);
  const need = Math.max(1, Math.ceil(want.size * COMPARABLE_MATCH));
  const ours = normalizeIncluded(included);
  // Model / set / edition numbers identify the item outright: LEGO 75192 is not
  // 75105, Just Dance 2015 is not 2014. Every one in the query must be present.
  const mustHave = [...want].filter((t) => t.length >= 3 && /\d/.test(t));
  const kept = [];
  for (const comp of comps) {
    if (!(Number.isFinite(comp.price) && comp.price > 0)) continue;
    const level = matchLevel(ours, comp, query);
    if (level === 0) continue;
    if (ours === "unknown" && ["loose", "partial"].includes(classifyIncluded(comp.title))) continue;
    const have = tokens(comp.title);
    if (mustHave.some((t) => !have.has(t))) continue;
    let shared = 0;
    for (const t of want) if (have.has(t)) shared++;
    if (shared >= need) kept.push({ comp, level });
  }
  // We know our state: only comps that explicitly share it set the price. A
  // silent title is usually the cheapest form of the item, which would price
  // a sealed or boxed copy like a loose one (seen live: sealed Zelda at $14.99).
  if (ours !== "unknown") return kept.filter((k) => k.level === 2).map((k) => k.comp);
  return kept.map((k) => k.comp);
}

/**
 * The lowest asking price among comparable live eBay listings, to the cent —
 * the draft is priced to MATCH the cheapest real competitor (user decision
 * 2026-10-03; it used to be the median). "Comparable" is what keeps that from
 * being a disc-only or for-parts listing: see `comparableComps`. A price
 * under half the comparable median is treated as an outlier and skipped.
 * When no comp is comparable enough, falls back to the lowest non-outlier
 * price of everything eBay returned. Item price only — shipping is not added.
 */
function priceFromComps(comps, query = "", included = "unknown") {
  const priced = comps.filter((c) => Number.isFinite(c.price) && c.price > 0);
  if (!priced.length) return null;
  const comparable = comparableComps(priced, query, included);
  // Nothing close enough in wording: any comp that is at least not a different
  // item / contradicting state, and only then everything eBay returned.
  // ...but never when we know our state and no comp shares it: the caller
  // falls back to the model's estimate, which does know the state.
  if (!comparable.length && normalizeIncluded(included) !== "unknown") return null;
  const usable = priced.filter((c) => matchLevel(included, c, query) > 0);
  const pool = comparable.length ? comparable : usable.length ? usable : priced;
  const floor = median(pool.map((c) => c.price)) * OUTLIER_FLOOR;
  const lowest = Math.min(...pool.map((c) => c.price).filter((price) => price >= floor));
  return Math.round(lowest * 100) / 100;
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

/**
 * Photo candidates for a listing, best first: comps with a photo that
 * comp_match.js does not rule out, explicit same-state matches (level 2)
 * ahead of unverified ones (level 1), then by shared title words, then eBay's
 * own order. Each entry is `{ comp, level }`.
 */
function rankPhotoComps(comps, query, included = "unknown") {
  const want = tokens(query);
  return comps
    .map((comp, index) => {
      if (!comp.imageUrl) return null;
      const level = matchLevel(included, comp, query);
      if (level === 0) return null;
      const have = tokens(comp.title);
      let score = 0;
      for (const t of want) if (have.has(t)) score++;
      return { comp, level, score, index };
    })
    .filter(Boolean)
    .sort((a, b) => b.level - a.level || b.score - a.score || a.index - b.index)
    .map(({ comp, level }) => ({ comp, level }));
}

/**
 * The comp whose photos the draft may use, plus the details fetched on the
 * way. See comp_match.js for the rule; in short:
 *   - our listing does not say what is included → the best-ranked candidate;
 *   - it does → the first candidate that is explicitly in the same state, by
 *     title / short description (level 2) or by its full description (a
 *     level-1 candidate whose detail text confirms it). At most
 *     MAX_DETAIL_CHECKS detail lookups; none confirmed → `photoComp: null`
 *     and the draft gets a placeholder rather than a wrong photo.
 * `detail` is the photo comp's detail when there is one, else the first one
 * fetched — still good for category / specifics ("sell similar"), which do
 * not depend on what is in the box.
 */
async function choosePhotoComp(comps, query, included, deps) {
  const ours = normalizeIncluded(included);
  const candidates = rankPhotoComps(comps, query, ours).slice(0, MAX_DETAIL_CHECKS);
  let firstDetail = null;
  for (const { comp, level } of candidates) {
    const detail = await safeDetail(comp.itemId, deps);
    firstDetail = firstDetail || detail;
    if (ours === "unknown" || level === 2) return { photoComp: comp, detail, photoDetail: detail };
    const text = detail ? `${detail.title || ""} ${detail.shortDescription || ""} ${detail.description || ""}` : "";
    if (descriptionConfirms(ours, text) === true) return { photoComp: comp, detail, photoDetail: detail };
  }
  return { photoComp: null, detail: firstDetail, photoDetail: null };
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
  // What comes with the listing; "unknown" when an older client's pending
  // item carries none. Every comp decision below goes through it.
  const included = normalizeIncluded(proposal.included);

  // 2. price — the user's own price always wins; comps still run because the
  // sell-similar details and photos come from them, and the market figure is
  // returned alongside so the review list can show both.
  const comps = await safeComps(_searchQuery, deps);
  const compPrice = priceFromComps(comps, _searchQuery, included);
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

  // 3. sell similar — category / condition / specifics from a comp. The same
  // lookup decides whose photos may be used (state must match: comp_match.js).
  const picked = await choosePhotoComp(comps, _searchQuery, included, deps);
  const { photoComp, photoDetail } = picked;
  // Nothing usable as a photo source (every comp ruled out): details can still
  // come from the closest title, as before.
  const fallback = picked.detail ? null : pickBestComp(comps, _searchQuery);
  const detail = picked.detail || (fallback ? await safeDetail(fallback.itemId, deps) : null);
  if (detail) {
    proposal.similarItemId = detail.itemId;
    if (detail.categoryId) proposal.ebayCategoryId = String(detail.categoryId);
    if (detail.conditionId) proposal.ebayConditionId = String(detail.conditionId);
    if (detail.epid) proposal.epid = String(detail.epid);
    const specifics = usefulSpecifics(detail.aspects, { isBundle: proposal.isBundle });
    if (Object.keys(specifics).length) proposal.itemSpecifics = specifics;
  }

  // 4. photos — (a) comp photos, only from comps in the same state as ours
  const urls = [];
  if (proposal.isBundle && _componentQueries.length) {
    // One photo per component so the cover shows what's in the lot. No detail
    // lookups here: when our state is known a component needs an explicit
    // (level 2) match, otherwise the best-ranked candidate.
    const perComponent = await mapWithConcurrency(_componentQueries, 2, async (q) => {
      const top = rankPhotoComps(await safeComps(q, deps), q, included)[0];
      return top && (included === "unknown" || top.level === 2) ? top.comp : null;
    });
    for (const hit of perComponent) {
      const url = hit && fullSizeEbayImage(hit.imageUrl);
      if (url && !urls.includes(url)) urls.push(url);
    }
  }
  if (!urls.length && photoDetail?.images?.length) {
    urls.push(...photoDetail.images.slice(0, MAX_PHOTOS));
  }
  if (!urls.length && photoComp?.imageUrl) {
    urls.push(fullSizeEbayImage(photoComp.imageUrl));
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

/**
 * One batch. Two entry modes, one enrichment path:
 *   { text }  — parse the WHOLE text (cheap), enrich the first `maxItems`
 *               listings (comps + details + photos are the expensive part),
 *               and return the rest un-enriched in `remaining`.
 *   { pendingItems } — enrich listings a previous call returned in `remaining`.
 *               No model call; order and wording stay exactly as first parsed.
 * The client loops until `remaining` is empty, so a long list is never cut
 * off at the batch size (it used to silently drop everything past 40).
 */
async function buildDrafts({ text, pendingItems: items, context: carriedContext = "", maxItems }, deps) {
  let context = carriedContext;
  let cores;
  let unparsedText = "";
  if (Array.isArray(items) && items.length) {
    cores = items.map(toProposalCore).filter(Boolean);
  } else {
    const parsed = await deps.parse(text, MAX_PARSED_ITEMS, carriedContext);
    context = parsed.context;
    cores = parsed.proposals;
    unparsedText = parsed.unparsedText || "";
  }
  const batch = cores.slice(0, maxItems);
  const drafts = await mapWithConcurrency(batch, CONCURRENCY, (core) => enrichProposal(core, deps));
  return {
    context,
    drafts,
    remaining: cores.slice(maxItems).map(toPendingItem),
    unparsedText,
    aiModel: PARSE_MODEL,
    aiPromptVersion: PROMPT_VERSION,
  };
}

exports.bulkDraftsFromText = onCall(
  { secrets: [GEMINI_API_KEY, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, GOOGLE_CSE_KEY, GOOGLE_CSE_CX], timeoutSeconds: 540, memory: "1GiB" },
  validated("bulkDraftsFromText", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) throw new HttpsError("failed-precondition", "AI is not configured.");

    const deps = {
      parse: async (text, maxItems, context) => {
        try {
          return await parseListWithGemini(apiKey, text, maxItems, context);
        } catch (e) {
          console.error(`[bulkDraftsFromText] parse failed: ${e.message}`);
          // "unavailable", not "internal": the client shows an internal
          // error's message as the bare word "INTERNAL".
          throw new HttpsError("unavailable", "The AI could not read that list. Please try again.");
        }
      },
      comps: retrieveComps,
      detail: retrieveCompDetail,
      google: (query) => googleImages(query, { key: process.env.GOOGLE_CSE_KEY, cx: process.env.GOOGLE_CSE_CX }),
    };
    if (!data.text && !(data.pendingItems && data.pendingItems.length)) {
      throw new HttpsError("invalid-argument", "Provide text or pendingItems.");
    }
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
  salvageItems,
  unparsedTail,
  toPendingItem,
  parseListWithGemini,
  priceFromComps,
  comparableComps,
  median,
  pickBestComp,
  rankPhotoComps,
  choosePhotoComp,
  usefulSpecifics,
  googleImages,
  enrichProposal,
  buildDrafts,
  mapWithConcurrency,
  PARSE_SYSTEM_PROMPT,
};
