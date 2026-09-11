//
//  SalesMetrics.swift
//  wonni
//
//  Sales-dashboard profit/aggregation math — mirrors the backend source of
//  truth in `functions/sales_metrics.js` (and its web mirror,
//  `web/src/lib/salesMetrics.js`). Keep the three in sync by hand — this is
//  compute logic, not a wire contract, so it isn't codegen'd.
//
//  Decision (2026-09-11, phase-3 sales-dashboard spec): takeHome should
//  almost always be real — eBay/Etsy come from the API, Mercari from a page
//  scrape. feeRates is only a backstop for the rare sale with no real
//  take-home. Hard-coded on purpose, not a remote config doc.
//
//  Cost lookup: there is no `Product`/`sourcePrice` Swift model yet (tracked
//  as open work), so callers pass a `costLookup: (String) -> Double?` keyed
//  by productId. Until that model exists, pass `{ _ in nil }` — cost (and
//  therefore the fee-% fallback branch of `net`) is simply 0, which is safe:
//  real `takeHome` already nets fees on its own.
//

import Foundation

enum SalesMetrics {

    /// Estimated marketplace take-rate, applied to (item + shipping) revenue.
    /// Backstop only — real `sale.takeHome` always wins when present.
    static let feeRates: [String: Double] = [
        "ebay": 0.1325,
        "etsy": 0.095,
        "mercari": 0.10,
        "tiktok": 0.08,
        "wonni": 0,
        "manual": 0,
    ]

    /// Sale statuses excluded from revenue/net totals by default.
    static let excludedStatuses: Set<SaleStatus> = [.cancelled, .returned]

    static func feeEstimate(platform: String, revenue: Double) -> Double {
        round2(revenue * (feeRates[platform] ?? 0))
    }

    struct Financials {
        var revenue: Double
        var cost: Double
        var feesEstimate: Double?
        var net: Double
        var margin: Double?
        var netIsEstimate: Bool
    }

    /// Per-sale financials. `cost` is looked up via `costLookup(productId)`,
    /// defaulting to 0 when there's no id or no match.
    static func saleFinancials(_ sale: Sale, costLookup: (String) -> Double? = { _ in nil }) -> Financials {
        let quantity = max(sale.quantity ?? 1, 1)
        let itemRevenue = sale.priceSoldFor * Double(quantity)
        let shippingRevenue = sale.shippingRevenue ?? 0
        let revenue = round2(itemRevenue + shippingRevenue)

        let unitCost = sale.linkedProductId.flatMap(costLookup) ?? 0
        let cost = round2(unitCost * Double(quantity))

        let feesEstimate: Double?
        let net: Double
        let netIsEstimate: Bool

        if let takeHome = sale.takeHome {
            feesEstimate = nil
            net = round2(takeHome - cost)
            netIsEstimate = false
        } else {
            let shippingLabelCost = sale.shippingLabelCost ?? 0
            let fee = feeEstimate(platform: sale.platform, revenue: revenue)
            feesEstimate = fee
            net = round2(revenue - fee - shippingLabelCost - cost)
            netIsEstimate = true
        }

        let margin: Double? = revenue > 0 ? round2(net / revenue) : nil

        return Financials(revenue: revenue, cost: cost, feesEstimate: feesEstimate, net: net, margin: margin, netIsEstimate: netIsEstimate)
    }

    static func isCounted(_ sale: Sale) -> Bool {
        if sale.isDeleted == true { return false }
        if excludedStatuses.contains(sale.status) { return false }
        return true
    }

    struct GroupTotals {
        var count: Int = 0
        var units: Int = 0
        var revenue: Double = 0
        var net: Double = 0
        var cost: Double = 0
        var avgOrderValue: Double = 0
        var netIsEstimate: Bool = false
    }

    enum GroupBy {
        case platform
        case tag
    }

    struct AggregateResult {
        var totals: GroupTotals
        var groups: [(key: String, totals: GroupTotals)]
    }

