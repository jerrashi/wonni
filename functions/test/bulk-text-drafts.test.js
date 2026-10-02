/**
 * bulk-text-drafts.test.js — `bulkDraftsFromText` minus the network: the
 * model-output → proposal mapping, comp-median pricing, best-comp selection,
 * the "sell similar" carry-over, and the photo priority chain with injected
 * comps / detail / google deps. The Gemini parse itself and the image model
 * are manual smokes (see bulk_text_drafts.js header).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "test-client-id";
process.env.EBAY_CLIENT_SECRET = "test-client-secret";

const { _internal } = require("../bulk_text_drafts");
const { fullSizeEbayImage } = require("../ebay_comps")._internal;
const { RequestSchemas, ResponseSchemas } = require("../contracts");

const {
  toProposalCore, parseModelOutput, priceFromComps, pickBestComp, usefulSpecifics, googleImages, enrichProposal, buildDrafts,
} = _internal;

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

// ── sell similar ───────────────────────────────────────────────────────────

test("pickBestComp: most shared title words wins, ties keep eBay's order, photo required", () => {
  const comps = [
    { itemId: "1", title: "Just Dance 4 Nintendo Wii CIB", imageUrl: "https://i.ebayimg.com/1/s-l225.jpg" },
    { itemId: "2", title: "Just Dance 4 2015 2014 Wii bundle lot of 3", imageUrl: "https://i.ebayimg.com/2/s-l225.jpg" },
    { itemId: "3", title: "Just Dance 4 2015 2014 Wii bundle lot of 3 tested", imageUrl: null },
  ];
  assert.equal(pickBestComp(comps, "Just Dance Wii bundle 4 2015 2014").itemId, "2");
  assert.equal(pickBestComp(comps, "Just Dance 4 Wii").itemId, "1");
  assert.equal(pickBestComp([comps[2]], "anything"), null);
  assert.equal(pickBestComp([], "anything"), null);
});

test("usefulSpecifics: drops per-seller noise, caps the count, keeps the rest in order", () => {
  const aspects = { Platform: "Nintendo Wii", "Country of Origin": "United States", MPN: "RVL-P-RSBE", "Game Name": "Super Smash Bros. Brawl", UPC: "0045496900397" };
  assert.deepEqual(usefulSpecifics(aspects), { Platform: "Nintendo Wii", "Game Name": "Super Smash Bros. Brawl", UPC: "0045496900397" });
  const many = Object.fromEntries(Array.from({ length: 30 }, (_, i) => [`A${i}`, String(i)]));
  assert.equal(Object.keys(usefulSpecifics(many)).length, 20);
  assert.deepEqual(usefulSpecifics(undefined), {});
  // A bundle's best comp is some other lot — its single-item identity fields are noise.
  const lot = { "Game Name": "Just Dance 1, 2, 3, 2015", UPC: "0008888", "Release Year": "2012", Platform: "Nintendo Wii", Publisher: "Ubisoft" };
  assert.deepEqual(usefulSpecifics(lot, { isBundle: true }), { Platform: "Nintendo Wii", Publisher: "Ubisoft" });
  assert.deepEqual(usefulSpecifics(lot, { isBundle: false }), lot);
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

test("googleImages: [] without secrets; maps items to https links; never throws", async () => {
  assert.deepEqual(await googleImages("x", {}), []);
  assert.deepEqual(await googleImages("x", { key: "unset", cx: "unset", fetchImpl: async () => { throw new Error("must not call"); } }), []);
  let url;
  const ok = await googleImages("We Ski Wii", {
    key: "k", cx: "c",
    fetchImpl: async (u) => { url = String(u); return { ok: true, json: async () => ({ items: [{ link: "https://a/1.jpg" }, { link: "http://insecure/2.jpg" }, { link: "https://a/3.jpg" }] }) }; },
  });
  assert.deepEqual(ok, ["https://a/1.jpg", "https://a/3.jpg"]);
  assert.match(url, /searchType=image/);
  assert.match(url, /q=We\+Ski\+Wii/);
  const failed = await googleImages("x", { key: "k", cx: "c", fetchImpl: async () => ({ ok: false, status: 429, json: async () => ({ error: { message: "quota" } }) }) });
  assert.deepEqual(failed, []);
  const threw = await googleImages("x", { key: "k", cx: "c", fetchImpl: async () => { throw new Error("down"); } });
  assert.deepEqual(threw, []);
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

const SSBB_COMPS = [
  { itemId: "v1|1|0", title: "SSBB Wii", price: 28, imageUrl: null, itemWebUrl: "https://ebay.com/1" },
  { itemId: "v1|2|0", title: "Super Smash Bros Brawl Nintendo Wii CIB", price: 32, imageUrl: "https://i.ebayimg.com/images/g/a/s-l225.jpg", itemWebUrl: "https://ebay.com/2" },
  { itemId: "v1|3|0", title: "Smash lot", price: 44, imageUrl: "https://i.ebayimg.com/images/g/b/s-l225.jpg", itemWebUrl: "https://ebay.com/3" },
];

const SSBB_DETAIL = {
  itemId: "v1|2|0",
  title: "Super Smash Bros Brawl Nintendo Wii CIB",
  categoryId: "139973",
  categoryPath: "Video Games & Consoles|Video Games",
  conditionId: "4000",
  condition: "Very Good",
  epid: "24070872136",
  images: ["https://i.ebayimg.com/images/g/a/s-l1600.jpg", "https://i.ebayimg.com/images/g/a2/s-l1600.jpg"],
  aspects: { Platform: "Nintendo Wii", "Game Name": "Super Smash Bros. Brawl", "Country of Origin": "United States" },
};

test("enrichProposal: comps price, sell-similar details and the best comp's photos; hints are stripped", async () => {
  const seen = [];
  const p = await enrichProposal(core(), {
    comps: async ({ title }) => { seen.push(title); return SSBB_COMPS; },
    detail: async (id) => { assert.equal(id, "v1|2|0"); return SSBB_DETAIL; },
    google: async () => { throw new Error("should not hit google when eBay has photos"); },
  });
  assert.deepEqual(seen, ["Super Smash Bros Brawl Wii CIB"]);
  assert.equal(p.suggestedPrice, 32);
  assert.equal(p.priceSource, "comps");
  assert.equal(p.similarItemId, "v1|2|0");
  assert.equal(p.ebayCategoryId, "139973");
  assert.equal(p.ebayConditionId, "4000");
  assert.equal(p.epid, "24070872136");
  assert.deepEqual(p.itemSpecifics, { Platform: "Nintendo Wii", "Game Name": "Super Smash Bros. Brawl" });
  assert.deepEqual(p.imageUrls, SSBB_DETAIL.images);
  assert.equal(p.imageSource, "ebay");
  assert.equal(p.comps.length, 3);
  assert.equal("_searchQuery" in p, false);
  assert.equal("_aiPrice" in p, false);
});

test("enrichProposal: detail failure degrades to the comp's thumbnail (full-size) with no sell-similar fields", async () => {
  const p = await enrichProposal(core(), {
    comps: async () => SSBB_COMPS,
    detail: async () => { throw new Error("eBay 500"); },
  });
  assert.deepEqual(p.imageUrls, ["https://i.ebayimg.com/images/g/a/s-l1600.jpg"]);
  assert.equal(p.imageSource, "ebay");
  assert.equal(p.ebayCategoryId, undefined);
  assert.equal(p.itemSpecifics, undefined);
});

test("enrichProposal: bundle gets one best-comp photo per component, priced on the whole-bundle query", async () => {
  const p = await enrichProposal(core({
    isBundle: true,
    bundleItems: ["Just Dance 4", "Just Dance 2015"],
    _searchQuery: "bundle-q",
    _componentQueries: ["Just Dance 4 Wii", "Just Dance 2015 Wii"],
  }), {
    comps: async ({ title }) => {
      if (title === "bundle-q") return [{ itemId: "lot", title: "lot", price: 60, imageUrl: "https://i.ebayimg.com/lot/s-l225.jpg", itemWebUrl: null }];
      return [
        { itemId: title + "-wrong", title: "Wii Sports", price: 15, imageUrl: "https://i.ebayimg.com/wrong/s-l225.jpg", itemWebUrl: null },
        { itemId: title, title, price: 15, imageUrl: `https://i.ebayimg.com/${encodeURIComponent(title)}/s-l225.jpg`, itemWebUrl: null },
      ];
    },
    detail: async () => null,
  });
  assert.equal(p.suggestedPrice, 60);
  assert.deepEqual(p.imageUrls, [
    "https://i.ebayimg.com/Just%20Dance%204%20Wii/s-l1600.jpg",
    "https://i.ebayimg.com/Just%20Dance%202015%20Wii/s-l1600.jpg",
  ]);
  assert.equal(p.imageSource, "ebay");
});

test("enrichProposal: no eBay photos → Google; no Google → none (never generated here)", async () => {
  const fromGoogle = await enrichProposal(core(), {
    comps: async () => [],
    google: async (q) => { assert.equal(q, "Super Smash Bros Brawl Wii CIB"); return ["https://cdn/x.jpg"]; },
  });
  assert.equal(fromGoogle.suggestedPrice, 35);
  assert.equal(fromGoogle.priceSource, "ai");
  assert.deepEqual(fromGoogle.imageUrls, ["https://cdn/x.jpg"]);
  assert.equal(fromGoogle.imageSource, "google");

  const nothing = await enrichProposal(core({ _aiPrice: undefined }), {
    comps: async () => { throw new Error("eBay down"); },
    google: async () => [],
  });
  assert.equal(nothing.priceSource, "none");
  assert.equal(nothing.suggestedPrice, undefined);
  assert.deepEqual(nothing.imageUrls, []);
  assert.equal(nothing.imageSource, "none");
});

// ── end to end against the contracts ───────────────────────────────────────

test("buildDrafts: output satisfies the response contract and request defaults apply", async () => {
  const data = RequestSchemas.bulkDraftsFromText.parse({ text: "wii games (CIB):\nSuper smash bros brawl\nbundle 1: a, b" });
  assert.equal(data.maxItems, 40);

  const result = await buildDrafts(data, {
    parse: async () => parseModelOutput(JSON.stringify({
      context: "Wii games CIB",
      items: [
        { sourceText: "Super smash bros brawl", title: "Super Smash Bros. Brawl (Wii) CIB", condition: "good", searchQuery: "ssbb", suggestedPrice: 30 },
        { sourceText: "bundle 1: a, b", title: "A & B Wii Bundle", isBundle: true, bundleItems: ["A", "B"], condition: "good", componentQueries: ["A Wii", "B Wii"] },
      ],
    }), data.maxItems),
    comps: async ({ title }) => (title === "ssbb" ? SSBB_COMPS : []),
    detail: async () => SSBB_DETAIL,
    google: async () => [],
  });

  const check = ResponseSchemas.bulkDraftsFromText.safeParse(result);
  assert.equal(check.success, true, JSON.stringify(check.error?.errors));
  assert.equal(result.drafts.length, 2);
  assert.equal(result.drafts[0].priceSource, "comps");
  assert.equal(result.drafts[0].ebayCategoryId, "139973");
  assert.equal(result.drafts[1].isBundle, true);
  assert.equal(result.drafts[1].priceSource, "none");
  assert.equal(result.drafts[1].imageSource, "none");
});

test("ebay_listing resolveCategoryId: a numeric ebayCategoryId on the product wins over the taxonomy suggestion", async () => {
  const { resolveCategoryId } = require("../ebay_listing")._internal;
  assert.equal(await resolveCategoryId("u", "t", { ebayCategoryId: "139973" }), "139973");
  assert.equal(await resolveCategoryId("u", "t", { ebayCategoryId: 139973 }), "139973");
  // Anything non-numeric falls through to suggestCategoryId, which needs the
  // network here — the thrown token error proves the fallthrough happened.
  await assert.rejects(resolveCategoryId("u", "t", { ebayCategoryId: "junk" }));
});

test("generateListingPhoto contract: title required, bundleItems/condition default", () => {
  const data = RequestSchemas.generateListingPhoto.parse({ title: "We Ski Wii" });
  assert.deepEqual(data, { title: "We Ski Wii", bundleItems: [], condition: "good" });
  assert.throws(() => RequestSchemas.generateListingPhoto.parse({}));
  assert.equal(ResponseSchemas.generateListingPhoto.safeParse({ url: null }).success, true);
});
