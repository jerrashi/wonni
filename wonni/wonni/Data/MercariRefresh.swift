//
//  MercariRefresh.swift
//
//  Mercari sales on Refresh (mock https://claude.ai/artifact/3N5S6mWWBA36jptkxDtygP v4,
//  approved 2026-11-14; BACKEND.md § Sold-out + sales tracking, decision 3 as amended).
//
//  The scraper (MercariSaleSyncManager.scanForNewSales + loadSaleData) hands over what it
//  found, newest first, stopping at the first sale Wonni has already seen. Then:
//    1. `reviewMercariSales {autoImport}` records every row linked to a product by its
//       Mercari id that has a title, price and sold date (toast with Undo →
//       `undoMercariAutoImport`), and parks every other row in the server-side inbox
//       (users/{uid}/mercariSaleInbox) as "pending". The inbox survives refreshes and
//       devices, which is why a stop-at-known refresh never loses a sale.
//    2. The banner shows how many wait; the review sheet lists them: "Needs info" (no
//       price / date / title, can't be checked until edited), "Ready", "Never import".
//       Every row opens an edit form. A "Not linked" row imports with no stock change.
//    3. `recordMercariSalesBatch {allowUnlinked}` records the checked rows (with `links`
//       for products the user picked or a confirmed "Suggested" title match).
//
//  `MercariRefreshPlan` is the pure part (selection, payloads) and is unit-tested.
//  `MercariRefreshService` is the thin callable wrapper.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// MARK: - Tabs

/// The two lists Mercari keeps under mypage/listings. Raw value is the URL segment.
enum MercariSaleTab: String, CaseIterable {
    case inProgress = "in_progress"
    case complete
}

// MARK: - Rows

/// One Mercari sale on the review list (scraped, or read back from the inbox).
struct MercariRefreshRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case new, recorded, discarded, invalid
    }

    let id: String                 // Mercari item id
    var orderId: String?
    var title: String
    var price: Double?
    var takeHome: Double?
    /// True while take-home is our fee estimate, not Mercari's own number.
    var takeHomeEstimated = false
    var soldAt: Date?
    var quantity = 1
    var thumbnailUrl: String?
    var trackingNumber: String?
    var kind: Kind = .new
    /// Matched by the server through a Mercari id already on a product / variant.
    var productId: String?
    var variantSku: String?
    var productTitle: String?
    /// Title-only guess from the server. Shown as "Suggested"; imported only when the
    /// user imports the row without changing it.
    var suggestedProductId: String?
    var suggestedProductTitle: String?
    var warning: String?

    init(id: String, title: String, price: Double?, kind: Kind = .new) {
        self.id = id
        self.title = title
        self.price = price
        self.kind = kind
    }

    /// Required fields this row still lacks ("title", "price", "date").
    var missing: [String] {
        var out: [String] = []
        if title.trimmingCharacters(in: .whitespaces).isEmpty { out.append("title") }
        if (price ?? 0) <= 0 { out.append("price") }
        if soldAt == nil { out.append("date") }
        return out
    }

    /// The row as `recordMercariSalesBatch` / `reviewMercariSales` expect it
    /// (MercariScrapeItemSchema). Optional fields are omitted when empty so a bad
    /// thumbnail never fails the whole row's schema check.
    var scrapeDictionary: [String: Any] {
        var d: [String: Any] = ["mercariItemId": id]
        if let price, price > 0 { d["priceSoldFor"] = price }
        if let orderId, !orderId.isEmpty { d["mercariOrderId"] = orderId }
        if !title.isEmpty { d["title"] = title }
        if let takeHome { d["takeHome"] = takeHome }
        if let soldAt { d["soldAt"] = ISO8601DateFormatter().string(from: soldAt) }
        if quantity > 1 { d["quantity"] = quantity }
        if let url = thumbnailUrl, let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true {
            d["thumbnailUrl"] = url
        }
        if let trackingNumber, !trackingNumber.isEmpty { d["trackingNumber"] = trackingNumber }
        return d
    }

    /// Mercari US fees as of 2025: 10% selling + 2.9% + $0.50 processing. Estimate only.
    static func estimatedTakeHome(_ price: Double?) -> Double? {
        guard let price, price > 0 else { return nil }
        return ((price - price * 0.129 - 0.5) * 100).rounded() / 100
    }
}

