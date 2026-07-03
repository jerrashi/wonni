//
//  MainView.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI
import Photos
import FirebaseFunctions
import FirebaseFirestore

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
        if queue.hasActiveTasks, !queue.suppressGlobalPill, let task = queue.current {
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
    @State private var soldTarget: UserListing? = nil
    @State private var isSelectMode = false

    // Mercari inactive + Wonni qty > 0 → sold on Mercari, user needs to decide qty/relist
    private func isSoldOnMercari(_ listing: UserListing) -> Bool {
        syncManager.syncResults[listing.id ?? ""]?.statusRaw == "inactive" &&
        (listing.quantity ?? 1) > 0 && listing.status != .sold
    }
    // Mercari inactive + Wonni qty = 0 or status = sold → truly out of stock
    private func isOutOfStock(_ listing: UserListing) -> Bool {
        syncManager.syncResults[listing.id ?? ""]?.statusRaw == "inactive" &&
        ((listing.quantity ?? 1) <= 0 || listing.status == .sold)
    }

    private var needsReviewListings: [UserListing] {
        syncManager.jobs.filter { !isOutOfStock($0) }
    }
    private var outOfStockListings: [UserListing] {
        syncManager.jobs.filter { isOutOfStock($0) }
    }
    private var activeWithDiffs: [UserListing] {
        needsReviewListings.filter {
            !isSoldOnMercari($0) &&
            hasDifferences(listing: $0, result: syncManager.syncResults[$0.id ?? ""])
        }
    }

    var body: some View {
        List(selection: $selectedIds) {
            if !syncManager.isFinished {
                Section {
                    ForEach(Array(syncManager.jobs.enumerated()), id: \.element.id) { index, listing in
                        syncRow(listing: listing, index: index)
                    }
                }
            } else {
                if !needsReviewListings.isEmpty {
                    Section {
                        ForEach(needsReviewListings, id: \.id) { listing in
                            if isSoldOnMercari(listing) {
                                soldOnMercariRow(listing: listing)
                                    .selectionDisabled(true)
                            } else {
                                syncRow(
                                    listing: listing,
                                    index: syncManager.jobs.firstIndex(where: { $0.id == listing.id }) ?? 0
                                )
                            }
                        }
                    }
                }
                if !outOfStockListings.isEmpty {
                    Section("Out of Stock") {
                        ForEach(outOfStockListings, id: \.id) { listing in
                            syncRow(
                                listing: listing,
                                index: syncManager.jobs.firstIndex(where: { $0.id == listing.id }) ?? 0
                            )
                            .opacity(0.6)
                            .selectionDisabled(true)
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(isSelectMode ? .active : .inactive))
        .navigationTitle("Mercari Sync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $soldTarget) { listing in
            NavigationStack {
                SoldOnMercariHandlerSheet(listing: listing) { soldTarget = nil }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if syncManager.isFinished {
                    if isSelectMode {
                        Button("Cancel") {
                            isSelectMode = false
                            selectedIds.removeAll()
                        }
                    } else {
                        Menu {
                            Button("Select active with changes") {
                                isSelectMode = true
                                selectedIds = Set(activeWithDiffs.map { $0.id })
                            }
                            Button("Select all with changes") {
                                isSelectMode = true
                                selectedIds = Set(needsReviewListings.filter {
                                    !isSoldOnMercari($0) &&
                                    hasDifferences(listing: $0, result: syncManager.syncResults[$0.id ?? ""])
                                }.map { $0.id })
                            }
                        } label: {
                            Text("Select")
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if syncManager.isFinished && !selectedIds.isEmpty {
                    if isApplying {
                        ProgressView("Applying...")
                            .frame(maxWidth: .infinity)
                    } else {
                        Button("Keep Wonni") { selectedIds.removeAll(); isSelectMode = false }
                        Spacer()
                        Button("Apply Mercari") { showActionSheet = true }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .confirmationDialog(
            "Apply Mercari data to \(selectedIds.count) listing\(selectedIds.count == 1 ? "" : "s")",
            isPresented: $showActionSheet,
            titleVisibility: .visible
        ) {
            Button("Apply All (Title, Price, Desc, Status)") { applyEdits(title: true, price: true, desc: true, status: true) }
            Button("Apply Only Titles") { applyEdits(title: true, price: false, desc: false, status: false) }
            Button("Apply Only Prices & Status") { applyEdits(title: false, price: true, desc: false, status: true) }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private func soldOnMercariRow(listing: UserListing) -> some View {
        Button { soldTarget = listing } label: {
            HStack(spacing: 12) {
                if let path = listing.photoPaths.first {
                    StorageImage(path: path).frame(width: 44, height: 44).cornerRadius(6)
                } else {
                    Color(.systemGray5).frame(width: 44, height: 44).cornerRadius(6)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(listing.customTitle ?? "Untitled")
                        .font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                    HStack(spacing: 4) {
                        Text("Sold on Mercari")
                            .font(.caption2).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.85))
                            .clipShape(Capsule())
                        Text("Qty: \(listing.quantity ?? 1)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Tap to resolve")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private func syncRow(listing: UserListing, index: Int) -> some View {
        let result = syncManager.syncResults[listing.id ?? ""]
        let hasDiff = hasDifferences(listing: listing, result: result)
        let isSynced = syncManager.isFinished && !hasDiff && result != nil
        let titleDiff = result?.title != nil && result?.title != listing.customTitle
        let priceDiff = result?.price != nil && abs((result?.price ?? 0) - (listing.price ?? 0)) >= 0.01

        HStack(alignment: .top, spacing: 12) {
            // Column 1: photo
            Group {
                if let path = listing.photoPaths.first {
                    StorageImage(path: path).frame(width: 44, height: 44).cornerRadius(6)
                } else {
                    Color(.systemGray5).frame(width: 44, height: 44).cornerRadius(6)
                }
            }
            .padding(.top, 2)

            // Column 2: stacked rows
            VStack(alignment: .leading, spacing: 5) {
                // Row 1: platform direction label (only when there's a diff)
                if hasDiff {
                    HStack(spacing: 4) {
                        Text("Wonni")
                            .font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2).foregroundStyle(.orange)
                        Text("Mercari")
                            .font(.caption2).fontWeight(.medium).foregroundStyle(.orange)
                    }
                }

                // Row 2: Wonni title (current)
                Text(listing.customTitle ?? "Untitled")
                    .font(.subheadline)
                    .foregroundStyle(titleDiff ? .secondary : .primary)
                    .strikethrough(titleDiff, color: .secondary)

                // Row 3: Mercari title (only if different)
                if let mercariTitle = result?.title, titleDiff {
                    Text(mercariTitle)
                        .font(.subheadline).foregroundStyle(.orange)
                }

                // Row 4: price
                if priceDiff, let mercariPrice = result?.price {
                    HStack(spacing: 6) {
                        Text(String(format: "$%.2f", listing.price ?? 0))
                            .strikethrough(color: .secondary).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.orange).imageScale(.small)
                        Text(String(format: "$%.2f", mercariPrice))
                            .foregroundStyle(.orange).fontWeight(.medium)
                    }
                    .font(.caption)
                } else if let price = listing.price {
                    Text(String(format: "$%.2f", price))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status icon
            Group {
                if index == syncManager.currentIndex - 1 && !syncManager.isFinished {
                    ProgressView()
                } else if hasDiff {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if isSynced {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if !syncManager.isFinished {
                    Image(systemName: "circle").foregroundStyle(.gray.opacity(0.4))
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .listRowBackground(hasDiff ? Color.orange.opacity(0.12) : nil)
    }

    private func hasDifferences(listing: UserListing, result: MercariSyncResult?) -> Bool {
        guard let r = result else { return false }
        let priceDiff = r.price != nil && abs(r.price! - (listing.price ?? 0)) >= 0.01
        let titleDiff = r.title != nil && r.title != listing.customTitle
        let descDiff = r.description != nil && r.description != listing.customDescription
        let soldDiff = r.isSold && listing.status != .sold
        return priceDiff || titleDiff || descDiff || soldDiff
    }

    private func applyEdits(title: Bool, price: Bool, desc: Bool, status: Bool) {
        isApplying = true
        let idsToApply = Set(selectedIds.compactMap { $0 })
        Task {
            await syncManager.applyBulkEdits(selectedIds: idsToApply, applyTitle: title, applyPrice: price, applyDescription: desc, applyStatus: status)
            selectedIds.removeAll()
            isSelectMode = false
            isApplying = false
            dismiss()
        }
    }
}

// MARK: - Per-listing sold-on-Mercari resolution sheet

struct SoldOnMercariHandlerSheet: View {
    let listing: UserListing
    let onDone: () -> Void

    enum Step { case qtyConfirm, relistOrOut }
    @State private var step: Step = .qtyConfirm
    @State private var effectiveQty: Int
    @State private var isWorking = false
    @State private var errorMessage: String? = nil
    @Environment(\.dismiss) private var dismiss

    init(listing: UserListing, onDone: @escaping () -> Void) {
        self.listing = listing
        self.onDone = onDone
        _effectiveQty = State(initialValue: listing.quantity ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Listing header
            HStack(spacing: 12) {
                if let path = listing.photoPaths.first {
                    StorageImage(path: path).frame(width: 52, height: 52).cornerRadius(8)
                } else {
                    Color(.systemGray5).frame(width: 52, height: 52).cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.customTitle ?? "Untitled")
                        .font(.headline).lineLimit(2)
                    Text("Current Wonni qty: \(listing.quantity ?? 1)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(.secondarySystemBackground))

            Divider()

            if isWorking {
                Spacer()
                ProgressView("Updating...")
                Spacer()
            } else if let err = errorMessage {
                Spacer()
                Text(err).foregroundStyle(.red).padding()
                Button("Dismiss") { dismiss(); onDone() }.padding()
                Spacer()
            } else if step == .qtyConfirm {
                qtyConfirmStep
            } else {
                relistStep
            }
        }
        .navigationTitle("Sold on Mercari")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss(); onDone() }
            }
        }
    }

    private var qtyConfirmStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cart.badge.minus")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("Was this sale already counted\nin your inventory?")
                .font(.title3).fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text("If another platform or manual update already decremented Wonni's quantity, choose \"Already counted.\" Otherwise choose \"Subtract 1 now\" and all platforms will be updated.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await subtractOne() }
                } label: {
                    Label("Subtract 1 now", systemImage: "minus.circle")

                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    // Qty is already correct; move to relist decision if qty > 0
                    effectiveQty = listing.quantity ?? 1
                    if effectiveQty > 0 {
                        step = .relistOrOut
                    } else {
                        dismiss(); onDone()
                    }
                } label: {
                    Label("Already counted", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .padding()
    }

    private var relistStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.trianglehead.2.counterclockwise.circle")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("You have \(effectiveQty) remaining in stock")
                .font(.title3).fontWeight(.semibold)
            Text("What would you like to do with the remaining stock?")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await relistOnMercari() }
                } label: {
                    Label("Relist on Mercari", systemImage: "arrow.up.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    Task { await markAllOutOfStock() }
                } label: {
                    Label("Mark all platforms out of stock", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button {
                    dismiss(); onDone()
                } label: {
                    Text("Keep current status")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .padding()
    }

    private func subtractOne() async {
        guard let id = listing.id else { return }
        isWorking = true
        do {
            _ = try await Functions.functions()
                .httpsCallable("decrementAndCascade")
                .call(["listingId": id, "platform": "mercari"])
            // decrementAndCascade auto-sets pendingMercariRelist if qty > 0,
            // so we don't need a separate relist prompt on this path.
            dismiss(); onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func relistOnMercari() async {
        guard let id = listing.id else { return }
        isWorking = true
        do {
            try await Firestore.firestore()
                .collection("listings").document(id)
                .updateData(["pendingMercariRelist": true,
                             "updatedAt": FieldValue.serverTimestamp()])
            dismiss(); onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func markAllOutOfStock() async {
        guard let id = listing.id else { return }
        isWorking = true
        do {
            _ = try await Functions.functions()
                .httpsCallable("markSoldOutAndCascade")
                .call(["listingId": id])
            dismiss(); onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

#Preview {
    MainView()
}
