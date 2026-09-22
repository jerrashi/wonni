// weverse_duplicate_detection.js
//
// Fuzzy repost/duplicate detection for Weverse imports.
//
// This is a SECOND layer on top of the existing exact `weverseSaleId` dedup
// check in weverse_product.js / weverse_bulk_import.js. Artists frequently
// repost the same item, or split what's functionally one product into
// separate domestic/international (or member-specific) sale listings, each
// with its own saleId — those slip right past an exact-id match.
//
// This module ONLY flags candidates for human review. It never blocks an
// import and never auto-merges anything: title/domestic-vs-international
// variants are sometimes genuinely different SKUs, so silently merging or
// rejecting on a fuzzy signal would be wrong. Callers should write the
// result (if any) onto the new product doc (e.g. `possibleDuplicateOf`) and
// leave surfacing it to a future UI.
//
// Deliberate scope cut: this pass is title + artist only, no image hashing.
// Comparing product photos (perceptual hashing, etc.) would catch reposts
// with a reworded title, but that's real additional infrastructure — left
// for a future enhancement, not an oversight.
//
// Pure functions only — no Firestore/network access, so this is fully
// unit-testable with plain JS objects in/out.

"use strict";

// Similarity metric: Jaccard index over normalized word-token sets.
// Chosen over edit-distance (Levenshtein) because Weverse titles are short,
// word-oriented phrases (e.g. "RM Photocard Set Domestic") rather than
// free-form prose — token overlap tracks "same product, reworded/reordered"
// much better than character-level distance, and it's trivial to implement
// with no dependencies.
//
// Threshold: titles need to share at least HALF their (noise-stripped)
// tokens to be flagged. This is intentionally on the permissive side: since
// a match is purely informational (never blocking, never auto-merging), a
// false positive just costs the user one extra glance at a review hint,
// while a false negative silently hides a real repost. In particular this
// threshold is chosen so that a same-artist domestic/international variant
// pair (which differs by roughly one token out of four-to-six) DOES clear
// the bar and gets flagged — see the dedicated test for that case.
const SIMILARITY_THRESHOLD = 0.5;

// Words that show up constantly in Weverse Shop titles but carry no
// distinguishing product information (see mapSaleToProduct in
// weverse_product.js for the shape of real titles, e.g.
// "[Weverse Shop] RM Jersey Set (Domestic)"). Stripping these keeps the
// token overlap focused on the actual product identity.
const NOISE_WORDS = new Set([
  "weverse",
  "shop",
  "official",
  "md",
  "goods",
  "set",
  "package",
  "ver",
  "version",
  "edition",
  "the",
  "a",
  "an",
  "of",
  "and",
]);

/**
 * Lowercase, strip punctuation/brackets, split on whitespace, drop noise
 * words and empty tokens. Keeps Latin letters/digits and Hangul so K-pop
 * member names / Korean titles still tokenize sensibly.
 */
function normalizeTitleTokens(title) {
  const cleaned = (title ?? "")
    .toLowerCase()
    .replace(/[[\](){}]/g, " ")
    .replace(/[^a-z0-9가-힣\s]/g, " ");

  return cleaned
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean)
    .filter((t) => !NOISE_WORDS.has(t));
}

/** Case/whitespace-insensitive artist name key for grouping. */
function normalizeArtistName(name) {
  return (name ?? "").trim().toLowerCase();
}

/** Jaccard similarity of two token arrays: |intersection| / |union|, in [0, 1]. */
function jaccardSimilarity(tokensA, tokensB) {
  const setA = new Set(tokensA);
  const setB = new Set(tokensB);
  if (setA.size === 0 && setB.size === 0) return 0;

  let intersectionSize = 0;
  for (const token of setA) {
    if (setB.has(token)) intersectionSize++;
  }
  const unionSize = setA.size + setB.size - intersectionSize;
  return unionSize === 0 ? 0 : intersectionSize / unionSize;
}

/**
 * Find existing weverse-sourced products that look like they might be the
 * same underlying item as `candidate` (repost, or a domestic/international
 * split listing) — flagged for review, never auto-merged or blocked.
 *
 * @param {{ title: string, artistName: string, weverseSaleId: string }} candidate
 *   The item currently being imported.
 * @param {Array<{ id: string, title: string, artistName: string, weverseSaleId: string }>} existingProducts
 *   The user's existing weverse-sourced products (source === "weverse"),
 *   excluding the candidate's own saleId.
 * @returns {Array<{ productId: string, score: number, reason: string }>}
 *   Possible duplicates, highest score first. Empty when none are found.
 */
function findPossibleDuplicates(candidate, existingProducts) {
  if (!candidate || !Array.isArray(existingProducts) || existingProducts.length === 0) {
    return [];
  }

  const candidateArtist = normalizeArtistName(candidate.artistName);
  const candidateTokens = normalizeTitleTokens(candidate.title);
  if (!candidateArtist || candidateTokens.length === 0) return [];

  const matches = [];

  for (const existing of existingProducts) {
    if (!existing || !existing.id) continue;
    // Never compare an item against itself.
    if (candidate.weverseSaleId && existing.weverseSaleId === candidate.weverseSaleId) continue;
    if (normalizeArtistName(existing.artistName) !== candidateArtist) continue;

    const existingTokens = normalizeTitleTokens(existing.title);
    if (existingTokens.length === 0) continue;

    const score = jaccardSimilarity(candidateTokens, existingTokens);
    if (score >= SIMILARITY_THRESHOLD) {
      matches.push({
        productId: existing.id,
        score: Math.round(score * 100) / 100,
        reason: `Same artist ("${candidate.artistName}") and similar title (${Math.round(score * 100)}% word overlap).`,
      });
    }
  }

  matches.sort((a, b) => b.score - a.score);
  return matches;
}

module.exports = {
  findPossibleDuplicates,
  jaccardSimilarity,
  normalizeTitleTokens,
  normalizeArtistName,
  SIMILARITY_THRESHOLD,
};
