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
  toProposalCore, parsePrice, orderBySource, parseModelOutput, priceFromComps, comparableComps, pickBestComp, rankPhotoComps, choosePhotoComp, parseListWithGemini, usefulSpecifics, googleImages, enrichProposal, buildDrafts, salvageItems, unparsedTail, toPendingItem,
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

test("parsePrice: numbers and the user's own formatting; junk is undefined", () => {
  assert.equal(parsePrice(25), 25);
  assert.equal(parsePrice("$25"), 25);
  assert.equal(parsePrice("12.50 obo"), 12.5);
  assert.equal(parsePrice("1,200"), 1200);
  assert.equal(parsePrice(19.999), 20);
  for (const junk of [null, undefined, "", "free", 0, -5, NaN]) assert.equal(parsePrice(junk), undefined);
});

test("toProposalCore: a user-stated price is kept apart from the model's estimate", () => {
  const withPrice = toProposalCore({ title: "Mario Kart Wii", userPrice: "$25", suggestedPrice: 31 });
  assert.equal(withPrice._userPrice, 25);
  assert.equal(withPrice._aiPrice, 31);
  assert.equal(toProposalCore({ title: "Mario Kart Wii", userPrice: null, suggestedPrice: 31 })._userPrice, undefined);
});

test("orderBySource: restores input order when the model regrouped; leaves a correct order alone", () => {
  const text = "Selling my Mario Kart Wii for $25,  then a bundle of Just Dance 4 + Just Dance 2015,\nand finally Wii Sports.";
  const named = (...names) => names.map((n) => ({ title: n, sourceText: n }));
  const titles = (list) => list.map((p) => p.title);

  // Model floated the bundle to the top and changed case/spacing.
  const shuffled = [
    { title: "bundle", sourceText: "bundle of just dance 4 + just dance 2015" },
    { title: "sports", sourceText: "WII SPORTS" },
    { title: "kart", sourceText: "Mario  Kart Wii" },
  ];
  assert.deepEqual(titles(orderBySource(shuffled, text)), ["kart", "bundle", "sports"]);

  // Already in order → same array back.
  const inOrder = named("Mario Kart Wii", "Just Dance 4", "Wii Sports");
  assert.equal(orderBySource(inOrder, text), inOrder);

  // A paraphrased snippet can't be located: it stays behind the one it followed.
  const withUnknown = [
    { title: "sports", sourceText: "Wii Sports" },
    { title: "mystery", sourceText: "something the model reworded" },
    { title: "kart", sourceText: "Mario Kart Wii" },
  ];
  assert.deepEqual(titles(orderBySource(withUnknown, text)), ["kart", "sports", "mystery"]);

  // The same snippet twice is two listings, not a reason to reorder.
  const twice = named("mario kart", "zelda", "mario kart");
  assert.equal(orderBySource(twice, "mario kart, zelda, mario kart"), twice);
});

test("parseModelOutput: reorders to the source text before capping", () => {
  const raw = JSON.stringify({ items: [
    { sourceText: "c", title: "C" }, { sourceText: "a", title: "A" }, { sourceText: "b", title: "B" },
  ] });
  assert.deepEqual(parseModelOutput(raw, 2, "a\nb\nc").proposals.map((p) => p.title), ["A", "B"]);
});

// ── pricing ────────────────────────────────────────────────────────────────

test("priceFromComps: the lowest comparable asking price, to the cent; null when none", () => {
  const q = "Super Smash Bros Brawl Wii CIB";
  const comps = [
    { title: "Super Smash Bros Brawl Nintendo Wii Complete CIB", price: 34.99 },
    { title: "Super Smash Bros. Brawl (Nintendo Wii, 2008) Tested", price: 27.5 },
    { title: "Super Smash Bros Brawl Wii w/ manual", price: 41 },
  ];
  assert.equal(priceFromComps(comps, q), 27.5);
  assert.equal(priceFromComps([{ price: null }, { price: 0 }, { price: -5 }], q), null);
  assert.equal(priceFromComps([], q), null);
});

