//
//  wonniApp.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI
import SwiftData

@main
struct wonniApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .modelContainer(for: [Item.self, Listing.self, Expense.self, Mileage.self])
    }
}
