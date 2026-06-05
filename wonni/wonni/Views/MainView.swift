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
                .processPill(uploadManager)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            NavigationStack { SearchView() }
                .processPill(uploadManager)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

            NavigationStack { CameraViewController() }
                .processPill(uploadManager)
                .tabItem { Label("Sell", systemImage: "plus.circle.fill") }
                .tag(2)

            NavigationStack { InboxView() }
                .processPill(uploadManager)
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .tag(3)

            NavigationStack { ProfileView() }
                .processPill(uploadManager)
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(4)
        }
        // When AI processing finishes, hop back to the Sell tab so the review/publish step is
        // shown right away. Without this, a user who minimized the processing screen and walked
        // off to another tab wouldn't see the next step until they re-tapped Sell.
        .onChange(of: uploadManager.showProcessResults) { _, show in
            if show { uploadManager.selectedTab = 2 }
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

private extension View {
    /// Pins the processing pill just above the tab bar and pushes this tab's content up to make
    /// room for it (a true VStack-style inset, not a ZStack overlay). Applied per-tab rather than
    /// on the TabView itself: a `safeAreaInset` on the TabView reserves space at the very bottom,
    /// where the tab bar already sits, so the pill ends up overlapping it. Insetting each tab's
    /// content instead places the pill in that tab's content area, cleanly above the tab bar.
    func processPill(_ uploadManager: UploadManager) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            if uploadManager.isProcessPillVisible {
                ProcessPillView()
                    .environmentObject(uploadManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                   value: uploadManager.isProcessPillVisible)
    }
}

#Preview {
    MainView()
}
