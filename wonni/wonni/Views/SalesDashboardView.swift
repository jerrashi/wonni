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
    @Environment(\.dismiss) private var dismiss
    @State private var sales: [Sale] = []
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var syncToast: String?
    @State private var selectedSale: Sale?
    @State private var filterPlatform: String? = nil
    @State private var showMercariSync = false
    @AppStorage("lastSalesSyncDate") private var lastSyncTimestamp: Double = 0
    
    @StateObject private var mercariSaleSyncManager = MercariSaleSyncManager()

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
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sales.isEmpty {
                    emptySalesState
                } else {
                    salesList
                }
            }

            .navigationTitle("Sales")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    syncButton
                }
            }
            .safeAreaInset(edge: .bottom) {
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
            }
            .animation(.spring(duration: 0.3), value: syncToast)
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
            .sheet(isPresented: $mercariSaleSyncManager.showSheet) {
                MercariSaleSyncSheet(manager: mercariSaleSyncManager)
            }
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

            // Individual sales
            Section("\(filteredSales.count) sale\(filteredSales.count == 1 ? "" : "s")") {
                ForEach(filteredSales) { sale in
                    Button {
                        selectedSale = sale
                    } label: {
                        SaleRow(sale: sale)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                if let id = sale.id {
                                    try? await SaleRepository.shared.deleteSale(id: id)
                                    await reload()
                                }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
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
            Text("Tap \u{21BA} to sync from eBay and Etsy, use \u{21BA} > Check Mercari listings for Mercari, or swipe left on a listing in your Profile to record one manually.")
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
        sales = (try? await SaleRepository.shared.fetchSales()) ?? []
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
        if !force { lastSyncTimestamp = Date().timeIntervalSince1970 }
        do {
            let result = try await Functions.functions()
                .httpsCallable("syncSales")
                .call(force ? ["force": true] : [:])
            let dict = result.data as? [String: Any] ?? [:]
            if dict["rateLimited"] as? Bool == true {
                showToast("Try again in a few minutes")
            } else {
                let newSales = dict["newSales"] as? Int ?? 0
                await reload()
                if dict["ebayError"] as? String == "reconnect_required" {
                    showToast("Reconnect eBay in Settings to enable sale sync")
                } else {
                    showToast(newSales > 0
                        ? "\(newSales) new sale\(newSales == 1 ? "" : "s") recorded"
                        : "Already up to date")
                }
            }
        } catch {
            if !force { lastSyncTimestamp = 0 }
            showToast("Sync failed: \(error.localizedDescription)")
        }
        
        let mercariSales = sales.filter { $0.platform == "mercari" && ($0.takeHome == nil || $0.trackingNumber == nil) }
        if !mercariSales.isEmpty {
            await mercariSaleSyncManager.sync(sales: mercariSales)
            await reload()
        }
        
        isSyncing = false
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
        case .pending:  ("Pending", .orange)
        case .shipped:  ("Shipped", .blue)
        case .complete: ("Complete", .green)
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


