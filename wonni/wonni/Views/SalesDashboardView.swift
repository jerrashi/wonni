//
//  SalesDashboardView.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore
import FirebaseFunctions
import FirebaseStorage
import WebKit

private let syncCooldown: TimeInterval = 5 * 60  // 5 minutes

struct SalesDashboardView: View {
    @State private var sales: [Sale] = []
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var salesSyncTaskId = UUID()
    @State private var syncToast: String?
    @State private var selectedSale: Sale?
    @State private var filterPlatform: String? = nil
    @State private var showMercariSync = false
    @State private var showMercariLogin = false
    @AppStorage("lastSalesSyncDate") private var lastSyncTimestamp: Double = 0
    @State private var mercariAutoImport: Bool = true  // loaded from Firestore in reload()
    
    @StateObject private var mercariSaleSyncManager = MercariSaleSyncManager()

    @State private var hiddenSales: [Sale] = []
    @State private var isHiddenSectionExpanded = false
    @State private var isSelectMode = false
    @State private var selectedSaleIds: Set<String> = []
    @State private var showBulkDeleteConfirmation = false
    @State private var showAddSale = false
    @State private var pendingUndoSale: Sale? = nil
    @State private var toastAction: (() -> Void)? = nil
    @State private var toastActionLabel: String = "Undo"
    @State private var saleToPurge: Sale? = nil
    @ObservedObject private var taskQueue = AppTaskQueue.shared

    private var secondsUntilNextSync: Int {
        let elapsed = Date().timeIntervalSince1970 - lastSyncTimestamp
        let remaining = syncCooldown - elapsed
        return remaining > 0 ? Int(ceil(remaining)) : 0
    }

