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

    /// Raw-dictionary fetch — `products` docs carry wonni_dropship's own schema, and no
    /// single Swift `Codable` model exists for the WHOLE doc yet (title, pricing, images,
    /// source-specific fields, etc. are all still loose dict access — see
    /// `fetchProductVariants` below for the one part of the doc that IS typed).
    func fetchProduct(productId: String) async throws -> [String: Any]? {
        let snap = try await db.collection(productsCollection).document(productId).getDocument()
        return snap.data()
    }

    /// Typed read of just the variant-related subset of `products/{id}` — `options`,
    /// `variants`, `hasVariants`, `quantityVariesByVariant` — decoded into the
    /// generated `ProductDoc` / `Variant` / `Option` structs (`Generated/BackendContracts.swift`,
    /// sourced from `functions/contracts/products.js`). Everything else on the doc still
    /// goes through `fetchProduct`'s raw dict; see that method's doc comment.
    ///
    /// Returns `nil` if the doc doesn't exist. A doc that exists but predates variants
    /// (no `options`/`variants` keys at all) decodes fine — every field on `ProductDoc`
    /// is optional/defaulted in the JSON Schema this was generated from.
    func fetchProductVariants(productId: String) async throws -> ProductDoc? {
        let snap = try await db.collection(productsCollection).document(productId).getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: ProductDoc.self)
    }

    /// Typed read of `products/{id}.imageAssets[]` — the per-photo array
    /// `variantTags` live on (see `VariantEditing.swift`'s `ProductImageAsset`/
    /// `variantPhotos` for the matching rules). Not part of the generated
    /// `ProductDoc` contract (only the variant subset is covered there — see
    /// `functions/contracts/products.js`'s file header), so this decodes the
    /// field straight out of the raw dict `fetchProduct` already returns
    /// rather than adding a second network round-trip.
    func fetchProductImageAssets(productId: String) async throws -> [ProductImageAsset] {
        guard let data = try await fetchProduct(productId: productId) else { return [] }
        guard let raw = data["imageAssets"] as? [[String: Any]] else { return [] }
        let jsonData = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([ProductImageAsset].self, from: jsonData)
    }

    /// Merge-writes the WHOLE `imageAssets` array — same whole-array-replace
    /// rule as `syncVariants` (see that method's doc comment): never patch a
    /// single element by dotted path.
    func syncProductImageAssets(productId: String, imageAssets: [ProductImageAsset]) async throws {
        let jsonData = try JSONEncoder().encode(imageAssets)
        let array = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] ?? []
        try await syncProduct(productId: productId, data: ["imageAssets": array])
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

    /// Merge-writes the WHOLE `options`/`variants` arrays onto `products/{productId}`,
    /// plus the `hasVariants`/`quantityVariesByVariant` flags. This is the ONLY entry
    /// point for touching variant data — never write a dotted path like
    /// `"variants.2.price"`: Firestore coerces a dotted numeric segment into a map key,
    /// which silently turns the whole `variants` array into a `{"0": …, "1": …, "2": …}`
    /// map and corrupts every other reader of the doc (web, the eBay/Mercari cross-post
    /// functions). See `functions/ebay_listing.js` / `functions/sales.js` for the
    /// server-side comments explaining the same rule, enforced there by always
    /// read-modify-writing the full array.
    ///
    /// No UI calls this yet — iOS has no variant-editing surface (that's a later
    /// phase). This is data-layer plumbing for that phase, and for anything server-side
    /// that needs iOS to push a full variant set (e.g. importing a multi-variant
    /// Weverse/AliExpress source).
    func syncVariants(
        productId: String,
        options: [Option],
        variants: [Variant],
        hasVariants: Bool,
        quantityVariesByVariant: Bool
    ) async throws {
        let encoder = Firestore.Encoder()
        let data: [String: Any] = [
            "options": try options.map { try encoder.encode($0) },
            "variants": try variants.map { try encoder.encode($0) },
            "hasVariants": hasVariants,
            "quantityVariesByVariant": quantityVariesByVariant,
            "updatedAt": Timestamp(date: Date()),
        ]
        try await db.collection(productsCollection).document(productId)
            .setData(data, merge: true)
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
    /// The `options`/`variants`/`hasVariants`/`quantityVariesByVariant` params are
    /// pass-through plumbing, not wired to real data yet: `UserListing` (iOS's own
    /// listing model) has no variant fields today, and no iOS UI produces variant
    /// data — there's nothing to source them from until a later phase builds
    /// variant-editing. They're accepted here (default `nil`/`false`, so every
    /// existing call site compiles unchanged) purely so this is the ONE place a
    /// future caller needs to touch to start carrying variants through this path,
    /// instead of this method silently dropping them the way it does today.
    func syncProductFromListing(
        _ listing: UserListing,
        options: [Option]? = nil,
        variants: [Variant]? = nil,
        hasVariants: Bool? = nil,
        quantityVariesByVariant: Bool? = nil
    ) async throws {
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
        // `listing.photoPaths` are bare Storage object keys (kept that way — deletion,
        // cross-post webviews, and templates all still key off the bare path). `products`
        // is the one field web/every Cloud Function reads directly as `<img src>`, so it
        // needs the resolved public URL, same convention StorageService.publicURL already
        // uses when it writes `products.images` from a fresh Storage upload.
        data["images"] = listing.photoPaths.map { StorageService.shared.publicURL(forPath: $0) }
        if let shipping = listing.shippingInfo {
            data["buyerPaysShipping"] = shipping.buyerPaysShipping
            data["handlingFee"] = shipping.handlingFee
            data["estimatedShippingDays"] = shipping.estimatedShippingDays
            data["handlingTimeDays"] = shipping.handlingTimeDays as Any
            data["weightLbs"] = shipping.weightLbs as Any
        }
        if let crossPostStatus = listing.crossPostStatus { data["crossPostStatus"] = crossPostStatus }
        if let crossPostListingIds = listing.crossPostListingIds { data["crossPostListingIds"] = crossPostListingIds }
        if let options {
            let encoder = Firestore.Encoder()
            data["options"] = try options.map { try encoder.encode($0) }
        }
        if let variants {
            let encoder = Firestore.Encoder()
            data["variants"] = try variants.map { try encoder.encode($0) }
        }
        if let hasVariants { data["hasVariants"] = hasVariants }
        if let quantityVariesByVariant { data["quantityVariesByVariant"] = quantityVariesByVariant }
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
