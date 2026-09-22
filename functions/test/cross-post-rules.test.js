/**
 * cross-post-rules.test.js — pure logic for the rule-based cross-posting
 * engine: rule matching (first-match-wins), the safe/whitelisted pricing
 * formula evaluator, and shipping-estimate date math. No Firestore/network —
 * see cross_post_rules.js's file header.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const {
  matchRule, matchesConditions, evaluatePricingFormula, computeShippingEstimates,
} = require("../cross_post_rules");

// ── matchRule / matchesConditions ───────────────────────────────────────

function rule(order, conditions, actions = {}) {
  return { order, conditions, actions };
}

test("matchRule: first-match-wins, ordered ascending by `order`, not declaration order", () => {
  const rules = [
    rule(2, { category: "jersey" }, { platforms: ["etsy"] }),
    rule(1, { category: "jersey" }, { platforms: ["ebay"] }),
  ];
  const product = { category: "jersey" };
  assert.deepEqual(matchRule(rules, product).actions.platforms, ["ebay"]);
});

test("matchRule: skips a non-matching rule and falls through to the next", () => {
  const rules = [
    rule(1, { category: "keyring" }, { platforms: ["ebay"] }),
    rule(2, { category: "jersey" }, { platforms: ["etsy"] }),
  ];
  const product = { category: "jersey" };
  assert.deepEqual(matchRule(rules, product).actions.platforms, ["etsy"]);
});

test("matchRule: no rule matches -> null (no automatic cross-posting)", () => {
  const rules = [rule(1, { category: "keyring" }, { platforms: ["ebay"] })];
  assert.equal(matchRule(rules, { category: "jersey" }), null);
});

test("matchRule: empty / missing rules list -> null", () => {
  assert.equal(matchRule([], { category: "jersey" }), null);
  assert.equal(matchRule(undefined, { category: "jersey" }), null);
});

test("matchesConditions: preOrder=true only matches a product with a preOrder object", () => {
  assert.equal(matchesConditions({ preOrder: true }, { preOrder: { deliveryEndAt: new Date() } }), true);
  assert.equal(matchesConditions({ preOrder: true }, { preOrder: null }), false);
  assert.equal(matchesConditions({ preOrder: true }, {}), false);
});

test("matchesConditions: preOrder=false only matches a non-pre-order product", () => {
  assert.equal(matchesConditions({ preOrder: false }, { preOrder: null }), true);
  assert.equal(matchesConditions({ preOrder: false }, { preOrder: { deliveryEndAt: new Date() } }), false);
});

test("matchesConditions: category / artistName are exact-match", () => {
  const conditions = { category: "jersey", artistName: "RM" };
  assert.equal(matchesConditions(conditions, { category: "jersey", artistName: "RM" }), true);
  assert.equal(matchesConditions(conditions, { category: "jersey", artistName: "Jin" }), false);
  assert.equal(matchesConditions(conditions, { category: "keyring", artistName: "RM" }), false);
});

test("matchesConditions: minPrice/maxPrice read product.sourcePrice", () => {
  const conditions = { minPrice: 20, maxPrice: 50 };
  assert.equal(matchesConditions(conditions, { sourcePrice: 30 }), true);
  assert.equal(matchesConditions(conditions, { sourcePrice: 10 }), false);
  assert.equal(matchesConditions(conditions, { sourcePrice: 60 }), false);
});

test("matchesConditions: minPrice/maxPrice fall back to listingPrice when sourcePrice is unset", () => {
  assert.equal(matchesConditions({ minPrice: 20 }, { listingPrice: 25 }), true);
  assert.equal(matchesConditions({ minPrice: 20 }, {}), false);
});

test("matchesConditions: every present condition must match (AND)", () => {
  const conditions = { preOrder: true, category: "jersey", minPrice: 20 };
  const good = { preOrder: { deliveryEndAt: new Date() }, category: "jersey", sourcePrice: 30 };
  assert.equal(matchesConditions(conditions, good), true);
  assert.equal(matchesConditions(conditions, { ...good, category: "keyring" }), false);
});

test("matchesConditions: an empty/missing conditions object matches everything", () => {
  assert.equal(matchesConditions({}, {}), true);
  assert.equal(matchesConditions(null, { category: "jersey" }), true);
});

// ── evaluatePricingFormula ───────────────────────────────────────────────

test("evaluatePricingFormula: '2x retail' example from the design conversation", () => {
  const formula = { mode: "max", terms: [{ factors: { retailPrice: 2 } }] };
  const inputs = { retailPrice: 40, costPrice: 40, estimatedShippingCost: 5, estimatedTax: 3 };
  assert.equal(evaluatePricingFormula(formula, inputs), 80);
});

test("evaluatePricingFormula: 'cost + tax + shipping + 10' example", () => {
  const formula = {
    mode: "max",
    terms: [{ factors: { costPrice: 1, estimatedShippingCost: 1, estimatedTax: 1 }, constant: 10 }],
  };
  const inputs = { retailPrice: 40, costPrice: 40, estimatedShippingCost: 5, estimatedTax: 3 };
  assert.equal(evaluatePricingFormula(formula, inputs), 40 + 5 + 3 + 10);
});

test("evaluatePricingFormula: 'price = max(2x retail, cost+tax+shipping+10)' picks the larger term", () => {
  const formula = {
    mode: "max",
    terms: [
      { factors: { retailPrice: 2 } },
      { factors: { costPrice: 1, estimatedShippingCost: 1, estimatedTax: 1 }, constant: 10 },
    ],
  };
  // 2x retail = 80; cost+ship+tax+10 = 58 -> max picks 80.
  assert.equal(
    evaluatePricingFormula(formula, { retailPrice: 40, costPrice: 40, estimatedShippingCost: 5, estimatedTax: 3 }),
    80,
  );
  // 2x retail = 20; cost+ship+tax+10 = 10+8+2+10=30 -> max picks 30.
  assert.equal(
    evaluatePricingFormula(formula, { retailPrice: 10, costPrice: 10, estimatedShippingCost: 8, estimatedTax: 2 }),
    30,
  );
});

test("evaluatePricingFormula: mode 'min' picks the smaller term", () => {
  const formula = {
    mode: "min",
    terms: [{ factors: { retailPrice: 2 } }, { factors: { retailPrice: 1 }, constant: 100 }],
  };
  // 2x20=40 vs 20+100=120 -> min picks 40.
  assert.equal(evaluatePricingFormula(formula, { retailPrice: 20 }), 40);
});

test("evaluatePricingFormula: a term with only a constant (no factors)", () => {
  const formula = { mode: "max", terms: [{ factors: {}, constant: 25 }] };
  assert.equal(evaluatePricingFormula(formula, {}), 25);
});

test("evaluatePricingFormula: multiple factors combine as a sum", () => {
  const formula = {
    mode: "max",
    terms: [{ factors: { retailPrice: 1.5, estimatedShippingCost: 2 }, constant: 1 }],
  };
  assert.equal(evaluatePricingFormula(formula, { retailPrice: 10, estimatedShippingCost: 3 }), 1.5 * 10 + 2 * 3 + 1);
});

test("evaluatePricingFormula: no terms -> 0", () => {
  assert.equal(evaluatePricingFormula({ mode: "max", terms: [] }, {}), 0);
  assert.equal(evaluatePricingFormula(undefined, {}), 0);
});

// ── computeShippingEstimates ─────────────────────────────────────────────

test("computeShippingEstimates: adds the domestic/international buffer to preOrder.deliveryEndAt", () => {
  const preOrder = { deliveryStartAt: new Date("2026-10-01T00:00:00Z"), deliveryEndAt: new Date("2026-10-10T00:00:00Z") };
  const { domesticEstimate, internationalEstimate } = computeShippingEstimates(preOrder, { domestic: 7, international: 30 });
  assert.equal(domesticEstimate.toISOString(), "2026-10-17T00:00:00.000Z");
  assert.equal(internationalEstimate.toISOString(), "2026-11-09T00:00:00.000Z");
});

test("computeShippingEstimates: uses deliveryEndAt, not deliveryStartAt, as the base", () => {
  const preOrder = { deliveryStartAt: new Date("2026-01-01T00:00:00Z"), deliveryEndAt: new Date("2026-02-01T00:00:00Z") };
  const { domesticEstimate } = computeShippingEstimates(preOrder, { domestic: 0, international: 0 });
  assert.equal(domesticEstimate.toISOString(), "2026-02-01T00:00:00.000Z");
});

test("computeShippingEstimates: not a pre-order -> both estimates null", () => {
  assert.deepEqual(computeShippingEstimates(null, { domestic: 7, international: 30 }), {
    domesticEstimate: null,
    internationalEstimate: null,
  });
});

test("computeShippingEstimates: pre-order with no deliveryEndAt -> both estimates null", () => {
  assert.deepEqual(computeShippingEstimates({ deliveryStartAt: new Date() }, { domestic: 7, international: 30 }), {
    domesticEstimate: null,
    internationalEstimate: null,
  });
});

test("computeShippingEstimates: reads a Firestore-Timestamp-like object via toDate()", () => {
  const fakeTimestamp = { toDate: () => new Date("2026-05-01T00:00:00Z") };
  const { domesticEstimate } = computeShippingEstimates({ deliveryEndAt: fakeTimestamp }, { domestic: 7, international: 30 });
  assert.equal(domesticEstimate.toISOString(), "2026-05-08T00:00:00.000Z");
});
