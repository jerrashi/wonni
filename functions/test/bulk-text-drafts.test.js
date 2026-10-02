/**
 * bulk-text-drafts.test.js — `bulkDraftsFromText` minus the network: the
 * model-output → proposal mapping, comp-median pricing, and the
 * price/photo enrichment with injected comps + image generation.
 * The Gemini parse itself is a manual smoke (see docs in bulk_text_drafts.js).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "test-client-id";
process.env.EBAY_CLIENT_SECRET = "test-client-secret";

const { _internal } = require("../bulk_text_drafts");
const { RequestSchemas, ResponseSchemas } = require("../contracts");

const { toProposalCore, parseModelOutput, priceFromComps, enrichProposal, buildDrafts, fullSizeEbayImage } = _internal;

// ── parse mapping ──────────────────────────────────────────────────────────

test("toProposalCore: bundle line → one listing with bundleItems + search hints", () => {
  const core = toProposalCore({
    sourceText: "bundle 1: just dance 4, just dance 2015, just dance 2014.",
    title: "Just Dance 4, 2015 & 2014 Nintendo Wii Bundle (3 Games, CIB)",
    shortTitle: "Just Dance 4 2015 2014 Wii Bundle 3 Games CIB",
    isBundle: true,
    bundleItems: ["Just Dance 4", "Just Dance 2015", "Just Dance 2014"],
    description: "Three Just Dance games for Wii, complete in box.",
    brand: "Ubisoft",
    category: "Video Games & Consoles > Video Games",
    condition: "good",
    tags: ["Wii", "just dance", "bundle"],
    searchQuery: "Just Dance Wii bundle",
    componentQueries: ["Just Dance 4 Wii", "Just Dance 2015 Wii", "Just Dance 2014 Wii"],
    suggestedPrice: 29.5,
  });
  assert.equal(core.isBundle, true);
  assert.deepEqual(core.bundleItems, ["Just Dance 4", "Just Dance 2015", "Just Dance 2014"]);
  assert.deepEqual(core.tags, ["wii", "just dance", "bundle"]);
  assert.equal(core.quantity, 1);
  assert.equal(core._searchQuery, "Just Dance Wii bundle");
  assert.equal(core._componentQueries.length, 3);
  assert.equal(core._aiPrice, 29.5);
});

test("toProposalCore: single item defaults — condition falls back to good, shortTitle derived, no bundleItems", () => {
  const core = toProposalCore({
    sourceText: "Super smash bros brawl",
    title: "Super Smash Bros. Brawl (Nintendo Wii) CIB",
    condition: "complete in box",
    isBundle: false,
    bundleItems: ["Super Smash Bros. Brawl"],
  });
  assert.equal(core.isBundle, false);
  assert.deepEqual(core.bundleItems, []);
  assert.equal(core.condition, "good");
  assert.equal(core.shortTitle, "Super Smash Bros. Brawl (Nintendo Wii) CIB");
  assert.equal(core.description, core.title);
  assert.equal(core._aiPrice, undefined);
});

test("toProposalCore: an item with no usable title is dropped", () => {
  assert.equal(toProposalCore({ description: "nothing" }), null);
});

test("parseModelOutput: strips code fences, keeps order, caps at maxItems", () => {
  const raw = "```json\n" + JSON.stringify({
    context: "Nintendo Wii games, complete in box",
    items: [
      { sourceText: "a", title: "A", condition: "good" },
      { sourceText: "b", title: "B", condition: "likenew" },
      { sourceText: "c", title: "C", condition: "new" },
    ],
  }) + "\n```";
  const { context, proposals } = parseModelOutput(raw, 2);
  assert.equal(context, "Nintendo Wii games, complete in box");
  assert.deepEqual(proposals.map((p) => p.title), ["A", "B"]);
  assert.equal(proposals[1].condition, "likenew");
});

// ── pricing ────────────────────────────────────────────────────────────────

test("priceFromComps: median of positive prices, whole dollars; null when none", () => {
  assert.equal(priceFromComps([{ price: 10 }, { price: 40 }, { price: 22.49 }]), 22);
  assert.equal(priceFromComps([{ price: 10 }, { price: 30 }]), 20);
  assert.equal(priceFromComps([{ price: null }, { price: 0 }, { price: -5 }]), null);
  assert.equal(priceFromComps([]), null);
});

// ── photos ─────────────────────────────────────────────────────────────────

test("fullSizeEbayImage: rewrites the Browse thumbnail size to 1600, leaves other URLs alone", () => {
  assert.equal(
    fullSizeEbayImage("https://i.ebayimg.com/images/g/7GgAAeSwqcpqvumR/s-l225.jpg"),
    "https://i.ebayimg.com/images/g/7GgAAeSwqcpqvumR/s-l1600.jpg"
  );
  assert.equal(fullSizeEbayImage("https://i.ebayimg.com/images/g/abc/s-l140.webp"), "https://i.ebayimg.com/images/g/abc/s-l1600.webp");
  assert.equal(fullSizeEbayImage("https://storage.googleapis.com/b/users/u/generated/1.png"), "https://storage.googleapis.com/b/users/u/generated/1.png");
  assert.equal(fullSizeEbayImage(null), null);
});

// ── enrichment ─────────────────────────────────────────────────────────────

function core(overrides = {}) {
  return {
    title: "Super Smash Bros. Brawl (Wii) CIB",
    shortTitle: "Super Smash Bros Brawl Wii CIB",
    description: "Complete in box.",
    condition: "good",
    tags: ["wii"],
    isBundle: false,
    bundleItems: [],
    quantity: 1,
    sourceText: "Super smash bros brawl",
    _searchQuery: "Super Smash Bros Brawl Wii CIB",
    _componentQueries: [],
    _aiPrice: 35,
    ...overrides,
  };
}

test("enrichProposal: comps price + first comp photo win; hints are stripped", async () => {
  const seen = [];
  const deps = {
    comps: async ({ title }) => {
      seen.push(title);
      return [
        { title: "SSBB Wii", price: 28, imageUrl: null, itemWebUrl: "https://ebay.com/1" },
        { title: "SSBB Wii CIB", price: 32, imageUrl: "https://i.ebayimg.com/images/g/a/s-l225.jpg", itemWebUrl: "https://ebay.com/2" },
        { title: "SSBB lot", price: 44, imageUrl: "https://i.ebayimg.com/b.jpg", itemWebUrl: "https://ebay.com/3" },
      ];
    },
    generate: async () => { throw new Error("should not generate when a comp photo exists"); },
  };
  const p = await enrichProposal(core(), "ebay", deps);
  assert.deepEqual(seen, ["Super Smash Bros Brawl Wii CIB"]);
  assert.equal(p.suggestedPrice, 32);
  assert.equal(p.priceSource, "comps");
  assert.deepEqual(p.imageUrls, ["https://i.ebayimg.com/images/g/a/s-l1600.jpg"]);
  assert.equal(p.imageSource, "ebay");
  assert.equal(p.comps.length, 3);
  assert.equal(p.comps[0].title, "SSBB Wii");
  assert.equal("_searchQuery" in p, false);
  assert.equal("_aiPrice" in p, false);
});

test("enrichProposal: bundle gets one photo per component, priced on the whole-bundle query", async () => {
  const deps = {
    comps: async ({ title }) => {
      if (title === "bundle-q") return [{ title: "lot", price: 60, imageUrl: "https://i.ebayimg.com/lot.jpg", itemWebUrl: null }];
      return [{ title, price: 15, imageUrl: `https://i.ebayimg.com/${encodeURIComponent(title)}.jpg`, itemWebUrl: null }];
    },
  };
  const p = await enrichProposal(core({
    isBundle: true,
    bundleItems: ["Just Dance 4", "Just Dance 2015"],
    _searchQuery: "bundle-q",
    _componentQueries: ["Just Dance 4 Wii", "Just Dance 2015 Wii"],
  }), "ebay", deps);
  assert.equal(p.suggestedPrice, 60);
  assert.deepEqual(p.imageUrls, [
    "https://i.ebayimg.com/Just%20Dance%204%20Wii.jpg",
    "https://i.ebayimg.com/Just%20Dance%202015%20Wii.jpg",
  ]);
  assert.equal(p.imageSource, "ebay");
});

test("enrichProposal: no comps → AI price + generated photo; generation failure is non-fatal", async () => {
  const generated = await enrichProposal(core(), "ebay", {
    comps: async () => [],
    generate: async () => "https://storage.googleapis.com/b/users/u/generated/1.png",
  });
  assert.equal(generated.suggestedPrice, 35);
  assert.equal(generated.priceSource, "ai");
  assert.deepEqual(generated.imageUrls, ["https://storage.googleapis.com/b/users/u/generated/1.png"]);
  assert.equal(generated.imageSource, "generated");

  const failed = await enrichProposal(core({ _aiPrice: undefined }), "ebay", {
    comps: async () => { throw new Error("eBay down"); },
    generate: async () => { throw new Error("quota"); },
  });
  assert.equal(failed.priceSource, "none");
  assert.equal(failed.suggestedPrice, undefined);
  assert.deepEqual(failed.imageUrls, []);
  assert.equal(failed.imageSource, "none");
});

test("enrichProposal: photoSource 'generate' skips comp photos but still prices from comps; 'none' skips photos", async () => {
  const deps = {
    comps: async () => [{ title: "x", price: 20, imageUrl: "https://i.ebayimg.com/x.jpg", itemWebUrl: null }],
    generate: async () => "https://storage.googleapis.com/b/gen.png",
  };
  const gen = await enrichProposal(core(), "generate", deps);
  assert.equal(gen.suggestedPrice, 20);
  assert.deepEqual(gen.imageUrls, ["https://storage.googleapis.com/b/gen.png"]);
  assert.equal(gen.imageSource, "generated");

  const none = await enrichProposal(core(), "none", deps);
  assert.deepEqual(none.imageUrls, []);
  assert.equal(none.imageSource, "none");
});

// ── end to end against the contract ────────────────────────────────────────

test("buildDrafts: output satisfies the response contract and request defaults apply", async () => {
  const data = RequestSchemas.bulkDraftsFromText.parse({ text: "wii games (CIB):\nSuper smash bros brawl\nbundle 1: a, b" });
  assert.equal(data.maxItems, 40);
  assert.equal(data.photoSource, "ebay");

  const result = await buildDrafts(data, {
    parse: async () => parseModelOutput(JSON.stringify({
      context: "Wii games CIB",
      items: [
        { sourceText: "Super smash bros brawl", title: "Super Smash Bros. Brawl (Wii) CIB", condition: "good", searchQuery: "ssbb", suggestedPrice: 30 },
        { sourceText: "bundle 1: a, b", title: "A & B Wii Bundle", isBundle: true, bundleItems: ["A", "B"], condition: "good", componentQueries: ["A Wii", "B Wii"] },
      ],
    }), data.maxItems),
    comps: async ({ title }) => (title === "ssbb" ? [{ title: "c", price: 25, imageUrl: "https://i.ebayimg.com/c.jpg", itemWebUrl: null }] : []),
    generate: async () => null,
  });

  const check = ResponseSchemas.bulkDraftsFromText.safeParse(result);
  assert.equal(check.success, true, JSON.stringify(check.error?.errors));
  assert.equal(result.drafts.length, 2);
  assert.equal(result.drafts[0].priceSource, "comps");
  assert.equal(result.drafts[1].isBundle, true);
  assert.equal(result.drafts[1].priceSource, "none");
  assert.equal(result.drafts[1].imageSource, "none");
});
