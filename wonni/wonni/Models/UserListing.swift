//
//  UserListing.swift
//  wonni
//
//  A seller's offer to sell one or more InventoryUnits.
//  - Single item:  inventoryUnitIds = [unitId]
//  - Bundle:       inventoryUnitIds = [bucketId, cupId]
//
//  When a listing sells, ALL referenced InventoryUnits are decremented by 1.
//  This means selling the combo auto-marks individual units as unavailable.
//

import Foundation
import FirebaseFirestore

// MARK: - Supporting Types

enum ItemCondition: String, Codable, CaseIterable {
    case new            = "new"
    case newWithoutTags = "newWithoutTags"
    case likeNew        = "likeNew"
    case good           = "good"
    case fair           = "fair"
    case poor           = "poor"
    case forParts       = "forParts"

    var displayName: String {
        switch self {
        case .new:            return "New"
        case .newWithoutTags: return "New without tags"
        case .likeNew:        return "Used - Like New"
        case .good:           return "Used - Good"
        case .fair:           return "Used - Fair"
        case .poor:           return "Used - Poor"
        case .forParts:       return "For Parts"
        }
    }
}

enum ListingStatus: String, Codable {
    case draft      = "draft"
    case active     = "active"
    case sold       = "sold"
    case cancelled  = "cancelled"
    case archived   = "archived"
}

struct ShippingInfo: Codable {
    var buyerPaysShipping: Bool
    var handlingFee: Double
    var estimatedShippingDays: Int
    var weightLbs: Double?
    var packageDimensions: PackageDimensions?
}

struct PackageDimensions: Codable {
    var lengthIn: Double
    var widthIn: Double
    var heightIn: Double
}

// MARK: - Variations

enum VariationStrategy: String, Codable {
    case singleListing     // All variations on one listing (Etsy default; eBay variesBy)
    case separateListings  // Each variation becomes its own listing
}

struct VariationAttribute: Codable {
    var name: String    // "Size", "Color" — maps to Etsy property_name / eBay variationSpecifics key
    var value: String   // "Large", "Red"
}

struct ListingVariation: Codable, Identifiable {
    var id: String = UUID().uuidString
    var attributes: [VariationAttribute]  // e.g. [{name:"Size",value:"L"},{name:"Color",value:"Red"}]
    var price: Double?     // overrides parent listing price; nil = inherit
    var quantity: Int?     // overrides parent quantity; nil = 1
    var sku: String?       // optional seller-defined SKU for this variant
}

// MARK: - UserListing

/// One seller's offer. References InventoryUnits for quantity tracking.
/// References a CatalogItem for shared product data.
struct UserListing: Identifiable, Codable {

    // ── Identity ──────────────────────────────────────────────────────────────
    @DocumentID var id: String?
    var userId: String              // FK → /users/{userId}
    var catalogItemId: String       // FK → /catalog/{catalogItemId}

    // ── Inventory references ──────────────────────────────────────────────────
    // Selling this listing decrements ALL referenced units by 1.
    var inventoryUnitIds: [String]  // FK → /inventory/{id}

    // ── Bundle metadata ───────────────────────────────────────────────────────
    var isBundleListing: Bool
    var bundleLabel: String?        // e.g. "Popcorn Bucket + Cup Combo"

    // ── User-customizable fields (override catalog defaults if set) ────────────
    var customTitle: String?
    var customDescription: String?
    
    // ── Platform / Market fields ──────────────────────────────────────────────
    var brand: String?
    var category: String?
    var tags: [String]?
    var personalNote: String?

    // ── Pricing ───────────────────────────────────────────────────────────────
    var price: Double?
    var currency: String            // "USD"
    var quantity: Int?              // nil = 1 (default for single-item listings)

    // ── Condition ─────────────────────────────────────────────────────────────
    var condition: ItemCondition
    var conditionNotes: String?     // e.g. "Minor scratch on back"

    // ── Photos (paths in Firebase Storage: /listings/{userId}/{listingId}/) ───
    var photoPaths: [String]
    var coverPhotoPath: String?     // First photo shown in browse view

    // ── Shipping ──────────────────────────────────────────────────────────────
    var shippingInfo: ShippingInfo?

    // ── Status & lifecycle ────────────────────────────────────────────────────
    var status: ListingStatus
    var createdAt: Timestamp?
    var updatedAt: Timestamp?
    var publishedAt: Timestamp?
    var soldAt: Timestamp?
    
    // ── Engagement ────────────────────────────────────────────────────────────
    var likesCount: Int?

