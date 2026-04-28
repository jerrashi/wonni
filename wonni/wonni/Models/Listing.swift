//
//  Models.swift
//  wonni
//

import Foundation
import SwiftData

@Model
class Item {
    var id: UUID
    var createdAt: Date
    @Attribute(.externalStorage) var photosData: [Data]
    var blurb: String
    var aiSuggestedTitle: String?
    var aiSuggestedPrice: Double?
    var aiSuggestedDescription: String?
    var userEditedTitle: String?
    var userEditedPrice: Double?
    var userEditedDescription: String?
    var buyerPaysShipping: Bool
    var handlingFee: Double
    var estimatedShippingDays: Int
    var isDraft: Bool
    
    init(id: UUID = UUID(), createdAt: Date = Date(), photosData: [Data] = [], blurb: String = "", buyerPaysShipping: Bool = true, handlingFee: Double = 0.0, estimatedShippingDays: Int = 3, isDraft: Bool = true) {
        self.id = id
        self.createdAt = createdAt
        self.photosData = photosData
        self.blurb = blurb
        self.buyerPaysShipping = buyerPaysShipping
        self.handlingFee = handlingFee
        self.estimatedShippingDays = estimatedShippingDays
        self.isDraft = isDraft
    }
}

enum Platform: String, Codable {
    case ebay = "eBay"
    case etsy = "Etsy"
    case mercari = "Mercari"
    case facebook = "Facebook Marketplace"
}

@Model
class Listing {
    var id: UUID
    var item: Item?
    var platform: Platform
    var platformListingId: String?
    var status: String
    var listedPrice: Double
    var listedDate: Date?
    var soldDate: Date?
    var views: Int
    var likes: Int
    
    init(id: UUID = UUID(), item: Item? = nil, platform: Platform, platformListingId: String? = nil, status: String = "drafted", listedPrice: Double = 0.0, listedDate: Date? = nil, soldDate: Date? = nil, views: Int = 0, likes: Int = 0) {
        self.id = id
        self.item = item
        self.platform = platform
        self.platformListingId = platformListingId
        self.status = status
        self.listedPrice = listedPrice
        self.listedDate = listedDate
        self.soldDate = soldDate
        self.views = views
        self.likes = likes
    }
}

@Model
class Expense {
    var id: UUID
    var date: Date
    var title: String
    var amount: Double
    var category: String
    @Attribute(.externalStorage) var receiptPhotoData: Data?
    
    init(id: UUID = UUID(), date: Date = Date(), title: String, amount: Double, category: String, receiptPhotoData: Data? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.amount = amount
        self.category = category
        self.receiptPhotoData = receiptPhotoData
    }
}

@Model
class Mileage {
    var id: UUID
    var date: Date
    var title: String
    var miles: Double
    
    init(id: UUID = UUID(), date: Date = Date(), title: String, miles: Double) {
        self.id = id
        self.date = date
        self.title = title
        self.miles = miles
    }
}
