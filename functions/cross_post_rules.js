/**
 * cross_post_rules.js — pure rule-matching + pricing-formula + shipping-
 * estimate logic for the rule-based cross-posting engine.
 *
 * This module is deliberately Firestore/network-free (same discipline as
 * weverse_duplicate_detection.js) so every branch here is unit-testable with
 * plain JS objects in/out. The Firestore load + write + per-platform
 * cross-post trigger wiring lives in cross_post.js.
 *
 * See contracts/cross_post_rules.js for the `users/{uid}/crossPostRules/{id}`
 * doc shape this operates on.
 *
 * ── Rule evaluation: first-match-wins ───────────────────────────────────────
 * `matchRule` returns the FIRST rule (by ascending `order`) whose conditions
 * all match — never a merge of every matching rule's actions. This is a
 * deliberate scope decision, not an oversight: merging platforms/pricing from
 * several matched rules raises real ambiguity (whose shippingBufferDays wins?
 * do pricing formulas average, or does the highest win?) that first-match-wins
 * sidesteps entirely. A user who wants rule B to also apply writes its
 * conditions to be mutually exclusive with rule A, or puts the more specific
 * rule first. No match at all → no cross-posting happens automatically; the
 * existing fully-manual per-listing cross-post flow is untouched.
 *
 * ── Pricing formula: closed, whitelisted structure — NEVER eval ───────────
 * `evaluatePricingFormula` interprets a `PricingFormula` (mode + terms), each
 * `PricingTerm` a linear combination over a small whitelist of known numeric
 * inputs (`PRICING_INPUT_KEYS`) plus a constant. This is intentionally NOT a
 * string expression: nothing here ever parses or executes user-authored code
 * (no `eval`, no `Function(...)`, no expression-language interpreter) — every
 * shape a rule can express is enumerated by contracts/cross_post_rules.js's
 * zod schema and interpreted by fixed arithmetic below.
 *
 *   "price = 2x retail"                       → { mode: "max", terms: [
 *     { factors: { retailPrice: 2 } },
 *   ]}
 *   "price = max(2x retail, cost+tax+shipping+10)" → { mode: "max", terms: [
 *     { factors: { retailPrice: 2 } },
 *     { factors: { costPrice: 1, estimatedShippingCost: 1, estimatedTax: 1 }, constant: 10 },
 *   ]}
 */

"use strict";

/** Closed whitelist of numeric inputs a `PricingTerm.factors` may reference.
 *  See contracts/cross_post_rules.js and cross_post.js's `resolvePricingInputs`
 *  for where each of these actually comes from on a real product. */
const PRICING_INPUT_KEYS = ["retailPrice", "costPrice", "estimatedShippingCost", "estimatedTax"];

// ── Rule matching ────────────────────────────────────────────────────────

/** The retail/source price a rule's `minPrice`/`maxPrice` condition checks
 *  against — the same field the pricing formula's `retailPrice` input reads
 *  (see cross_post.js `resolvePricingInputs`), so a rule authored around
 *  "under $50" lines up with the number the formula itself uses. Falls back
 *  to `listingPrice` when `sourcePrice` isn't set (e.g. a non-Weverse product
 *  with no cost field but an existing manually-set list price). */
function conditionPrice(product) {
  const sourcePrice = Number(product?.sourcePrice);
  if (Number.isFinite(sourcePrice)) return sourcePrice;
  const listingPrice = Number(product?.listingPrice);
  return Number.isFinite(listingPrice) ? listingPrice : null;
}

/** Does `product` satisfy every PRESENT condition in `conditions`? (AND —
 *  an omitted/null condition field imposes no constraint.) */
function matchesConditions(conditions, product) {
  const c = conditions || {};

  if (c.preOrder != null) {
    const hasPreOrder = product?.preOrder != null;
    if (c.preOrder !== hasPreOrder) return false;
  }
  if (c.category != null) {
    if ((product?.category ?? null) !== c.category) return false;
  }
  if (c.artistName != null) {
    if ((product?.artistName ?? null) !== c.artistName) return false;
  }
  if (c.minPrice != null || c.maxPrice != null) {
    const price = conditionPrice(product);
    if (price == null) return false;
    if (c.minPrice != null && price < c.minPrice) return false;
    if (c.maxPrice != null && price > c.maxPrice) return false;
  }

  return true;
}

