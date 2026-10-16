/**
 * ebay_photos.js — "find eBay photos" for a listing, shared by every client.
 *
 * One eBay Browse search → every result with a photo, ranked so the first
 * strong match is a safe automatic pick and nothing is hidden (user decision
 * 2026-10-14: the right listing is often deep in the long tail, so the chooser
 * shows all of them with chips saying what each one is). Used by
 *
 *   - text_to_listings / bulk_text_drafts.js  — the automatic photo pick and
 *     the `photoCandidates` that ride on every proposal;
 *   - the `draftPhotoCandidates` / `draftPhotoCandidateDetail` callables — the
 *     iOS chooser's re-search and Import;
 *   - the web chooser (same callables).
 *
 * Only the ranking and the "what to copy from a chosen listing" rules live
 * here. How the candidates are presented is each client's business.
 * Matching rules (`matchLevel`, included state, "different item" markers) are
 * in comp_match.js — read its header first.
 */

"use strict";

const { retrieveComps, retrieveCompDetail, fullSizeEbayImage } = require("./ebay_comps")._internal;
const { normalizeIncluded, compIncluded, differentItemMarkers, matchLevel } = require("./comp_match");

// 50 is the most one Browse search returns that we read. A plain search mixes
// loose, boxed and sealed copies, so the wider net is what gives comp_match.js
// enough listings in the SAME state as ours to price and photograph from.
const COMPS_PER_QUERY = 50;
// A listing the user chose by hand in the photo chooser brings its whole
// photo set (eBay allows 24; Mercari takes 12).
const MAX_IMPORT_PHOTOS = 12;
const MAX_SPECIFICS = 20;
const COMPARABLE_MATCH = 0.8;   // share of the query's words a comp title must contain

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

/**
 * Does a comp's title name the same item as the query? Enough shared words
 * (COMPARABLE_MATCH of the query's), and every model / set / edition number
 * in the query — LEGO 75192 is not 75105, Just Dance 2015 is not 2014.
 */
function titleMatches(query, title) {
  const want = tokens(query);
  const need = Math.max(1, Math.ceil(want.size * COMPARABLE_MATCH));
  const mustHave = [...want].filter((t) => t.length >= 3 && /\d/.test(t));
  const have = tokens(title);
  if (mustHave.some((t) => !have.has(t))) return false;
  let shared = 0;
  for (const t of want) if (have.has(t)) shared++;
  return shared >= need;
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
 * Would this comp's photo be a safe automatic pick? The same item (close
 * title) in the same state — explicitly (level 2), or, when our listing does
 * not say what is included, at least not contradicted (level 1).
 */
function candidateIsStrong(comp, query, included = "unknown") {
  const ours = normalizeIncluded(included);
  const level = matchLevel(ours, comp, query);
  const sameState = ours === "unknown" ? level >= 1 : level === 2;
  return sameState && titleMatches(query, comp.title);
}

/**
 * Every searched listing with a photo, for the photo chooser (contract
 * `PhotoCandidateSchema`): strong matches first, then the rest by state
 * match, shared title words and eBay's own order. Nothing is dropped — not
 * even contradictions or reproductions — because the user picks by eye and
 * the chips say what each one is.
 */
function photoCandidates(comps, query, included = "unknown") {
  const ours = normalizeIncluded(included);
  const want = tokens(query);
  return comps
    .map((comp, index) => {
      if (!comp.imageUrl || !comp.itemId) return null;
      const have = tokens(comp.title);
      let score = 0;
      for (const t of want) if (have.has(t)) score++;
      return {
        candidate: {
          itemId: String(comp.itemId),
          title: comp.title || "",
          price: Number.isFinite(comp.price) ? comp.price : null,
          imageUrl: fullSizeEbayImage(comp.imageUrl),
          itemWebUrl: comp.itemWebUrl ?? null,
          included: compIncluded(comp),
          markers: differentItemMarkers(`${comp.title || ""} ${comp.shortDescription || ""}`, query),
          strong: candidateIsStrong(comp, query, ours),
        },
        level: matchLevel(ours, comp, query),
        score,
        index,
      };
    })
    .filter(Boolean)
    .sort((a, b) => (b.candidate.strong - a.candidate.strong) || (b.level - a.level) || (b.score - a.score) || (a.index - b.index))
    .map((entry) => entry.candidate);
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

/** A chosen listing's detail → what the client imports onto the draft
 *  (contract `DraftPhotoCandidateDetailResponseSchema`). */
function candidateDetail(detail, { isBundle = false } = {}) {
  const out = {
    title: detail.title || "",
    imageUrls: (detail.images || []).slice(0, MAX_IMPORT_PHOTOS),
  };
  if (detail.categoryId) out.ebayCategoryId = String(detail.categoryId);
  if (detail.conditionId) out.ebayConditionId = String(detail.conditionId);
  if (detail.epid) out.epid = String(detail.epid);
  const specifics = usefulSpecifics(detail.aspects, { isBundle });
  if (Object.keys(specifics).length) out.itemSpecifics = specifics;
  return out;
}

/**
 * The shared entry point: search eBay for `query` and return the ranked
 * candidates. `comps` may be injected (tests, or a caller that already
 * searched). Never throws — an eBay failure is an empty list, logged.
 */
async function findEbayPhotos({ query, included = "unknown", comps = null, search = retrieveComps }) {
  if (!query) return [];
  let results = comps;
  if (!results) {
    try {
      results = await search({ title: query, limit: COMPS_PER_QUERY });
    } catch (e) {
      console.warn(`[findEbayPhotos] search failed for "${query}": ${e.message}`);
      return [];
    }
  }
  return photoCandidates(results, query, included);
}

/** The one `getItem` per import: a chosen listing's photos + sell-similar details. */
async function ebayPhotoDetail(itemId, { isBundle = false, detail = retrieveCompDetail } = {}) {
  return candidateDetail(await detail(itemId), { isBundle });
}

module.exports = {
  COMPS_PER_QUERY,
  MAX_IMPORT_PHOTOS,
  MAX_SPECIFICS,
  tokens,
  titleMatches,
  pickBestComp,
  rankPhotoComps,
  candidateIsStrong,
  photoCandidates,
  usefulSpecifics,
  candidateDetail,
  findEbayPhotos,
  ebayPhotoDetail,
};