test("priceFromComps: not-comparable listings and outliers never set the price", () => {
  const q = "Super Smash Bros Brawl Wii CIB";
  const good = [
    { title: "Super Smash Bros Brawl Nintendo Wii Complete", price: 30 },
    { title: "Super Smash Bros Brawl Wii CIB Tested", price: 33 },
    { title: "Super Smash Bros Brawl Wii", price: 36 },
  ];
  // Cheaper, but not the same thing: disc only, for parts, a different game.
  assert.equal(priceFromComps([
    ...good,
    { title: "Super Smash Bros Brawl Wii DISC ONLY", price: 12 },
    { title: "Super Smash Bros Brawl Wii for parts not working", price: 6 },
    { title: "Mario Kart Wii CIB", price: 9 },
  ], q), 30);
  // Same words, but under half the comparable median: an outlier, skipped.
  assert.equal(priceFromComps([...good, { title: "Super Smash Bros Brawl Wii", price: 4 }], q), 30);
  // The user IS selling a disc-only copy: those listings are the comparables.
  assert.equal(priceFromComps([
    { title: "Super Smash Bros Brawl Wii Disc Only", price: 12 },
    { title: "Super Smash Bros Brawl Wii disc only tested", price: 14 },
  ], "Super Smash Bros Brawl Wii disc only"), 12);
});

test("priceFromComps: a different model number is a different item", () => {
  const q = "Lego 75192 Millennium Falcon sealed";
  assert.equal(priceFromComps([
    { title: "LEGO Star Wars Millennium Falcon 75105 NEW SEALED", price: 250 },
    { title: "LEGO 75192 UCS Millennium Falcon New Sealed", price: 780 },
    { title: "LEGO Star Wars 75192 Millennium Falcon Sealed Box", price: 849.99 },
  ], q), 780);
});

test("priceFromComps: nothing comparable → lowest non-outlier of whatever eBay returned", () => {
  assert.equal(priceFromComps([{ title: "lot a", price: 20 }, { title: "lot b", price: 24.99 }, { title: "junk", price: 2 }], "obscure thing xyz"), 20);
  assert.equal(comparableComps([{ title: "lot a", price: 20 }], "obscure thing xyz").length, 0);
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

test("enrichProposal: the user's price wins; the comps median rides along as marketPrice and details/photos still come from comps", async () => {
  const p = await enrichProposal(core({ _userPrice: 25 }), {
    comps: async () => SSBB_COMPS, detail: async () => SSBB_DETAIL, google: async () => [],
  });
  assert.equal(p.suggestedPrice, 25);
  assert.equal(p.priceSource, "user");
  assert.equal(p.marketPrice, 32);
  assert.equal(p.marketPriceSource, "comps");
  assert.equal(p.ebayCategoryId, "139973");
  assert.equal(p.imageSource, "ebay");
  assert.equal("_userPrice" in p, false);

  const noComps = await enrichProposal(core({ _userPrice: 25 }), { comps: async () => [], detail: async () => null, google: async () => [] });
  assert.equal(noComps.suggestedPrice, 25);
  assert.equal(noComps.marketPrice, 35);
  assert.equal(noComps.marketPriceSource, "ai");

  const alone = await enrichProposal(core({ _userPrice: 25, _aiPrice: undefined }), { comps: async () => [], detail: async () => null, google: async () => [] });
  assert.equal(alone.priceSource, "user");
  assert.equal("marketPrice" in alone, false);
  assert.equal(ResponseSchemas.bulkDraftsFromText.shape.drafts.element.safeParse(alone).success, true);
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
        { sourceText: "Super smash bros brawl", title: "Super Smash Bros. Brawl (Wii) CIB", condition: "good", searchQuery: "Super Smash Bros Brawl Wii", suggestedPrice: 30 },
        { sourceText: "bundle 1: a, b", title: "A & B Wii Bundle", isBundle: true, bundleItems: ["A", "B"], condition: "good", componentQueries: ["A Wii", "B Wii"] },
      ],
    }), data.maxItems),
    comps: async ({ title }) => (title === "Super Smash Bros Brawl Wii" ? SSBB_COMPS : []),
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

// ── batching, shipping fields, truncated parses ────────────────────────────

const RAW_ITEM = (n, extra = {}) => ({
  sourceText: `game ${n}`, title: `Game ${n} (Wii) CIB`, condition: "good", searchQuery: `game ${n} wii`, suggestedPrice: 10 + n, ...extra,
});

test("toProposalCore: shipping estimates ride on the proposal (lbs → oz, junk dropped)", () => {
  const core = toProposalCore(RAW_ITEM(1, { weightOz: 5.4, lengthIn: 7.52, widthIn: "5", heightIn: -1 }));
  assert.equal(core.weightOz, 5);
  assert.equal(core.lengthIn, 7.5);
  assert.equal(core.widthIn, 5);
  assert.equal("heightIn" in core, false);
  assert.equal(toProposalCore(RAW_ITEM(2, { weightLbs: 1.5 })).weightOz, 24);
  assert.equal("weightOz" in toProposalCore(RAW_ITEM(3)), false);
});

