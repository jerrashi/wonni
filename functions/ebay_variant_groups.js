"use strict";

/**
 * Splitting one Wonni product into several eBay multi-variation listings.
 *
 * eBay's documented limits (Trading API variations guide, verified 2026-11-11):
 * 250 variations per listing, 5 variation specifics per variation, 30 values
 * per specific name. A big collection (30 series x 20 options = 600 variants)
 * can't be one eBay listing, so it becomes several item groups — still ONE
 * product in Wonni. Group 1 keeps the legacy key (the productId) so listings
 * posted before this existed are unchanged.
 */

const EBAY_LIMITS = { maxVariations: 250, maxDimensions: 5, maxValuesPerAspect: 30 };

const valuesOf = (v, name) => {
  const raw = v.optionValues?.[name];
  return (Array.isArray(raw) ? raw : [raw]).filter((x) => x != null && x !== "").map(String);
};

/** First group keeps `productId`; later ones are alphanumeric (eBay rejects `::` etc). */
function groupKeyFor(productId, index) {
  return index === 0 ? productId : `${productId}g${index + 1}`;
}

/** "<title> - Part 2 of 3", trimmed so the whole thing stays within eBay's 80 chars. */
function groupTitle(title, index, count, max = 80) {
  if (count <= 1) return title;
  const suffix = ` - Part ${index + 1} of ${count}`;
  return `${String(title).slice(0, Math.max(0, max - suffix.length)).trimEnd()}${suffix}`;
}

/**
 * Plan the item groups.
 * @param {Array<{v: object, i: number}>} items  active variants with their index in product.variants
 * @param {Array<{name: string}>} options        product.options (variation dimensions)
 * @param {{productId: string}} ctx
 * @returns {Array<{key: string, items: Array}>}  in group order; never empty if items isn't
 *
 * Stable: a variant already posted keeps its `ebayGroupKey` (a legacy variant
 * with none is in group 1), so re-posting never moves a live variant between
 * listings. New variants go to a group that already holds their primary
 * option value, else any group with room, else a new group. Fresh products
 * are packed in primary-value order so each listing is a coherent set
 * (e.g. whole series together).
 */
function planVariantGroups(items, options, { productId, limits = EBAY_LIMITS } = {}) {
  const names = options.map((o) => o.name);
  if (names.length > limits.maxDimensions) {
    throw Object.assign(new Error(`eBay allows at most ${limits.maxDimensions} variation types per listing; this product has ${names.length}.`), { code: "too-many-dimensions" });
  }
  const groups = []; // {key, items, sets: {name: Set}}
  const newGroup = (key) => {
    const g = { key, items: [], sets: Object.fromEntries(names.map((n) => [n, new Set()])) };
    groups.push(g);
    return g;
  };
  const fits = (g, v) => g.items.length < limits.maxVariations
    && names.every((n) => {
      const have = g.sets[n];
      const add = valuesOf(v, n).filter((x) => !have.has(x)).length;
      return have.size + add <= limits.maxValuesPerAspect;
    });
  const add = (g, it) => {
    g.items.push(it);
    names.forEach((n) => valuesOf(it.v, n).forEach((x) => g.sets[n].add(x)));
  };

  const existingKeys = new Set();
  for (const it of items) if (it.v.ebayGroupKey) existingKeys.add(it.v.ebayGroupKey);
  const legacyKey = groupKeyFor(productId, 0);

  // 1. Pin already-posted variants to their group (legacy = group 1).
  const byKey = new Map();
  const unplaced = [];
  for (const it of items) {
    const posted = it.v.ebayOfferId || it.v.ebayGroupKey;
    if (!posted) { unplaced.push(it); continue; }
    const key = it.v.ebayGroupKey || legacyKey;
    if (!byKey.has(key)) byKey.set(key, newGroup(key));
    add(byKey.get(key), it);
  }

  // 2. Place new variants, primary option first so a series stays together.
  const primary = names[0];
  const order = [...unplaced].sort((a, b) => {
    const pa = valuesOf(a.v, primary)[0] ?? "", pb = valuesOf(b.v, primary)[0] ?? "";
    return pa === pb ? a.i - b.i : 0; // stable: keep first-seen order of primary values
  });
  const firstSeen = new Map();
  order.forEach((it) => { const p = valuesOf(it.v, primary)[0] ?? ""; if (!firstSeen.has(p)) firstSeen.set(p, firstSeen.size); });
  order.sort((a, b) => (firstSeen.get(valuesOf(a.v, primary)[0] ?? "") - firstSeen.get(valuesOf(b.v, primary)[0] ?? "")) || a.i - b.i);

  let nextIndex = groups.length;
  const takeKey = () => {
    let key;
    do { key = groupKeyFor(productId, nextIndex++); } while (existingKeys.has(key) || groups.some((g) => g.key === key));
    return key;
  };
  const openGroup = () => newGroup(groups.length === 0 ? legacyKey : takeKey());

  // Would the whole cluster fit in `g`? (dry run on copies of the counters)
  const clusterFits = (g, cluster) => {
    if (g.items.length + cluster.length > limits.maxVariations) return false;
    return names.every((n) => {
      const have = new Set(g.sets[n]);
      cluster.forEach((it) => valuesOf(it.v, n).forEach((x) => have.add(x)));
      return have.size <= limits.maxValuesPerAspect;
    });
  };

  const clusters = [];
  for (const it of order) {
    const p = valuesOf(it.v, primary)[0] ?? "";
    const last = clusters[clusters.length - 1];
    if (last && last.p === p) last.items.push(it); else clusters.push({ p, items: [it] });
  }
  for (const { p, items: cluster } of clusters) {
    // Whole cluster into the group already holding this primary value, else
    // any group it fits in, else a fresh group — splitting a cluster across
    // listings only when it can't fit in one at all.
    const home = groups.find((x) => x.items.some((o) => (valuesOf(o.v, primary)[0] ?? "") === p) && clusterFits(x, cluster));
    const target = home || groups.find((x) => clusterFits(x, cluster));
    if (target) { cluster.forEach((it) => add(target, it)); continue; }
    const empty = { items: [], sets: Object.fromEntries(names.map((n) => [n, new Set()])) };
    if (clusterFits(empty, cluster)) { const g = openGroup(); cluster.forEach((it) => add(g, it)); continue; }
    for (const it of cluster) {
      const g = groups.find((x) => fits(x, it.v)) || openGroup();
      add(g, it);
    }
  }

  // Group 1 first (legacy key), then by key order.
  groups.sort((a, b) => (a.key === legacyKey ? -1 : b.key === legacyKey ? 1 : a.key.localeCompare(b.key)));
  return groups.map(({ key, items: its }) => ({ key, items: its }));
}

module.exports = { EBAY_LIMITS, groupKeyFor, groupTitle, planVariantGroups };