    private var filteredSales: [Sale] {
        guard let p = filterPlatform else { return sales }
        return sales.filter { $0.platform == p }
    }
    private var totalRevenue: Double { filteredSales.reduce(0) { $0 + $1.priceSoldFor } }
    private var totalTakeHome: Double { filteredSales.reduce(0) { $0 + ($1.takeHome ?? 0) } }
    private var platforms: [String] { Array(Set(sales.map { $0.platform })).sorted() }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sales.isEmpty {
                emptySalesState
            } else {
                salesList
            }
        }
        .background(
            MercariSheetWebView(webView: mercariSaleSyncManager.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
        .navigationTitle("Sales")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    syncButton
                    Button { showAddSale = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .onAppear { taskQueue.suppressGlobalPill = true }
        .onDisappear { taskQueue.suppressGlobalPill = false }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let task = taskQueue.current {
                    AppTaskQueuePillView(task: task, queueCount: taskQueue.count)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let toast = syncToast {
                    HStack(spacing: 12) {
                        Text(toast)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        if let action = toastAction {
                            Spacer()
                            Button(toastActionLabel) { action() }
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.92))
                    .clipShape(Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if isSelectMode && !selectedSaleIds.isEmpty {
                    Button {
                        showBulkDeleteConfirmation = true
                    } label: {
                        let plural = selectedSaleIds.count == 1 ? "" : "s"
                        Text("Hide \(selectedSaleIds.count) sale\(plural)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: syncToast)
            .animation(.spring(duration: 0.25), value: selectedSaleIds.isEmpty)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: taskQueue.current?.id)
        }
            .sheet(item: $selectedSale) { sale in
                SaleDetailSheet(sale: sale) {
                    Task { await reload() }
                }
            }
            .sheet(isPresented: $showMercariSync) {
                MercariProfileSyncSheet {
                    Task { await reload() }
                }
            }
            .sheet(isPresented: $showMercariLogin) {
                MercariSyncLoginSheet(webView: mercariSaleSyncManager.webView) {
                    showMercariLogin = false
                }
            }
            .onChange(of: mercariSaleSyncManager.needsLogin) { _, needs in
                if needs { showMercariLogin = true }
            }
            .sheet(isPresented: $showAddSale, onDismiss: { Task { await reload() } }) {
                AddSaleSheet()
            }
            .confirmationDialog(
                "Delete \(selectedSaleIds.count) sale\(selectedSaleIds.count == 1 ? "" : "s")?",
                isPresented: $showBulkDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await bulkHide() }
                }
            } message: {
                Text("These sales will be removed from your dashboard. You can restore them from Deleted Sales.")
            }
            .confirmationDialog(
                "Permanently delete this sale?",
                isPresented: Binding(get: { saleToPurge != nil }, set: { if !$0 { saleToPurge = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    if let sale = saleToPurge { Task { await purgeSale(sale) } }
                }
            } message: {
                Text("This can't be undone. If it was imported from Mercari, it can be re-scanned on the next sync.")
            }
        .task { await reload() }
    }

    private var salesList: some View {
        List {
            // Summary cards
            Section {
                HStack(spacing: 12) {
                    summaryCard(
                        title: "Sales",
                        value: "\(filteredSales.count)",
                        icon: "tag.fill",
                        color: .blue
                    )
                    summaryCard(
                        title: "Revenue",
                        value: String(format: "$%.0f", totalRevenue),
                        icon: "dollarsign.circle.fill",
                        color: .green
                    )
                    summaryCard(
                        title: "Take-Home",
                        value: String(format: "$%.0f", totalTakeHome),
                        icon: "banknote.fill",
                        color: .teal
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Platform filter
            if platforms.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip(label: "All", selected: filterPlatform == nil) {
                                filterPlatform = nil
                            }
                            ForEach(platforms, id: \.self) { p in
                                filterChip(
                                    label: Sale.platformDisplayName(p),
                                    selected: filterPlatform == p
                                ) { filterPlatform = filterPlatform == p ? nil : p }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            // Hidden sales
            if !hiddenSales.isEmpty {
                Section {
                    if isHiddenSectionExpanded {
                        ForEach(hiddenSales) { sale in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sale.listingTitle ?? "Untitled")
                                        .font(.subheadline).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(Sale.platformDisplayName(sale.platform))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.secondary)
                                            .clipShape(Capsule())
                                        Text(sale.soldAt.dateValue().formatted(.dateTime.month(.abbreviated).day()))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(String(format: "$%.2f", sale.priceSoldFor))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Button("Restore") {
                                    Task {
                                        if let id = sale.id {
                                            try? await SaleRepository.shared.restoreSale(id: id)
                                            await reload()
                                        }
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(Color.accentColor)
                                Button {
                                    saleToPurge = sale
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .tint(.red)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isHiddenSectionExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("Deleted (\(hiddenSales.count))")
                            Spacer()
                            Image(systemName: isHiddenSectionExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }

            // Individual sales
            Section {
                ForEach(filteredSales) { sale in
                    Button {
                        if isSelectMode {
                            guard let id = sale.id else { return }
                            if selectedSaleIds.contains(id) {
                                selectedSaleIds.remove(id)
                            } else {
                                selectedSaleIds.insert(id)
                            }
                        } else {
                            selectedSale = sale
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isSelectMode {
                                let id = sale.id ?? ""
                                Image(systemName: selectedSaleIds.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedSaleIds.contains(id) ? Color.accentColor : Color.secondary)
                                    .font(.title3)
                            }
                            SaleRow(sale: sale)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        if !isSelectMode {
                            Button {
                                deleteSale(sale)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("\(filteredSales.count) sale\(filteredSales.count == 1 ? "" : "s")")
                    Spacer()
                    Button(isSelectMode ? "Cancel" : "Select") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelectMode.toggle()
                            if !isSelectMode { selectedSaleIds.removeAll() }
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .refreshable { await syncSales() }
    }

    @ViewBuilder
    private var syncButton: some View {
        if isSyncing {
            ProgressView().scaleEffect(0.85)
        } else {
            Button {
                Task { await syncSales() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(secondsUntilNextSync > 0 ? .tertiary : .primary)
            }
            .simultaneousGesture(
                LongPressGesture().onEnded { _ in
                    Task { await syncSales(force: true) }
                }
            )
            .contextMenu {
                Button("Import from Mercari") { showAddSale = true }
            }
        }
    }

    private var emptySalesState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No sales yet").font(.title3.weight(.semibold))
            Text("Tap \u{21BA} to sync from eBay and Etsy, use \u{21BA} > Check Mercari listings for Mercari, or tap + to add a sale manually.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(value).font(.title3.weight(.bold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func filterChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color(.tertiarySystemFill))
                .clipShape(Capsule())
        }
    }

    private func reload() async {
        isLoading = true
        async let fetchSales = SaleRepository.shared.fetchSales()
        async let fetchHidden = SaleRepository.shared.fetchHiddenSales()
        async let fetchSettings = IntegrationRepository.shared.loadSalesDashboardSettings()
        // De-duped defensively by id, keeping the first (server order) occurrence — a belt-
        // and-suspenders guard alongside the Undo-insert guard in deleteSale, in case some
        // other interleaving of a fire-and-forget write and a reload ever produces a repeat
        // (github issue #39).
        var seenIds = Set<String>()
        sales = ((try? await fetchSales) ?? []).filter { seenIds.insert($0.id ?? UUID().uuidString).inserted }
        hiddenSales = (try? await fetchHidden) ?? []
        mercariAutoImport = await fetchSettings
        isLoading = false
    }

    private func syncSales(force: Bool = false) async {
        if !force && secondsUntilNextSync > 0 {
            let m = secondsUntilNextSync / 60
            let s = secondsUntilNextSync % 60
            showToast("Try again in \(m > 0 ? "\(m)m \(s)s" : "\(s)s")")
            return
        }
        isSyncing = true
        let taskId = UUID()
        salesSyncTaskId = taskId
        AppTaskQueue.shared.begin(id: taskId, label: "Syncing sales")
        if !force { lastSyncTimestamp = Date().timeIntervalSince1970 }
        defer {
            AppTaskQueue.shared.complete(id: taskId)
            isSyncing = false
        }

        let toast = await syncAPIPlatforms(force: force)
        if let toast { showToast(toast) }
        // Runs after so a "new Mercari sales found" review banner (if any) shows last and
        // isn't immediately overwritten by the eBay/Etsy toast above.
        await syncWebPlatforms()
    }

    // Calls the Cloud Function which runs eBay → Etsy in sequence.
    // Returns a toast string, or nil on rate-limit (toast handled inside).
    private func syncAPIPlatforms(force: Bool) async -> String? {
        do {
            let result = try await Functions.functions()
                .httpsCallable("syncSales")
                .call(force ? ["force": true] : [:])
            let dict = result.data as? [String: Any] ?? [:]
            if dict["rateLimited"] as? Bool == true {
                return "Try again in a few minutes"
            }
            let newSales = dict["newSales"] as? Int ?? 0
            await reload()
            if dict["ebayError"] as? String == "reconnect_required" {
                return "Reconnect eBay in Settings to enable sale sync"
            }
            return newSales > 0
                ? "\(newSales) new sale\(newSales == 1 ? "" : "s") recorded"
                : "Already up to date"
        } catch {
            if !force { lastSyncTimestamp = 0 }
            return "Sync failed: \(error.localizedDescription)"
        }
    }

    // Iterates web-autofill platform managers in order.
    // Add new platforms here as: await nextPlatformSyncManager.sync(sales: sales)
    private func syncWebPlatforms() async {
        // Include deleted (hidden) sales so restored+deleted items never resurface on sync.
        let knownMercariIds = Set((sales + hiddenSales).compactMap { $0.platform == "mercari" ? $0.platformOrderId : nil })
        // Stop at any item dated before the calendar day of the last sync.
        // e.g. last sync at 6/26 8:42am → stop at items dated 6/25 or earlier.
        let stopDate = lastSyncTimestamp > 0
            ? Calendar.current.startOfDay(for: Date(timeIntervalSince1970: lastSyncTimestamp))
            : nil
        let found = await mercariSaleSyncManager.scanForNewSales(
            knownOrderIds: knownMercariIds,
            stopBeforeDate: stopDate
        )
        if !found.isEmpty {
            if mercariAutoImport {
                for item in found {
                    // Enrich before saving so we never write a sale missing take-home or a
                    // real sold date — scanForNewSales only reads title/price off the list page.
                    // fetchPhoto: true also gets the confirmed-reliable item-page price, since
                    // scanForNewSales' own price is only a cents-vs-dollars magnitude guess
                    // (github issue #38) — falls back to that guess only if this fetch fails.
                    let enrichment = await mercariSaleSyncManager.loadSaleData(itemId: item.id, fetchPhoto: true)
                    guard let name = item.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let price = enrichment?.price ?? item.price, price > 0,
                          let takeHome = enrichment?.takeHome,
                          let saleDate = enrichment?.soldAt else {
                        print("[SyncWebPlatforms] Skipping \(item.id): incomplete sale data (name/price/takeHome/soldAt)")
                        continue
                    }
                    let match = await ListingRepository.shared.findListingByMercariId(item.id)
                    let sale = Sale(
                        listingId: match?.listingId,
                        listingTitle: name,
                        coverPhotoPath: match?.coverPhotoPath,
                        thumbnailUrl: match?.coverPhotoPath == nil ? (enrichment?.thumbnailUrl ?? item.thumbnailUrl) : nil,
                        platform: "mercari",
                        platformOrderId: item.id,
                        priceSoldFor: price,
                        takeHome: takeHome,
                        trackingNumber: enrichment?.trackingNumber,
                        carrier: enrichment?.carrier,
                        status: enrichment?.status ?? .pending,
                        soldAt: Timestamp(date: saleDate)
                    )
                    try? await SaleRepository.shared.addSale(sale)
                }
                await reload()
            } else {
                // Auto-import is off — persist to the durable pending-sales collection (not
                // just an in-memory toast) so the "+" modal's list survives app restarts
                // (github issue #50), and surface a banner instead of forcing the sheet open
                // mid-sync.
                await PendingMercariSaleRepository.shared.upsert(found)
                let count = found.count
                showToast(
                    "\(count) new Mercari sale\(count == 1 ? "" : "s") found — review in Import",
                    actionLabel: "Review",
                    duration: 8_000_000_000
                ) {
                    showAddSale = true
                }
            }
        }
        await mercariSaleSyncManager.sync(sales: sales)
        // Future: await facebookSaleSyncManager.scanForNewSales(...) / .sync(...)
        await reload()
    }

    private func purgeSale(_ sale: Sale) async {
        guard let id = sale.id else { return }
        withAnimation { hiddenSales.removeAll { $0.id == id } }
        try? await SaleRepository.shared.permanentlyDeleteSale(id: id)
        saleToPurge = nil
        await reload()
    }

    private func bulkHide() async {
        let ids = selectedSaleIds
        for id in ids {
            try? await SaleRepository.shared.hideSale(id: id)
        }
        selectedSaleIds.removeAll()
        isSelectMode = false
        await reload()
    }

    private func showToast(
        _ message: String,
        actionLabel: String = "Undo",
        duration: UInt64? = nil,
        action: (() -> Void)? = nil
    ) {
        withAnimation(.easeInOut) {
            syncToast = message
            toastAction = action
            toastActionLabel = actionLabel
        }
        let effectiveDuration = duration ?? (action != nil ? 5_000_000_000 : 3_000_000_000)
        Task {
            try? await Task.sleep(nanoseconds: effectiveDuration)
            withAnimation(.easeInOut) {
                if syncToast == message {
                    syncToast = nil
                    toastAction = nil
                }
            }
        }
    }

    private func deleteSale(_ sale: Sale) {
        guard let id = sale.id else { return }
        withAnimation { sales.removeAll { $0.id == id } }
        Task {
            try? await SaleRepository.shared.hideSale(id: id)
        }
        showToast("Sale deleted") {
            // If a pull-to-refresh landed between the delete and this Undo tap, the fire-and-
            // forget hideSale write may not have reached the server yet, so reload()'s fetch
            // could have already repopulated this sale — inserting again would duplicate the
            // row (github issue #39). Only insert if it isn't already present.
            withAnimation {
                if !sales.contains(where: { $0.id == id }) {
                    sales.insert(sale, at: 0)
                }
            }
            Task {
                try? await SaleRepository.shared.restoreSale(id: id)
                await reload()
            }
        }
    }
}

// MARK: - Sale Row

private struct SaleRow: View {
    let sale: Sale

    var body: some View {
        HStack(spacing: 12) {
            // Cover photo or placeholder. thumbnailUrl (a platform CDN URL) is preferred
            // over coverPhotoPath (a Firebase Storage path) — it loads directly with no
            // Storage bandwidth/read cost, and is already sized as a thumbnail.
            Group {
                if let urlStr = sale.thumbnailUrl, let url = URL(string: urlStr) {
                    AsyncExternalImage(url: url, referer: sale.platform == "mercari" ? "https://www.mercari.com" : nil)
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let path = sale.coverPhotoPath {
                    AsyncFirebaseImage(path: path)
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: "tag")
                                .foregroundStyle(.secondary)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(sale.listingTitle ?? "Untitled").font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    platformBadge(sale.platform)
                    Text(sale.soldAt.dateValue().formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let addr = sale.buyerAddress?.oneLiner, !addr.isEmpty {
                    Text(addr).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "$%.2f", sale.priceSoldFor))
                    .font(.subheadline.weight(.semibold))
                if let take = sale.takeHome {
                    Text(String(format: "≈$%.2f", take))
                        .font(.caption).foregroundStyle(.green)
                }
                statusBadge(sale.status)
            }
        }
        .padding(.vertical, 4)
    }

    private func platformBadge(_ platform: String) -> some View {
        Text(Sale.platformDisplayName(platform))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(platformColor(platform))
            .clipShape(Capsule())
    }

    private func platformColor(_ platform: String) -> Color {
        switch platform {
        case "ebay":    return .blue
        case "mercari": return Color(red: 1, green: 0.3, blue: 0.3)
        case "etsy":    return Color(red: 0.95, green: 0.4, blue: 0.0)
        default:        return .gray
        }
    }

    private func statusBadge(_ status: SaleStatus) -> some View {
        let (label, color): (String, Color) = switch status {
        case .pending:   ("Pending", .orange)
        case .shipped:   ("Shipped", .blue)
        case .delivered: ("Delivered", .cyan)
        case .complete:  ("Complete", .green)
        case .cancelled: ("Cancelled", .red)
        case .returned:  ("Returned", .purple)
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }
}

// MARK: - Sale Detail / Edit Sheet

struct SaleDetailSheet: View {
    let sale: Sale
    var onUpdated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trackingNumber: String
    @State private var carrier: String
    @State private var status: SaleStatus
    @State private var priceString: String
    @State private var takeHomeString: String
    @State private var soldAt: Date
    @State private var addressText: String
    @State private var isSaving = false

    init(sale: Sale, onUpdated: @escaping () -> Void) {
        self.sale = sale
        self.onUpdated = onUpdated
        _trackingNumber = State(initialValue: sale.trackingNumber ?? "")
        _carrier = State(initialValue: sale.carrier ?? "USPS")
        _status = State(initialValue: sale.status)
        _soldAt = State(initialValue: sale.soldAt.dateValue())
        _priceString = State(initialValue: String(format: "%.2f", sale.priceSoldFor))
        _addressText = State(initialValue: sale.buyerAddress?.multiLine ?? "")
        if let take = sale.takeHome {
            _takeHomeString = State(initialValue: String(format: "%.2f", take))
        } else {
            _takeHomeString = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Listing") {
                    LabeledContent("Title", value: sale.listingTitle ?? "—")
                    LabeledContent("Platform", value: Sale.platformDisplayName(sale.platform))
                    HStack {
                        Text("Item price")
                        Spacer()
                        TextField("Amount", text: $priceString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if let shipping = sale.shippingRevenue {
                        LabeledContent("Shipping charged", value: String(format: "$%.2f", shipping))
                    }
                    if let labelCost = sale.shippingLabelCost {
                        LabeledContent("Shipping label", value: String(format: "-$%.2f", labelCost))
                    }
                    HStack {
                        Text("Take-home")
                        Spacer()
                        TextField("Amount", text: $takeHomeString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date sold", selection: $soldAt, displayedComponents: .date)
                    if let orderId = sale.platformOrderId {
                        LabeledContent("Order ID", value: orderId)
                    }
                }

                Section {
                    TextField("Paste recipient address (optional)", text: $addressText, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(2...6)
                    if !addressText.isEmpty {
                        Button {
                            UIPasteboard.general.string = addressText
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .font(.caption)
                    }
                } header: {
                    Text("Buyer address")
                } footer: {
                    Text("Mercari doesn't expose a shipping label with the address on it — paste it here if the buyer shared it.")
                }

                Section("Shipping") {
                    Picker("Carrier", selection: $carrier) {
                        ForEach(["USPS", "UPS", "FedEx", "Other"], id: \.self) { Text($0) }
                    }
                    HStack {
                        TextField("Tracking number", text: $trackingNumber)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !trackingNumber.isEmpty {
                            Button {
                                UIPasteboard.general.string = trackingNumber
                            } label: { Image(systemName: "doc.on.doc").foregroundStyle(.secondary) }
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(SaleStatus.allCases, id: \.self) { s in
                            Text(s.rawValue.capitalized).tag(s)
                        }
                    }
                }
            }
            .navigationTitle("Sale Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                    }
                }
            }
        }
    }

    private func save() async {
        guard let id = sale.id else { return }
        isSaving = true
        var data: [String: Any] = ["status": status.rawValue]

        if !Calendar.current.isDate(soldAt, inSameDayAs: sale.soldAt.dateValue()) {
            data["soldAt"] = Timestamp(date: soldAt)
        }

        let cleanedTh = takeHomeString.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let th = Double(cleanedTh) {
            data["takeHome"] = th
        }

        let cleanedPrice = priceString.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let price = Double(cleanedPrice), price != sale.priceSoldFor {
            data["priceSoldFor"] = price
        }

        let trimmedAddress = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress != (sale.buyerAddress?.multiLine ?? "") {
            // Dot-path update targets just the line1 field, preserving any structured
            // name/city/state/zip already synced from eBay/Etsy instead of clobbering them.
            data["buyerAddress.line1"] = trimmedAddress.isEmpty ? FieldValue.delete() : trimmedAddress
        }

        if !trackingNumber.isEmpty {
            data["trackingNumber"] = trackingNumber
            data["carrier"] = carrier
            if status == .pending {
                data["status"] = SaleStatus.shipped.rawValue
                data["shippedAt"] = Timestamp(date: Date())
            }
        }
        try? await SaleRepository.shared.updateSale(id: id, data: data)
        onUpdated()
        dismiss()
        isSaving = false
    }
}

// MARK: - Mercari Profile Import Sheet

struct MercariFoundSaleItem: Identifiable {
    let id: String
    var name: String?
    var price: Double?
    var thumbnailUrl: String?
    var takeHome: Double?
    var soldAt: Date?
    var enrichFailed: Bool = false
}

/// Post-discovery enrichment only — the visible-webview scan (`scanCurrentPage`) that used to
/// live here was removed in favor of the always-headless `MercariSaleSyncManager.scanForNewSales`
/// (github issue #50); this class now just fills in take-home/soldAt/photo/price for items that
/// scan already found, reusing the headless `MercariSaleSyncManager` passed in by the caller so
/// a second WKWebView instance isn't spun up just for enrichment.
@MainActor
final class MercariSalesPageImporter: ObservableObject {
    @Published var scanStatus = ""
    @Published var foundItems: [MercariFoundSaleItem] = []
    @Published var isEnriching = false
    @Published var enrichedCount = 0

    // Reuses the same hardened order-page + item-page scraper the periodic sync path uses
    // (MercariSaleSyncManager.loadSaleData), instead of a second bespoke JS implementation
    // that only ever read the order page and never fetched a real photo (github issue #50).
    private let saleSync: MercariSaleSyncManager

    init(saleSync: MercariSaleSyncManager) {
        self.saleSync = saleSync
    }

    /// Re-enriches a single item (used for the "Retry" action on a flagged/failed row) without
    /// re-running the whole batch.
    func enrichItem(_ id: String) async {
        guard let i = foundItems.firstIndex(where: { $0.id == id }) else { return }
        foundItems[i].enrichFailed = false
        if let result = await saleSync.loadSaleData(itemId: id, fetchPhoto: true) {
            foundItems[i].takeHome = result.takeHome ?? foundItems[i].takeHome
            foundItems[i].soldAt = result.soldAt ?? foundItems[i].soldAt
            foundItems[i].thumbnailUrl = result.thumbnailUrl ?? foundItems[i].thumbnailUrl
            // Overrides the list-page scan's price, which is only a magnitude-heuristic guess
            // at cents-vs-dollars (github issue #38) — the item detail page's price is confirmed
            // reliable (see MercariSaleResult.price).
            foundItems[i].price = result.price ?? foundItems[i].price
            if foundItems[i].takeHome == nil || foundItems[i].soldAt == nil {
                foundItems[i].enrichFailed = true
            }
        } else {
            foundItems[i].enrichFailed = true
        }
    }

    func enrichItems() async {
        // Skip items that already have everything a durable-store reload might hand back
        // in — no need to re-hit the order page for a pending item that was already
        // successfully enriched on a previous sync.
        let indicesNeedingWork = foundItems.indices.filter { i in
            MercariSaleValidation.needsFix(
                name: foundItems[i].name, price: foundItems[i].price,
                takeHome: foundItems[i].takeHome, soldAt: foundItems[i].soldAt
            )
        }
        guard !indicesNeedingWork.isEmpty else { return }
        isEnriching = true
        enrichedCount = 0
        defer { isEnriching = false }

        for i in indicesNeedingWork {
            let id = foundItems[i].id
            scanStatus = "Fetching order details \(enrichedCount + 1)/\(indicesNeedingWork.count)…"
            // Always visit the item page (fetchPhoto: true) — not just when the list-page scan
            // found no thumbnail — so every item also gets its price corrected against the
            // confirmed-reliable item-page value instead of trusting the list page's ambiguous
            // cents-vs-dollars guess (github issue #38).
            if let result = await saleSync.loadSaleData(itemId: id, fetchPhoto: true) {
                foundItems[i].takeHome = result.takeHome
                foundItems[i].soldAt = result.soldAt
                if let photo = result.thumbnailUrl { foundItems[i].thumbnailUrl = photo }
                if let price = result.price { foundItems[i].price = price }
                if result.takeHome == nil || result.soldAt == nil {
                    foundItems[i].enrichFailed = true
                    print("[Importer] Could not enrich \(id) — order page data missing")
                }
            } else {
                foundItems[i].enrichFailed = true
                print("[Importer] Order page timed out for \(id)")
            }
            enrichedCount = i + 1
        }
        scanStatus = ""
    }
}

// MARK: - Async external image loader with optional Referer header

private struct AsyncExternalImage: View {
    let url: URL
    var referer: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable()
            } else {
                Color(.systemGray5)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            var req = URLRequest(url: url)
            if let ref = referer { req.setValue(ref, forHTTPHeaderField: "Referer") }
            if let (data, _) = try? await URLSession.shared.data(for: req) {
                image = UIImage(data: data)
            }
        }
    }
}

// MARK: - Mercari login sheet (shown when sync detects a login redirect)

private struct MercariSyncLoginSheet: View {
    let webView: WKWebView
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            MercariSheetWebView(webView: webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Log in to Mercari")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone() }
                    }
                }
        }
    }
}

// MARK: - Async Firebase image loader (thin wrapper for storage paths)

private struct AsyncFirebaseImage: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable()
            } else {
                Color(.systemGray5)
            }
        }
        .task {
            guard image == nil else { return }
            let ref = Storage.storage().reference(withPath: path)
            if let data = try? await ref.data(maxSize: 2 * 1024 * 1024) {
                image = UIImage(data: data)
            }
        }
    }
}


