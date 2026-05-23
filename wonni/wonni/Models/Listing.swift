//
//  Models.swift
//  wonni
//

import Foundation
import SwiftData
import UIKit

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
    var weightLbs: Double?
    var lengthIn: Double?
    var widthIn: Double?
    var heightIn: Double?
    var isDraft: Bool
    var sourceAssetIdentifiers: [String]
    var tags: [String]
    var personalNote: String?
    var firebasePhotoPaths: [String]?
    var firestoreListingId: String?
    var processedAt: Date?
    var visionTitle: String?
    var isLocalPhotoOnly: Bool

    init(id: UUID = UUID(), createdAt: Date = Date(), photosData: [Data] = [], blurb: String = "", buyerPaysShipping: Bool = true, handlingFee: Double = 0.0, estimatedShippingDays: Int = 3, weightLbs: Double? = nil, lengthIn: Double? = nil, widthIn: Double? = nil, heightIn: Double? = nil, isDraft: Bool = true, sourceAssetIdentifiers: [String] = [], tags: [String] = [], personalNote: String? = nil, firebasePhotoPaths: [String]? = nil, firestoreListingId: String? = nil, processedAt: Date? = nil, visionTitle: String? = nil, isLocalPhotoOnly: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.photosData = photosData
        self.blurb = blurb
        self.buyerPaysShipping = buyerPaysShipping
        self.handlingFee = handlingFee
        self.estimatedShippingDays = estimatedShippingDays
        self.weightLbs = weightLbs
        self.lengthIn = lengthIn
        self.widthIn = widthIn
        self.heightIn = heightIn
        self.isDraft = isDraft
        self.sourceAssetIdentifiers = sourceAssetIdentifiers
        self.tags = tags
        self.personalNote = personalNote
        self.firebasePhotoPaths = firebasePhotoPaths
        self.firestoreListingId = firestoreListingId
        self.processedAt = processedAt
        self.visionTitle = visionTitle
        self.isLocalPhotoOnly = isLocalPhotoOnly
    }

    func image(for assetId: String) -> UIImage? {
        if let idx = sourceAssetIdentifiers.firstIndex(of: assetId) {
            if idx < photosData.count {
                return UIImage(data: photosData[idx])
            }
        }
        return nil
    }

    func movePhoto(from: Int, to: Int) {
        var ids = sourceAssetIdentifiers
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        sourceAssetIdentifiers = ids
        
        if isLocalPhotoOnly && from < photosData.count && to < photosData.count {
            var data = photosData
            data.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            photosData = data
        }
    }

    func removePhoto(assetId: String) -> Data? {
        guard let idx = sourceAssetIdentifiers.firstIndex(of: assetId) else { return nil }
        sourceAssetIdentifiers.remove(at: idx)
        
        if isLocalPhotoOnly && idx < photosData.count {
            return photosData.remove(at: idx)
        }
        return nil
    }

    func insertPhoto(assetId: String, data: Data?, at index: Int) {
        if index >= sourceAssetIdentifiers.count {
            sourceAssetIdentifiers.append(assetId)
            if let data = data {
                photosData.append(data)
            }
        } else {
            sourceAssetIdentifiers.insert(assetId, at: index)
            if let data = data {
                photosData.insert(data, at: index)
            }
        }
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
