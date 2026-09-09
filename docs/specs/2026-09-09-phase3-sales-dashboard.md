# Phase 3 — Unified Sales Dashboard

Roadmap item 3. The old `~/.claude/plans/sales-dashboard-spec.md` referenced in
`CLAUDE.md` is gone; this replaces it, grounded in the code as it stands
2026-09-09 (post-consolidation).

## Where things are today

| | Web `pages/Sales.jsx` (549 L) | iOS `Views/SalesDashboardView.swift` (983 L) |
|---|---|---|
| Revenue total | ✅ | ✅ |
| Net / take-home total | ❌ | ✅ |
| Cost of goods, margin % | ❌ | ❌ |
| Platform breakdown | ✅ (card) | ⚠️ filter only |
| Tag breakdown | ✅ (card) | ❌ |
| Trend over time | ❌ | ❌ |
| Sync eBay / Etsy (`syncSales`) | ✅ (added 2026-09-09) | ✅ |
| Mercari scrape import | ❌ (extension, separate) | ✅ (WKWebView) |
| `getOrderTakeHome` fetch | ✅ in Log-a-sale modal | ✅ in Record-a-sale sheet |
| Delete → undo toast | ⚠️ delete only, no undo | ✅ 5 s undo + Deleted section |
| Bulk select / delete | ❌ | ✅ |
| Edit a sale (soldAt, takeHome, tracking, carrier, status, address) | ❌ (log only) | ✅ detail sheet |
| Status lifecycle shown / editable | ❌ | ✅ |

Shared already: `sales/{id}` = the canonical `SaleDoc` (`functions/contracts/sales.js`);
`recordSale` / `syncSales` / `getOrderTakeHome` on the backend.

`orders/{id}` (AliExpress/TikTok fulfillment) is **empty in prod** and
`pages/Orders.jsx` is unused — treat as out of scope (see § 3d).

## What "unified" means

React and SwiftUI can't share view code. What we make identical:

1. **Data model** — done (`SaleDoc`).
2. **Compute layer** — profit math + metric aggregation, one definition,
   mirrored to each client. Same pattern as `web/src/lib/pricing.js` ↔
   `functions/platform_adapters.js`.
3. **Backend enrichment** — `syncSales`, `getOrderTakeHome` (done);
   optional take-home backfill (§ 3a).
4. **Feature parity** — same metrics, filters, edit surface, lifecycle, so the
   two clients feel like one product.

---

## 3a — Shared compute layer  *(do first; unblocks both clients)*

**`functions/sales_metrics.js`** — pure, no Firebase:

- `saleFinancials(sale, product)` →
  `{ revenue, cost, feesEstimate, net, margin, netIsEstimate }`
  - `revenue = priceSoldFor + (shippingRevenue || 0)`
  - `cost = (Number(product?.sourcePrice) || 0) * (quantity || 1)`
  - `net = takeHome != null`
    - `? takeHome - cost`
    - `: revenue - feeEstimate(platform, revenue) - (shippingLabelCost || 0) - cost`  → `netIsEstimate: true`
  - `feeEstimate`: eBay 13.25 %, Etsy 9.5 %, Mercari 10 %, TikTok 8 %, wonni/manual 0 %
    (one table, easy to tune later)
  - `margin = revenue > 0 ? net / revenue : null`
- `aggregate(sales, productsById, { groupBy })` → `{ totals, groups }`
  where `groupBy ∈ "platform" | "tag" | null`; totals = `{ count, units,
  revenue, net, cost, avgOrderValue }`.
- `trend(sales, { bucket })` → `[{ periodStart, revenue, net, count }]`,
  `bucket ∈ "day" | "week" | "month"`.
- Ignore `isDeleted`, `status:"cancelled"`, `status:"returned"` in totals
  (configurable).

**Mirrors** (kept in lockstep, each with its own tests):
- `web/src/lib/salesMetrics.js`
- `wonni/wonni/Data/SalesMetrics.swift`

**Tests**: `functions/test/sales-metrics.test.js` — revenue/cost/net math,
estimate vs real take-home, per-group aggregation, day/week/month buckets,
excluded statuses.

**Optional**: `enrichPendingSalesTakeHome` (callable or scheduled) — for each
`sales/` doc with `status != "complete"` and `takeHome == null` and a
`platformOrderId`, call the existing `ebayFetchFinance` / `etsyReceiptTakeHome`
and persist. `syncSales` already does this per-order on its run; this just
covers manually-logged sales. ~small.

## 3b — Web to parity  *(I can do this; you review in the browser)*

1. **Metrics row**: add **Net Profit**, **Est. Margin %**, **Cost of Goods**
   (from `salesMetrics.js`). Mark net with a `~` when `netIsEstimate`.
2. **Trend**: an 8-week revenue+net bar/sparkline (inline SVG, no lib).
3. **Edit a sale**: a detail modal — `soldAt`, `takeHome`, `trackingNumber`,
   `carrier`, `status`, `buyerAddress` — writing straight to `sales/{id}` via
   `updateDoc` (Firestore rules already allow the owner). Matches the iOS
   `SaleDetailSheet` field set.
4. **Status**: show the lifecycle chip in the row; a one-click "advance"
   (`pending → shipped → delivered → complete`).
5. **Delete → undo**: 5 s "Sale deleted · Undo" toast (soft-delete +
   optimistic remove), and a collapsible **Deleted** section, matching iOS.
6. Skip bulk-select for v1.

## 3c — iOS to parity  *(additive; you build in Xcode)*

1. **Tag breakdown** + **Platform breakdown** cards (iOS has the filter, not
   the cards).
2. **Net / Margin / Cost** metrics via `SalesMetrics.swift`.
3. **Trend chart** (Swift Charts).

The existing iOS Mercari scrape / hidden-section / bulk-select / detail-sheet
machinery stays as-is.

## 3d — `orders/` — deferred

`orders/` is empty and `Orders.jsx` unused. When AliExpress/TikTok
auto-fulfillment goes live, model an order as an **optional child of a sale**
(a sourcing/fulfillment step), surfaced as an expandable row inside the sales
dashboard — not a separate page. Not part of this phase.

---

## Sequencing & effort

| | Effort | Notes |
|---|---|---|
| 3a compute layer | ~1 session | backend + 2 mirrors + tests |
| 3b web | ~1–2 sessions | metrics, edit modal, trend, undo |
| 3c iOS | ~1 session | additive cards + chart; needs Xcode |
| 3d orders | — | deferred |

## Decisions needed

1. **Net when `takeHome` is null** — show the fee-% estimate (flagged `~`) and
   overwrite when the real take-home lands? *(recommended)* Or show `net: —`
   until fetched?
2. **Fee percentages** — the table above is a starting guess; want it in a
   Firestore `system/` doc so it's tunable without a deploy, or hard-coded for
   now? *(recommended: hard-coded, revisit)*
3. **Web sale edits** — direct `updateDoc` *(recommended, rules already allow)*
   vs. a new `updateSale` callable. Callable only buys us server-side
   status-change side-effects, which we don't need yet.
4. **`sales/` vs `orders/`** — keep separate concepts? *(recommended: yes,
   defer orders entirely)*
