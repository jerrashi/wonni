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
    @State private var showImportSales = false
    @State private var pendingMercariImports: [MercariFoundSaleItem] = []
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
                    Menu {
                        Button("Add Manually") { showAddSale = true }
                        Button("Import from Mercari") { showImportSales = true }
                    } label: {
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
                AddSaleView()
            }
            .sheet(isPresented: $showImportSales, onDismiss: { pendingMercariImports = [] }) {
                MercariSalesImportSheet(preloadedItems: pendingMercariImports) {
                    Task { await reload() }
                }
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
                Button("Import from Mercari") {
                    pendingMercariImports = []
                    showImportSales = true
                }
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
        sales = (try? await fetchSales) ?? []
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
                    let enrichment = await mercariSaleSyncManager.loadSaleData(itemId: item.id)
                    guard let name = item.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let price = item.price, price > 0,
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
                // Auto-import is off — surface a banner instead of forcing the sheet open
                // mid-sync; tapping "Review" opens the import sheet pre-populated with
                // what was found.
                pendingMercariImports = found
                let count = found.count
                showToast(
                    "\(count) new Mercari sale\(count == 1 ? "" : "s") found — review in Import",
                    actionLabel: "Review",
                    duration: 8_000_000_000
                ) {
                    showImportSales = true
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
            withAnimation { sales.insert(sale, at: 0) }
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

// MARK: - Add Sale Sheet (URL-based scrape + manual fields)

struct AddSaleSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var isFetching = false
    @State private var fetchError: String? = nil

    @State private var platform = "mercari"
    @State private var title = ""
    @State private var priceString = ""
    @State private var platformOrderId = ""
    @State private var soldAt = Date()
    @State private var takeHomeString = ""
    @State private var trackingNumber = ""
    @State private var carrier = "USPS"
    @State private var isSaving = false

    @StateObject private var loader = MercariItemLoader()
    @State private var matchedListingId: String? = nil
    @State private var matchedCoverPhotoPath: String? = nil

    private var canSave: Bool {
        !title.isEmpty && Double(priceString.replacingOccurrences(of: "$", with: "")) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("Paste order status URL, listing URL, or item ID", text: $urlString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        if isFetching {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Button("Fetch") { Task { await fetchFromURL() } }
                                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                    if let err = fetchError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Import from URL")
                } footer: {
                    Text("Paste a Mercari order status URL, listing URL, or item ID to auto-fill.")
                }

                Section("Details") {
                    Picker("Platform", selection: $platform) {
                        ForEach(["ebay", "mercari", "etsy"], id: \.self) { p in
                            Text(Sale.platformDisplayName(p)).tag(p)
                        }
                    }
                    TextField("Item title", text: $title)
                    HStack {
                        Text("Price sold for")
                        Spacer()
                        TextField("0.00", text: $priceString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date sold", selection: $soldAt, displayedComponents: .date)
                    if !platformOrderId.isEmpty {
                        LabeledContent("Item ID", value: platformOrderId)
                    }
                }

                Section("Financials") {
                    HStack {
                        Text("Take-home")
                        Spacer()
                        TextField("Optional", text: $takeHomeString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Shipping") {
                    Picker("Carrier", selection: $carrier) {
                        ForEach(["USPS", "UPS", "FedEx", "Other"], id: \.self) { Text($0) }
                    }
                    TextField("Tracking number (optional)", text: $trackingNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .background(
                MercariSheetWebView(webView: loader.webView)
                    .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
            )
            .navigationTitle("Add Sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    private func fetchFromURL() async {
        let input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        isFetching = true; fetchError = nil

        if input.range(of: #"^m[a-zA-Z0-9]+$"#, options: .regularExpression) != nil {
            // Raw Mercari item ID — fetch order status data first, then item page for title
            platform = "mercari"
            platformOrderId = input
            await fetchFromOrderStatusPage(itemId: input)
            await loader.load(itemId: input)
            if loader.phase == .loaded {
                if let n = loader.name, !n.isEmpty { title = n }
                if let date = loader.soldAt { soldAt = date }
                let match = await ListingRepository.shared.findListingByMercariId(input)
                matchedListingId = match?.listingId
                matchedCoverPhotoPath = match?.coverPhotoPath
            }
        } else if input.contains("mercari.com") {
            platform = "mercari"

            // Check if it's an order status URL
            let orderStatusPattern = #"/transaction/order_status/(m[a-zA-Z0-9]+)"#
            if let range = input.range(of: orderStatusPattern, options: .regularExpression),
               let idRange = input[range].range(of: #"m[a-zA-Z0-9]+"#, options: .regularExpression) {
                let itemId = String(input[range][idRange])
                platformOrderId = itemId
                await loader.load(itemId: itemId)
                if loader.phase == .loaded {
                    if let n = loader.name, !n.isEmpty { title = n }
                    if let date = loader.soldAt { soldAt = date }
                    let match = await ListingRepository.shared.findListingByMercariId(itemId)
                    matchedListingId = match?.listingId
                    matchedCoverPhotoPath = match?.coverPhotoPath
                }
                await fetchFromOrderStatusPage(itemId: itemId)
            } else {
                // Check if it's an item listing URL
                let itemPattern = #"/item/(m[a-zA-Z0-9]+)"#
                if let range = input.range(of: itemPattern, options: .regularExpression),
                   let idRange = input[range].range(of: #"m[a-zA-Z0-9]+"#, options: .regularExpression) {
                    let itemId = String(input[range][idRange])
                    platformOrderId = itemId
                    await loader.load(itemId: itemId)
                    if loader.phase == .loaded {
                        if let n = loader.name, !n.isEmpty { title = n }
                        if let date = loader.soldAt { soldAt = date }
                        let match = await ListingRepository.shared.findListingByMercariId(itemId)
                        matchedListingId = match?.listingId
                        matchedCoverPhotoPath = match?.coverPhotoPath
                    }
                    await fetchFromOrderStatusPage(itemId: itemId)
                } else {
                    fetchError = "Couldn't find a Mercari listing URL or order status URL."
                }
            }
        } else if input.contains("ebay.com") {
            platform = "ebay"
            if let range = input.range(of: #"\d{10,}"#, options: .regularExpression) {
                platformOrderId = String(input[range])
            }
            fetchError = "eBay details can't be scraped — fill in the fields manually."
        } else if input.contains("etsy.com") {
            platform = "etsy"
            fetchError = "Etsy details can't be scraped — fill in the fields manually."
        } else {
            fetchError = "Paste a Mercari, eBay, or Etsy URL."
        }
        isFetching = false
    }

    private func fetchFromOrderStatusPage(itemId: String) async {
        await withCheckedContinuation { continuation in
            let scraper = MercariTakeHomeScraper(mercariId: itemId, onSuccess: { data in
                if let price = data.soldPrice {
                    self.priceString = String(format: "%.2f", price)
                }
                if let takeHome = data.takeHome {
                    self.takeHomeString = String(format: "%.2f", takeHome)
                }
                if let tracking = data.trackingNumber {
                    self.trackingNumber = tracking
                }
                if let carrier = data.carrier {
                    self.carrier = carrier
                }
                if let date = data.soldDate {
                    self.soldAt = date
                }
                continuation.resume()
            }, onFail: {
                continuation.resume()
            })
            scraper.start()
        }
    }

    private func save() async {
        let cleanPrice = priceString.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Double(cleanPrice) else { return }
        isSaving = true
        let cleanTH = takeHomeString.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let takeHome = Double(cleanTH)
        let tracking = trackingNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let sale = Sale(
            listingId: matchedListingId,
            listingTitle: title.isEmpty ? nil : title,
            coverPhotoPath: matchedCoverPhotoPath,
            thumbnailUrl: matchedCoverPhotoPath == nil ? loader.thumbnailUrl : nil,
            platform: platform,
            platformOrderId: platformOrderId.isEmpty ? nil : platformOrderId,
            priceSoldFor: price,
            takeHome: takeHome,
            trackingNumber: tracking.isEmpty ? nil : tracking,
            carrier: tracking.isEmpty ? nil : carrier,
            status: tracking.isEmpty ? .pending : .shipped,
            soldAt: Timestamp(date: soldAt)
        )
        try? await SaleRepository.shared.addSale(sale)
        onSaved()
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

@MainActor
final class MercariSalesPageImporter: ObservableObject {
    @Published var isScanning = false
    @Published var scanStatus = ""
    @Published var foundItems: [MercariFoundSaleItem] = []
    @Published var scanError: String? = nil
    @Published var isEnriching = false
    @Published var enrichedCount = 0

    let webView: WKWebView
    private let navDelegate = SaleNavDelegate()

    private static let soldAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy"
        return f
    }()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = mercariProcessPool
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
        wv.navigationDelegate = navDelegate
        wv.load(URLRequest(url: URL(string: "https://www.mercari.com/mypage/listings/in_progress/?sortBy=7")!))
    }

    func enrichItems() async {
        guard !foundItems.isEmpty else { return }
        isEnriching = true
        enrichedCount = 0
        defer { isEnriching = false }

        let js = """
        (function() {
            var out = { takeHome: null, soldAt: null };
            var th = document.querySelector('p[data-testid="You-made-value"]');
            if (th) {
                var t = th.innerText.replace(/[^0-9.]/g, '');
                if (t) out.takeHome = parseFloat(t);
            }
            var dateEl = document.querySelector('p[data-testid="ItemSoldTime"]');
            if (dateEl) {
                var m = dateEl.innerText.match(/(\\d{2}\\/\\d{2}\\/\\d{2,4})/);
                if (m) out.soldAt = m[1];
            }
            return JSON.stringify(out);
        })();
        """

        for i in foundItems.indices {
            let id = foundItems[i].id
            scanStatus = "Fetching order details \(i + 1)/\(foundItems.count)…"
            guard let url = URL(string: "https://www.mercari.com/transaction/order_status/\(id)/") else {
                foundItems[i].enrichFailed = true
                enrichedCount = i + 1
                continue
            }
            navDelegate.reset()
            webView.load(URLRequest(url: url))
            guard await navDelegate.waitForLoad(timeout: 10) else {
                print("[Importer] Order page timed out for \(id)")
                foundItems[i].enrichFailed = true
                enrichedCount = i + 1
                continue
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let deadline = Date().addingTimeInterval(8)
            var enriched = false
            while Date() < deadline && !enriched {
                // JSONSerialization decodes JS `null` as NSNull, not Swift nil — `dict["takeHome"] != nil`
                // is true even for `{takeHome: null}`, so the two fields must be cast to their real
                // types (which fail for NSNull) to tell "not yet rendered" from "actually present".
                if let jsStr = (try? await webView.callJS(js)) as? String,
                   let data = jsStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let takeHome = (dict["takeHome"] as? NSNumber)?.doubleValue
                    let soldAtStr = dict["soldAt"] as? String
                    if takeHome != nil || soldAtStr != nil {
                        foundItems[i].takeHome = takeHome
                        if let dateStr = soldAtStr {
                            let fmt = Self.soldAtFormatter
                            fmt.dateFormat = "MM/dd/yy"
                            var parsed = fmt.date(from: dateStr)
                            if parsed == nil { fmt.dateFormat = "MM/dd/yyyy"; parsed = fmt.date(from: dateStr); fmt.dateFormat = "MM/dd/yy" }
                            foundItems[i].soldAt = parsed
                        }
                        enriched = true
                    } else {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            if !enriched {
                foundItems[i].enrichFailed = true
                print("[Importer] Could not enrich \(id) — order page data missing")
            }
            enrichedCount = i + 1
        }
        scanStatus = ""
    }

    func scanCurrentPage() async {
        isScanning = true; scanError = nil; foundItems = []

        // Phase 1: scroll to bottom repeatedly to trigger infinite-scroll loading
        await scrollToLoadAll()

        // Phase 2: extract all items now present in the DOM
        scanStatus = "Extracting items…"

        let js = #"""
        return (function() {
            // Phase 1: __NEXT_DATA__ — collect IDs and whatever name/price the JSON has.
            // Use a map (not a Set) so Phase 2 can backfill missing fields for the same item.
            var byId = {};
            var nd = document.getElementById('__NEXT_DATA__');
            if (nd) {
                try {
                    var data = JSON.parse(nd.textContent || '');
                    var pp = data.props && data.props.pageProps;
                    // Try every known path across in_progress, sold_out, and other mypage variants.
                    var items = (pp && (
                        pp.items ||
                        pp.soldItems ||
                        pp.listingItems ||
                        (pp.data && (pp.data.items || pp.data.soldItems)) ||
                        (pp.seller && pp.seller.items)
                    )) || [];
                    for (var item of items) {
                        var sid = String(item.id || '');
                        if (!sid || byId[sid]) continue;
                        if (item.status && item.status.toLowerCase() === 'inactive') continue;
                        // Name may be top-level or nested under a product object.
                        var itemName = item.name ||
                                       (item.product && item.product.name) ||
                                       item.productName || null;
                        // Price may be cents or dollars; >500 heuristic distinguishes them.
                        var rawPrice = item.price != null ? item.price :
                                       (item.product && item.product.price != null ? item.product.price : null);
                        var itemPrice = rawPrice != null ? (rawPrice > 500 ? rawPrice / 100 : rawPrice) : null;
                        // Check every image field name seen across Mercari's JSON structure variants.
                        var thumb = null;
                        if (item.photos && item.photos.length > 0)
                            thumb = item.photos[0].thumbnailUrl || item.photos[0].url || null;
                        if (!thumb) thumb = item.thumbnailUrl || item.photo_url || item.image || item.imageUrl ||
                                           item.thumbnail || item.photo ||
                                           (item.product && (item.product.thumbnailUrl || item.product.photo_url)) || null;
                        if (Array.isArray(thumb) && thumb.length > 0) thumb = thumb[0];
                        byId[sid] = { id: sid, name: itemName, price: itemPrice, thumbnailUrl: thumb };
                    }
                } catch(e) {
                    console.log('Error parsing __NEXT_DATA__:', e);
                }
            }
            // Phase 2: DOM links — adds newly seen items AND backfills name/price that Phase 1 left null.
            var links = Array.from(document.querySelectorAll('a[href*="/us/item/m"]'));
            for (var link of links) {
                var m = link.href.match(/\/us\/item\/(m[a-zA-Z0-9]+)/);
                if (!m) continue;
                var sid = m[1];
                var ribbon = link.querySelector('[class*="RibbonTitle"]');
                if (ribbon && ribbon.innerText.trim().toLowerCase() === 'inactive') continue;
                var existing = byId[sid];
                var needsName = !existing || !existing.name;
                var needsPrice = !existing || existing.price == null;
                var needsThumb = !existing || !existing.thumbnailUrl;
                if (!existing || needsName || needsPrice || needsThumb) {
                    var domName = null, domPrice = null, domThumb = null;
                    if (needsName) {
                        var nameEl = link.querySelector('[data-testid="ItemName"],[data-testid="item-name"],p');
                        if (nameEl && nameEl.innerText.trim()) domName = nameEl.innerText.trim();
                        if (!domName) {
                            var imgs = link.querySelectorAll('img');
                            for (var i = 0; i < imgs.length; i++) {
                                if (imgs[i].alt && !imgs[i].alt.toLowerCase().includes('avatar')) {
                                    domName = imgs[i].alt.trim(); break;
                                }
                            }
                        }
                    }
                    if (needsPrice) {
                        var priceEl = link.querySelector('[data-testid="ItemPrice"],[data-testid="item-price"],span');
                        var priceStr = priceEl ? priceEl.innerText.replace(/[^0-9.]/g,'') : '';
                        if (!priceStr) {
                            var pm = (link.innerText || '').match(/\$\s*([0-9,]+(?:\.[0-9]{2})?)/);
                            if (pm) priceStr = pm[1].replace(/,/g, '');
                        }
                        if (priceStr) domPrice = parseFloat(priceStr);
                    }
                    if (needsThumb) {
                        // Check src, data-src/data-image (lazy-load), filtering out placeholder
                        // data URIs and any Mercari-CDN image so noise doesn't win over a real photo.
                        var imgs2 = link.querySelectorAll('img');
                        for (var j = 0; j < imgs2.length; j++) {
                            var src2 = imgs2[j].src || imgs2[j].getAttribute('data-src') ||
                                       imgs2[j].getAttribute('data-image') || '';
                            if (!src2 || src2.includes('avatar') || src2.startsWith('data:') || src2.length < 20) continue;
                            domThumb = src2; break;
                        }
                        if (!domThumb) {
                            for (var k = 0; k < imgs2.length; k++) {
                                var src3 = imgs2[k].src || '';
                                if (src3.indexOf('mercdn.net') !== -1 || src3.indexOf('mercari-images') !== -1) {
                                    domThumb = src3; break;
                                }
                            }
                        }
                    }
                    if (existing) {
                        if (needsName && domName) existing.name = domName;
                        if (needsPrice && domPrice != null) existing.price = domPrice;
                        if (needsThumb && domThumb) existing.thumbnailUrl = domThumb;
                    } else {
                        byId[sid] = { id: sid, name: domName, price: domPrice, thumbnailUrl: domThumb };
                    }
                }
            }
            var results = [];
            for (var k in byId) results.push(byId[k]);
            return JSON.stringify(results);
        })();
        """#

        if let json = (try? await webView.callJS(js)) as? String,
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            // DEBUG: Log raw JSON from JavaScript extraction
            print("[MercariSalesPageImporter] Raw JSON from JS: \(json)")

            foundItems = arr.compactMap { dict in
                guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                let item = MercariFoundSaleItem(
                    id: id,
                    name: dict["name"] as? String,
                    price: (dict["price"] as? NSNumber)?.doubleValue,
                    thumbnailUrl: dict["thumbnailUrl"] as? String
                )
                // DEBUG: Log parsed items
                print("[MercariSalesPageImporter] Parsed item ID: \(id)")
                print("[MercariSalesPageImporter]   name: \(item.name ?? "nil")")
                print("[MercariSalesPageImporter]   price: \(item.price ?? 0)")
                print("[MercariSalesPageImporter]   thumbnailUrl: \(item.thumbnailUrl ?? "nil")")
                return item
            }
            if foundItems.isEmpty {
                scanError = "No items found. Navigate to your Sold Items tab first."
            } else {
                Task { await enrichItems() }
            }
        } else {
            scanError = "Couldn't scan — make sure you're on a Mercari page."
        }
        scanStatus = ""
        isScanning = false
    }

    private func scrollToLoadAll() async {
        // Count how many item links are currently in the DOM
        let countJS = #"return document.querySelectorAll('a[href*="/us/item/m"]').length;"#
        let scrollJS = "window.scrollTo(0, document.body.scrollHeight); return document.body.scrollHeight;"

        var lastCount = 0
        var sameStreak = 0

        for _ in 0..<50 {
            _ = try? await webView.callJS(scrollJS)
            // Wait for the new batch of items to render
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let count = (try? await webView.callJS(countJS)) as? Int ?? 0
            scanStatus = "Loading items… (\(count) found)"

            if count == lastCount {
                sameStreak += 1
                if sameStreak >= 2 { break } // two consecutive scrolls with no new items = end of list
            } else {
                sameStreak = 0
                lastCount = count
            }
        }
    }
}

struct MercariSalesImportSheet: View {
    var preloadedItems: [MercariFoundSaleItem]
    var onImported: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var importer = MercariSalesPageImporter()
    @State private var selectedIds: Set<String> = []
    @State private var isImporting = false
    @State private var soldAt = Date()

    init(preloadedItems: [MercariFoundSaleItem] = [], onImported: @escaping () -> Void) {
        self.preloadedItems = preloadedItems
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            // If items were pre-loaded from a sync scan, skip the browser and go straight to selection.
            let displayItems = importer.foundItems.isEmpty ? preloadedItems : importer.foundItems
            if displayItems.isEmpty {
                browserView
            } else {
                resultsView(items: displayItems)
            }
        }
        .task {
            // Preloaded items come from scanForNewSales(), which only reads title/price off
            // the list page — takeHome/soldAt are never set. Without running them through the
            // same order-page enrichment as a browser scan, every preloaded item would fail
            // the title/price/takeHome/soldAt import guard below and silently import nothing.
            guard importer.foundItems.isEmpty, !preloadedItems.isEmpty else { return }
            importer.foundItems = preloadedItems
            await importer.enrichItems()
        }
    }

    private var browserView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { importer.webView.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(importer.webView.canGoBack ? .primary : .tertiary)
                }
                Spacer()
                if importer.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75)
                        Text(importer.scanStatus)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Navigate to Sold Items, then tap Scan")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan") { Task { await importer.scanCurrentPage() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(importer.isScanning)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))

            if let err = importer.scanError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGroupedBackground))
            }

            MercariSheetWebView(webView: importer.webView)
                .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle("Import Mercari Sales")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func resultsView(items: [MercariFoundSaleItem]) -> some View {
        VStack(spacing: 0) {
            if importer.isEnriching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(importer.scanStatus.isEmpty ? "Fetching order details…" : importer.scanStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGroupedBackground))
            }
            if let err = importer.scanError {
                Text(err)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGroupedBackground))
            }

            DatePicker("Fallback date sold", selection: $soldAt, displayedComponents: .date)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

            List(items) { item in
                Button {
                    if selectedIds.contains(item.id) { selectedIds.remove(item.id) }
                    else { selectedIds.insert(item.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIds.contains(item.id) ? Color.accentColor : Color.secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? item.id).font(.subheadline).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(item.id).font(.caption2).foregroundStyle(.secondary)
                                if let date = item.soldAt {
                                    Text("·").font(.caption2).foregroundStyle(.secondary)
                                    Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else if importer.isEnriching {
                                    ProgressView().scaleEffect(0.6)
                                }
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let price = item.price {
                                Text(String(format: "$%.2f", price))
                                    .font(.subheadline.weight(.semibold))
                            }
                            if let th = item.takeHome {
                                Text(String(format: "≈$%.2f", th))
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("\(items.count) items found")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if preloadedItems.isEmpty {
                    // Blocked during enrichment: enrichItems() indexes into foundItems by a
                    // range captured at loop start, so clearing it here for a fresh scan while
                    // that loop is still running would write past the end of the new array.
                    Button("Back") { importer.foundItems = []; selectedIds.removeAll() }
                        .disabled(importer.isEnriching)
                } else {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("All") { selectedIds = Set(items.map { $0.id }) }
                    .disabled(selectedIds.count == items.count)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("Import (\(selectedIds.count))") { Task { await importSelected(from: items) } }
                        .disabled(selectedIds.isEmpty || importer.isEnriching)
                }
            }
        }
    }

    private func importSelected(from items: [MercariFoundSaleItem]) async {
        isImporting = true
        var skipped = 0
        var succeededIds: Set<String> = []
        for item in items where selectedIds.contains(item.id) {
            guard let name = item.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let price = item.price, price > 0,
                  let takeHome = item.takeHome else {
                print("[Import] Skipping \(item.id): missing title, price, or take-home")
                skipped += 1
                continue
            }
            let match = await ListingRepository.shared.findListingByMercariId(item.id)
            let sale = Sale(
                listingId: match?.listingId,
                listingTitle: name,
                coverPhotoPath: match?.coverPhotoPath,
                thumbnailUrl: match?.coverPhotoPath == nil ? item.thumbnailUrl : nil,
                platform: "mercari",
                platformOrderId: item.id,
                priceSoldFor: price,
                takeHome: takeHome,
                status: .pending,
                soldAt: item.soldAt.map { Timestamp(date: $0) } ?? Timestamp(date: soldAt)
            )
            do {
                try await SaleRepository.shared.addSale(sale)
                succeededIds.insert(item.id)
            } catch {
                print("[Import] Failed to save sale for \(item.id): \(error)")
            }
        }
        isImporting = false
        // Drop successfully-imported items so retrying the still-skipped ones can't
        // double-save them.
        importer.foundItems.removeAll { succeededIds.contains($0.id) }
        selectedIds.subtract(succeededIds)
        onImported()
        if skipped > 0 {
            print("[Import] \(skipped) sale(s) skipped due to missing title, price, or take-home")
            let plural = skipped == 1 ? "" : "s"
            importer.scanError = "\(skipped) item\(plural) skipped — still missing price or take-home. Re-scan to retry."
        } else {
            dismiss()
        }
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


