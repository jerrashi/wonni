/**
 * sales_metrics.js — pure profit/aggregation math for the sales dashboard.
 *
 * No Firebase imports. Mirrored (kept in lockstep by hand, not codegen —
 * this is compute logic, not a wire contract) to:
 *   - web/src/lib/salesMetrics.js
 *   - wonni/wonni/Data/SalesMetrics.swift
 *
 * Decision (2026-09-11, phase-3 sales-dashboard spec): takeHome should
 * almost always be real — eBay/Etsy come from the API (syncSales /
 * getOrderTakeHome), Mercari from a page scrape. FEE_RATES below is only a
 * backstop for the rare sale where no real take-home could be resolved.
 * Hard-coded on purpose (not a Firestore config doc) — revisit if it drifts.
 */

/** Estimated marketplace take-rate, applied to (item + shipping) revenue.
 *  Backstop only — real `sale.takeHome` always wins when present. */
const FEE_RATES = {
  ebay: 0.1325,
  etsy: 0.095,
  mercari: 0.10,
  tiktok: 0.08,
  wonni: 0,
  manual: 0,
};

/** Sale statuses excluded from revenue/net totals by default — the sale
 *  didn't actually stick. */
const EXCLUDED_STATUSES = new Set(["cancelled", "returned"]);

function feeEstimate(platform, revenue) {
  const rate = FEE_RATES[platform] ?? 0;
  return round2(revenue * rate);
}