test("toPendingItem: round-trips through toProposalCore unchanged and satisfies the request contract", () => {
  const core = toProposalCore(RAW_ITEM(1, { userPrice: "$25", weightOz: 6, isBundle: true, bundleItems: ["a", "b"], componentQueries: ["a wii", "b wii"] }));
  const pending = toPendingItem(core);
  assert.equal(Object.keys(pending).some((k) => k.startsWith("_")), false);
  assert.equal(pending.userPrice, 25);
  assert.deepEqual(toProposalCore(pending), core);
  const req = RequestSchemas.bulkDraftsFromText.safeParse({ pendingItems: [pending] });
  assert.equal(req.success, true, JSON.stringify(req.error?.errors));
});

test("buildDrafts: text mode enriches the first batch and returns the rest in order, un-enriched", async () => {
  const raw = JSON.stringify({ context: "wii", items: [1, 2, 3, 4, 5].map((n) => RAW_ITEM(n)) });
  let compCalls = 0;
  const deps = {
    parse: async (text, maxItems) => parseModelOutput(raw, maxItems, text),
    comps: async () => { compCalls++; return []; },
    detail: async () => null,
    google: async () => [],
  };
  const first = await buildDrafts({ text: "game 1\ngame 2\ngame 3\ngame 4\ngame 5", maxItems: 2 }, deps);
  assert.deepEqual(first.drafts.map((d) => d.title), ["Game 1 (Wii) CIB", "Game 2 (Wii) CIB"]);
  assert.deepEqual(first.remaining.map((r) => r.sourceText), ["game 3", "game 4", "game 5"]);
  assert.equal(first.unparsedText, "");
  assert.equal(compCalls, 2, "only the batch is enriched");
  assert.equal(ResponseSchemas.bulkDraftsFromText.safeParse(first).success, true);

  // items mode: no parse call, same enrichment, order kept.
  const second = await buildDrafts({ pendingItems: first.remaining, context: first.context, maxItems: 2 }, {
    ...deps, parse: async () => { throw new Error("must not re-parse"); },
  });
  assert.deepEqual(second.drafts.map((d) => d.title), ["Game 3 (Wii) CIB", "Game 4 (Wii) CIB"]);
  assert.deepEqual(second.remaining.map((r) => r.sourceText), ["game 5"]);
  assert.equal(second.context, "wii");
  assert.equal(second.drafts[0].priceSource, "ai");
  assert.equal(second.drafts[0].suggestedPrice, 13);
});

test("salvageItems: keeps every complete object from JSON cut off mid-item", () => {
  const full = JSON.stringify({ context: "wii \"cib\"", items: [RAW_ITEM(1, { description: "has } and { and \"quotes\"" }), RAW_ITEM(2), RAW_ITEM(3)] });
  const cut = full.slice(0, full.lastIndexOf('{"sourceText"') + 40);
  const { context, items } = salvageItems(cut);
  assert.equal(context, 'wii "cib"');
  assert.deepEqual(items.map((i) => i.sourceText), ["game 1", "game 2"]);
  assert.equal(items[0].description, 'has } and { and "quotes"');
  assert.deepEqual(salvageItems("not json at all"), { context: "", items: [], lost: [] });
});

test("parseModelOutput: a truncated response salvages items and reports the unparsed tail", () => {
  const text = "wii games:\nGame 1\nGAME   2\ngame 3\ngame 4 - missing manual";
  const full = JSON.stringify({ context: "wii", items: [RAW_ITEM(1), RAW_ITEM(2), RAW_ITEM(3)] });
  const cut = full.slice(0, full.lastIndexOf('{"sourceText"') + 30);
  const out = parseModelOutput(cut, 400, text, { truncated: true });
  assert.deepEqual(out.proposals.map((p) => p.sourceText), ["game 1", "game 2"]);
  assert.equal(out.unparsedText, "game 3\ngame 4 - missing manual");
  // Not truncated: malformed JSON is still an error, and the tail is empty.
  assert.throws(() => parseModelOutput(cut, 400, text));
  assert.equal(parseModelOutput(full, 400, text).unparsedText, "");
});

