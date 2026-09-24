/**
 * contracts/cross_post_rules.js — the rule-based cross-posting engine.
 *
 * A user's rules live at `users/{uid}/crossPostRules/{ruleId}`, each an
 * ordered (`order`) `{ conditions, actions }` pair. `cross_post_rules.js`'s
 * `matchRule` evaluates them in ascending `order` and returns the FIRST rule
 * whose conditions all match (first-match-wins, not a merge — see that
 * file's header comment for why). `applyCrossPostRules` (cross_post.js) is
 * the callable that loads a product + its owner's rules, runs the match, and
 * (on a match) computes the listing price + shipping estimates and triggers
 * cross-posting.
 *
 * ── PricingTerm: a closed, whitelisted structure — NEVER an eval'd string ──
 * A rule's `actions.pricingFormula` is built from `PricingTerm`s, each a
 * linear combination over a FIXED whitelist of known numeric inputs
 * (`retailPrice`, `costPrice`, `estimatedShippingCost`, `estimatedTax` — see
 * `cross_post_rules.js`'s `PRICING_INPUT_KEYS`) plus a constant:
 *
 *   { factors: { retailPrice: 2 } }
 *     → "2 × retail price"
 *   { factors: { costPrice: 1, estimatedShippingCost: 1, estimatedTax: 1 }, constant: 10 }
 *     → "cost + shipping + tax + 10"
 *
 * `PricingFormula.mode` ("max" | "min") picks between every term's evaluated
 * value — `max(2x retail, cost+tax+shipping+10)` is `mode: "max"` with both
 * terms above. This is intentionally a zod-validated, non-extensible shape:
 * `factors` can ONLY contain the whitelisted keys (any other key fails
 * validation), and the evaluator (`evaluatePricingFormula`) only ever does
 * fixed arithmetic over them — no `eval`, `new Function(...)`, or expression
 * parser touches user-authored data anywhere in this feature.
 *
 * ── Where the pricing inputs come from (see cross_post.js `resolvePricingInputs`) ──
 * `retailPrice` / `costPrice` both read `product.sourcePrice` — the Weverse
 * listed price captured at import (`weverse_product.js` `mapSaleToProduct` →
 * `product_schema.js` `buildNewProductDoc`'s `sourcePrice`). The codebase has
 * only this one source-side money field; there's no separate "cost you
 * actually paid" field distinct from the Weverse price, so both whitelisted
 * inputs deliberately resolve to the same number today. `estimatedShippingCost`
 * and `estimatedTax` have NO existing field anywhere in the schema (verified
 * against product_schema.js, weverse_product.js and web/src/pages/
 * ProductDetail.jsx — the closest things, `handlingTimeDays` and
 * `shippingLabelCost`, are a listing-prep lead time and a POST-SALE actual
 * label cost respectively, not a pre-listing cost estimate). Rather than
 * silently treating them as 0, they default to a per-user configurable flat
 * placeholder stored at `users/{uid}.crossPostPricingDefaults` — see
 * `CrossPostPricingDefaultsSchema` below — which a future settings UI can
 * expose, same pattern as the existing `tiktokFeeRate` user setting
 * (user_settings.js `updateSettings`).
 */

const { z } = require("zod");
const { ProductIdSchema, MoneySchema, CrossPostPlatformSchema, OkResponseSchema } = require("./_shared");

// ── Conditions ───────────────────────────────────────────────────────────

/** All PRESENT fields must match (AND); every field is optional — an absent
 *  field imposes no constraint. See cross_post_rules.js `matchesConditions`. */
const CrossPostConditionsSchema = z.object({
  /** true ⇒ only matches when `product.preOrder != null`; false ⇒ only a
   *  non-pre-order product; omitted ⇒ no constraint either way. */
  preOrder: z.boolean().nullish(),
  category: z.string().min(1).nullish(),
  artistName: z.string().min(1).nullish(),
  /** Compared against `product.sourcePrice` (falling back to `listingPrice`
   *  when unset) — see cross_post_rules.js `conditionPrice`. */
  minPrice: z.number().nonnegative().nullish(),
  maxPrice: z.number().nonnegative().nullish(),
}).default({});

// ── Actions ──────────────────────────────────────────────────────────────

/** The 4 platforms this engine can trigger a cross-post to. A subset of
 *  `CrossPostPlatformSchema` — `wonni` (the first-party marketplace) isn't a
 *  "cross-post" target and isn't included here. */
const CrossPostRulePlatformSchema = CrossPostPlatformSchema.exclude(["wonni"]);

const ShippingBufferDaysSchema = z.object({
  domestic: z.number().int().min(0).max(365),
  international: z.number().int().min(0).max(365),
});

/** A linear combination over the whitelisted numeric inputs, plus a constant.
 *  See file header — this is interpreted by fixed arithmetic, NEVER eval'd. */
const PricingTermSchema = z.object({
  factors: z.record(
    z.enum(["retailPrice", "costPrice", "estimatedShippingCost", "estimatedTax"]),
    z.number(),
  ).default({}),
  constant: z.number().default(0),
});

const PricingFormulaSchema = z.object({
  mode: z.enum(["max", "min"]),
  terms: z.array(PricingTermSchema).min(1).max(10),
});

const CrossPostActionsSchema = z.object({
  platforms: z.array(CrossPostRulePlatformSchema).min(1),
  shippingBufferDays: ShippingBufferDaysSchema,
  pricingFormula: PricingFormulaSchema,
});

// ── Rule doc (users/{uid}/crossPostRules/{ruleId}) ──────────────────────

const CrossPostRuleSchema = z.object({
  /** Evaluation order, ascending. First matching rule wins — see
   *  cross_post_rules.js's file header for why this isn't a merge. */
  order: z.number(),
  conditions: CrossPostConditionsSchema,
  actions: CrossPostActionsSchema,
});

// ── Per-user pricing-input defaults (users/{uid}.crossPostPricingDefaults) ─
// Placeholder inputs for the two whitelisted pricing terms with no existing
// source field anywhere in the schema — see file header. Flat USD amounts,
// same shape as the existing per-user `tiktokFeeRate` setting.

const CrossPostPricingDefaultsSchema = z.object({
  estimatedShippingCost: MoneySchema.default(0),
  estimatedTax: MoneySchema.default(0),
});

// ── applyCrossPostRules ──────────────────────────────────────────────────

const ApplyCrossPostRulesRequestSchema = z.object({
  productId: ProductIdSchema,
});

const ApplyCrossPostRulesResponseSchema = z.object({
  matched: z.boolean(),
  ruleId: z.string().nullable(),
  listingPrice: z.number().nullable(),
  platforms: z.record(z.string(), z.string()).default({}),
});

module.exports = {
  CrossPostConditionsSchema,
  CrossPostRulePlatformSchema,
  ShippingBufferDaysSchema,
  PricingTermSchema,
  PricingFormulaSchema,
  CrossPostActionsSchema,
  CrossPostRuleSchema,
  CrossPostPricingDefaultsSchema,
  ApplyCrossPostRulesRequestSchema,
  ApplyCrossPostRulesResponseSchema,
  contracts: [
    {
      name: "applyCrossPostRules",
      summary: "Run a user's ordered cross-post rules against a product; on the first match, compute the listing price + shipping estimates and trigger cross-posting to the matched platforms.",
      request: ApplyCrossPostRulesRequestSchema,
      response: ApplyCrossPostRulesResponseSchema,
    },
  ],
};
