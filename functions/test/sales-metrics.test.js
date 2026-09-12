const test = require("node:test");
const assert = require("node:assert/strict");
const { feeEstimate, saleFinancials, aggregate, trend, FEE_RATES } = require("../sales_metrics");

test("feeEstimate applies the platform rate to revenue", () => {
  assert.equal(feeEstimate("ebay", 100), 13.25);
  assert.equal(feeEstimate("etsy", 100), 9.5);
  assert.equal(feeEstimate("mercari", 100), 10);
  assert.equal(feeEstimate("tiktok", 100), 8);
  assert.equal(feeEstimate("wonni", 100), 0);
  assert.equal(feeEstimate("manual", 100), 0);
  assert.equal(feeEstimate("unknown-platform", 100), 0);
});

test("saleFinancials: real takeHome wins, no fee estimate applied", () => {
  const sale = { priceSoldFor: 50, quantity: 1, platform: "ebay", takeHome: 40 };
  const product = { sourcePrice: 10 };
  const fin = saleFinancials(sale, product);
  assert.equal(fin.revenue, 50);
  assert.equal(fin.cost, 10);
  assert.equal(fin.net, 30); // 40 takeHome - 10 cost
  assert.equal(fin.netIsEstimate, false);
  assert.equal(fin.feesEstimate, null);
  assert.equal(fin.margin, 0.6);
});

test("saleFinancials: falls back to fee-% estimate when takeHome is null", () => {
  const sale = { priceSoldFor: 100, quantity: 1, platform: "ebay", takeHome: null, shippingLabelCost: 5 };
  const product = { sourcePrice: 20 };
  const fin = saleFinancials(sale, product);
  // revenue 100, fee 13.25, label 5, cost 20 -> net = 100-13.25-5-20 = 61.75
  assert.equal(fin.revenue, 100);
  assert.equal(fin.feesEstimate, 13.25);
  assert.equal(fin.net, 61.75);
  assert.equal(fin.netIsEstimate, true);
});

test("saleFinancials: quantity multiplies item price and cost, not shipping", () => {
  const sale = { priceSoldFor: 10, quantity: 3, platform: "manual", shippingRevenue: 4, takeHome: null };
  const product = { sourcePrice: 2 };
  const fin = saleFinancials(sale, product);
  assert.equal(fin.revenue, 34); // 10*3 + 4
  assert.equal(fin.cost, 6); // 2*3
  assert.equal(fin.netIsEstimate, true); // manual has 0% fee but still "estimate" since no real takeHome
  assert.equal(fin.net, 28); // 34 - 0 fee - 0 label - 6 cost
});

test("saleFinancials: missing product defaults cost to 0", () => {
  const sale = { priceSoldFor: 25, quantity: 1, platform: "manual", takeHome: 25 };
  const fin = saleFinancials(sale, null);
  assert.equal(fin.cost, 0);
  assert.equal(fin.net, 25);
});

test("saleFinancials: revenue 0 gives null margin, no divide-by-zero", () => {
  const sale = { priceSoldFor: 0, quantity: 1, platform: "manual", takeHome: 0 };
  const fin = saleFinancials(sale, null);
  assert.equal(fin.revenue, 0);
  assert.equal(fin.margin, null);
});

test("aggregate: isDeleted is excluded from everything; cancelled/returned only from revenue", () => {
  const sales = [
    { priceSoldFor: 100, platform: "ebay", takeHome: 90, status: "complete" },
    { priceSoldFor: 50, platform: "ebay", takeHome: 45, status: "cancelled" },
    { priceSoldFor: 30, platform: "ebay", takeHome: 25, status: "returned" },
    { priceSoldFor: 20, platform: "ebay", takeHome: 18, status: "complete", isDeleted: true },
  ];
  const { totals } = aggregate(sales, {});
  // count/net/cost: every non-deleted sale (3), isDeleted dropped entirely.
  assert.equal(totals.count, 3);
  assert.equal(totals.net, 90 + 45 + 25);
  // revenue: only the non-excluded status.
  assert.equal(totals.revenue, 100);
  assert.equal(totals.revenueCount, 1);
  assert.equal(totals.avgOrderValue, 100); // over revenueCount, not count
});

test("aggregate: a returned sale's real negative takeHome shows as a net loss, zero revenue", () => {
  // The exact scenario from the spec: a return the seller lost money on
  // (unrefunded outbound shipping / return-shipping charge baked into a
  // negative real takeHome), with revenue still excluded.
  const sales = [
    { priceSoldFor: 40, platform: "ebay", takeHome: -8.4, status: "returned" },
  ];
  const { totals } = aggregate(sales, {});
  assert.equal(totals.revenue, 0);
  assert.equal(totals.revenueCount, 0);
  assert.equal(totals.count, 1);
  assert.equal(totals.net, -8.4);
});

test("aggregate: a cancelled sale with no real takeHome falls back to the fee-% estimate (known gap, not this spec's fix)", () => {
  const sales = [
    { priceSoldFor: 40, platform: "ebay", takeHome: null, status: "cancelled" },
  ];
  const { totals } = aggregate(sales, {});
  // Revenue is correctly excluded either way. Net is NOT a clean zero here —
  // with no real takeHome, saleFinancials falls back to the fee-% estimate,
  // which assumes a normal completed sale. That's an inaccurate net for a
  // cancellation with nothing actually charged, but requiring manual entry
  // instead of estimating for this case is deferred (spec §4, last
  // paragraph) — pin the current behavior so that fix shows as a visible
  // diff here, not a silent regression.
  assert.equal(totals.revenue, 0);
  assert.equal(totals.net, 34.7); // 40 - 13.25%*40 fee estimate - 0 label - 0 cost
  assert.equal(totals.netIsEstimate, true);
});