function round2(n) {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

/**
 * Per-sale financials. `product` may be null/undefined (deleted or manual
 * sale with no linked product) — cost falls back to 0.
 *
 * @returns {{revenue:number, cost:number, feesEstimate:number, net:number,
 *   margin:number|null, netIsEstimate:boolean}}
 */
function saleFinancials(sale, product) {
  const quantity = Number.isFinite(sale?.quantity) && sale.quantity > 0 ? sale.quantity : 1;
  const itemRevenue = (Number(sale?.priceSoldFor) || 0) * quantity;
  const shippingRevenue = Number(sale?.shippingRevenue) || 0;
  const revenue = round2(itemRevenue + shippingRevenue);

  const cost = round2((Number(product?.sourcePrice) || 0) * quantity);

  const hasRealTakeHome = typeof sale?.takeHome === "number" && Number.isFinite(sale.takeHome);
  let net;
  let feesEstimate;
  let netIsEstimate;

  if (hasRealTakeHome) {
    feesEstimate = null;
    net = round2(sale.takeHome - cost);
    netIsEstimate = false;
  } else {
    const shippingLabelCost = Number(sale?.shippingLabelCost) || 0;
    feesEstimate = feeEstimate(sale?.platform, revenue);
    net = round2(revenue - feesEstimate - shippingLabelCost - cost);
    netIsEstimate = true;
  }

  const margin = revenue > 0 ? round2(net / revenue) : null;

  return { revenue, cost, feesEstimate, net, margin, netIsEstimate };
}

function isCounted(sale) {
  if (!sale) return false;
  if (sale.isDeleted) return false;
  if (sale.status && EXCLUDED_STATUSES.has(sale.status)) return false;
  return true;
}

/**
 * Aggregate a list of sales into totals, optionally grouped.
 *
 * @param {Array} sales - SaleDoc-shaped objects.
 * @param {Object} productsById - map of productId -> product doc, for cost lookup.
 * @param {{groupBy?: "platform"|"tag"|null}} opts
 * @returns {{totals: Object, groups: Array<{key:string, totals:Object}>}}
 */
function aggregate(sales, productsById = {}, opts = {}) {
  const { groupBy = null } = opts;
  const counted = (sales || []).filter(isCounted);

  const emptyTotals = () => ({
    count: 0,
    units: 0,
    revenue: 0,
    net: 0,
    cost: 0,
    avgOrderValue: 0,
    netIsEstimate: false, // true if ANY sale in the group used the fee-% fallback
  });

  const totals = emptyTotals();
  const groupMap = new Map();

  for (const sale of counted) {
    const product = sale.productId ? productsById[sale.productId] : null;
    const fin = saleFinancials(sale, product);
    const quantity = Number.isFinite(sale.quantity) && sale.quantity > 0 ? sale.quantity : 1;

    totals.count += 1;
    totals.units += quantity;
    totals.revenue = round2(totals.revenue + fin.revenue);
    totals.net = round2(totals.net + fin.net);
    totals.cost = round2(totals.cost + fin.cost);
    if (fin.netIsEstimate) totals.netIsEstimate = true;

    if (groupBy) {
      const keys = groupKeysFor(sale, groupBy);
      for (const key of keys) {
        if (!groupMap.has(key)) groupMap.set(key, emptyTotals());
        const g = groupMap.get(key);
        g.count += 1;
        g.units += quantity;
        g.revenue = round2(g.revenue + fin.revenue);
        g.net = round2(g.net + fin.net);
        g.cost = round2(g.cost + fin.cost);
        if (fin.netIsEstimate) g.netIsEstimate = true;
      }
    }
  }

  totals.avgOrderValue = totals.count > 0 ? round2(totals.revenue / totals.count) : 0;
  const groups = [...groupMap.entries()]
    .map(([key, g]) => {
      g.avgOrderValue = g.count > 0 ? round2(g.revenue / g.count) : 0;
      return { key, totals: g };
    })
    .sort((a, b) => b.totals.revenue - a.totals.revenue);

  return { totals, groups };
}

function groupKeysFor(sale, groupBy) {
  if (groupBy === "platform") return [sale.platform || "manual"];
  if (groupBy === "tag") {
    const tags = Array.isArray(sale.productTags) ? sale.productTags : [];
    return tags.length > 0 ? tags : ["untagged"];
  }
  return [];
}

/**
 * Bucket sales into a revenue/net trend over time.
 *
 * @param {Array} sales
 * @param {{bucket?: "day"|"week"|"month", productsById?: Object}} opts
 * @returns {Array<{periodStart:string, revenue:number, net:number, count:number}>}
 *   periodStart is an ISO date string (UTC midnight), sorted ascending.
 */
function trend(sales, opts = {}) {
  const { bucket = "week", productsById = {} } = opts;
  const counted = (sales || []).filter(isCounted).filter((s) => s.soldAt);

  const buckets = new Map();
  for (const sale of counted) {
    const d = toDate(sale.soldAt);
    if (!d || Number.isNaN(d.getTime())) continue;
    const periodStart = bucketStart(d, bucket);
    const key = periodStart.toISOString();
    if (!buckets.has(key)) buckets.set(key, { periodStart: key, revenue: 0, net: 0, count: 0 });
    const b = buckets.get(key);
    const product = sale.productId ? productsById[sale.productId] : null;
    const fin = saleFinancials(sale, product);
    b.revenue = round2(b.revenue + fin.revenue);
    b.net = round2(b.net + fin.net);
    b.count += 1;
  }

  return [...buckets.values()].sort((a, b) => a.periodStart.localeCompare(b.periodStart));
}

function toDate(v) {
  if (v instanceof Date) return v;
  if (v && typeof v.toDate === "function") return v.toDate(); // Firestore Timestamp
  if (typeof v === "number") return new Date(v);
  if (typeof v === "string") return new Date(v);
  return null;
}

function bucketStart(date, bucket) {
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  if (bucket === "day") return d;
  if (bucket === "month") {
    d.setUTCDate(1);
    return d;
  }
  // week: Monday-start
  const dow = d.getUTCDay(); // 0=Sun..6=Sat
  const diff = (dow + 6) % 7; // days since Monday
  d.setUTCDate(d.getUTCDate() - diff);
  return d;
}

module.exports = {
  FEE_RATES,
  EXCLUDED_STATUSES,
  feeEstimate,
  saleFinancials,
  aggregate,
  trend,
  _internal: { isCounted, groupKeysFor, bucketStart, round2 },
};
