/**
 * cross_post.js — Firestore/platform wiring for the rule-based cross-posting
 * engine. Pure matching/pricing/shipping-date logic lives in
 * cross_post_rules.js (see that file's header for the first-match-wins and
 * closed-pricing-formula design notes); this file loads a product + a user's
 * `users/{uid}/crossPostRules` docs, runs the match, writes the computed
 * listing price + shipping estimates onto the product, and best-effort
 * triggers cross-posting to each platform the matched rule names.
 *
 * `applyCrossPostRulesCore` is exported separately from the `onCall` wrapper
 * (same split as `recordSale`/`recordSaleCore` in sales.js) so
 * weverse_product.js / weverse_bulk_import.js can call it directly as an
 * automatic, best-effort post-import step without an HTTP round-trip.
 */

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { validated } = require("./contracts");
const { matchRule, evaluatePricingFormula, computeShippingEstimates } = require("./cross_post_rules");
const { EBAY_SECRETS } = require("./sales");
const { geminiApiKey } = require("./gemini_identify");

/**
 * Load this user's ordered cross-post rules. No Firestore composite index is
 * needed — `crossPostRules` is a small per-user subcollection, so sorting by
 * `order` client-side (same as `matchRule` does anyway) is simpler than
 * requiring an `orderBy` index.
 */
async function loadCrossPostRules(db, uid) {
  const snap = await db.collection("users").doc(uid).collection("crossPostRules").get();
  return snap.docs.map((doc) => ({ id: doc.id, ...doc.data() }));
}

/** Does this user have at least one cross-post rule configured? Cheap
 *  existence check used to gate the automatic post-import hook — see
 *  weverse_product.js / weverse_bulk_import.js — so nothing changes for a
 *  user who hasn't set any rules up. */
async function hasCrossPostRules(db, uid) {
  const snap = await db.collection("users").doc(uid).collection("crossPostRules").limit(1).get();
  return !snap.empty;
}

/**
 * Resolve the whitelisted pricing-formula inputs for a product. `retailPrice`
 * and `costPrice` both read `product.sourcePrice` (see contracts/
 * cross_post_rules.js's file header for why — it's the only source-side
 * money field the schema has). `estimatedShippingCost` / `estimatedTax` have
 * no product-level field at all, so they fall back to this user's
 * `crossPostPricingDefaults` (defaulting to 0 if the user never set one —
 * documented, not silent, via contracts/cross_post_rules.js).
 */
function resolvePricingInputs(product, pricingDefaults) {
  const sourcePrice = Number(product?.sourcePrice) || 0;
  return {
    retailPrice: sourcePrice,
    costPrice: sourcePrice,
    estimatedShippingCost: Number(pricingDefaults?.estimatedShippingCost) || 0,
    estimatedTax: Number(pricingDefaults?.estimatedTax) || 0,
  };
}

async function loadPricingDefaults(db, uid) {
  const snap = await db.collection("users").doc(uid).get();
  const defaults = snap.exists ? snap.data()?.crossPostPricingDefaults : null;
  return {
    estimatedShippingCost: Number(defaults?.estimatedShippingCost) || 0,
    estimatedTax: Number(defaults?.estimatedTax) || 0,
  };
}

/**
 * Trigger cross-posting to one platform. Best-effort — mirrors sales.js
 * `cascade()`'s per-platform try/catch: a failure on one platform is
 * recorded in the returned outcome, never thrown, so it can't block the
 * other platforms or the caller.
 *
 * eBay/Etsy: call the extracted `*CreateListingCore` directly (no HTTP
 * round-trip between Cloud Functions — see ebay_listing.js /
 * etsy_listing.js). Mercari has no listing-creation API at all (every other
 * Mercari write path in this codebase — sales.js `applyMercariFlags` — is a
 * manual-flag flow for the same reason); TikTok's create flow needs
 * additional inputs (category id, etc.) this rule-driven trigger doesn't
 * have on hand, so both are left "skipped" — a deliberate, documented scope
 * cut, same as sales.js cascade's own `// TODO: tiktokUpdateListing …`.
 */
