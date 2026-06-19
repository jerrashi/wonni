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
                .appTaskQueuePill()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            NavigationStack { SearchView() }
                .appTaskQueuePill()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)

            NavigationStack { CameraViewController() }
                .appTaskQueuePill()
                .tabItem { Label("Sell", systemImage: "plus.circle.fill") }
                .tag(2)

            NavigationStack { InboxView() }
                .appTaskQueuePill()
                .tabItem { Label("Inbox", systemImage: "tray.fill") }
                .tag(3)

            NavigationStack { ProfileView() }
                .appTaskQueuePill()
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
                .tag(4)
        }
        .background(
            Group {
                MercariSheetWebView(webView: bulkImportManager.urlExtractor.webView)
                    .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
                MercariSheetWebView(webView: mercariSyncManager.loader.webView)
                    .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
            }
        )
        .sheet(isPresented: $uploadManager.showProgressSheet) {
            NavigationStack { ProcessProgressView() }
                .environmentObject(uploadManager)
        }
        .sheet(isPresented: $bulkImportManager.showProgressSheet) {
            NavigationStack { BulkImportProgressView() }
                .environmentObject(bulkImportManager)
        }
        .sheet(isPresented: $mercariSyncManager.showProgressSheet) {
            NavigationStack { MercariSyncProgressSheet() }
                .environmentObject(mercariSyncManager)
        }
        // When AI processing finishes, show the publish overview as a global sheet.
        // The 0.5 s delay lets any open cover/sheet (ProcessProgressView fullScreenCover
        // or pill sheet) finish its dismiss animation before the results sheet appears —
        // presenting two sheets simultaneously in the same frame corrupts the nav stack.
        .onChange(of: uploadManager.showProcessResults) { _, show in
            if show {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    uploadManager.showResultsOverview = true
                }
            }
        }
        // Close the results sheet when publishing completes and the app returns to root.
        .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
            if should {
                uploadManager.showResultsOverview = false
            }
        }
        .sheet(isPresented: $uploadManager.showResultsOverview) {
            NavigationStack { ProcessResultsOverviewView() }
                .environmentObject(uploadManager)
        }
        // Global Mercari cross-post pill — shown above the tab bar for all flows that
        // call UploadManager.globalMercariJob. Runs the WebView headlessly; expands to
        // full screen only when user interaction is required (login, category review).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let job = uploadManager.globalMercariJob {
                MercariAutoPosterView(job: job) {
                    let completion = uploadManager.onMercariJobComplete
                    uploadManager.globalMercariJob = nil
                    uploadManager.onMercariJobComplete = nil
                    completion?()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: uploadManager.globalMercariJob?.id)
        .sheet(isPresented: $uploadManager.showCrossPostStatus) {
            NavigationStack {
                CrossPostStatusView(
                    items: uploadManager.sessionCrossPostItems,
                    onDone: {
                        uploadManager.crossPostStatusPending = false
                        uploadManager.showCrossPostStatus = false
                        uploadManager.sessionCrossPostItems = []
                        uploadManager.shouldReturnToRoot = true
                    }
                )
            }
            .environmentObject(uploadManager)
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
    // Pins the universal task queue pill just above the tab bar.
    // Applied per-tab (not on the TabView) so the pill sits in each tab's
    // content area rather than overlapping the tab bar itself.
    func appTaskQueuePill() -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            AppTaskQueuePillContent()
        }
    }
}

// MARK: - Universal task queue pill

struct AppTaskQueuePillContent: View {
    @ObservedObject private var queue = AppTaskQueue.shared

    var body: some View {
        if queue.hasActiveTasks, let task = queue.current {
            AppTaskQueuePillView(task: task, queueCount: queue.count)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct AppTaskQueuePillView: View {
    let task: AppTaskQueue.AppTask
    let queueCount: Int

    var body: some View {
        HStack(spacing: 12) {
            if task.progress < 0 {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.75)
                    .frame(width: 20, height: 20)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: task.progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: task.progress)
                }
                .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(task.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    if queueCount > 1 {
                        Text("+\(queueCount - 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.25)))
                    }
                }
                if let detail = task.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Spacer()

            if task.onTap != nil {
                Button {
                    task.onTap?()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(task.accentColor.opacity(0.85)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: task.label)
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
