//
//  wonniApp.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI
import SwiftData
import FirebaseCore

@main
struct wonniApp: App {
    @StateObject private var uploadManager = UploadManager()
    @StateObject private var authManager = AuthManager()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(uploadManager)
                .environmentObject(authManager)
        }
        .modelContainer(for: [Item.self, Listing.self, Expense.self, Mileage.self])
    }
}
