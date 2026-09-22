/**
 * cross-post-apply.test.js — Firestore wiring for the rule-based cross-
 * posting engine (cross_post.js), against the in-memory FakeFirestore. No
 * emulator, no real eBay/Etsy calls — platform creation is injected via
 * `deps` (see cross_post.js `triggerPlatformCrossPost`'s doc comment), same
 * pattern as sales.js's `updateSaleStatusCore` `deps.refetchTakeHome`.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal } = require("../cross_post");

const {
  applyCrossPostRulesCore, maybeApplyCrossPostRulesAfterImport, hasCrossPostRules,
  resolvePricingInputs, loadPricingDefaults,
} = _internal;

const UID = "user_1";

function seedProduct(overrides = {}) {
  return {
    userId: UID,
    title: "RM Jersey",
    category: "jersey",
    artistName: "RM",
    sourcePrice: 40,
    listingPrice: null,
    preOrder: null,
    crossPostStatus: {},
    ...overrides,
  };
}

function crossPostRule(order, overrides = {}) {
  return {
    order,
    conditions: {},
    actions: {
      platforms: ["ebay"],
      shippingBufferDays: { domestic: 7, international: 30 },
      pricingFormula: { mode: "max", terms: [{ factors: { retailPrice: 2 } }] },
    },
    ...overrides,
  };
}

// ── hasCrossPostRules ────────────────────────────────────────────────────

test("hasCrossPostRules: false when the subcollection is empty", async () => {
  const db = new FakeFirestore();
  assert.equal(await hasCrossPostRules(db, UID), false);
});

test("hasCrossPostRules: true once a rule doc exists", async () => {
  const db = new FakeFirestore();
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1").set(crossPostRule(1));
  assert.equal(await hasCrossPostRules(db, UID), true);
});

// ── resolvePricingInputs / loadPricingDefaults ──────────────────────────

test("resolvePricingInputs: retailPrice and costPrice both read product.sourcePrice", () => {
  const inputs = resolvePricingInputs(seedProduct({ sourcePrice: 55 }), { estimatedShippingCost: 5, estimatedTax: 2 });
  assert.deepEqual(inputs, { retailPrice: 55, costPrice: 55, estimatedShippingCost: 5, estimatedTax: 2 });
});

test("loadPricingDefaults: falls back to 0/0 when the user has no crossPostPricingDefaults set", async () => {
  const db = new FakeFirestore({ users: { [UID]: {} } });
  assert.deepEqual(await loadPricingDefaults(db, UID), { estimatedShippingCost: 0, estimatedTax: 0 });
});

test("loadPricingDefaults: reads the per-user configured defaults", async () => {
  const db = new FakeFirestore({ users: { [UID]: { crossPostPricingDefaults: { estimatedShippingCost: 6, estimatedTax: 4 } } } });
  assert.deepEqual(await loadPricingDefaults(db, UID), { estimatedShippingCost: 6, estimatedTax: 4 });
});

// ── applyCrossPostRulesCore ──────────────────────────────────────────────

test("applyCrossPostRulesCore: no matching rule -> matched:false, product untouched", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct({ category: "keyring" }) } });
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1")
    .set(crossPostRule(1, { conditions: { category: "jersey" } }));

  const result = await applyCrossPostRulesCore(db, UID, "p1");
  assert.deepEqual(result, { matched: false, ruleId: null, listingPrice: null, platforms: {} });
  assert.equal(db.peek("products", "p1").listingPrice, null);
});

test("applyCrossPostRulesCore: matching rule computes listingPrice + shipping estimates and writes them", async () => {
  const preOrder = { deliveryStartAt: new Date("2026-10-01"), deliveryEndAt: new Date("2026-10-10") };
  const db = new FakeFirestore({ products: { p1: seedProduct({ preOrder, sourcePrice: 40 }) } });
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1").set(crossPostRule(1, {
    conditions: { preOrder: true },
    actions: {
      platforms: ["ebay", "etsy"],
      shippingBufferDays: { domestic: 7, international: 30 },
      pricingFormula: { mode: "max", terms: [{ factors: { retailPrice: 2 } }] },
    },
  }));

  const ebayCreateListingCore = async () => ({ listingId: "ebay-1" });
  const etsyCreateListingCore = async () => ({ success: true, listingId: "etsy-1" });

  const result = await applyCrossPostRulesCore(db, UID, "p1", { ebayCreateListingCore, etsyCreateListingCore });

  assert.equal(result.matched, true);
  assert.equal(result.ruleId, "r1");
  assert.equal(result.listingPrice, 80); // 2 x 40 retail
  assert.deepEqual(result.platforms, { ebay: "posted", etsy: "posted" });

  const stored = db.peek("products", "p1");
  assert.equal(stored.listingPrice, 80);
  assert.equal(stored.appliedCrossPostRuleId, "r1");
  assert.equal(stored.shippingEstimate.domestic.toISOString(), "2026-10-17T00:00:00.000Z");
  assert.equal(stored.shippingEstimate.international.toISOString(), "2026-11-09T00:00:00.000Z");
});

test("applyCrossPostRulesCore: first-match-wins across the loaded rules (order, not doc-write order)", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct() } });
  const rulesRef = db.collection("users").doc(UID).collection("crossPostRules");
  // Written out of `order` sequence on purpose.
  await rulesRef.doc("second").set(crossPostRule(2, {
    actions: { platforms: ["etsy"], shippingBufferDays: { domestic: 0, international: 0 }, pricingFormula: { mode: "max", terms: [{ factors: {}, constant: 5 }] } },
  }));
  await rulesRef.doc("first").set(crossPostRule(1, {
    actions: { platforms: ["ebay"], shippingBufferDays: { domestic: 0, international: 0 }, pricingFormula: { mode: "max", terms: [{ factors: {}, constant: 9 }] } },
  }));

  const noop = async () => ({});
  const result = await applyCrossPostRulesCore(db, UID, "p1", { ebayCreateListingCore: noop, etsyCreateListingCore: noop });
  assert.equal(result.ruleId, "first");
  assert.equal(result.listingPrice, 9);
  assert.deepEqual(result.platforms, { ebay: "posted" });
});

test("applyCrossPostRulesCore: a platform failure is recorded, never thrown, and doesn't block other platforms", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct() } });
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1").set(crossPostRule(1, {
    actions: {
      platforms: ["ebay", "etsy"],
      shippingBufferDays: { domestic: 0, international: 0 },
      pricingFormula: { mode: "max", terms: [{ factors: { retailPrice: 1 } }] },
    },
  }));

  const ebayCreateListingCore = async () => { throw new Error("eBay down"); };
  const etsyCreateListingCore = async () => ({ success: true, listingId: "etsy-1" });

  const result = await applyCrossPostRulesCore(db, UID, "p1", { ebayCreateListingCore, etsyCreateListingCore });
  assert.deepEqual(result.platforms, { ebay: "failed", etsy: "posted" });
  // The product write (listing price / shipping estimate) still landed.
  assert.equal(db.peek("products", "p1").listingPrice, 40);
});

test("applyCrossPostRulesCore: mercari/tiktok platforms are 'skipped' (no automatic create flow yet)", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct() } });
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1").set(crossPostRule(1, {
    actions: {
      platforms: ["mercari", "tiktok"],
      shippingBufferDays: { domestic: 0, international: 0 },
      pricingFormula: { mode: "max", terms: [{ factors: { retailPrice: 1 } }] },
    },
  }));
  const result = await applyCrossPostRulesCore(db, UID, "p1");
  assert.deepEqual(result.platforms, { mercari: "skipped", tiktok: "skipped" });
});

test("applyCrossPostRulesCore: unknown product -> not-found", async () => {
  const db = new FakeFirestore();
  await assert.rejects(() => applyCrossPostRulesCore(db, UID, "missing"), /not-found|Product not found/);
});

test("applyCrossPostRulesCore: another user's product -> permission-denied", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct({ userId: "someone_else" }) } });
  await assert.rejects(() => applyCrossPostRulesCore(db, UID, "p1"), /permission-denied|Not your product/);
});

// ── maybeApplyCrossPostRulesAfterImport (the weverseImportProduct /
//    weverseBulkImportProducts post-import hook) ─────────────────────────

test("maybeApplyCrossPostRulesAfterImport: no-op when the user has no crossPostRules configured", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct() } });
  const result = await maybeApplyCrossPostRulesAfterImport(db, UID, "p1");
  assert.equal(result, null);
  // Untouched — same product doc as written by the import itself.
  assert.equal(db.peek("products", "p1").listingPrice, null);
  assert.equal(db.peek("products", "p1").appliedCrossPostRuleId, undefined);
});

test("maybeApplyCrossPostRulesAfterImport: runs the engine once the user has configured a rule", async () => {
  const db = new FakeFirestore({ products: { p1: seedProduct() } });
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1").set(crossPostRule(1));
  const result = await maybeApplyCrossPostRulesAfterImport(db, UID, "p1", { ebayCreateListingCore: async () => ({}) });
  assert.equal(result.matched, true);
  assert.equal(db.peek("products", "p1").listingPrice, 80);
});

test("maybeApplyCrossPostRulesAfterImport: never throws, even if the engine itself fails", async () => {
  const db = new FakeFirestore(); // no product p1 at all -> applyCrossPostRulesCore would throw not-found
  await db.collection("users").doc(UID).collection("crossPostRules").doc("r1").set(crossPostRule(1));
  const result = await maybeApplyCrossPostRulesAfterImport(db, UID, "p1");
  assert.equal(result, null);
});
