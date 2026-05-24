//
//  MainView.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI
import Photos

struct MainView: View {
    @EnvironmentObject var uploadManager: UploadManager
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        TabView(selection: $uploadManager.selectedTab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

            NavigationStack { CameraViewController() }
                .tabItem { Label("Sell", systemImage: "plus.circle.fill") }
                .tag(2)

            NavigationStack { InboxView() }
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .tag(3)

            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(4)
        }
        // Overlay pills ABOVE the tab bar using safeAreaInset on the whole TabView
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                if uploadManager.isProcessPillVisible {
                    ProcessPillView()
                        .environmentObject(uploadManager)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8),
                        value: uploadManager.isProcessPillVisible)
        }
        .fullScreenCover(isPresented: Binding(
            get: { authManager.currentUser == nil },
            set: { _ in }
        )) {
            SignInView()
                .environmentObject(authManager)
        }
        .fullScreenCover(isPresented: Binding(
            get: { authManager.currentUser != nil && !hasSeenOnboarding },
            set: { _ in }
        )) {
            OnboardingView()
        }
        .alert("Delete uploaded photos from device?", isPresented: $uploadManager.showDeletePhotosPrompt) {
            Button("Delete", role: .destructive) {
                deleteUploadedPhotos(uploadManager.uploadedAssetIDs)
                uploadManager.uploadedAssetIDs = []
            }
            Button("Keep", role: .cancel) {
                uploadManager.uploadedAssetIDs = []
            }
        } message: {
            Text("\(uploadManager.uploadedAssetIDs.count) photo(s) were uploaded to Wonni. You can remove them from your Photos library to free up space.")
        }
    }

    private func deleteUploadedPhotos(_ assetIDs: [String]) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

#Preview {
    MainView()
}
