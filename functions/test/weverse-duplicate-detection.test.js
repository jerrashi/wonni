/**
 * weverse-duplicate-detection.test.js — the fuzzy repost/duplicate layer
 * that sits on top of the existing exact `weverseSaleId` dedup check.
 * Pure function, no Firestore involved.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const {
  findPossibleDuplicates,
  jaccardSimilarity,
  normalizeTitleTokens,
  SIMILARITY_THRESHOLD,
} = require("../weverse_duplicate_detection");

test("findPossibleDuplicates: flags a near-identical title from the same artist", () => {
  const candidate = { title: "[Weverse Shop] RM Photocard Set", artistName: "RM", weverseSaleId: "999" };
  const existingProducts = [
    { id: "p1", title: "RM Photocard Set", artistName: "RM", weverseSaleId: "111" },
  ];

  const matches = findPossibleDuplicates(candidate, existingProducts);
  assert.equal(matches.length, 1);
  assert.equal(matches[0].productId, "p1");
  assert.ok(matches[0].score >= SIMILARITY_THRESHOLD);
  assert.match(matches[0].reason, /RM/);
});

test("findPossibleDuplicates: different artist is never flagged, even with an identical title", () => {
  const candidate = { title: "Photocard Set", artistName: "RM", weverseSaleId: "999" };
  const existingProducts = [
    { id: "p1", title: "Photocard Set", artistName: "Jungkook", weverseSaleId: "111" },
  ];

  assert.deepEqual(findPossibleDuplicates(candidate, existingProducts), []);
});

test("findPossibleDuplicates: same artist but wildly different title is not flagged", () => {
  const candidate = { title: "RM Jersey Set", artistName: "RM", weverseSaleId: "999" };
  const existingProducts = [
    { id: "p1", title: "Winter Season's Greetings DVD Box", artistName: "RM", weverseSaleId: "111" },
  ];

  assert.deepEqual(findPossibleDuplicates(candidate, existingProducts), []);
});

test("findPossibleDuplicates: domestic/international variant pair — deliberately flagged as a candidate", () => {
  // Same base product split into two saleIds; differs by one token out of
  // four. This is a documented, deliberate behavior (see the threshold
  // comment in weverse_duplicate_detection.js): since a match is purely
  // informational and never blocks/merges, we'd rather over-flag this case
  // than silently hide a likely repost.
  const candidate = { title: "RM Jersey Set (International)", artistName: "RM", weverseSaleId: "999" };
  const existingProducts = [
    { id: "p1", title: "RM Jersey Set (Domestic)", artistName: "RM", weverseSaleId: "111" },
  ];

  const matches = findPossibleDuplicates(candidate, existingProducts);
  assert.equal(matches.length, 1);
  assert.equal(matches[0].productId, "p1");
  assert.ok(matches[0].score >= SIMILARITY_THRESHOLD, `expected score >= ${SIMILARITY_THRESHOLD}, got ${matches[0].score}`);
});

test("findPossibleDuplicates: no existing products returns an empty array", () => {
  const candidate = { title: "RM Jersey Set", artistName: "RM", weverseSaleId: "999" };
  assert.deepEqual(findPossibleDuplicates(candidate, []), []);
});

test("findPossibleDuplicates: the candidate's own saleId is never matched against itself", () => {
  const candidate = { title: "RM Jersey Set", artistName: "RM", weverseSaleId: "111" };
  const existingProducts = [
    { id: "p1", title: "RM Jersey Set", artistName: "RM", weverseSaleId: "111" },
  ];
  assert.deepEqual(findPossibleDuplicates(candidate, existingProducts), []);
});

test("findPossibleDuplicates: artist match is case/whitespace insensitive", () => {
  const candidate = { title: "RM Jersey Set", artistName: "  rm  ", weverseSaleId: "999" };
  const existingProducts = [
    { id: "p1", title: "RM Jersey Set", artistName: "RM", weverseSaleId: "111" },
  ];
  assert.equal(findPossibleDuplicates(candidate, existingProducts).length, 1);
});

test("findPossibleDuplicates: results are sorted by score, highest first", () => {
  const candidate = { title: "RM Photocard Set A B C", artistName: "RM", weverseSaleId: "999" };
  const existingProducts = [
    { id: "weak", title: "RM Photocard Set X Y Z", artistName: "RM", weverseSaleId: "111" },
    { id: "strong", title: "RM Photocard Set A B", artistName: "RM", weverseSaleId: "112" },
  ];
  const matches = findPossibleDuplicates(candidate, existingProducts);
  assert.ok(matches.length >= 1);
  assert.equal(matches[0].productId, "strong");
});

// ── normalizeTitleTokens / jaccardSimilarity (the building blocks) ─────────

test("normalizeTitleTokens: strips noise words, brackets and punctuation", () => {
  const tokens = normalizeTitleTokens("[Weverse Shop] RM Jersey Set (Domestic)!");
  assert.deepEqual(tokens, ["rm", "jersey", "domestic"]);
});

test("normalizeTitleTokens: empty/nullish input returns an empty array", () => {
  assert.deepEqual(normalizeTitleTokens(""), []);
  assert.deepEqual(normalizeTitleTokens(null), []);
  assert.deepEqual(normalizeTitleTokens(undefined), []);
});

test("jaccardSimilarity: identical token sets score 1, disjoint sets score 0", () => {
  assert.equal(jaccardSimilarity(["a", "b"], ["a", "b"]), 1);
  assert.equal(jaccardSimilarity(["a", "b"], ["c", "d"]), 0);
  assert.equal(jaccardSimilarity([], []), 0);
});