    private static func groupKeys(for sale: Sale, groupBy: GroupBy) -> [String] {
        switch groupBy {
        case .platform:
            return [sale.platform.isEmpty ? "manual" : sale.platform]
        case .tag:
            let tags = sale.productTags ?? []
            return tags.isEmpty ? ["untagged"] : tags
        }
    }

    static func aggregate(_ sales: [Sale], costLookup: (String) -> Double? = { _ in nil }, groupBy: GroupBy? = nil) -> AggregateResult {
        let counted = sales.filter(isCounted)

        var totals = GroupTotals()
        var groupMap: [String: GroupTotals] = [:]
        var groupOrder: [String] = []

        for sale in counted {
            let fin = saleFinancials(sale, costLookup: costLookup)
            let quantity = max(sale.quantity ?? 1, 1)

            totals.count += 1
            totals.units += quantity
            totals.revenue = round2(totals.revenue + fin.revenue)
            totals.net = round2(totals.net + fin.net)
            totals.cost = round2(totals.cost + fin.cost)
            if fin.netIsEstimate { totals.netIsEstimate = true }

            if let groupBy {
                for key in groupKeys(for: sale, groupBy: groupBy) {
                    if groupMap[key] == nil {
                        groupMap[key] = GroupTotals()
                        groupOrder.append(key)
                    }
                    groupMap[key]!.count += 1
                    groupMap[key]!.units += quantity
                    groupMap[key]!.revenue = round2(groupMap[key]!.revenue + fin.revenue)
                    groupMap[key]!.net = round2(groupMap[key]!.net + fin.net)
                    groupMap[key]!.cost = round2(groupMap[key]!.cost + fin.cost)
                    if fin.netIsEstimate { groupMap[key]!.netIsEstimate = true }
                }
            }
        }

        totals.avgOrderValue = totals.count > 0 ? round2(totals.revenue / Double(totals.count)) : 0
        let groups = groupOrder.map { key -> (key: String, totals: GroupTotals) in
            var g = groupMap[key]!
            g.avgOrderValue = g.count > 0 ? round2(g.revenue / Double(g.count)) : 0
            return (key: key, totals: g)
        }.sorted { $0.totals.revenue > $1.totals.revenue }

        return AggregateResult(totals: totals, groups: groups)
    }

    enum Bucket {
        case day, week, month
    }

    struct TrendPoint {
        var periodStart: Date
        var revenue: Double
        var net: Double
        var count: Int
    }

    private static func bucketStart(_ date: Date, bucket: Bucket) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = cal.startOfDay(for: date)
        switch bucket {
        case .day:
            return dayStart
        case .month:
            let comps = cal.dateComponents([.year, .month], from: dayStart)
            return cal.date(from: comps)!
        case .week:
            // Monday-start, matching the JS mirrors.
            let weekday = cal.component(.weekday, from: dayStart) // 1=Sun..7=Sat
            let daysSinceMonday = (weekday + 5) % 7
            return cal.date(byAdding: .day, value: -daysSinceMonday, to: dayStart)!
        }
    }

    /// Bucket sales into a revenue/net trend over time, sorted ascending.
    static func trend(_ sales: [Sale], bucket: Bucket = .week, costLookup: (String) -> Double? = { _ in nil }) -> [TrendPoint] {
        let counted = sales.filter(isCounted)

        var buckets: [Date: TrendPoint] = [:]
        var order: [Date] = []

        for sale in counted {
            let periodStart = bucketStart(sale.soldAt.dateValue(), bucket: bucket)
            let fin = saleFinancials(sale, costLookup: costLookup)
            if buckets[periodStart] == nil {
                buckets[periodStart] = TrendPoint(periodStart: periodStart, revenue: 0, net: 0, count: 0)
                order.append(periodStart)
            }
            buckets[periodStart]!.revenue = round2(buckets[periodStart]!.revenue + fin.revenue)
            buckets[periodStart]!.net = round2(buckets[periodStart]!.net + fin.net)
            buckets[periodStart]!.count += 1
        }

        return order.sorted().map { buckets[$0]! }
    }

    private static func round2(_ n: Double) -> Double {
        (n * 100).rounded() / 100
    }
}
