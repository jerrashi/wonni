//
//  ProductRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

/// The shared `products/{id}` collection wonni_dropship (web) already owns and iOS now
/// also writes into — the single "Product" record described in the cross-platform draft
/// continuity plan: an unpublished-or-ready working item, distinct from `listings`
/// (ListingRepository's collection), which is only ever a real, published, for-sale
/// posting. A product only ever becomes a `listings` doc via the explicit "Post to
/// Wonni" action (`postToWonni` Cloud Function), never automatically here.
///
/// Unlike `ListingRepository`, every write here is a `merge: true` set — a product may
/// not have a Firestore doc yet (a brand-new iOS draft) or may already (something
/// continued from web), and the caller shouldn't need to know which.
class ProductRepository: ObservableObject {
    static let shared = ProductRepository()

    private let db = Firestore.firestore()
    private let productsCollection = "products"

    /// Creates or updates `products/{productId}` with `data`, merging rather than
    /// overwriting — safe to call repeatedly as a draft is edited, regardless of
    /// whether the doc already exists.
    func syncProduct(productId: String, data: [String: Any]) async throws {
        try await db.collection(productsCollection).document(productId)
            .setData(data, merge: true)
    }

    /// Raw-dictionary fetch — `products` docs carry wonni_dropship's own schema (no
    /// Swift `Codable` model exists for it yet), so this intentionally doesn't attempt
    /// to decode into a typed struct the way `ListingRepository` does for `UserListing`.
    func fetchProduct(productId: String) async throws -> [String: Any]? {
        let snap = try await db.collection(productsCollection).document(productId).getDocument()
        return snap.data()
    }

    /// "Desktop Drafts" — dropship (web-originated) products still in progress
    /// (`isDraft != false`), for the iOS side of the "start on one client, finish on
    /// the other" flow. Filters out `source == "ios"` client-side rather than adding a
    /// `!=` Firestore filter — this reuses the exact same `userId`+`isDraft` composite
    /// index dropship's own web dashboard already needs (see wonni's
    /// firestore.indexes.json), instead of requiring a second one just for this query.
    func fetchDesktopDrafts(userId: String) async throws -> [(id: String, data: [String: Any])] {
        let snap = try await db.collection(productsCollection)
            .whereField("userId", isEqualTo: userId)
            .whereField("isDraft", isEqualTo: true)
            .getDocuments()
        return snap.documents
            .filter { ($0.data()["source"] as? String) != "ios" }
            .map { (id: $0.documentID, data: $0.data()) }
    }
}
