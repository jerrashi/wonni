//
//  MercariRefresh.swift
//
//  The Mercari "Refresh" review step (BACKEND.md § Sold-out + sales tracking, decision 3;
//  mock https://claude.ai/artifact/9kVDXBohrFYbQQCzfHCaWp).
//
//  The scraper (MercariSaleSyncManager.scanForNewSales + loadSaleData) hands over what it
//  found. Nothing is recorded until the user has seen it:
//    1. `reviewMercariSales` classifies every row: new / recorded / discarded / invalid,
//       and says which product (if any) it matches.
//    2. The user unchecks what they don't want, links unmatched rows to a product, or
//       marks a row "Never import".
//    3. `recordMercariSalesBatch` records the checked rows (with `links` for the ones the
//       user matched by hand, so the server writes the Mercari id onto the product).
//
//  `MercariRefreshPlan` is the pure part (selection, payloads) and is unit-tested.
//  `MercariRefreshService` is the thin callable wrapper.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// MARK: - Rows

/// One scraped, enriched Mercari sale on the review list.
struct MercariRefreshRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case new, recorded, discarded, invalid
    }

    let id: String                 // Mercari item id
    var title: String
    var price: Double
    var takeHome: Double?
    var soldAt: Date?
    var thumbnailUrl: String?
    var trackingNumber: String?
    var kind: Kind = .new
    /// Matched by the server through a Mercari id already on a product / variant.
    var productId: String?
    var variantSku: String?
    var productTitle: String?
    var warning: String?

    /// The row as `recordMercariSalesBatch` / `reviewMercariSales` expect it
    /// (MercariScrapeItemSchema). Optional fields are omitted when empty so a bad
    /// thumbnail never fails the whole row's schema check.
    var scrapeDictionary: [String: Any] {
        var d: [String: Any] = ["mercariItemId": id, "priceSoldFor": price]
        if !title.isEmpty { d["title"] = title }
        if let takeHome { d["takeHome"] = takeHome }
        if let soldAt { d["soldAt"] = ISO8601DateFormatter().string(from: soldAt) }
        if let url = thumbnailUrl, let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true {
            d["thumbnailUrl"] = url
        }
        if let trackingNumber, !trackingNumber.isEmpty { d["trackingNumber"] = trackingNumber }
        return d
    }
}

/// The user's "this sale is that product" answer for an unmatched row.
struct MercariLink: Equatable {
    let productId: String
    let variantSku: String?
    let productTitle: String
    let variantLabel: String?
}

// MARK: - Plan

struct MercariRefreshPlan: Equatable {
    var rows: [MercariRefreshRow]
    /// Rows the user unchecked. Everything new starts checked (opt-out model).
    var unchecked: Set<String> = []
    var links: [String: MercariLink] = [:]

    /// Rows that can be imported at all.
    var importable: [MercariRefreshRow] { rows.filter { $0.kind == .new } }
    var selected: [MercariRefreshRow] { importable.filter { !unchecked.contains($0.id) } }
    var selectedCount: Int { selected.count }

    func isChecked(_ id: String) -> Bool { !unchecked.contains(id) }

    /// True when the row matches a product, by the server or by the user's link.
    func isMatched(_ row: MercariRefreshRow) -> Bool { row.productId != nil || links[row.id] != nil }

    mutating func toggle(_ id: String) {
        guard rows.first(where: { $0.id == id })?.kind == .new else { return }
        if unchecked.contains(id) { unchecked.remove(id) } else { unchecked.insert(id) }
    }

    /// Linking a row also checks it: choosing a product is an intent to import.
    mutating func link(_ id: String, to link: MercariLink) {
        links[id] = link
        unchecked.remove(id)
    }

    mutating func unlink(_ id: String) { links[id] = nil }

    /// Drops rows (after "Never import") so they leave the list at once.
    mutating func remove(_ ids: Set<String>) {
        rows.removeAll { ids.contains($0.id) }
        unchecked.subtract(ids)
        for id in ids { links[id] = nil }
    }

    /// Request body for `recordMercariSalesBatch`: only the checked rows, plus the
    /// user's links for those rows (never for rows that are not being imported).
    func recordPayload() -> [String: Any] {
        let chosen = selected
        var payload: [String: Any] = ["items": chosen.map(\.scrapeDictionary)]
        var linkMap: [String: Any] = [:]
        for row in chosen {
            guard let link = links[row.id] else { continue }
            var entry: [String: Any] = ["productId": link.productId]
            if let sku = link.variantSku { entry["variantSku"] = sku }
            linkMap[row.id] = entry
        }
        if !linkMap.isEmpty { payload["links"] = linkMap }
        return payload
    }

    /// Request body for `reviewMercariSales` (the scrape rows, newest first, as found).
    static func reviewPayload(_ rows: [MercariRefreshRow]) -> [String: Any] {
        ["items": rows.map(\.scrapeDictionary)]
    }