test("aggregate: a renamed cancelled/returned bucket (label only) still excludes revenue by key", () => {
  // key is what sale.status stores; label is display-only (sale_stages.js) —
  // this proves the exclusion check (keyed on sale.status) survives a
  // relabel, since it never looks at the label at all.
  const sales = [
    { priceSoldFor: 40, platform: "ebay", takeHome: -5, status: "cancelled" }, // labeled "Refunded" in the user's saleStages, doesn't matter here
  ];
  const { totals } = aggregate(sales, {});
  assert.equal(totals.revenue, 0);
  assert.equal(totals.net, -5);
});

test("aggregate: groups by platform, sorted by revenue desc", () => {
  const sales = [
    { priceSoldFor: 100, platform: "ebay", takeHome: 90, status: "complete" },
    { priceSoldFor: 200, platform: "etsy", takeHome: 180, status: "complete" },
    { priceSoldFor: 50, platform: "ebay", takeHome: 45, status: "complete" },
  ];
  const { totals, groups } = aggregate(sales, {}, { groupBy: "platform" });
  assert.equal(totals.count, 3);
  assert.equal(totals.revenue, 350);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].key, "etsy");
  assert.equal(groups[0].totals.revenue, 200);
  assert.equal(groups[1].key, "ebay");
  assert.equal(groups[1].totals.revenue, 150);
});

test("aggregate: groups by tag, untagged bucket for no productTags", () => {
  const sales = [
    { priceSoldFor: 10, platform: "manual", takeHome: 10, status: "complete", productTags: ["kpop", "photocard"] },
    { priceSoldFor: 20, platform: "manual", takeHome: 20, status: "complete" },
  ];
  const { groups } = aggregate(sales, {}, { groupBy: "tag" });
  const keys = groups.map((g) => g.key).sort();
  assert.deepEqual(keys, ["kpop", "photocard", "untagged"]);
});

test("aggregate: looks up cost via productsById", () => {
  const sales = [{ priceSoldFor: 100, platform: "ebay", takeHome: 90, status: "complete", productId: "p1" }];
  const { totals } = aggregate(sales, { p1: { sourcePrice: 15 } });
  assert.equal(totals.cost, 15);
});

test("aggregate: netIsEstimate true when any counted sale used the fallback", () => {
  const sales = [
    { priceSoldFor: 100, platform: "ebay", takeHome: 90, status: "complete" },
    { priceSoldFor: 50, platform: "ebay", takeHome: null, status: "complete" },
  ];
  const { totals } = aggregate(sales, {});
  assert.equal(totals.netIsEstimate, true);
});

test("trend: buckets by day/week/month and sorts ascending", () => {
  const sales = [
    { priceSoldFor: 10, platform: "manual", takeHome: 10, status: "complete", soldAt: "2026-01-15T12:00:00Z" },
    { priceSoldFor: 20, platform: "manual", takeHome: 20, status: "complete", soldAt: "2026-01-01T00:00:00Z" },
    { priceSoldFor: 30, platform: "manual", takeHome: 30, status: "complete", soldAt: "2026-02-01T00:00:00Z" },
  ];
  const monthly = trend(sales, { bucket: "month" });
  assert.equal(monthly.length, 2);
  assert.equal(monthly[0].periodStart, "2026-01-01T00:00:00.000Z");
  assert.equal(monthly[0].revenue, 30);
  assert.equal(monthly[1].periodStart, "2026-02-01T00:00:00.000Z");
  assert.equal(monthly[1].revenue, 30);
});

test("trend: week bucket starts on Monday", () => {
  // 2026-01-15 is a Thursday
  const sales = [{ priceSoldFor: 10, platform: "manual", takeHome: 10, status: "complete", soldAt: "2026-01-15T12:00:00Z" }];
  const weekly = trend(sales, { bucket: "week" });
  assert.equal(weekly.length, 1);
  assert.equal(weekly[0].periodStart, "2026-01-12T00:00:00.000Z"); // Monday of that week
});

test("trend: excludes isDeleted and sales with no soldAt; cancelled/returned show net but not revenue", () => {
  const sales = [
    { priceSoldFor: 10, platform: "manual", takeHome: 10, status: "cancelled", soldAt: "2026-01-15T00:00:00Z" },
    { priceSoldFor: 10, platform: "manual", takeHome: 10, status: "complete" }, // no soldAt
    { priceSoldFor: 999, platform: "manual", takeHome: 999, status: "complete", isDeleted: true, soldAt: "2026-01-15T00:00:00Z" },
  ];
  const weekly = trend(sales, { bucket: "week" });
  assert.equal(weekly.length, 1); // only the cancelled sale has both isCounted + soldAt
  assert.equal(weekly[0].revenue, 0); // cancelled excluded from revenue
  assert.equal(weekly[0].net, 10); // real takeHome still counts
  assert.equal(weekly[0].count, 1);
});

test("trend: accepts Firestore-Timestamp-shaped soldAt (toDate())", () => {
  const fakeTimestamp = { toDate: () => new Date("2026-03-05T00:00:00Z") };
  const sales = [{ priceSoldFor: 10, platform: "manual", takeHome: 10, status: "complete", soldAt: fakeTimestamp }];
  const monthly = trend(sales, { bucket: "month" });
  assert.equal(monthly.length, 1);
  assert.equal(monthly[0].periodStart, "2026-03-01T00:00:00.000Z");
});

test("FEE_RATES table matches the documented percentages", () => {
  assert.deepEqual(FEE_RATES, { ebay: 0.1325, etsy: 0.095, mercari: 0.10, tiktok: 0.08, wonni: 0, manual: 0 });
});
