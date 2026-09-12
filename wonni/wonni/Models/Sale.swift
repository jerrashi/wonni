//
//  Sale.swift
//  wonni
//

import Foundation
import FirebaseFirestore

/// Sale lifecycle status. The backend (docs/specs/2026-09-11-stage-board-and-
/// revenue-accounting.md §1) made `sale.status` an open, per-user-configurable
/// string — any of these 6 built-in keys, or a custom bucket key a user added
/// in Settings/web. `.other` is that fallback: without it, decoding a sale
/// sitting in a custom bucket would throw and the whole sale would silently
/// vanish from every list (`try? $0.data(as: Sale.self)` in SaleRepository
/// swallows the error). The 6 built-in *keys* are permanent (sale_stages.js)
/// so they're still worth their own cases for exhaustive `switch`es elsewhere
/// (statusBadge colors, etc.) — `.other` only ever holds a custom key.
enum SaleStatus: Codable, Hashable {
    case pending    // sold, not yet shipped
    case shipped    // tracking entered / in transit
    case delivered  // package delivered, within return window
    case complete   // return window closed / both parties rated
    case cancelled  // order cancelled
    case returned   // buyer returned item
    case other(String)

    private static let knownByRawValue: [String: SaleStatus] = [
        "pending": .pending, "shipped": .shipped, "delivered": .delivered,
        "complete": .complete, "cancelled": .cancelled, "returned": .returned,
    ]

    var rawValue: String {
        switch self {
        case .pending:          return "pending"
        case .shipped:          return "shipped"
        case .delivered:        return "delivered"
        case .complete:         return "complete"
        case .cancelled:        return "cancelled"
        case .returned:         return "returned"
        case .other(let raw):   return raw
        }
    }

    init(rawValue: String) {
        self = Self.knownByRawValue[rawValue] ?? .other(rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = SaleStatus(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SaleAddress: Codable, Equatable {
    var name: String?
    var line1: String?
    var line2: String?
    var city: String?
    var state: String?
    var zip: String?
    var country: String?

    var oneLiner: String {
        [line1, line2, city.map { "\($0)," }, state, zip]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    var multiLine: String {
        [name, line1, line2, [city, state, zip].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct Sale: Identifiable, Codable {
    @DocumentID var id: String?
    var userId: String
    /// Legacy field name — old iOS-written sale docs use `listingId`. The
    /// consolidated backend (`recordSaleCore`) writes `productId` instead.
    var listingId: String?
    /// Canonical `products/{id}` reference. Written by the backend and, going
    /// forward, by `SaleRepository`. Read via `linkedProductId`.
    var productId: String?
    var listingTitle: String?          // snapshot at time of sale
    var coverPhotoPath: String?        // Firebase Storage path snapshot — fallback, costs Storage bandwidth to load
    var thumbnailUrl: String?          // platform CDN thumbnail (eBay/Mercari) — preferred display source, no Storage cost

    var platform: String               // "ebay" | "mercari" | "etsy"
    var platformOrderId: String?

    var priceSoldFor: Double           // item price only, excluding shipping
    var shippingRevenue: Double?       // shipping charged to buyer
    var takeHome: Double?              // net after platform fees and shipping label cost
    var shippingLabelCost: Double?     // eBay shipping label cost
    var quantity: Int?                 // units sold; nil/absent means 1 (canonical default)
    var productTags: [String]?         // tag snapshot at sale time — drives the tag breakdown

    var buyerAddress: SaleAddress?
    var trackingNumber: String?
    var carrier: String?               // "USPS" | "UPS" | "FedEx"

    var status: SaleStatus
    var soldAt: Timestamp
    var shippedAt: Timestamp?
    var createdAt: Timestamp?
    var updatedAt: Timestamp?

    var isDeleted: Bool?
    var deletedAt: Timestamp?

    // MARK: - Init

    /// The `products/{id}` this sale is for, from whichever field name is set.
    var linkedProductId: String? { productId ?? listingId }

    init(
        id: String? = nil,
        userId: String = "",
        listingId: String? = nil,
        productId: String? = nil,
        listingTitle: String? = nil,
        coverPhotoPath: String? = nil,
        thumbnailUrl: String? = nil,
        platform: String,
        platformOrderId: String? = nil,
        priceSoldFor: Double,
        shippingRevenue: Double? = nil,
        takeHome: Double? = nil,
        shippingLabelCost: Double? = nil,
        quantity: Int? = nil,
        productTags: [String]? = nil,
        buyerAddress: SaleAddress? = nil,
        trackingNumber: String? = nil,
        carrier: String? = nil,
        status: SaleStatus = .pending,
        soldAt: Timestamp = Timestamp(date: Date()),
        shippedAt: Timestamp? = nil,
        createdAt: Timestamp? = nil,
        updatedAt: Timestamp? = nil
    ) {
        self.id = id
        self.userId = userId
        self.listingId = listingId
        self.productId = productId ?? listingId
        self.listingTitle = listingTitle
        self.coverPhotoPath = coverPhotoPath
        self.thumbnailUrl = thumbnailUrl
        self.platform = platform
        self.platformOrderId = platformOrderId
        self.priceSoldFor = priceSoldFor
        self.shippingRevenue = shippingRevenue
        self.takeHome = takeHome
        self.shippingLabelCost = shippingLabelCost
        self.quantity = quantity
        self.productTags = productTags
        self.buyerAddress = buyerAddress
        self.trackingNumber = trackingNumber
        self.carrier = carrier
        self.status = status
        self.soldAt = soldAt
        self.shippedAt = shippedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "ebay":    return "eBay"
        case "mercari": return "Mercari"
        case "etsy":    return "Etsy"
        default:        return platform.capitalized
        }
    }
}
