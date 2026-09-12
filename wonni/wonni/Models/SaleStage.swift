//
//  SaleStage.swift
//  wonni
//
//  Mirrors functions/sale_stages.js / web/src/lib/saleStages.js — the
//  kanban/spreadsheet bucket list `sale.status` points into. Kept in sync by
//  hand (UI-default data, not a wire contract, so it isn't codegen'd). See
//  docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §1/§6.
//

import Foundation

struct SaleStage: Identifiable, Equatable {
    var key: String
    var label: String
    var builtIn: Bool

    var id: String { key }
}

enum SaleStages {
    /// Keys are the LITERAL `sale.status` wire values (SaleStatus.rawValue) —
    /// see sale_stages.js's header comment for why. Only labels are free to
    /// read however's friendliest.
    static let builtIn: [SaleStage] = [
        SaleStage(key: "pending", label: "Ready to Ship", builtIn: true),
        SaleStage(key: "shipped", label: "In Transit", builtIn: true),
        SaleStage(key: "delivered", label: "Delivered", builtIn: true),
        SaleStage(key: "complete", label: "Completed", builtIn: true),
        SaleStage(key: "cancelled", label: "Cancelled", builtIn: true),
        SaleStage(key: "returned", label: "Returned", builtIn: true),
    ]

    /// Parse the `saleStages` field off a `users/{uid}` document's data,
    /// falling back to the built-ins — mirrors loadSaleStages' "empty/missing
    /// means never customized" rule (sale_stages.js).
    static func parse(_ data: [String: Any]?) -> [SaleStage] {
        guard let raw = data?["saleStages"] as? [[String: Any]], !raw.isEmpty else {
            return builtIn
        }
        let parsed = raw.compactMap { entry -> SaleStage? in
            guard let key = entry["key"] as? String, let label = entry["label"] as? String else { return nil }
            return SaleStage(key: key, label: label, builtIn: entry["builtIn"] as? Bool ?? false)
        }
        return parsed.isEmpty ? builtIn : parsed
    }

    /// `stages` plus, if `currentKey` isn't among them (a deleted custom
    /// bucket, or stages hasn't loaded yet), one extra entry for it so a
    /// picker/board never silently drops the sale it's showing.
    static func including(_ currentKey: String, in stages: [SaleStage]) -> [SaleStage] {
        guard !currentKey.isEmpty, !stages.contains(where: { $0.key == currentKey }) else { return stages }
        return stages + [SaleStage(key: currentKey, label: currentKey.capitalized, builtIn: false)]
    }
}
