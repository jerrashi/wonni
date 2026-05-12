//
//  wonniApp.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAuth

@main
struct wonniApp: App {
    @StateObject private var uploadManager = UploadManager()

    init() {
        FirebaseApp.configure()

        // Ensure user is signed in for Firestore/Storage access
        if Auth.auth().currentUser == nil {
            Auth.auth().signInAnonymously { result, error in
                if let error = error {
                    print("Error signing in anonymously: \(error.localizedDescription)")
                } else {
                    print("Signed in anonymously with UID: \(result?.user.uid ?? "unknown")")
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(uploadManager)
        }
        .modelContainer(for: [Item.self, Listing.self, Expense.self, Mileage.self])
    }
}