    /// Request body for `setMercariSalesDiscarded`.
    func discardPayload(ids: [String], discarded: Bool) -> [String: Any] {
        let items: [[String: Any]] = ids.compactMap { id in
            guard let row = rows.first(where: { $0.id == id }) else { return nil }
            var d: [String: Any] = ["mercariItemId": id, "priceSoldFor": row.price]
            if !row.title.isEmpty { d["title"] = row.title }
            return d
        }
        return ["items": items, "discarded": discarded]
    }

    /// Applies the server's classification to scraped rows.
    static func applying(_ review: ReviewMercariSalesResponse, to rows: [MercariRefreshRow]) -> [MercariRefreshRow] {
        let byId = Dictionary(review.rows.map { ($0.mercariItemId, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            guard let r = byId[row.id] else { return row }
            var out = row
            switch r.reviewState {
            case .new: out.kind = .new
            case .recorded: out.kind = .recorded
            case .discarded: out.kind = .discarded
            case .invalid: out.kind = .invalid
            }
            out.productId = r.productId
            out.variantSku = r.variantSku
            out.productTitle = r.productTitle
            out.warning = r.warning
            return out
        }
    }

    /// The scan's stop rule in one place: rows newer than the first already-recorded row.
    /// (The server reports `firstRecordedIndex`; rows from there on are known sales.)
    static func newerThanFirstRecorded(_ rows: [MercariRefreshRow], firstRecordedIndex: Int?) -> [MercariRefreshRow] {
        guard let i = firstRecordedIndex, i >= 0, i <= rows.count else { return rows }
        return Array(rows[..<i])
    }
}

// MARK: - Service

enum MercariRefreshService {
    private static var functions: Functions { Functions.functions() }

    /// Classifies scraped rows. Records nothing.
    static func review(_ rows: [MercariRefreshRow]) async throws -> ReviewMercariSalesResponse {
        guard !rows.isEmpty else { return ReviewMercariSalesResponse(firstRecordedIndex: nil, rows: []) }
        let callable = functions.httpsCallable("reviewMercariSales")
        callable.timeoutInterval = 120
        let result = try await callable.call(MercariRefreshPlan.reviewPayload(rows))
        return try decode(ReviewMercariSalesResponse.self, from: result.data)
    }

    /// Records the checked rows. Returns how many sales were newly recorded.
    static func record(_ plan: MercariRefreshPlan) async throws -> RecordMercariSalesBatchResponse {
        let callable = functions.httpsCallable("recordMercariSalesBatch")
        callable.timeoutInterval = 120
        let result = try await callable.call(plan.recordPayload())
        return try decode(RecordMercariSalesBatchResponse.self, from: result.data)
    }

    static func setDiscarded(_ plan: MercariRefreshPlan, ids: [String], discarded: Bool) async throws {
        guard !ids.isEmpty else { return }
        let callable = functions.httpsCallable("setMercariSalesDiscarded")
        _ = try await callable.call(plan.discardPayload(ids: ids, discarded: discarded))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from payload: Any) throws -> T {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw NSError(domain: "MercariRefresh", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read the server response."])
        }
        return decoded
    }

    // MARK: Link picker data

    struct LinkCandidate: Identifiable, Equatable {
        struct Variant: Identifiable, Equatable {
            let sku: String
            let label: String
            var id: String { sku }
        }
        let id: String            // products/{id}
        let title: String
        let variants: [Variant]
    }

    /// The user's products, for the "Link to product…" picker. One query; filtered on-device.
    static func linkCandidates() async -> [LinkCandidate] {
        guard let uid = Auth.auth().currentUser?.uid else { return [] }
        guard let snap = try? await Firestore.firestore().collection("products")
            .whereField("userId", isEqualTo: uid).getDocuments() else { return [] }
        return snap.documents.compactMap { doc in
            let data = doc.data()
            guard let title = data["title"] as? String, !title.isEmpty else { return nil }
            if data["isDeleted"] as? Bool == true { return nil }
            let variants: [LinkCandidate.Variant] = (data["variants"] as? [[String: Any]] ?? []).compactMap { v in
                guard let sku = v["sku"] as? String, !sku.isEmpty else { return nil }
                let values = (v["optionValues"] as? [String: Any])?.values.compactMap { $0 as? String } ?? []
                return .init(sku: sku, label: values.isEmpty ? sku : values.sorted().joined(separator: " / "))
            }
            return LinkCandidate(id: doc.documentID, title: title, variants: variants)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Case-insensitive, every word must appear. Empty query lists everything.
    static func filter(_ candidates: [LinkCandidate], query: String) -> [LinkCandidate] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return candidates }
        return candidates.filter { c in words.allSatisfy { c.title.lowercased().contains($0) } }
    }
}
