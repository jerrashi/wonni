//
//  CatalogItem.swift
//  wonni
//
//  Represents a canonical product in the shared wonni catalog.
//  Multiple sellers can list the same CatalogItem; enrichment data
//  (Gemini descriptions, eBay market prices) is shared across all of them.
//

import Foundation
import FirebaseFirestore

// MARK: - Supporting Types

struct VariantDimension: Codable {
    var name: String           // e.g. "Size"
    var values: [String]       // e.g. ["XS", "S", "M", "L", "XL"]
    var affects: VariantEffect
}

enum VariantEffect: String, Codable {
    case pricing      = "pricing"
    case availability = "availability"
    case both         = "both"
}

struct PriceBucket: Codable {
    var priceBucket: Double    // Lower bound of this bucket (e.g. 18.00)
    var soldCount: Int         // Units sold at this price from market data
}

struct MarketData: Codable {
    var ebayAvgSoldPrice: Double?
    var ebayRecentSoldPrices: [Double]
    var ebaySuggestedListPrice: Double?
    var amazonPrice: Double?
    var googleShoppingPrice: Double?
    var lastRefreshed: Timestamp?

    enum CodingKeys: String, CodingKey {
        case ebayAvgSoldPrice, ebayRecentSoldPrices, ebaySuggestedListPrice
        case amazonPrice, googleShoppingPrice, lastRefreshed
    }
}

struct ExternalIds: Codable {
    var ebayItemId: String?
    var amazonAsin: String?
    var upc: String?
    var ean: String?
    var isbn: String?
}

// MARK: - CatalogItem

/// Shared, canonical product record. Enriched by Gemini, eBay, Amazon, Google.
/// Clients can read; writes are server-side only.
struct CatalogItem: Identifiable, Codable {

    // ── Identity ────────────────────────────────────────────────────────────
    @DocumentID var id: String?
    var category: String            // "Electronics > Audio > Headphones"
    var brand: String?
    var model: String?
    var name: String                // "Sony WH-1000XM4 Wireless Headphones"

    // ── Descriptions ────────────────────────────────────────────────────────
    var descriptionShort: String    // 1–2 sentence summary
    var descriptionLong: String     // Full catalog description
    var attributes: [String: String] // {"Color": "Black", "Connectivity": "Bluetooth 5.0"}
    var keywords: [String]

    // ── Variant dimensions ───────────────────────────────────────────────────
    var variantDimensions: [VariantDimension]

    // ── Reference images (user-contributed, stored in /catalog/ in Storage) ──
    var referenceImagePaths: [String]

    // ── Market data ─────────────────────────────────────────────────────────
    var marketData: MarketData?

    // ── Price distribution histogram (for seller pricing graph UI) ───────────
    var priceDistribution: [PriceBucket]

    // ── External identifiers ────────────────────────────────────────────────
    var externalIds: ExternalIds?

    // ── Gemini enrichment metadata ──────────────────────────────────────────
    var geminiDescriptionLastUpdated: Timestamp?

    // ── Lifecycle ────────────────────────────────────────────────────────────
    var createdAt: Timestamp?
    var updatedAt: Timestamp?
    var activeListingCount: Int     // Denormalized count for quick display
}