/// The user's "this sale is that product" answer.
struct MercariLink: Equatable {
    let productId: String
    let variantSku: String?
    let productTitle: String
    let variantLabel: String?
}

// MARK: - Inbox (server-side review list)

/// users/{uid}/mercariSaleInbox as the server returns it. Hand-written so the app does not
/// depend on the per-callable quicktype names (`PurplePending` …) for the same shape.
struct MercariInbox: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        struct Item: Decodable, Equatable {
            let mercariItemId: String
            var mercariOrderId: String?
            var title: String?
            var priceSoldFor: Double?
            var takeHome: Double?
            var soldAtText: String?
            var soldAtMillis: Double?
            var soldDate: String?
            var quantity: Int?
            var thumbnailUrl: String?
            var trackingNumber: String?

            enum CodingKeys: String, CodingKey {
                case mercariItemId, mercariOrderId, title, priceSoldFor, takeHome, soldAt, soldDate, soldDateText
                case quantity, thumbnailUrl, trackingNumber
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                mercariItemId = try c.decode(String.self, forKey: .mercariItemId)
                mercariOrderId = try? c.decodeIfPresent(String.self, forKey: .mercariOrderId)
                title = try? c.decodeIfPresent(String.self, forKey: .title)
                priceSoldFor = try? c.decodeIfPresent(Double.self, forKey: .priceSoldFor)
                takeHome = try? c.decodeIfPresent(Double.self, forKey: .takeHome)
                // soldAt is an ISO string (app) or epoch ms; the extension sends soldDate "mm/dd/yy".
                soldAtText = try? c.decodeIfPresent(String.self, forKey: .soldAt)
                soldAtMillis = try? c.decodeIfPresent(Double.self, forKey: .soldAt)
                soldDate = (try? c.decodeIfPresent(String.self, forKey: .soldDate))
                    ?? (try? c.decodeIfPresent(String.self, forKey: .soldDateText))
                quantity = try? c.decodeIfPresent(Int.self, forKey: .quantity)
                thumbnailUrl = try? c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
                trackingNumber = try? c.decodeIfPresent(String.self, forKey: .trackingNumber)
            }

            var soldAt: Date? {
                if let soldAtMillis { return Date(timeIntervalSince1970: soldAtMillis / 1000) }
                if let soldAtText {
                    let f = ISO8601DateFormatter()
                    if let d = f.date(from: soldAtText) { return d }
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = f.date(from: soldAtText) { return d }
                }
                return soldDate.flatMap { MercariDateParsing.parseSoldDate($0) }
            }
        }

        let item: Item
        let inboxState: String
        var productId: String?
        var variantSku: String?
        var productTitle: String?
        var suggestedProductId: String?
        var suggestedProductTitle: String?
    }

    var pending: [Entry]
    var discarded: [Entry]

    static let empty = MercariInbox(pending: [], discarded: [])

    /// Every Mercari item id the inbox knows (waiting or hidden): the scan stops at these.
    var knownIds: Set<String> { Set((pending + discarded).map(\.item.mercariItemId)) }
}

extension MercariRefreshRow {
    init(entry: MercariInbox.Entry, kind: Kind) {
        let it = entry.item
        self.init(id: it.mercariItemId, title: it.title ?? "", price: it.priceSoldFor, kind: kind)
        orderId = it.mercariOrderId
        takeHome = it.takeHome
        soldAt = it.soldAt
        quantity = max(1, it.quantity ?? 1)
        thumbnailUrl = it.thumbnailUrl
        trackingNumber = it.trackingNumber
        productId = entry.productId
        variantSku = entry.variantSku
        productTitle = entry.productTitle
        suggestedProductId = entry.suggestedProductId
        suggestedProductTitle = entry.suggestedProductTitle
    }
}

// MARK: - Plan

