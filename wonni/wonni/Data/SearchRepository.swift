//
//  SearchRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

// MARK: - Models

struct TrendingSearch: Identifiable, Codable {
    @DocumentID var id: String?
    var query: String
    var sortOrder: Int
    var isActive: Bool
}

struct SearchHistoryEntry: Identifiable, Codable {
    @DocumentID var id: String?
    var query: String
    var searchedAt: Timestamp
}

struct SavedSearch: Identifiable, Codable {
    @DocumentID var id: String?
    var query: String
    var savedAt: Timestamp
}

/// Written by the `notifySavedSearchMatches` Cloud Function when a newly-published
/// listing matches one of this user's saved searches.
struct SearchMatchNotification: Identifiable, Codable {
    @DocumentID var id: String?
    var savedQuery: String
    var listingId: String
    var listingTitle: String?
    var listingPrice: Double?
    var listingPhotoPath: String?
    var createdAt: Timestamp
    var isRead: Bool
}

// MARK: - Search Repository

class SearchRepository {
    static let shared = SearchRepository()

    private let db = Firestore.firestore()
    private let maxHistoryCount = 10

    // MARK: - Trending

    func fetchTrending() async throws -> [TrendingSearch] {
        let snapshot = try await db.collection("trending")
            .whereField("isActive", isEqualTo: true)
            .getDocuments()
        return snapshot.documents
            .compactMap { try? $0.data(as: TrendingSearch.self) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Saved Searches

    private func savedSearchesCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SearchRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        return db.collection("users").document(uid).collection("savedSearches")
    }

    func fetchSavedSearches() async throws -> [SavedSearch] {
        let col = try savedSearchesCollection()
        let snapshot = try await col.order(by: "savedAt", descending: true).getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: SavedSearch.self) }
    }

    /// Saves a query. Uses lowercased query as document ID to prevent duplicates.
    func saveSearch(query: String) async throws {
        let col = try savedSearchesCollection()
        let key = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let entry = SavedSearch(query: query.trimmingCharacters(in: .whitespaces),
                                savedAt: Timestamp(date: Date()))
        try col.document(key).setData(from: entry)
    }

    func removeSavedSearch(entry: SavedSearch) async throws {
        guard let id = entry.id else { return }
        let col = try savedSearchesCollection()
        try await col.document(id).delete()
    }

    // MARK: - Saved-Search Match Notifications

    private func searchNotificationsCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SearchRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        return db.collection("users").document(uid).collection("searchNotifications")
    }

    func observeSearchNotifications(
        completion: @escaping (Result<[SearchMatchNotification], Error>) -> Void
    ) -> ListenerRegistration? {
        guard let col = try? searchNotificationsCollection() else {
            completion(.failure(NSError(domain: "SearchRepository", code: 401)))
            return nil
        }
        return col.order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error { completion(.failure(error)); return }
                let items = snapshot?.documents.compactMap { try? $0.data(as: SearchMatchNotification.self) } ?? []
                completion(.success(items))
            }
    }

    func markNotificationRead(_ notification: SearchMatchNotification) async throws {
        guard let id = notification.id else { return }
        let col = try searchNotificationsCollection()
        try await col.document(id).updateData(["isRead": true])
    }

    // MARK: - Search History

    private func historyCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SearchRepository", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        return db.collection("users").document(uid).collection("searchHistory")
    }

    func fetchHistory() async throws -> [SearchHistoryEntry] {
        let col = try historyCollection()
        let snapshot = try await col.order(by: "searchedAt", descending: true)
            .limit(to: maxHistoryCount)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: SearchHistoryEntry.self) }
    }

    /// Saves query to history. Uses query as document ID so re-searching
    /// the same term updates searchedAt rather than creating a duplicate.
    func addToHistory(query: String) async throws {
        let col = try historyCollection()
        let key = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let entry = SearchHistoryEntry(query: query.trimmingCharacters(in: .whitespaces),
                                       searchedAt: Timestamp(date: Date()))
        try col.document(key).setData(from: entry)

        let all = try await col.order(by: "searchedAt", descending: true).getDocuments()
        if all.documents.count > maxHistoryCount {
            let toDelete = all.documents.dropFirst(maxHistoryCount)
            for doc in toDelete { try await doc.reference.delete() }
        }
    }

    func removeFromHistory(entry: SearchHistoryEntry) async throws {
        guard let id = entry.id else { return }
        let col = try historyCollection()
        try await col.document(id).delete()
    }

    func clearHistory() async throws {
        let col = try historyCollection()
        let snapshot = try await col.getDocuments()
        for doc in snapshot.documents { try await doc.reference.delete() }
    }

    // MARK: - Search

    /// Token-based fuzzy search on customTitle: order-independent (each query word can
    /// match any title word) and typo-tolerant (edit-distance matching scaled to word
    /// length). Returns active listings only, best matches first.
    /// Upgrade path: replace body with Algolia/Typesense client call — interface stays identical.
    func search(query: String) async throws -> [UserListing] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let queryTokens = Self.tokenize(trimmed)
        guard !queryTokens.isEmpty else { return [] }

        // Fetches the active catalog client-side since Firestore can't do fuzzy/
        // token matching server-side. Fine at current scale; revisit with a real
        // search index (Algolia/Typesense) once the catalog outgrows this.
        let snapshot = try await db.collection("listings")
            .whereField("status", isEqualTo: ListingStatus.active.rawValue)
            .limit(to: 500)
            .getDocuments()

        let scored: [(listing: UserListing, score: Double)] = snapshot.documents.compactMap { doc in
            guard let listing = try? doc.data(as: UserListing.self) else { return nil }
            let titleTokens = Self.tokenize(listing.customTitle ?? "")
            guard let score = Self.matchScore(queryTokens: queryTokens, titleTokens: titleTokens) else { return nil }
            return (listing, score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(60)
            .map { $0.listing }
    }

    // MARK: - Fuzzy Matching

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Average per-token match quality, or nil if any query token has no acceptable
    /// match in the title (i.e. all query words must be present in some form).
    private static func matchScore(queryTokens: [String], titleTokens: [String]) -> Double? {
        guard !queryTokens.isEmpty else { return nil }
        var total = 0.0
        for token in queryTokens {
            guard let best = tokenMatchScore(query: token, titleTokens: titleTokens) else { return nil }
            total += best
        }
        return total / Double(queryTokens.count)
    }

    /// Best match quality between one query token and any title token: 1.0 for an exact
    /// match, 0.85 for a prefix match (handles partial typing and shortened words), and a
    /// distance-scaled score for typos. The edit-distance tolerance (maxLen / 3, min 1) is
    /// the knob that controls how forgiving search feels — loosen it and unrelated short
    /// words start matching each other; tighten it and real typos like "penicl" stop
    /// finding "pencil".
    private static func tokenMatchScore(query: String, titleTokens: [String]) -> Double? {
        var best: Double?
        for token in titleTokens {
            let score: Double
            if token == query {
                score = 1.0
            } else if token.hasPrefix(query) || query.hasPrefix(token) {
                score = 0.85
            } else {
                let distance = levenshteinDistance(query, token)
                let maxLen = max(query.count, token.count)
                let allowedDistance = max(1, maxLen / 3)
                guard distance <= allowedDistance else { continue }
                score = 1.0 - (Double(distance) / Double(maxLen))
            }
            if best == nil || score > best! { best = score }
        }
        return best
    }

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previousRow = Array(0...bChars.count)
        var currentRow = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            currentRow[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                currentRow[j] = min(
                    previousRow[j] + 1,
                    currentRow[j - 1] + 1,
                    previousRow[j - 1] + cost
                )
            }
            previousRow = currentRow
        }
        return previousRow[bChars.count]
    }
}