/**
 * First rule (ordered ascending by `order`) whose conditions all match
 * `product`, or null when nothing matches. See file header for why this is
 * first-match-wins rather than a merge of every matching rule.
 *
 * @param {Array<{order: number, conditions: object, actions: object}>} rules
 * @param {object} product
 * @returns {object | null}
 */
function matchRule(rules, product) {
  if (!Array.isArray(rules) || rules.length === 0) return null;
  const ordered = [...rules].sort((a, b) => (Number(a?.order) || 0) - (Number(b?.order) || 0));
  for (const rule of ordered) {
    if (matchesConditions(rule?.conditions, product)) return rule;
  }
  return null;
}

// ── Pricing formula ──────────────────────────────────────────────────────

/** Evaluate one `PricingTerm` (a linear combination over the whitelist + a
 *  constant) against resolved numeric `inputs`. Unknown/non-whitelisted keys
 *  in `factors` are simply never read — the whitelist loop below only ever
 *  looks at `PRICING_INPUT_KEYS`, so there's no way for an extra key to do
 *  anything even if it somehow got past the zod schema. */
function evaluateTerm(term, inputs) {
  const factors = term?.factors || {};
  let total = Number(term?.constant) || 0;
  for (const key of PRICING_INPUT_KEYS) {
    const factor = factors[key];
    if (factor == null) continue;
    const value = Number(inputs?.[key]) || 0;
    total += Number(factor) * value;
  }
  return total;
}

/**
 * Evaluate a `PricingFormula` (`{ mode: "max"|"min", terms: PricingTerm[] }`)
 * against resolved numeric `inputs` (`{ retailPrice, costPrice,
 * estimatedShippingCost, estimatedTax }`). `mode` picks the max or min across
 * every term's evaluated value. Returns 0 for a formula with no terms.
 *
 * @param {{mode: "max"|"min", terms: object[]}} formula
 * @param {{retailPrice?: number, costPrice?: number, estimatedShippingCost?: number, estimatedTax?: number}} inputs
 * @returns {number}
 */
function evaluatePricingFormula(formula, inputs) {
  const terms = Array.isArray(formula?.terms) ? formula.terms : [];
  if (!terms.length) return 0;
  const values = terms.map((term) => evaluateTerm(term, inputs));
  return formula?.mode === "min" ? Math.min(...values) : Math.max(...values);
}

// ── Shipping estimates ───────────────────────────────────────────────────

function toDate(value) {
  if (value == null) return null;
  if (value instanceof Date) return value;
  // Firestore Timestamp (real or the FakeFirestore's plain Date substitute).
  if (typeof value.toDate === "function") return value.toDate();
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

function addDays(date, days) {
  const d = new Date(date.getTime());
  d.setDate(d.getDate() + (Number(days) || 0));
  return d;
}

/**
 * Add the rule's handling buffer to the Weverse pre-order delivery estimate
 * (`preOrder.deliveryEndAt` — the LATEST end of Weverse's own delivery
 * window, per weverse_product.js `mapSaleToProduct`; `deliveryStartAt` is
 * intentionally not used here, since "add a week for handling" means padding
 * the latest/worst-case date, not the earliest). Domestic and international
 * get their own buffer, per `shippingBufferDays.domestic` /
 * `.international`.
 *
 * Not a pre-order (or missing/unparseable `deliveryEndAt`) → both estimates
 * are null; there's no source date to add a buffer to.
 *
 * @param {{deliveryStartAt?: any, deliveryEndAt?: any} | null} preOrder
 * @param {{domestic: number, international: number}} shippingBufferDays
 * @returns {{domesticEstimate: Date | null, internationalEstimate: Date | null}}
 */
function computeShippingEstimates(preOrder, shippingBufferDays) {
  const base = toDate(preOrder?.deliveryEndAt);
  if (!base) return { domesticEstimate: null, internationalEstimate: null };

  return {
    domesticEstimate: addDays(base, shippingBufferDays?.domestic ?? 0),
    internationalEstimate: addDays(base, shippingBufferDays?.international ?? 0),
  };
}

module.exports = {
  PRICING_INPUT_KEYS,
  matchesConditions,
  matchRule,
  evaluateTerm,
  evaluatePricingFormula,
  computeShippingEstimates,
};
