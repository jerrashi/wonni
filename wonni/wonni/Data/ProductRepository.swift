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

    /// `products/{listing.id}` twin for a `UserListing` written straight into `listings`
    /// (bulk Mercari import, single-URL import, "sell similar" duplication — none of
    /// these go through UploadManager's `Item`-draft flow, so nothing else ever calls
    /// `syncProduct` for them). Without this, the listing has no `products` doc: it's
    /// invisible to web/every Cloud Function, and `ebayCreateListing`/`etsyCreateListing`
    /// (called with the listing's own id as `productId` — see ProfileView) fail outright
    /// because there's nothing at that id in `products`.
    ///
    /// Most of these listings are already `status: .active` at creation (bulk/URL
    /// import re-posts something already live elsewhere); "sell similar" duplication
    /// is the one path that creates a genuine `status: .draft` copy instead. `isDraft`
    /// mirrors `listing.status` either way, same as the `Item`-draft path tracks the
    /// draft's own in-progress state.
    func syncProductFromListing(_ listing: UserListing) async throws {
        guard let productId = listing.id else { return }
        var data: [String: Any] = [:]
        data["userId"] = listing.userId
        data["source"] = "ios"
        data["isDraft"] = (listing.status == .draft)
        data["title"] = listing.customTitle
        data["description"] = listing.customDescription
        data["listingPrice"] = listing.price
        data["condition"] = Self.webCondition(for: listing.condition)
        data["category"] = listing.category
        data["brand"] = listing.brand
        data["tags"] = listing.tags
        data["personalNote"] = listing.personalNote
        data["images"] = listing.photoPaths
        if let shipping = listing.shippingInfo {
            data["buyerPaysShipping"] = shipping.buyerPaysShipping
            data["handlingFee"] = shipping.handlingFee
            data["estimatedShippingDays"] = shipping.estimatedShippingDays
            data["handlingTimeDays"] = shipping.handlingTimeDays as Any
            data["weightLbs"] = shipping.weightLbs as Any
        }
        if let crossPostStatus = listing.crossPostStatus { data["crossPostStatus"] = crossPostStatus }
        if let crossPostListingIds = listing.crossPostListingIds { data["crossPostListingIds"] = crossPostListingIds }
        data["updatedAt"] = Timestamp(date: Date())
        try await syncProduct(productId: productId, data: data)
    }

    /// `ItemCondition`'s raw values (`likeNew`, `newWithoutTags`, `forParts`, …) aren't
    /// the same strings as web's canonical `product.condition` enum
    /// (`new|likenew|good|fair|poor` — see CLAUDE.md open work item on this exact
    /// mismatch). `newWithoutTags` and `forParts` have no dedicated web value; folded
    /// into the closest neighbor rather than left unmapped.
    private static func webCondition(for condition: ItemCondition) -> String {
        switch condition {
        case .new, .newWithoutTags: return "new"
        case .likeNew: return "likenew"
        case .good: return "good"
        case .fair: return "fair"
        case .poor, .forParts: return "poor"
        }
    }
}
