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
    @StateObject private var bulkImportManager = BulkImportManager()
    @StateObject private var mercariSyncManager = MercariSyncManager()

    init() {
        FirebaseApp.configure()
        Task {
            await MercariObservedDataRepository.shared.fetchBrandsIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(uploadManager)
                .environmentObject(authManager)
                .environmentObject(bulkImportManager)
                .environmentObject(mercariSyncManager)
                .onOpenURL { url in
                    print("[wonniApp] onOpenURL received URL: \(url.absoluteString)")
                    guard url.scheme == "wonni" else {
                        print("[wonniApp] onOpenURL ignored (scheme is not wonni)")
                        return
                    }
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    guard let host = url.host, host == "oauth" else {
                        print("[wonniApp] onOpenURL ignored (host is not oauth)")
                        return
                    }
                    
                    let platform = url.path.replacingOccurrences(of: "/", with: "")
                    if let codeValue = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                        print("[wonniApp] onOpenURL extracted code: \(codeValue) for platform: \(platform)")
                        Task {
                            do {
                                try await IntegrationRepository.shared.linkPlatformWithCode(platform: platform, code: codeValue)
                                print("[wonniApp] onOpenURL linkPlatformWithCode completed successfully")
                            } catch {
                                print("[wonniApp] onOpenURL linkPlatformWithCode error: \(error)")
                            }
                        }
                    } else {
                        print("[wonniApp] onOpenURL did not find 'code' query item")
                    }
                }
        }
        .modelContainer(for: [Item.self, Listing.self, Expense.self, Mileage.self])
    }
}
