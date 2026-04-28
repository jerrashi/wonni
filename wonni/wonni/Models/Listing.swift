//
//  Listing.swift
//  wonni
//
//  Created by Jerry Shi on 3/4/25.
//

import Foundation
import SwiftData

enum Platform: String, Codable {
    case ebay = "eBay"
    case etsy = "Etsy"
    case mercari = "Mercari"
    case facebook = "Facebook Marketplace"
}

@Model
class Listing {
    var id: UUID
    var item: Item? // Reference to the parent Item
    var platform: Platform
    var platformListingId: String? // ID on the external platform
    var status: String // active, sold, drafted, ended
    var listedPrice: Double
    var listedDate: Date?
    var soldDate: Date?
    var views: Int
    var likes: Int
    
    init(id: UUID = UUID(), 
         item: Item? = nil, 
         platform: Platform, 
         platformListingId: String? = nil, 
         status: String = "drafted", 
         listedPrice: Double = 0.0, 
         listedDate: Date? = nil, 
         soldDate: Date? = nil, 
         views: Int = 0, 
         likes: Int = 0) {
        
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
