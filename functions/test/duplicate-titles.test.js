/**
 * duplicate-titles.test.js — eBay's identical-item refusal and the "Title (n)" rule.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const D = require("../duplicate_titles");
const { _internal: E } = require("../ebay_listing");

const UID = "u1";
const JAEMIN = "Jaemin Purchase Bonus Photocard - NCT DREAM Seoul Pop Up Exclusive";

// The error exactly as eBay returned it on 2026-11-16 (function logs).
const liveError = () => Object.assign(new Error("eBay API error (400)"), {
  status: 400,
  ebayErrors: [{
    errorId: 25002, domain: "API_INVENTORY", subdomain: "Selling", category: "Request",
    message: `A user error has occurred. It looks like this listing is for an item you already have on eBay: ${JAEMIN} (147683278340). We don't allow listings for identical items from the same seller to appear on eBay at the same time. If you'd like to list more than one of the same item, create a multi-quantity fixed price listing.`,
    parameters: [
      { name: "0", value: JAEMIN }, { name: "1", value: "147683278340" },
      { name: "2", value: "http://pages.ebay.com/help/policies/listing-multi.html" },
      { name: "3", value: "147683278396" }, { name: "4", value: "6E91BA35-2A58-4350-8A1C-6A15C3FCEBFC" },
    ],
  }],
});

test("nextFreeTitle: file-system style (1), (2), … skipping taken ones, case-insensitive", () => {
  assert.equal(D.nextFreeTitle("Card", ["Card"]), "Card (1)");
  assert.equal(D.nextFreeTitle("Card", ["Card", "card (1)"]), "Card (2)");
  assert.equal(D.nextFreeTitle("Card (1)", ["Card", "Card (1)", "Card (3)"]), "Card (2)", "an existing suffix is replaced, not stacked");
});

test("fitTitle: a long title keeps its (n) suffix inside eBay's 80 characters", () => {
  const long = `${"x".repeat(85)} (2)`;
  const fitted = D.fitTitle(long, 80);
  assert.equal(fitted.length, 80);
  assert.ok(fitted.endsWith(" (2)"));
  assert.equal(D.fitTitle("short (1)"), "short (1)");
  assert.equal(D.fitTitle("y".repeat(90)).length, 80);
});

test("regression: the eBay title for a long renamed product still carries the suffix", () => {
  const { title } = E.ebayListingText({ title: `${"Photocard ".repeat(9)}(1)`, condition: "new" });
  assert.ok(title.length <= 80);
  assert.ok(title.endsWith(" (1)"));
});

test("ebayDuplicateOf: reads the live identical-item error; ignores the create-offer 25002", () => {
  assert.deepEqual(D.ebayDuplicateOf(liveError()), { existingListingId: "147683278340", existingTitle: JAEMIN });
  const offerExists = { ebayErrors: [{ errorId: 25002, message: "Offer entity already exists.", parameters: [{ name: "offerId", value: "9" }] }] };
  assert.equal(D.ebayDuplicateOf(offerExists), null);
  assert.equal(D.ebayDuplicateOf(new Error("x")), null);
});

test("resolveEbayDuplicate: another Wonni product owns the listing → rename to (1) on products and the iOS listing", async () => {
  const db = new FakeFirestore({
    products: {
      A: { userId: UID, title: JAEMIN, crossPostListingIds: { ebay: "147683278340" } },
      B: { userId: UID, title: JAEMIN },
      other: { userId: "someone-else", title: `${JAEMIN} (1)` },
    },
    listings: { B: { userId: UID, customTitle: JAEMIN } },
  });
  const r = await D.resolveEbayDuplicate(db, UID, "B", D.ebayDuplicateOf(liveError()));
  assert.deepEqual(r, { renamed: true, title: `${JAEMIN} (1)` }, "another user's titles don't count");
  assert.equal(db.peek("products", "B").title, `${JAEMIN} (1)`);
  assert.equal(db.peek("listings", "B").customTitle, `${JAEMIN} (1)`);
  assert.equal(db.peek("products", "A").title, JAEMIN, "the live one keeps its title");
});

test("resolveEbayDuplicate: a third copy becomes (2); a split-listing owner is found by its group ids", async () => {
  const db = new FakeFirestore({
    products: {
      A: { userId: UID, title: "Tee", ebayListings: [{ groupKey: "g", listingId: "111" }] },
      B: { userId: UID, title: "Tee (1)" },
      C: { userId: UID, title: "Tee" },
    },
  });
  const r = await D.resolveEbayDuplicate(db, UID, "C", { existingListingId: "111" });
  assert.equal(r.title, "Tee (2)");
});

test("resolveEbayDuplicate: listing not in Wonni → eBay marked failed with a readable reason", async () => {
  const db = new FakeFirestore({ products: { B: { userId: UID, title: JAEMIN, crossPostStatus: { mercari: "active" } } } });
  await assert.rejects(D.resolveEbayDuplicate(db, UID, "B", D.ebayDuplicateOf(liveError())),
    (e) => e.code === "already-exists" && /147683278340/.test(e.message) && /quantity/.test(e.message));
  const p = db.peek("products", "B");
  assert.equal(p.crossPostStatus.ebay, "failed");
  assert.equal(p.crossPostStatus.mercari, "active");
  assert.match(p.crossPostErrors.ebay, /isn't one of your Wonni products/);
  assert.equal(p.title, JAEMIN, "not renamed");
});

test("resolveEbayDuplicate: the product's own listing is never a reason to rename", async () => {
  const db = new FakeFirestore({ products: { A: { userId: UID, title: "Card", ebayListingId: "5" } } });
  await assert.rejects(D.resolveEbayDuplicate(db, UID, "A", { existingListingId: "5" }), /already has this product live/);
  assert.equal(db.peek("products", "A").title, "Card");
});
