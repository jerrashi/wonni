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
        Task {
            guard Auth.auth().currentUser == nil else { return }
            do {
                let result = try await Auth.auth().signInAnonymously()
                print("[Auth] signed in anonymously: \(result.user.uid)")
            } catch {
                print("[Auth] anonymous sign-in failed: \(error.localizedDescription)")
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
