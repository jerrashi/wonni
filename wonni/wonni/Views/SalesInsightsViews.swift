//
//  SalesInsightsViews.swift
//  wonni
//
//  Phase 3c (sales-dashboard parity, docs/specs/2026-09-09-phase3-sales-dashboard.md
//  §3c) — the iOS-side cards web already has: Net/Margin/Cost metrics,
//  platform + tag breakdowns, and a trend chart. All math comes from
//  Data/SalesMetrics.swift (the Swift mirror of functions/sales_metrics.js) —
//  nothing here should recompute revenue/net/margin itself.
//
//  ── How to wire this in ─────────────────────────────────────────────────
//  These are standalone, compiling views — SalesDashboardView.swift (983 L)
//  isn't touched. Drop them into `salesList` in that file:
//
//    1. `SalesMetricsRow` — right after the existing 3-card `summaryCard`
//       HStack (around line 197, "// Platform filter" comment follows it).
//       Same Section, same .listRowInsets/.listRowBackground/.listRowSeparator
//       as that HStack so it sits flush underneath.
//    2. `SalesTrendChart` — its own Section, between the summary cards and
//       the platform filter chips. Pass `filteredSales` so it respects the
//       existing platform filter.
//    3. `PlatformBreakdownCard` / `TagBreakdownCard` — new Section(s) below
//       the trend chart, or wherever reads better next to the existing
//       platform-filter chip row. Wire their `onSelect` to the same
//       `filterPlatform` state the chip row already uses (for platform) —
//       tag has no existing filter state, so either add one or leave the
//       card tap inert for now.
//
//  All three read `SalesMetrics.aggregate`/`.trend`, which need a
//  `costLookup: (String) -> Double?` for Cost of Goods / margin. There is no
//  `Product` Swift model yet (open item, see CLAUDE.md "iOS onto the shared
//  eBay/field-fill backend" — cost tracking isn't ported either), so every
//  view below defaults it to `{ _ in nil }` (cost reads as $0, so Net just
//  equals real takeHome — never wrong, only incomplete). Once a Product
//  model + repository exist, thread a real lookup through the `costLookup`
//  parameter on each view below — that's a single-line change per call site.
//

import SwiftUI
import Charts

// MARK: - Net / Margin / Cost metrics

/// Mirrors web's "Net Profit / Est. Margin / Cost of Goods" cards
/// (web/src/pages/Sales.jsx). Same `summaryCard` visual language as the
/// existing Sales/Revenue/Take-Home row in SalesDashboardView.
struct SalesMetricsRow: View {
    let sales: [Sale]
    var costLookup: (String) -> Double? = { _ in nil }

    private var totals: SalesMetrics.GroupTotals {
        SalesMetrics.aggregate(sales, costLookup: costLookup).totals
    }

    var body: some View {
        HStack(spacing: 12) {
            metricCard(
                title: "Net Profit" + (totals.netIsEstimate ? " ~" : ""),
                value: String(format: "$%.0f", totals.net),
                icon: "chart.line.uptrend.xyaxis",
                color: .teal
            )
            metricCard(
                title: "Margin",
                value: totals.revenue > 0 ? String(format: "%.0f%%", (totals.net / totals.revenue) * 100) : "—",
                icon: "percent",
                color: .indigo
            )
            metricCard(
                title: "Cost of Goods",
                value: String(format: "$%.0f", totals.cost),
                icon: "shippingbox.fill",
                color: .orange
            )
        }
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(value).font(.title3.weight(.bold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Platform / tag breakdown cards

/// One row per group (platform or tag), sorted by revenue desc — same shape
/// as web's "Sales by Platform" / "Sales by Tag" cards. `onSelect` fires with
/// the tapped group's key (e.g. "ebay" or a tag string); pass `nil` to leave
/// selection unwired for now.
struct SalesBreakdownCard: View {
    let title: String
    let icon: String
    let sales: [Sale]
    let groupBy: SalesMetrics.GroupBy
    var costLookup: (String) -> Double? = { _ in nil }
    var selectedKey: String? = nil
    var onSelect: ((String) -> Void)? = nil
    /// Optional display-name override, e.g. Sale.platformDisplayName for platform groups.
    var labelFor: (String) -> String = { $0 }

    private var groups: [(key: String, totals: SalesMetrics.GroupTotals)] {
        SalesMetrics.aggregate(sales, costLookup: costLookup, groupBy: groupBy).groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))

            if groups.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(groups, id: \.key) { group in
                        Button {
                            onSelect?(group.key)
                        } label: {
                            HStack {
                                Text(labelFor(group.key))
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(group.totals.units) sold · $\(String(format: "%.2f", group.totals.revenue))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selectedKey == group.key ? Color.accentColor : .clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Trend chart

/// 8-week revenue/net trend — Swift Charts mirror of web's inline-SVG
/// TrendChart (web/src/pages/Sales.jsx). Bucketing/math already done by
/// `SalesMetrics.trend`; this view is just the chart body.
///
/// TODO(you): pick the chart's look. A reasonable starting point —
/// `BarMark` per week for revenue, a `LineMark` + `PointMark` for net,
/// laid out like the web version — is sketched below but commented out so
/// this compiles as a placeholder first. Swap it in, or design your own;
/// `SalesMetrics.TrendPoint` gives you `periodStart: Date`, `revenue`,
/// `net`, `count` per bucket, already excluding cancelled/returned/deleted.
struct SalesTrendChart: View {
    let sales: [Sale]
    var bucket: SalesMetrics.Bucket = .week
    var weeksShown: Int = 8
    var costLookup: (String) -> Double? = { _ in nil }

    private var points: [SalesMetrics.TrendPoint] {
        let all = SalesMetrics.trend(sales, bucket: bucket, costLookup: costLookup)
        return Array(all.suffix(weeksShown))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(weeksShown)-Week Trend")
                .font(.subheadline.weight(.semibold))

            if points.isEmpty {
                Text("Not enough sales yet to chart a trend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 120)
            } else {
                // --- TODO(you): replace this placeholder with a real Chart. ---
                // Example starting point:
                //
                // Chart(points, id: \.periodStart) { point in
                //     BarMark(
                //         x: .value("Week", point.periodStart, unit: .weekOfYear),
                //         y: .value("Revenue", point.revenue)
                //     )
                //     .foregroundStyle(Color.accentColor.opacity(0.35))
                //
                //     LineMark(
                //         x: .value("Week", point.periodStart, unit: .weekOfYear),
                //         y: .value("Net", point.net)
                //     )
                //     .foregroundStyle(.teal)
                //     .symbol(.circle)
                // }
                // .frame(height: 140)
                // .chartYAxis { AxisMarks(position: .leading) }
                //
                placeholderChart
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Bare-bones fallback so the file compiles standalone before you fill
    /// in the real Chart above. Delete once the real chart is in.
    private var placeholderChart: some View {
        let maxRevenue = max(points.map(\.revenue).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(points, id: \.periodStart) { point in
                VStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(height: max(4, CGFloat(point.revenue / maxRevenue) * 100))
                    Text(point.periodStart.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 130, alignment: .bottom)
    }
}
