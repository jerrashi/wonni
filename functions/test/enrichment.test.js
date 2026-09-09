/**
 * enrichment.test.js — the pure mapping layer of `enrichListing`.
 * The Gemini call + Firestore path need an emulator / manual smoke.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal } = require("../enrichment");
const { RequestSchemas } = require("../contracts");

const { normalizeCondition, toListingFields, writesToContract, toInlineData } = _internal;

// ── normalizeCondition ─────────────────────────────────────────────────────

test("normalizeCondition: iOS 7-value + keywords → canonical 5", () => {
  assert.equal(normalizeCondition("newWithoutTags"), "new");
  assert.equal(normalizeCondition("sealed"), "new");
  assert.equal(normalizeCondition("like new"), "likenew");
  assert.equal(normalizeCondition("mint"), "likenew");
  assert.equal(normalizeCondition("used"), "good");
  assert.equal(normalizeCondition("forParts"), "poor");
  assert.equal(normalizeCondition("nonsense"), undefined);
  assert.equal(normalizeCondition(null), undefined);
});

// ── toListingFields ────────────────────────────────────────────────────────

test("toListingFields: name→title, shortTitle derived, lbs→oz, dims, clamps", () => {
  const f = toListingFields({
    name: "N".repeat(200),
    description: "A real description.",
    brand: "BTS",
    category: "Collectibles > K-pop > Photocards",
    condition: "likeNew",
    suggestedPrice: 12.999,
    weightLbs: 0.5,
    lengthIn: 4.44, widthIn: 3, heightIn: 0.2,
    tags: ["A", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
    itemSpecifics: { Type: "Photo Card", Member: "  Jungkook  ", Junk: "" },
    confidence: 1.7,
  });
  assert.equal(f.title.length, 140);
  assert.equal(f.shortTitle.length, 80, "derived from title when the model omits it");
  assert.equal(f.condition, "likenew");
  assert.equal(f.suggestedPrice, 13);
  assert.equal(f.weightOz, 8, "0.5 lb → 8 oz");
  assert.equal(f.lengthIn, 4.4);
  assert.equal(f.tags.length, 8);
  assert.deepEqual(f.itemSpecifics, { Type: "Photo Card", Member: "Jungkook" });
  assert.equal(f.confidence, 1, "clamped to [0,1]");
});

test("toListingFields: keeps an explicit shortTitle, drops undefined keys", () => {
  const f = toListingFields({ name: "Long name here", shortTitle: "Short One" });
  assert.equal(f.shortTitle, "Short One");
  assert.ok(!("description" in f));
  assert.ok(!("weightOz" in f));
});

test("toListingFields: prefers weightOz when the model gives it directly", () => {
  assert.equal(toListingFields({ weightOz: 6 }).weightOz, 6);
});

// ── writesToContract ───────────────────────────────────────────────────────

test("writesToContract: renames gemini* doc keys, drops mercariCondition", () => {
  assert.deepEqual(
    writesToContract({
      description: "d", brand: "b", condition: "good", mercariCondition: "good",
      tags: ["x"], geminiCategory: "A > B", geminiItemSpecifics: { K: "V" },
    }),
    { description: "d", brand: "b", condition: "good", tags: ["x"], category: "A > B", itemSpecifics: { K: "V" } },
  );
  assert.deepEqual(writesToContract({}), {});
});

// ── toInlineData ───────────────────────────────────────────────────────────

test("toInlineData: parses a data: URI and passes raw base64 through", async () => {
  assert.deepEqual(
    await toInlineData("data:image/png;base64,AAAA"),
    { inlineData: { mimeType: "image/png", data: "AAAA" } },
  );
  assert.deepEqual(
    await toInlineData("/9j/4AAQSkZJRg=="),
    { inlineData: { mimeType: "image/jpeg", data: "/9j/4AAQSkZJRg==" } },
  );
});

// ── contract ───────────────────────────────────────────────────────────────

test("enrichListing contract: draft needs images, product needs productId", () => {
  const s = RequestSchemas.enrichListing;
  assert.equal(s.safeParse({ mode: "draft", images: ["AAA"] }).success, true);
  assert.equal(s.safeParse({ mode: "draft", images: [] }).success, false);
  assert.equal(s.safeParse({ mode: "product", productId: "p1" }).success, true);
  assert.equal(s.safeParse({ mode: "product" }).success, false);
  assert.equal(s.safeParse({ mode: "bogus" }).success, false);
  // product-mode defaults
  assert.equal(s.parse({ mode: "product", productId: "p1" }).fillBlanksOnly, true);
  assert.equal(s.parse({ mode: "product", productId: "p1" }).persist, true);
});