test("unparsedTail: nothing locatable → empty, never a guess", () => {
  assert.equal(unparsedTail("a\nb\nc", [{ sourceText: "zzz" }]), "");
  assert.equal(unparsedTail("mario kart, mario kart, zelda", [{ sourceText: "mario kart" }, { sourceText: "Mario  Kart" }]), ", zelda");
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

// ── photo / price matching by what is included (comp_match.js) ─────────────

const POKEMON_COMPS = [
  { itemId: "cib", title: "Pokemon Blue Version Nintendo Game Boy Complete In Box CIB", price: 500, imageUrl: "https://i.ebayimg.com/cib/s-l225.jpg" },
  { itemId: "silent", title: "Pokemon Blue Version (Nintendo Game Boy, 1998)", price: 64.99, imageUrl: "https://i.ebayimg.com/silent/s-l225.jpg", shortDescription: "Game is tested and works great" },
  { itemId: "box", title: "Pokemon Blue Version Nintendo Game Boy 1998 *** BOX ONLY ***", price: 169.99, imageUrl: "https://i.ebayimg.com/box/s-l225.jpg" },
  { itemId: "repro", title: "NEW Pokemon Blue Version GBC Cartridge Only Tested Saves", price: 24.99, imageUrl: "https://i.ebayimg.com/repro/s-l225.jpg", shortDescription: "These cartridges are newly made and are not the originally published version." },
  { itemId: "loose1", title: "Pokemon Blue Version (Game Boy, 1998) Authentic Cartridge Only", price: 57, imageUrl: "https://i.ebayimg.com/loose1/s-l225.jpg" },
  { itemId: "loose2", title: "Pokemon Blue Version (Game Boy, 1998)", price: 54.99, imageUrl: "https://i.ebayimg.com/loose2/s-l225.jpg", shortDescription: "Fully working, cartridge only." },
  { itemId: "cib2", title: "Pokemon Blue Version (Game Boy, 1998) Complete", price: 350, imageUrl: "https://i.ebayimg.com/cib2/s-l225.jpg" },
];
const POKEMON_Q = "Pokemon Blue Version Game Boy";

test("rankPhotoComps: explicit same-state comps first; contradictions, packaging and repros never", () => {
  const ids = (included) => rankPhotoComps(POKEMON_COMPS, POKEMON_Q, included).map((r) => `${r.comp.itemId}:${r.level}`);
  assert.deepEqual(ids("loose"), ["loose1:2", "loose2:2", "silent:1"]);
  assert.deepEqual(ids("complete"), ["cib:2", "cib2:2", "silent:1"]);
  // Nothing stated: best match as before, minus the empty box and the repro.
  assert.deepEqual(ids("unknown"), ["cib:1", "silent:1", "loose1:1", "loose2:1", "cib2:1"]);
});

test("priceFromComps: a loose cartridge and a boxed copy of the same game get different prices", () => {
  assert.equal(priceFromComps(POKEMON_COMPS, POKEMON_Q, "loose"), 54.99);
  assert.equal(priceFromComps(POKEMON_COMPS, POKEMON_Q, "complete"), 350);
});

test("enrichProposal: a cartridge-only listing never gets a boxed copy's photo", async () => {
  const p = await enrichProposal(core({ _searchQuery: POKEMON_Q, included: "loose", media: "cartridge" }), {
    comps: async () => POKEMON_COMPS,
    detail: async (id) => ({ itemId: id, categoryId: "139973", images: [`https://i.ebayimg.com/${id}/full.jpg`], aspects: {} }),
  });
  assert.deepEqual(p.imageUrls, ["https://i.ebayimg.com/loose1/full.jpg"]);
  assert.equal(p.included, "loose");
  assert.equal(p.media, "cartridge");
});

test("choosePhotoComp: a silent title is used only when its full description confirms the state", async () => {
  const comps = [
    { itemId: "a", title: "Chrono Trigger SNES", imageUrl: "https://i.ebayimg.com/a/s-l225.jpg" },
    { itemId: "b", title: "Chrono Trigger Super Nintendo SNES", imageUrl: "https://i.ebayimg.com/b/s-l225.jpg" },
  ];
  const descriptions = { a: "Comes with the original box and manual.", b: "<p>You get the <b>cartridge only</b>.</p>" };
  const calls = [];
  const detail = async (id) => { calls.push(id); return { itemId: id, title: "", description: descriptions[id], images: [] }; };
  const loose = await choosePhotoComp(comps, "Chrono Trigger SNES", "loose", { detail });
  assert.equal(loose.photoComp.itemId, "b");
  assert.deepEqual(calls, ["a", "b"]);
  // Sell-similar details still come from the first comp looked at.
  assert.equal(loose.detail.itemId, "b");

  // Nothing confirms "sealed": no photo comp (→ placeholder), details kept.
  const sealed = await choosePhotoComp(comps, "Chrono Trigger SNES", "sealed", { detail });
  assert.equal(sealed.photoComp, null);
  assert.equal(sealed.detail.itemId, "a");

  // The listing says nothing: first candidate, one lookup.
  calls.length = 0;
  const any = await choosePhotoComp(comps, "Chrono Trigger SNES", "unknown", { detail });
  assert.equal(any.photoComp.itemId, "a");
  assert.deepEqual(calls, ["a"]);
});

test("enrichProposal: no comp in the same state → no eBay photo, sell-similar details kept", async () => {
  const p = await enrichProposal(core({ _searchQuery: POKEMON_Q, included: "sealed" }), {
    comps: async () => POKEMON_COMPS.filter((c) => c.itemId !== "silent"),
    detail: async (id) => ({ itemId: id, categoryId: "139973", images: ["https://i.ebayimg.com/x/full.jpg"], aspects: { Platform: "Nintendo Game Boy" } }),
  });
  assert.deepEqual(p.imageUrls, []);
  assert.equal(p.imageSource, "none");
  assert.equal(p.ebayCategoryId, "139973");
});

test("toProposalCore: included comes from the model, else from the item's own words", () => {
  assert.equal(toProposalCore({ title: "Pokemon Blue", included: "loose", media: "cartridge" }).included, "loose");
  assert.equal(toProposalCore({ title: "Pokemon Blue", included: "loose", media: "cartridge" }).media, "cartridge");
  assert.equal(toProposalCore({ title: "Halo 3 Xbox 360", sourceText: "halo 3 (disc only)", included: "nonsense" }).included, "loose");
  assert.equal(toProposalCore({ title: "Halo 3 Xbox 360", sourceText: "halo 3" }).included, "unknown");
  assert.equal(toProposalCore({ title: "Halo 3 Xbox 360", media: "vinyl" }).media, "other");
  // Survives the pendingItems round trip.
  const pending = toPendingItem(toProposalCore({ title: "Pokemon Blue", included: "complete", media: "cartridge" }));
  assert.equal(toProposalCore(pending).included, "complete");
  assert.equal(RequestSchemas.bulkDraftsFromText.safeParse({ pendingItems: [pending] }).success, true);
});

// ── malformed model JSON (the "INTERNAL" error, 2026-10-05) ────────────────

const BAD_JSON = () => {
  const good = JSON.stringify({ context: "ps2", items: [RAW_ITEM(1), RAW_ITEM(2), RAW_ITEM(3)] });
  // An unescaped quote inside item 2's description, as the model produced.
  return good.replace('"sourceText":"game 2"', '"sourceText":"game 2","note":"3.5" disk"');
};

test("salvageItems: one malformed item does not take its neighbours down; its words are reported", () => {
  const { items, lost } = salvageItems(BAD_JSON());
  assert.deepEqual(items.map((i) => i.sourceText), ["game 1", "game 3"]);
  assert.deepEqual(lost, ["game 2"]);
});

test("parseListWithGemini: invalid JSON is retried once; a second failure keeps what parses", async () => {
  const good = JSON.stringify({ context: "ps2", items: [RAW_ITEM(1), RAW_ITEM(2)] });
  const attempts = [];
  const retried = await parseListWithGemini("k", "game 1\ngame 2", 400, "", {
    generate: async (_prompt, attempt) => { attempts.push(attempt); return { raw: attempt ? good : BAD_JSON(), truncated: false }; },
  });
  assert.deepEqual(attempts, [0, 1]);
  assert.equal(retried.proposals.length, 2);
  assert.equal(retried.unparsedText, "");

  const twice = await parseListWithGemini("k", "game 1\ngame 2\ngame 3", 400, "", {
    generate: async () => ({ raw: BAD_JSON(), truncated: false }),
  });
  assert.deepEqual(twice.proposals.map((p) => p.sourceText), ["game 1", "game 3"]);
  assert.equal(twice.unparsedText, "game 2", "the item that could not be read goes back to the user");

  await assert.rejects(parseListWithGemini("k", "x", 400, "", { generate: async () => ({ raw: "sorry, I cannot", truncated: false }) }));
});
