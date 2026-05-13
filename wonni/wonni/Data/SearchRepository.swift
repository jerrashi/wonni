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

        // Trim to maxHistoryCount by deleting oldest entries beyond the cap
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

    /// Prefix-match search on customTitle. Returns active listings only.
    /// Upgrade path: replace body with Algolia client call — interface stays identical.
    func search(query: String) async throws -> [UserListing] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let endBound = trimmed + "\u{f8ff}"
        let snapshot = try await db.collection("listings")
            .whereField("customTitle", isGreaterThanOrEqualTo: trimmed)
            .whereField("customTitle", isLessThan: endBound)
            .limit(to: 60)
            .getDocuments()

        return snapshot.documents
            .compactMap { try? $0.data(as: UserListing.self) }
            .filter { $0.status == .active }
    }
}
