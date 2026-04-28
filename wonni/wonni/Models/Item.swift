//
//  Item.swift
//  wonni
//

import Foundation
import SwiftData

@Model
class Item {
    var id: UUID
    var createdAt: Date
    
    // Photo data - saving as external storage to prevent CoreData bloat
    @Attribute(.externalStorage) var photosData: [Data]
    
    // Default blurb from settings / drafts
    var blurb: String
    
    // AI Generated Data
    var aiSuggestedTitle: String?
    var aiSuggestedPrice: Double?
    var aiSuggestedDescription: String?
    
    // User Edited Data
    var userEditedTitle: String?
    var userEditedPrice: Double?
    var userEditedDescription: String?
    
    // Shipping rules
    var buyerPaysShipping: Bool
    var handlingFee: Double
    var estimatedShippingDays: Int
    
    // Status
    var isDraft: Bool
    
    init(id: UUID = UUID(), 
         createdAt: Date = Date(), 
         photosData: [Data] = [], 
         blurb: String = "", 
         buyerPaysShipping: Bool = true, 
         handlingFee: Double = 0.0, 
         estimatedShippingDays: Int = 3,
         isDraft: Bool = true) {
        
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
