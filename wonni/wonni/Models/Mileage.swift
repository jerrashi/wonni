//
//  Mileage.swift
//  wonni
//

import Foundation
import SwiftData

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
