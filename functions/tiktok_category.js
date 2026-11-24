/**
 * tiktok_category.js — category choice, category-required attributes and
 * category rules for a TikTok Shop post (API 202309, through tiktok_client).
 *
 * - Category: the user's pick (`categoryId`), else the product's remembered
 *   `tiktokCategoryId`, else TikTok's own recommendation from the title
 *   (POST /product/202309/categories/recommend).
 * - Attributes: GET /product/202309/categories/{id}/attributes. Every required
 *   PRODUCT_PROPERTY is filled from what the product already knows (brand, the
 *   item specifics the AI / sell-similar filled, eBay aspects): a listed value
 *   when one matches, the typed value when the attribute is customizable, else a
 *   neutral listed value ("Other", "Not Applicable", …). Optional attributes go
 *   only when they match a listed value. SALES_PROPERTY (variations) is the SKU
 *   builder's job. TikTok spells the flag `is_requried` in its samples; both
 *   spellings are read.
 * - Rules: GET /product/202309/categories/{id}/rules. A category that needs a
 *   certification or a size chart fails with a readable reason before anything
 *   is posted (Wonni has neither field).
 */

"use strict";

const { HttpsError } = require("firebase-functions/v2/https");

const NEUTRAL_VALUES = ["other", "others", "not applicable", "n/a", "none", "not specified", "unbranded", "no brand", "unknown", "multicolor", "mixed"];

const norm = (s) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

/** Everything the product says about itself, as { lowercased name: [values] }. */
function productFacts(product) {
  const facts = {};
  const add = (name, raw) => {
    if (!name || raw == null || raw === "") return;
    const key = norm(name);
    const vals = (Array.isArray(raw) ? raw : [raw]).map((v) => String(v).trim()).filter(Boolean);
    if (!vals.length) return;
    facts[key] = [...new Set([...(facts[key] || []), ...vals])];
  };
  for (const src of [product.itemSpecifics, product.geminiItemSpecifics, product.ebayAspects]) {
    if (src && typeof src === "object") for (const [k, v] of Object.entries(src)) add(k, v);
  }
  if (product.brand) add("brand", product.brand);
  return facts;
}

// TikTok attribute names that mean the same thing as a common specifics name.
const ALIASES = { "color": ["colour", "main color"], "material": ["materials"], "theme": ["character", "franchise"], "brand": ["manufacturer"] };

function factFor(facts, attrName) {
  const key = norm(attrName);
  if (facts[key]) return facts[key];
  for (const [canon, alts] of Object.entries(ALIASES)) {
    const group = [canon, ...alts];
    if (group.includes(key)) for (const g of group) if (facts[g]) return facts[g];
  }
  return null;
}

const isRequired = (a) => a?.is_required === true || a?.is_requried === true;

/**
 * Category attributes + product → { attributes: [{id, values:[{id?, name}]}], missing: [names] }.
 * `missing` = required product attributes with nothing to fill them.
 */
function buildProductAttributes(categoryAttributes = [], product = {}) {
  const facts = productFacts(product);
  const attributes = [];
  const missing = [];
  for (const a of categoryAttributes) {
    if (a?.type && a.type !== "PRODUCT_PROPERTY") continue;
    const required = isRequired(a);
    const listed = Array.isArray(a.values) ? a.values : [];
    const have = factFor(facts, a.name) || [];
    const limit = a.is_multiple_selection ? Infinity : 1;

    const matched = [];
    for (const v of have) {
      const hit = listed.find((x) => norm(x.name) === norm(v));
      if (hit && !matched.some((m) => m.id === String(hit.id))) matched.push({ id: String(hit.id), name: hit.name });
    }
    let values = matched.slice(0, limit);
    if (!values.length && have.length && (a.is_customizable || !listed.length)) {
      values = have.slice(0, limit).map((name) => ({ name: name.slice(0, 50) }));
    }
    if (!values.length && required) {
      const neutral = listed.find((x) => NEUTRAL_VALUES.includes(norm(x.name)));
      if (neutral) values = [{ id: String(neutral.id), name: neutral.name }];
    }
    if (values.length) attributes.push({ id: String(a.id), values });
    else if (required) missing.push(a.name);
  }
  return { attributes, missing };
}

/** Rules TikTok enforces that Wonni can't satisfy → readable reasons ([] = fine). */
function unmetRules(rules = {}) {
  const out = [];
  const certs = (rules.product_certifications || []).filter((c) => c?.is_required);
  if (certs.length) out.push(`a certification (${certs.map((c) => c.name).join(", ")})`);
  if (rules.size_chart?.is_required) out.push("a size chart");
  return out;
}

async function recommendCategory(client, product) {
  const data = await client.request("POST", "/product/202309/categories/recommend", {
    body: { product_title: String(product.title || "").slice(0, 255) },
    what: "Choosing a TikTok category",
  });
  const id = data?.leaf_category_id ?? data?.categories?.find((c) => c.is_leaf)?.id;
  if (!id) throw new HttpsError("failed-precondition", "TikTok couldn't suggest a category for this title. Pick one and post again.");
  const path = (data.categories || []).map((c) => c.name ?? c.local_name).filter(Boolean).join(" > ");
  return { categoryId: String(id), path: path || null };
}

/**
 * Category + attributes for a post. Throws a readable failed-precondition when
 * the category needs something Wonni can't fill.
 */
async function resolveTiktokCategory(client, product, { categoryId } = {}) {
  let chosen = categoryId || product.tiktokCategoryId || null;
  let path = null;
  let recommended = false;
  if (!chosen) {
    ({ categoryId: chosen, path } = await recommendCategory(client, product));
    recommended = true;
  }
  const [attrData, rules] = await Promise.all([
    client.request("GET", `/product/202309/categories/${chosen}/attributes`, { what: "Loading TikTok category fields" }),
    client.request("GET", `/product/202309/categories/${chosen}/rules`, { what: "Loading TikTok category rules" }).catch(() => ({})),
  ]);
  const { attributes, missing } = buildProductAttributes(attrData?.attributes, product);
  const unmet = unmetRules(rules);
  return { categoryId: String(chosen), path, recommended, attributes, missing, unmet };
}

function categoryProblem({ missing, unmet }) {
  const parts = [];
  if (missing.length) parts.push(`these fields: ${missing.join(", ")}. Add them under Item specifics`);
  if (unmet.length) parts.push(`${unmet.join(" and ")}, which Wonni can't send yet. Pick a different category`);
  return parts.length ? `TikTok needs ${parts.join("; also ")}.` : null;
}

module.exports = {
  productFacts, buildProductAttributes, unmetRules, recommendCategory, resolveTiktokCategory, categoryProblem, isRequired,
};