    // ── Source assets (PHAsset identifiers, used during draft flow) ───────────
    // Cleared once photos are uploaded to Storage and photoPaths is populated.
    var sourceAssetIdentifiers: [String]

    // ── Gemini identification ─────────────────────────────────────────────────
    var geminiIdentificationConfirmed: Bool
    var geminiRawResponse: String?   // Raw JSON from Gemini for debugging

    // ── Cross-Posting ─────────────────────────────────────────────────────────
    var sellingProfileId: String?
    var crossPostStatus: [String: String]?          // e.g. ["ebay": "posted", "mercari": "pending"]
    var crossPostListingIds: [String: String]?       // e.g. ["ebay": "123456789"]
    var ebayCategory: Int?                           // pre-resolved eBay category ID

    // Mercari pending actions (set by decrementAndCascade Cloud Function)
    // iOS clears these after the user completes the headless action.
    var pendingMercariDeactivation: Bool?  // qty hit 0; Mercari listing needs deactivating
    var pendingMercariRelist: Bool?        // Mercari sold while qty>0; needs re-listing

    // ── Variations ────────────────────────────────────────────────────────────
    // Etsy: maps to inventory products/property_values; eBay: maps to variesBy + variationSpecifics
    var variations: [ListingVariation]?
    var variationStrategy: VariationStrategy?

    // MARK: - Convenience

    var isDraft: Bool { status == .draft }
    var isActive: Bool { status == .active }

    // MARK: - Init (for creating new draft listings)

    static func newDraft(
        userId: String,
        catalogItemId: String = "",
        sourceAssetIdentifiers: [String] = []
    ) -> UserListing {
        UserListing(
            userId: userId,
            catalogItemId: catalogItemId,
            inventoryUnitIds: [],
            isBundleListing: false,
            currency: "USD",
            condition: .good,
            photoPaths: [],
            status: .draft,
            sourceAssetIdentifiers: sourceAssetIdentifiers,
            geminiIdentificationConfirmed: false
        )
    }

    // Memberwise init (Codable synthesizes decode/encode, but we need a manual
    // init for newDraft convenience since some fields are optional).
    init(
        id: String? = nil,
        userId: String,
        catalogItemId: String,
        inventoryUnitIds: [String] = [],
        isBundleListing: Bool = false,
        bundleLabel: String? = nil,
        customTitle: String? = nil,
        customDescription: String? = nil,
        price: Double? = nil,
        currency: String = "USD",
        quantity: Int? = nil,
        condition: ItemCondition = .good,
        conditionNotes: String? = nil,
        photoPaths: [String] = [],
        coverPhotoPath: String? = nil,
        shippingInfo: ShippingInfo? = nil,
        status: ListingStatus = .draft,
        createdAt: Timestamp? = nil,
        updatedAt: Timestamp? = nil,
        publishedAt: Timestamp? = nil,
        soldAt: Timestamp? = nil,
        sourceAssetIdentifiers: [String] = [],
        geminiIdentificationConfirmed: Bool = false,
        geminiRawResponse: String? = nil,
        sellingProfileId: String? = nil,
        crossPostStatus: [String: String]? = nil,
        crossPostListingIds: [String: String]? = nil,
        ebayCategory: Int? = nil,
        pendingMercariDeactivation: Bool? = nil,
        pendingMercariRelist: Bool? = nil,
        variations: [ListingVariation]? = nil,
        variationStrategy: VariationStrategy? = nil
    ) {
        self.id = id
        self.userId = userId
        self.catalogItemId = catalogItemId
        self.inventoryUnitIds = inventoryUnitIds
        self.isBundleListing = isBundleListing
        self.bundleLabel = bundleLabel
        self.customTitle = customTitle
        self.customDescription = customDescription
        self.price = price
        self.currency = currency
        self.quantity = quantity
        self.condition = condition
        self.conditionNotes = conditionNotes
        self.photoPaths = photoPaths
        self.coverPhotoPath = coverPhotoPath
        self.shippingInfo = shippingInfo
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.soldAt = soldAt
        self.sourceAssetIdentifiers = sourceAssetIdentifiers
        self.geminiIdentificationConfirmed = geminiIdentificationConfirmed
        self.geminiRawResponse = geminiRawResponse
        self.sellingProfileId = sellingProfileId
        self.crossPostStatus = crossPostStatus
        self.crossPostListingIds = crossPostListingIds
        self.ebayCategory = ebayCategory
        self.pendingMercariDeactivation = pendingMercariDeactivation
        self.pendingMercariRelist = pendingMercariRelist
        self.variations = variations
        self.variationStrategy = variationStrategy
    }
}
