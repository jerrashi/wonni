//
//  Sale.swift
//  wonni
//

import Foundation
import FirebaseFirestore

enum SaleStatus: String, Codable, CaseIterable {
    case pending   = "pending"    // sold, not yet shipped
    case shipped   = "shipped"    // tracking entered
    case complete  = "complete"   // delivered / closed
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
    var listingId: String?
    var listingTitle: String?          // snapshot at time of sale
    var coverPhotoPath: String?        // snapshot

    var platform: String               // "ebay" | "mercari" | "etsy"
    var platformOrderId: String?

    var priceSoldFor: Double           // item price only, excluding shipping
    var shippingRevenue: Double?       // shipping charged to buyer
    var takeHome: Double?              // net after platform fees and shipping label cost
    var shippingLabelCost: Double?     // eBay shipping label cost

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

    init(
        id: String? = nil,
        userId: String = "",
        listingId: String? = nil,
        listingTitle: String? = nil,
        coverPhotoPath: String? = nil,
        platform: String,
        platformOrderId: String? = nil,
        priceSoldFor: Double,
        shippingRevenue: Double? = nil,
        takeHome: Double? = nil,
        shippingLabelCost: Double? = nil,
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
        self.listingTitle = listingTitle
        self.coverPhotoPath = coverPhotoPath
        self.platform = platform
        self.platformOrderId = platformOrderId
        self.priceSoldFor = priceSoldFor
        self.shippingRevenue = shippingRevenue
        self.takeHome = takeHome
        self.shippingLabelCost = shippingLabelCost
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
