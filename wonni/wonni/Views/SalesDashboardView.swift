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
    @AppStorage("lastSalesSyncDate") private var lastSyncTimestamp: Double = 0
    
    @StateObject private var mercariSaleSyncManager = MercariSaleSyncManager()

    @State private var hiddenSales: [Sale] = []
    @State private var isHiddenSectionExpanded = false
    @State private var isSelectMode = false
    @State private var selectedSaleIds: Set<String> = []
    @State private var saleToDelete: Sale? = nil
    @State private var showBulkDeleteConfirmation = false
    @State private var showAddSale = false
    @State private var showImportSales = false

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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let toast = syncToast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
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
            .sheet(isPresented: $showAddSale, onDismiss: { Task { await reload() } }) {
                AddSaleView()
            }
            .sheet(isPresented: $showImportSales) {
                MercariSalesImportSheet { Task { await reload() } }
            }
            .confirmationDialog(
                "Delete this sale?",
                isPresented: Binding(
                    get: { saleToDelete != nil },
                    set: { if !$0 { saleToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        if let id = saleToDelete?.id {
                            try? await SaleRepository.shared.hideSale(id: id)
                            await reload()
                        }
                        saleToDelete = nil
                    }
                }
            } message: {
                Text("The sale will be removed from your dashboard. You can restore it from Deleted Sales.")
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
                            Button(role: .destructive) {
                                saleToDelete = sale
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
                Button("Check Mercari listings") {
                    showMercariSync = true
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
        sales = (try? await fetchSales) ?? []
        hiddenSales = (try? await fetchHidden) ?? []
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
        salesSyncTaskId = UUID()
        AppTaskQueue.shared.begin(id: salesSyncTaskId, label: "Syncing sales")
        if !force { lastSyncTimestamp = Date().timeIntervalSince1970 }

        let toast = await syncAPIPlatforms(force: force)
        await syncWebPlatforms()

        AppTaskQueue.shared.complete(id: salesSyncTaskId)
        isSyncing = false
        if let toast { showToast(toast) }
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
        // Update status of existing non-terminal Mercari sales.
        // New sale discovery is user-initiated via "+" > "Import from Mercari".
        await mercariSaleSyncManager.sync(sales: sales)
        // Future: await facebookSaleSyncManager.scanForNewSales(...) / .sync(...)
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

    private func showToast(_ message: String) {
        syncToast = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncToast = nil
        }
    }
}

// MARK: - Sale Row

private struct SaleRow: View {
    let sale: Sale

    var body: some View {
        HStack(spacing: 12) {
            // Cover photo or placeholder
            Group {
                if let path = sale.coverPhotoPath {
                    AsyncFirebaseImage(path: path)
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let urlStr = sale.thumbnailUrl, let url = URL(string: urlStr) {
                    AsyncExternalImage(url: url, referer: sale.platform == "mercari" ? "https://www.mercari.com" : nil)
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
    @State private var takeHomeString: String
    @State private var isSaving = false

    init(sale: Sale, onUpdated: @escaping () -> Void) {
        self.sale = sale
        self.onUpdated = onUpdated
        _trackingNumber = State(initialValue: sale.trackingNumber ?? "")
        _carrier = State(initialValue: sale.carrier ?? "USPS")
        _status = State(initialValue: sale.status)
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
                    LabeledContent("Item price", value: String(format: "$%.2f", sale.priceSoldFor))
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
                    if let orderId = sale.platformOrderId {
                        LabeledContent("Order ID", value: orderId)
                    }
                }

                if let addr = sale.buyerAddress, !addr.multiLine.isEmpty {
                    Section("Buyer address") {
                        Text(addr.multiLine)
                            .font(.subheadline)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = addr.multiLine
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                            }
                    }
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
        
        let cleanedTh = takeHomeString.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let th = Double(cleanedTh) {
            data["takeHome"] = th
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
                        TextField("Paste Mercari item URL", text: $urlString)
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
                    Text("Paste a Mercari listing URL to auto-fill title and price.")
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
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        isFetching = true; fetchError = nil

        if url.contains("mercari.com") {
            platform = "mercari"
            let pattern = #"/item/(m[a-zA-Z0-9]+)"#
            if let range = url.range(of: pattern, options: .regularExpression),
               let idRange = url[range].range(of: #"m[a-zA-Z0-9]+"#, options: .regularExpression) {
                let itemId = String(url[range][idRange])
                platformOrderId = itemId
                await loader.load(itemId: itemId)
                if loader.phase == .loaded {
                    if let n = loader.name, !n.isEmpty { title = n }
                    if let p = loader.priceDollars { priceString = String(format: "%.2f", p) }
                    let match = await ListingRepository.shared.findListingByMercariId(itemId)
                    matchedListingId = match?.listingId
                    matchedCoverPhotoPath = match?.coverPhotoPath
                } else {
                    fetchError = "Couldn't load item — make sure you're logged in to Mercari."
                }
            } else {
                fetchError = "Couldn't find an item ID in that URL."
            }
        } else if url.contains("ebay.com") {
            platform = "ebay"
            if let range = url.range(of: #"\d{10,}"#, options: .regularExpression) {
                platformOrderId = String(url[range])
            }
            fetchError = "eBay details can't be scraped — fill in the fields manually."
        } else if url.contains("etsy.com") {
            platform = "etsy"
            fetchError = "Etsy details can't be scraped — fill in the fields manually."
        } else {
            fetchError = "Paste a Mercari, eBay, or Etsy URL."
        }
        isFetching = false
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
    let name: String?
    let price: Double?
    let thumbnailUrl: String?
}

@MainActor
final class MercariSalesPageImporter: ObservableObject {
    @Published var isScanning = false
    @Published var scanStatus = ""
    @Published var foundItems: [MercariFoundSaleItem] = []
    @Published var scanError: String? = nil

    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = mercariProcessPool
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
        wv.load(URLRequest(url: URL(string: "https://www.mercari.com/mypage/listings/in_progress/?sortBy=7")!))
    }

    func scanCurrentPage() async {
        isScanning = true; scanError = nil; foundItems = []

        // Phase 1: scroll to bottom repeatedly to trigger infinite-scroll loading
        await scrollToLoadAll()

        // Phase 2: extract all items now present in the DOM
        scanStatus = "Extracting items…"

        let js = #"""
        return (function() {
            var results = [];
            var seen = new Set();
            var nd = document.getElementById('__NEXT_DATA__');
            if (nd) {
                try {
                    var data = JSON.parse(nd.textContent || '');
                    var pp = data.props && data.props.pageProps;
                    var items = (pp && (pp.items || (pp.data && pp.data.items) ||
                                 (pp.seller && pp.seller.items))) || [];
                    for (var item of items) {
                        var sid = String(item.id || '');
                        if (!sid || seen.has(sid)) continue;
                        if (item.status && item.status.toLowerCase() === 'inactive') continue;
                        seen.add(sid);
                        results.push({ id: sid, name: item.name || null,
                                       price: item.price ? item.price / 100 : null });
                    }
                } catch(e) {}
            }
            // DOM fallback: any link pointing to /us/item/m...
            var links = Array.from(document.querySelectorAll('a[href*="/us/item/m"]'));
            for (var link of links) {
                var m = link.href.match(/\/us\/item\/(m[a-zA-Z0-9]+)/);
                if (!m || seen.has(m[1])) continue;
                var ribbon = link.querySelector('[class*="RibbonTitle"]');
                if (ribbon && ribbon.innerText.trim().toLowerCase() === 'inactive') continue;
                seen.add(m[1]);
                var nameEl = link.querySelector('[data-testid="ItemName"],[data-testid="item-name"],p');
                var priceEl = link.querySelector('[data-testid="ItemPrice"],[data-testid="item-price"],span');
                var name = nameEl ? nameEl.innerText.trim() : null;
                var priceStr = priceEl ? priceEl.innerText.replace(/[^0-9.]/g,'') : null;
                results.push({ id: m[1], name: name||null, price: priceStr?parseFloat(priceStr):null });
            }
            return JSON.stringify(results);
        })();
        """#

        if let json = (try? await webView.callJS(js)) as? String,
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            foundItems = arr.compactMap { dict in
                guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                return MercariFoundSaleItem(
                    id: id,
                    name: dict["name"] as? String,
                    price: (dict["price"] as? NSNumber)?.doubleValue,
                    thumbnailUrl: dict["thumbnailUrl"] as? String
                )
            }
            if foundItems.isEmpty {
                scanError = "No items found. Navigate to your Sold Items tab first."
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
    var onImported: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var importer = MercariSalesPageImporter()
    @State private var selectedIds: Set<String> = []
    @State private var isImporting = false
    @State private var soldAt = Date()
    @State private var showDatePicker = false

    var body: some View {
        NavigationStack {
            if importer.foundItems.isEmpty {
                browserView
            } else {
                resultsView
            }
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

    private var resultsView: some View {
        VStack(spacing: 0) {
            DatePicker("Date sold", selection: $soldAt, displayedComponents: .date)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

            List(importer.foundItems) { item in
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
                            Text(item.id).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let price = item.price {
                            Text(String(format: "$%.2f", price))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("\(importer.foundItems.count) items found")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { importer.foundItems = []; selectedIds.removeAll() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("All") { selectedIds = Set(importer.foundItems.map { $0.id }) }
                    .disabled(selectedIds.count == importer.foundItems.count)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("Import (\(selectedIds.count))") { Task { await importSelected() } }
                        .disabled(selectedIds.isEmpty)
                }
            }
        }
    }

    private func importSelected() async {
        isImporting = true
        for item in importer.foundItems where selectedIds.contains(item.id) {
            let match = await ListingRepository.shared.findListingByMercariId(item.id)
            let sale = Sale(
                listingId: match?.listingId,
                listingTitle: item.name,
                coverPhotoPath: match?.coverPhotoPath,
                thumbnailUrl: match?.coverPhotoPath == nil ? item.thumbnailUrl : nil,
                platform: "mercari",
                platformOrderId: item.id,
                priceSoldFor: item.price ?? 0,
                status: .pending,
                soldAt: Timestamp(date: soldAt)
            )
            try? await SaleRepository.shared.addSale(sale)
        }
        onImported()
        dismiss()
        isImporting = false
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


