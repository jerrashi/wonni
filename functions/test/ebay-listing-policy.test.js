/**
 * ebay-listing-policy.test.js — the eBay copy of a used item's title and
 * description never says "like new" (eBay error 25019, live 2026-10-16), and
 * that refusal reaches the client as a readable error.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

process.env.EBAY_CLIENT_ID = "x";
process.env.EBAY_CLIENT_SECRET = "y";

const { _internal } = require("../ebay_listing");
const { sanitizeEbayText, ebayListingText, ebayPolicyError } = _internal;

test("sanitizeEbayText: 'like new' becomes 'excellent' for used items, case and article preserved; new items untouched", () => {
  assert.equal(sanitizeEbayText("TORRAS Case for iPhone 16 Pro Max Blue - Like New", "LIKE_NEW"), "TORRAS Case for iPhone 16 Pro Max Blue - Excellent");
  assert.equal(sanitizeEbayText("Like new in box. The item is in like-new condition. LIKE NEW!", "USED_GOOD"), "Excellent in box. The item is in excellent condition. EXCELLENT!");
  assert.equal(sanitizeEbayText("This is a like new copy of Lemonade", "LIKE_NEW"), "This is an excellent copy of Lemonade");
  assert.equal(sanitizeEbayText("Brand new, sealed. Like new box.", "NEW"), "Brand new, sealed. Like new box.");
  assert.equal(sanitizeEbayText("Like-new", "NEW_OTHER"), "Like-new");
  assert.equal(sanitizeEbayText("Unlike newcomers, this one is dislike newest", "USED_GOOD"), "Unlike newcomers, this one is dislike newest", "only the whole phrase");
  assert.equal(sanitizeEbayText("", "USED_GOOD"), "");
  assert.equal(sanitizeEbayText(undefined, "USED_GOOD"), "");
});

test("ebayListingText: title capped at 80 after the rewrite; condition read off the product", () => {
  const used = ebayListingText({ title: "X".repeat(78) + " Like New", description: "Like new.", condition: "likeNew" });
  assert.equal(used.title.length, 80);
  assert.equal(used.title.startsWith("X".repeat(78) + " E"), true);
  assert.equal(used.description, "Excellent.");
  const fresh = ebayListingText({ title: "Sealed Like New Box", description: "Like new.", condition: "new" });
  assert.equal(fresh.title, "Sealed Like New Box");
});

test("ebayPolicyError: 25019 → failed-precondition with eBay's explanation, HTML stripped; other errors pass through", () => {
  const e = new Error("eBay API error (400)");
  e.ebayErrors = [{ errorId: 25019, message: "Cannot revise listing.", parameters: [{ name: "0", value: "We don&rsquo;t allow phrases such as &quot;like new&quot; in your title.<br />\n<br />\nMake sure your listing follows our <a href=\"x\">policy</a>." }] }];
  const mapped = ebayPolicyError(e);
  assert.equal(mapped.code, "failed-precondition");
  assert.equal(mapped.message, `eBay refused this listing: We don't allow phrases such as "like new" in your title. Make sure your listing follows our policy.`);
  const other = new Error("x");
  other.ebayErrors = [{ errorId: 25001 }];
  assert.equal(ebayPolicyError(other), null);
  assert.equal(ebayPolicyError(new Error("plain")), null);
});
