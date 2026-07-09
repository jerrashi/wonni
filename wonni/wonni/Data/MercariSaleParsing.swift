//
//  MercariSaleParsing.swift
//  wonni
//
//  Pure logic only — no Firebase/WebKit imports — so this is unit-testable without
//  mocking network/Firestore/WKWebView.
//

import Foundation

/// What a pasted string resolved to. `id` conformance lets it drive
/// `.navigationDestination(item:)` directly.
enum MercariInputDetection: Hashable, Identifiable {
    case itemId(String)
    case orderStatusURL(itemId: String)
    case itemURL(itemId: String)
    case unrecognized

    var id: String {
        switch self {
        case .itemId(let id): return "itemId:\(id)"
        case .orderStatusURL(let id): return "orderStatusURL:\(id)"
        case .itemURL(let id): return "itemURL:\(id)"
        case .unrecognized: return "unrecognized"
        }
    }

    var itemId: String? {
        switch self {
        case .itemId(let id), .orderStatusURL(let id), .itemURL(let id): return id
        case .unrecognized: return nil
        }
    }
}

/// Detects a bare Mercari item ID, a Mercari order-status URL, or a Mercari item URL from
/// free-text input. Ported from AddSaleView.swift's `fetchFromURL()` regex cascade, minus
/// all async/network calls, so the detection logic itself is testable.
enum MercariURLDetector {
    static func detect(_ rawInput: String) -> MercariInputDetection {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .unrecognized }

        if input.range(of: #"^m[a-zA-Z0-9]+$"#, options: .regularExpression) != nil {
            return .itemId(input)
        }

        guard input.contains("mercari.com") else { return .unrecognized }

        let orderStatusPattern = #"/transaction/order_status/(m[a-zA-Z0-9]+)"#
        if let range = input.range(of: orderStatusPattern, options: .regularExpression),
           let idRange = input[range].range(of: #"m[a-zA-Z0-9]+"#, options: .regularExpression) {
            return .orderStatusURL(itemId: String(input[range][idRange]))
        }

        let itemPattern = #"/item/(m[a-zA-Z0-9]+)"#
        if let range = input.range(of: itemPattern, options: .regularExpression),
           let idRange = input[range].range(of: #"m[a-zA-Z0-9]+"#, options: .regularExpression) {
            return .itemURL(itemId: String(input[range][idRange]))
        }

        return .unrecognized
    }
}

/// Consolidates the MM/dd/yy / MM/dd/yyyy Mercari sold-date parsing that's currently
/// duplicated across several scrape call sites — single source of truth for new code.
enum MercariDateParsing {
    private static let shortYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy"
        return f
    }()

    private static let longYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy"
        return f
    }()

    static func parseSoldDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return shortYearFormatter.date(from: trimmed) ?? longYearFormatter.date(from: trimmed)
    }
}

/// Field-presence check used to decide whether a scraped Mercari sale item still needs the
/// user to fix something before it can be imported — pulled out of
/// `MercariSalesImportSheet.isFlagged` so it's independently testable.
enum MercariSaleValidation {
    static func needsFix(name: String?, price: Double?, takeHome: Double?, soldAt: Date?) -> Bool {
        let hasName = !(name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPrice = (price ?? 0) > 0
        let hasTakeHome = takeHome != nil
        let hasSoldAt = soldAt != nil
        return !(hasName && hasPrice && hasTakeHome && hasSoldAt)
    }
}
