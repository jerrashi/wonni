/**
 * commit-listing-proposals.test.js — the web's commit step with a fake
 * Firestore / Storage / image fetch: doc shape, photo re-hosting (bad photos
 * skipped, non-images refused), per-proposal error isolation, contract check.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "x";
process.env.EBAY_CLIENT_SECRET = "y";

const { _internal } = require("../commit_listing_proposals");
const { RequestSchemas, ResponseSchemas } = require("../contracts");
const { productDocFor, commitProposals } = _internal;

const proposal = (extra = {}) => ({
  title: "Spigen Ultra Hybrid Case for iPhone 18 Pro, Clear",
  shortTitle: "Spigen Ultra Hybrid iPhone 18 Pro Case Clear",
  description: "Clear case, never opened.",
  brand: "Spigen",
  category: "Cell Phones & Accessories > Cases",
  condition: "new",
  tags: ["spigen", "iphone"],
  isBundle: false,
  bundleItems: [],
  quantity: 1,
  suggestedPrice: 12,
  priceSource: "ai",
  imageUrls: ["https://m.media-amazon.com/a.jpg", "https://m.media-amazon.com/b.png"],
  imageSource: "source",
  comps: [],
  sourceText: "iphone 18 pro case [link 1]",
  weightOz: 4,
  lengthIn: 7, widthIn: 4, heightIn: 1,
  ebayCategoryId: "9355",
  itemSpecifics: { Brand: "Spigen" },
  photoMatch: "strong",
  searchQuery: "spigen ultra hybrid iphone 18 pro",
  sourceUrl: "https://www.amazon.com/Spigen/dp/B0CHX1W1XY",
  source: "amazon",
  sourceId: "B0CHX1W1XY",
  sourcePrice: 15.99,
  ...extra,
});

function fakes() {
  const docs = {};
  let n = 0;
  const db = { collection: () => ({ doc: () => { const id = `p${++n}`; return { id, set: async (d) => { docs[id] = d; } }; } }) };
  const saved = [];
  const storage = { name: "bucket", file: (path) => ({ name: path, save: async () => { saved.push(path); } }) };
  return { db, storage, docs, saved };
}

test("productDocFor: importer doc shape plus the proposal's listing fields; cost and asking price stay apart", () => {
  const doc = productDocFor("u1", proposal(), { images: ["https://storage.googleapis.com/b/x.jpg"], now: "NOW" });
  assert.equal(doc.userId, "u1");
  assert.equal(doc.source, "amazon");
  assert.equal(doc.sourceId, "B0CHX1W1XY");
  assert.equal(doc.sourceUrl, "https://www.amazon.com/Spigen/dp/B0CHX1W1XY");
  assert.equal(doc.isDraft, true);
  assert.equal(doc.condition, "new");
  assert.equal(doc.sourcePrice, 15.99);
  assert.equal(doc.listingPrice, 12);
  assert.equal(doc.aiSuggestedPrice, 12);
  assert.deepEqual(doc.images, ["https://storage.googleapis.com/b/x.jpg"]);
  assert.deepEqual(doc.sourceImages, ["https://m.media-amazon.com/a.jpg", "https://m.media-amazon.com/b.png"]);
  assert.equal(doc.shortTitle, "Spigen Ultra Hybrid iPhone 18 Pro Case Clear");
  assert.deepEqual(doc.tags, ["spigen", "iphone"]);
  assert.equal(doc.quantity, 1);
  assert.equal(doc.ebayCategoryId, "9355");
  assert.deepEqual(doc.geminiItemSpecifics, { Brand: "Spigen" });
  assert.equal(doc.weightOz, 4);
  assert.equal(doc.weightLbs, 0.25);
  assert.equal(doc.lengthIn, 7);
  assert.equal(doc.listingSource.kind, "textToListings");
  assert.equal(doc.listingSource.photoMatch, "strong");
  assert.equal(doc.importedAt, "NOW");

  const text = productDocFor("u1", proposal({ source: undefined, sourceUrl: undefined, sourceId: undefined, sourcePrice: undefined, priceSource: "user", suggestedPrice: 20, marketPrice: 14, quantity: 3 }), { images: [], now: "NOW" });
  assert.equal(text.source, "text");
  assert.equal(text.sourcePrice, null);
  assert.equal(text.listingPrice, 20, "the user's own price is the list price");
  assert.equal(text.aiSuggestedPrice, 14, "the market figure stays as the suggestion");
  assert.equal(text.quantity, 3);
  assert.equal("sourceUrl" in text, false);
});

test("commitProposals: re-hosts photos (skipping failures and non-images), writes one doc per proposal, isolates errors, applies rules", async () => {
  const { db, storage, docs, saved } = fakes();
  const rules = [];
  const result = await commitProposals("u1", [
    proposal(),
    proposal({ title: "Broken", imageUrls: ["https://x/1.jpg", "https://x/2.jpg", "https://x/3.html"] }),
    proposal({ title: "Explodes" }),
  ], {
    db, storage, now: "NOW",
    fetchBytesImpl: async (url) => {
      if (url.endsWith("2.jpg")) throw new Error("404");
      if (url.endsWith(".html")) return { buffer: Buffer.from("<html>"), contentType: "text/html" };
      if (url.endsWith(".png")) return { buffer: Buffer.from("png"), contentType: "image/png" };
      return { buffer: Buffer.from("jpg"), contentType: "image/jpeg" };
    },
    applyRules: async (_db, uid, id) => { if (docs[id].title === "Explodes") throw new Error("rules blew up"); rules.push(id); },
  });
  assert.deepEqual(result.productIds, ["p1", "p2"]);
  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].title, "Explodes");
  assert.match(result.errors[0].error, /rules blew up/);
  assert.deepEqual(docs.p1.images, [
    "https://storage.googleapis.com/bucket/dropship/u1/text-p1/0.jpg",
    "https://storage.googleapis.com/bucket/dropship/u1/text-p1/1.png",
  ]);
  assert.deepEqual(docs.p2.images, ["https://storage.googleapis.com/bucket/dropship/u1/text-p2/0.jpg"], "the 404 and the html are skipped");
  assert.deepEqual(saved, ["dropship/u1/text-p1/0.jpg", "dropship/u1/text-p1/1.png", "dropship/u1/text-p2/0.jpg", "dropship/u1/text-p3/0.jpg", "dropship/u1/text-p3/1.png"]);
  assert.deepEqual(rules, ["p1", "p2"]);
  assert.equal(ResponseSchemas.commitListingProposals.safeParse(result).success, true);
});

test("commitListingProposals contract: proposals are DraftProposals, 1..60", () => {
  assert.equal(RequestSchemas.commitListingProposals.safeParse({ proposals: [proposal()] }).success, true);
  assert.equal(RequestSchemas.commitListingProposals.safeParse({ proposals: [] }).success, false);
  assert.equal(RequestSchemas.commitListingProposals.safeParse({ proposals: [{ title: "x" }] }).success, false);
});
