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
    @EnvironmentObject var bulkImportManager: BulkImportManager
    @EnvironmentObject var mercariSyncManager: MercariSyncManager
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        TabView(selection: $uploadManager.selectedTab) {
            NavigationStack { HomeView() }
                .processPill(uploadManager)
                .bulkImportPill(bulkImportManager)
                .mercariSyncPill(mercariSyncManager)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            NavigationStack { SearchView() }
                .processPill(uploadManager)
                .bulkImportPill(bulkImportManager)
                .mercariSyncPill(mercariSyncManager)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

            NavigationStack { CameraViewController() }
                .processPill(uploadManager)
                .bulkImportPill(bulkImportManager)
                .mercariSyncPill(mercariSyncManager)
                .tabItem { Label("Sell", systemImage: "plus.circle.fill") }
                .tag(2)

            NavigationStack { InboxView() }
                .processPill(uploadManager)
                .bulkImportPill(bulkImportManager)
                .mercariSyncPill(mercariSyncManager)
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .tag(3)

            NavigationStack { ProfileView() }
                .processPill(uploadManager)
                .bulkImportPill(bulkImportManager)
                .mercariSyncPill(mercariSyncManager)
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

    func bulkImportPill(_ bulkImportManager: BulkImportManager) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            if bulkImportManager.isPillVisible {
                BulkImportPillView()
                    .environmentObject(bulkImportManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                   value: bulkImportManager.isPillVisible)
    }

    func mercariSyncPill(_ mercariSyncManager: MercariSyncManager) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            if mercariSyncManager.isPillVisible {
                MercariSyncPillView()
                    .environmentObject(mercariSyncManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            MercariSheetWebView(webView: mercariSyncManager.loader.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                   value: mercariSyncManager.isPillVisible)
    }
}

struct MercariSyncPillView: View {
    @EnvironmentObject var syncManager: MercariSyncManager
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: syncManager.progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: syncManager.progress)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("Syncing with Mercari...")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(syncManager.currentIndex) of \(syncManager.totalCount)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            Button {
                syncManager.showProgressSheet = true
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.accentColor.opacity(0.85)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .sheet(isPresented: $syncManager.showProgressSheet) {
            NavigationStack {
                MercariSyncProgressSheet()
            }
            .environmentObject(syncManager)
        }
    }
}

struct MercariSyncProgressSheet: View {
    @EnvironmentObject var syncManager: MercariSyncManager
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedIds = Set<String?>()
    @State private var showActionSheet = false
    @State private var isApplying = false

    var body: some View {
        List(selection: $selectedIds) {
            ForEach(Array(syncManager.jobs.enumerated()), id: \.element.id) { index, listing in
                let result = syncManager.syncResults[listing.id ?? ""]
                let hasDiff = hasDifferences(listing: listing, result: result)
                let isSynced = index < syncManager.currentIndex - 1
                
                HStack(spacing: 12) {
                    if let firstPhotoPath = listing.photoPaths.first {
                        StorageImage(path: firstPhotoPath)
                            .frame(width: 44, height: 44)
                            .cornerRadius(6)
                    } else {
                        Color(.systemGray5)
                            .frame(width: 44, height: 44)
                            .cornerRadius(6)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        if let r = result, r.title != nil && r.title != listing.customTitle {
                            Text(r.title!)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text("Wonni: \(listing.customTitle ?? "Untitled")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(listing.customTitle ?? "Untitled")
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        
                        if let r = result, r.price != nil && abs(r.price! - (listing.price ?? 0)) >= 0.01 {
                            HStack {
                                Text(String(format: "$%.2f", listing.price ?? 0))
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Text(String(format: "$%.2f", r.price!))
                                    .foregroundStyle(.orange)
                            }
                            .font(.caption)
                        } else if let price = listing.price {
                            Text(String(format: "$%.2f", price))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if index == syncManager.currentIndex - 1 {
                        ProgressView()
                    } else if result != nil && hasDiff {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if isSynced {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.gray.opacity(0.5))
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(hasDiff ? Color.orange.opacity(0.15) : nil)
            }
        }
        .environment(\.editMode, .constant(syncManager.isFinished ? .active : .inactive))
        .navigationTitle("Mercari Sync Progress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if syncManager.isFinished {
                    Button(selectedIds.count == syncManager.jobs.count ? "Deselect All" : "Select All") {
                        if selectedIds.count == syncManager.jobs.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(syncManager.jobs.map { $0.id })
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if syncManager.isFinished {
                    if isApplying {
                        ProgressView("Applying...")
                            .frame(maxWidth: .infinity)
                    } else {
                        Button("Keep Wonni Data") {
                            selectedIds.removeAll()
                        }
                        .disabled(selectedIds.isEmpty)
                        
                        Spacer()
                        
                        Button("Apply Mercari Data") {
                            showActionSheet = true
                        }
                        .fontWeight(.semibold)
                        .disabled(selectedIds.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Apply to \(selectedIds.count) listings", isPresented: $showActionSheet, titleVisibility: .visible) {
            Button("Apply All (Title, Price, Desc, Status)") { applyEdits(title: true, price: true, desc: true, status: true) }
            Button("Apply Only Titles") { applyEdits(title: true, price: false, desc: false, status: false) }
            Button("Apply Only Prices & Status") { applyEdits(title: false, price: true, desc: false, status: true) }
            Button("Cancel", role: .cancel) { }
        }
    }
    
    private func hasDifferences(listing: UserListing, result: MercariSyncResult?) -> Bool {
        guard let r = result else { return false }
        let priceDiff = r.price != nil && abs(r.price! - (listing.price ?? 0)) >= 0.01
        let titleDiff = r.title != nil && r.title != listing.customTitle
        let descDiff = r.description != nil && r.description != listing.customDescription
        let soldDiff = r.isSold && listing.status != ListingStatus.sold
        return priceDiff || titleDiff || descDiff || soldDiff
    }
    
    private func applyEdits(title: Bool, price: Bool, desc: Bool, status: Bool) {
        isApplying = true
        let idsToApply = Set(selectedIds.compactMap { $0 })
        Task {
            await syncManager.applyBulkEdits(selectedIds: idsToApply, applyTitle: title, applyPrice: price, applyDescription: desc, applyStatus: status)
            selectedIds.removeAll()
            isApplying = false
            dismiss()
        }
    }
}

#Preview {
    MainView()
}