async function triggerPlatformCrossPost(platform, uid, productId, deps = {}) {
  try {
    if (platform === "ebay") {
      // `deps.ebayCreateListingCore` defaults to the real core, lazily
      // required to dodge a require cycle (same reasoning as sale_poller.js's
      // `refetchTakeHome` injection in sales.js's `updateSaleStatusCore`) —
      // tests inject a fake instead of hitting Firestore/the eBay API.
      const core = deps.ebayCreateListingCore ?? require("./ebay_listing")._internal.ebayCreateListingCore;
      await core(uid, productId);
      return "posted";
    }
    if (platform === "etsy") {
      const core = deps.etsyCreateListingCore ?? require("./etsy_listing")._internal.etsyCreateListingCore;
      await core(uid, { productId });
      return "posted";
    }
    if (platform === "mercari" || platform === "tiktok") {
      return "skipped";
    }
    return "skipped";
  } catch (e) {
    console.error(`[applyCrossPostRules] ${platform} failed for ${productId}:`, e.message);
    return "failed";
  }
}

/**
 * Core rule application. Shared by the `applyCrossPostRules` callable and the
 * automatic post-import hook (weverse_product.js / weverse_bulk_import.js).
 * `uid`/`productId` are assumed already validated by the caller.
 *
 * @returns {Promise<{matched: boolean, ruleId: string|null, listingPrice: number|null, platforms: Record<string,string>}>}
 */
async function applyCrossPostRulesCore(db, uid, productId, deps = {}) {
  const productRef = db.collection("products").doc(productId);
  const productSnap = await productRef.get();
  if (!productSnap.exists) throw new HttpsError("not-found", "Product not found.");
  const product = productSnap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

  const rules = await loadCrossPostRules(db, uid);
  const rule = matchRule(rules, product);
  if (!rule) {
    return { matched: false, ruleId: null, listingPrice: null, platforms: {} };
  }

  const pricingDefaults = await loadPricingDefaults(db, uid);
  const inputs = resolvePricingInputs(product, pricingDefaults);
  const listingPrice = Math.round(evaluatePricingFormula(rule.actions?.pricingFormula, inputs) * 100) / 100;

  const { domesticEstimate, internationalEstimate } = computeShippingEstimates(
    product.preOrder ?? null,
    rule.actions?.shippingBufferDays,
  );

  // Whole-doc-safe merge write — no dotted `variants.N.x`-style paths, same
  // convention as every other product write in this codebase (see sales.js's
  // "NEVER a dotted path" comments).
  await productRef.set({
    listingPrice,
    shippingEstimate: {
      domestic: domesticEstimate,
      international: internationalEstimate,
    },
    appliedCrossPostRuleId: rule.id ?? null,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  const platforms = Array.isArray(rule.actions?.platforms) ? rule.actions.platforms : [];
  const outcomes = {};
  for (const platform of platforms) {
    outcomes[platform] = await triggerPlatformCrossPost(platform, uid, productId, deps);
  }

  return { matched: true, ruleId: rule.id ?? null, listingPrice, platforms: outcomes };
}

/**
 * Automatic, best-effort post-import hook for weverse_product.js /
 * weverse_bulk_import.js. NEVER throws — an import must succeed regardless
 * of what the cross-post engine does — and only runs at all when the user
 * has at least one `crossPostRules` doc configured, so a user who hasn't set
 * any rules up sees zero behavior change from before this feature existed.
 */
async function maybeApplyCrossPostRulesAfterImport(db, uid, productId, deps = {}) {
  try {
    if (!(await hasCrossPostRules(db, uid))) return null;
    return await applyCrossPostRulesCore(db, uid, productId, deps);
  } catch (e) {
    console.error(`[maybeApplyCrossPostRulesAfterImport] ${productId}:`, e.message);
    return null;
  }
}

exports.applyCrossPostRules = onCall(
  { secrets: [...EBAY_SECRETS, geminiApiKey], timeoutSeconds: 120 },
  validated("applyCrossPostRules", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return applyCrossPostRulesCore(admin.firestore(), uid, data.productId);
  }),
);

exports._internal = {
  loadCrossPostRules,
  hasCrossPostRules,
  resolvePricingInputs,
  loadPricingDefaults,
  triggerPlatformCrossPost,
  applyCrossPostRulesCore,
  maybeApplyCrossPostRulesAfterImport,
};
exports.maybeApplyCrossPostRulesAfterImport = maybeApplyCrossPostRulesAfterImport;
