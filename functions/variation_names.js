"use strict";

// Variation dimension names. The Weverse importer used to call every single
// dimension "Style", so a shirt's S/M/L/XL went to eBay as Style. eBay's apparel
// categories refuse Style as a variation (25002 "Style is not allowed as a
// variation specific") and still require a Size, which then got the brand
// ("BTS is not a valid value for Size", 25129). Live failures 2026-11-26.

const SIZE_WORDS = new Set([
  "xxs", "xs", "s", "m", "l", "xl", "xxl", "xxxl", "2xl", "3xl", "4xl", "5xl",
  "small", "medium", "large", "x-large", "xx-large", "xxx-large", "extra large",
  "one size", "free", "free size", "f", "os",
]);

/** "M", "XL", "100", "M-L", "XL / XXL" → true; "Jimin", "Scarf" → false. */
function isSizeValue(value) {
  const v = String(value ?? "").trim().toLowerCase();
  if (!v) return false;
  if (SIZE_WORDS.has(v) || /^\d{2,3}$/.test(v)) return true;
  const parts = v.split(/\s*[-~/]\s*/).filter(Boolean);
  return parts.length > 1 && parts.every((p) => SIZE_WORDS.has(p) || /^\d{2,3}$/.test(p));
}

/** Every value is a size (and there is at least one). */
function looksLikeSizes(values) {
  const list = (values || []).map((x) => (x && typeof x === "object" ? x.value ?? x.name : x)).filter((x) => x != null && String(x).trim());
  return list.length > 0 && list.every(isSizeValue);
}

/**
 * The name each option goes to eBay under, for one category. The product doc keeps
 * its own names; only the eBay payload is renamed.
 * - an aspect eBay allows for variations in this category: kept;
 * - sizes → "Size", values all in the category's Color list → "Color";
 * - a name that is a category aspect eBay doesn't allow for variations (Style on
 *   apparel) → "Option" (a custom name eBay accepts, as the member jerseys show);
 * - anything else: kept (custom names are fine).
 * Two options never get the same name; the later one keeps its own.
 */
function ebayVariationNames(options = [], categoryAspects = []) {
  const byName = new Map(categoryAspects.map((a) => [String(a.name).toLowerCase(), a]));
  const ci = (s) => String(s).toLowerCase();
  const used = new Set();
  const out = {};
  for (const opt of options) {
    const name = String(opt?.name ?? "");
    const meta = byName.get(ci(name));
    let target = name;
    if (!(meta && meta.variationEnabled)) {
      const colors = byName.get("color")?.values || [];
      const values = opt?.values || [];
      if (looksLikeSizes(values)) target = "Size";
      else if (colors.length && values.length && values.every((v) => colors.some((c) => ci(c) === ci(v?.value ?? v)))) target = "Color";
      else if (meta) target = "Option";
    }
    if (used.has(ci(target))) target = name;
    used.add(ci(target));
    out[name] = target;
  }
  return out;
}

/**
 * One choice is no choice (user, 2026-11-27: "no need for Style for the scarf"):
 * an import with a single variant becomes a plain product, no options/variants.
 */
function dropSingleChoice({ options, variants }) {
  return Array.isArray(variants) && variants.length > 1 ? { options, variants } : { options: [], variants: [] };
}

module.exports = { isSizeValue, looksLikeSizes, ebayVariationNames, dropSingleChoice };