struct MercariRefreshPlan: Equatable {
    var rows: [MercariRefreshRow]
    /// Rows the user unchecked. Every complete new row starts checked (opt-out model).
    var unchecked: Set<String> = []
    var links: [String: MercariLink] = [:]
    /// Rows whose "Suggested" product the user removed (import them unlinked).
    var declinedSuggestions: Set<String> = []

    init(rows: [MercariRefreshRow]) { self.rows = rows }

    /// The review list for what is waiting in the inbox (+ the hidden rows for Restore).
    init(inbox: MercariInbox) {
        rows = inbox.pending.map { MercariRefreshRow(entry: $0, kind: .new) }
            + inbox.discarded.map { MercariRefreshRow(entry: $0, kind: .discarded) }
    }

    /// Rows that can be imported at all (once complete).
    var importable: [MercariRefreshRow] { rows.filter { $0.kind == .new } }
    /// New rows missing a title, price or date: listed first, can't be checked.
    var needsInfo: [MercariRefreshRow] { importable.filter { !$0.missing.isEmpty } }
    var ready: [MercariRefreshRow] { importable.filter { $0.missing.isEmpty } }
    var selected: [MercariRefreshRow] { ready.filter { !unchecked.contains($0.id) } }
    var selectedCount: Int { selected.count }

    func isChecked(_ id: String) -> Bool {
        guard let row = rows.first(where: { $0.id == id }), row.missing.isEmpty else { return false }
        return !unchecked.contains(id)
    }

    /// What the row will be linked to on import: the server's id match, the user's pick,
    /// or the Suggested title match (unless the user removed it).
    enum Product: Equatable {
        case matched(title: String?)
        case linked(MercariLink)
        case suggested(id: String, title: String?)
        case none
    }

    func product(for row: MercariRefreshRow) -> Product {
        if row.productId != nil { return .matched(title: row.productTitle) }
        if let link = links[row.id] { return .linked(link) }
        if let id = row.suggestedProductId, !declinedSuggestions.contains(row.id) {
            return .suggested(id: id, title: row.suggestedProductTitle)
        }
        return .none
    }

    /// True when the row will lower stock on import.
    func isMatched(_ row: MercariRefreshRow) -> Bool { product(for: row) != .none }

