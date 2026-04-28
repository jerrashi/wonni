//
//  Expense.swift
//  wonni
//

import Foundation
import SwiftData

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
