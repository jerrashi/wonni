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
//  ── Wired in ─────────────────────────────────────────────────────────────
//  All three are now placed in SalesDashboardView.swift's `salesList`:
//  SalesMetricsRow right under the existing 3-card summary row, SalesTrendChart
//  in its own Section below that, then platform + tag SalesBreakdownCards
//  below the trend chart. All four read `sales` (not `filteredSales`) so the
//  numbers don't shift under you as you tap a filter — same as the web
//  version. Platform-card taps drive the existing `filterPlatform`; a new
//  `filterTag` state drives tag-card taps and the row list.
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
/// TrendChart (web/src/pages/Sales.jsx): a `BarMark` per bucket for revenue,
/// a `LineMark` + `PointMark` for net. Bucketing/math is done by
/// `SalesMetrics.trend`, which already excludes cancelled/returned/deleted.
/// Restyle freely — this is one reasonable take, not the only one.
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
                chart
                HStack(spacing: 16) {
                    legendDot(color: Color.accentColor.opacity(0.5), label: "Revenue")
                    legendDot(color: .teal, label: "Net")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chart: some View {
        Chart(points, id: \.periodStart) { point in
            BarMark(
                x: .value("Week", point.periodStart, unit: bucket.calendarComponent),
                y: .value("Revenue", point.revenue)
            )
            .foregroundStyle(Color.accentColor.opacity(0.35))
            .cornerRadius(2)

            LineMark(
                x: .value("Week", point.periodStart, unit: bucket.calendarComponent),
                y: .value("Net", max(point.net, 0))
            )
            .foregroundStyle(.teal)
            .interpolationMethod(.monotone)

            PointMark(
                x: .value("Week", point.periodStart, unit: bucket.calendarComponent),
                y: .value("Net", max(point.net, 0))
            )
            .foregroundStyle(.teal)
            .symbolSize(28)
        }
        .frame(height: 140)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(String(format: "$%.0f", d))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: points.map(\.periodStart)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }
}

private extension SalesMetrics.Bucket {
    /// `Calendar.Component` for the axis unit — day/week/month buckets
    /// already align to these boundaries in `SalesMetrics.trend`.
    var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}