    mutating func toggle(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), row.kind == .new, row.missing.isEmpty else { return }
        if unchecked.contains(id) { unchecked.remove(id) } else { unchecked.insert(id) }
    }

    /// Linking a row also checks it: choosing a product is an intent to import.
    mutating func link(_ id: String, to link: MercariLink) {
        links[id] = link
        unchecked.remove(id)
    }

    /// Removes the user's link, or declines the Suggested product.
    mutating func unlink(_ id: String) {
        if links[id] != nil { links[id] = nil } else { declinedSuggestions.insert(id) }
    }

    /// The edit form's Done: replaces the row's fields and checks it.
    mutating func update(_ row: MercariRefreshRow) {
        guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[i] = row
        unchecked.remove(row.id)
    }

    /// Rows the user hid with "Never import".
    var hidden: [MercariRefreshRow] { rows.filter { $0.kind == .discarded } }

    /// Puts a hidden row back on the import list (after the server has un-hidden it).
    mutating func restore(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].kind == .discarded else { return }
        rows[i].kind = .new
        unchecked.remove(id)
    }

    /// "Never import": the row moves to the hidden section.
    mutating func hide(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].kind = .discarded
        unchecked.remove(id)
        links[id] = nil
    }

    /// Drops rows so they leave the list at once.
    mutating func remove(_ ids: Set<String>) {
        rows.removeAll { ids.contains($0.id) }
        unchecked.subtract(ids)
        for id in ids { links[id] = nil }
    }

    /// Request body for `recordMercariSalesBatch`: only the checked rows, plus the
    /// product each one is linked to (never for rows that are not being imported).
    /// `allowUnlinked`: a "Not linked" row records with no product and no stock change.
    func recordPayload() -> [String: Any] {
        let chosen = selected
        var payload: [String: Any] = ["items": chosen.map(\.scrapeDictionary), "allowUnlinked": true]
        var linkMap: [String: Any] = [:]
        for row in chosen {
            switch product(for: row) {
            case .linked(let link):
                var entry: [String: Any] = ["productId": link.productId]
                if let sku = link.variantSku { entry["variantSku"] = sku }
                linkMap[row.id] = entry
            case .suggested(let id, _):
                linkMap[row.id] = ["productId": id]
            case .matched, .none:
                continue
            }
        }
        if !linkMap.isEmpty { payload["links"] = linkMap }
        return payload
    }

    /// Request body for `reviewMercariSales` (the scrape rows, newest first, as found).
    /// `recordLinked` false = the "Auto-import linked Mercari sales" switch is off: every row waits.
    static func reviewPayload(_ rows: [MercariRefreshRow], recordLinked: Bool = true) -> [String: Any] {
        ["items": rows.map(\.scrapeDictionary), "autoImport": true, "recordLinked": recordLinked]
    }

    /// Request body for `setMercariSalesDiscarded`.
    func discardPayload(ids: [String], discarded: Bool) -> [String: Any] {
        let items: [[String: Any]] = ids.compactMap { id in
            guard let row = rows.first(where: { $0.id == id }) else { return nil }
            var d: [String: Any] = ["mercariItemId": id]
            if let price = row.price, price > 0 { d["priceSoldFor"] = price }
            if let orderId = row.orderId { d["mercariOrderId"] = orderId }
            if !row.title.isEmpty { d["title"] = row.title }
            return d
        }
        return ["items": items, "discarded": discarded]
    }

    /// The scan's stop rule in one place: rows newer than the first already-recorded row.
    static func newerThanFirstRecorded(_ rows: [MercariRefreshRow], firstRecordedIndex: Int?) -> [MercariRefreshRow] {
        guard let i = firstRecordedIndex, i >= 0, i <= rows.count else { return rows }
        return Array(rows[..<i])
    }
}

// MARK: - Service

enum MercariRefreshService {
    private static var functions: Functions { Functions.functions() }

    /// What a refresh's review call did: rows recorded on their own, and the inbox now.
    struct ReviewOutcome: Equatable {
        var autoRecordedIds: [String]
        var inbox: MercariInbox
    }

    /// Records the id-linked complete rows, parks the rest in the inbox.
    static func review(_ rows: [MercariRefreshRow], recordLinked: Bool = true) async throws -> ReviewOutcome {
        guard !rows.isEmpty else { return ReviewOutcome(autoRecordedIds: [], inbox: try await inbox()) }
        let callable = functions.httpsCallable("reviewMercariSales")
        callable.timeoutInterval = 300
        let result = try await callable.call(MercariRefreshPlan.reviewPayload(rows, recordLinked: recordLinked))
        let dict = result.data as? [String: Any] ?? [:]
        let ids = (dict["rows"] as? [[String: Any]] ?? [])
            .filter { $0["reviewState"] as? String == "autoRecorded" }
            .compactMap { $0["mercariItemId"] as? String }
        return ReviewOutcome(autoRecordedIds: ids, inbox: try decode(MercariInbox.self, from: dict["inbox"] ?? [:]))
    }

    /// What is waiting / hidden, without a scan (banner on appear).
    static func inbox() async throws -> MercariInbox {
        let result = try await functions.httpsCallable("listMercariSaleInbox").call([:])
        return try decode(MercariInbox.self, from: result.data)
    }

    /// The toast's Undo: deletes the auto-recorded sales, restores stock, back to review.
    static func undoAutoImport(ids: [String]) async throws -> MercariInbox {
        let callable = functions.httpsCallable("undoMercariAutoImport")
        callable.timeoutInterval = 120
        let result = try await callable.call(["items": ids.map { ["mercariItemId": $0] }])
        let dict = result.data as? [String: Any] ?? [:]
        return try decode(MercariInbox.self, from: dict["inbox"] ?? [:])
    }

    /// Records the checked rows.
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

    static func decode<T: Decodable>(_ type: T.Type, from payload: Any) throws -> T {
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
