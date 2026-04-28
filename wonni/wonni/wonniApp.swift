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
    @StateObject private var modelData = ModelData()

    var body: some Scene {
        WindowGroup {
            MainView()
                // Inject ModelData into the environment
                .environmentObject(modelData)
        }
        .modelContainer(for: [Item.self, Listing.self, Expense.self, Mileage.self])
    }
}
