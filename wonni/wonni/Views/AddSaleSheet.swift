//
//  AddSaleSheet.swift
//  wonni
//
//  Unified "+" import modal: a platform toggle, a single auto-detecting paste field for
//  one-off imports, and a synced list of Mercari sales discovered-but-not-yet-imported below
//  it. Replaces the old AddSaleView.swift (tabbed Paste-URL/eBay UI) and SalesDashboardView's
//  separate MercariSalesImportSheet — those were two disconnected entry points into what's
//  really one workflow (github issues #48/#49/#50).
//

import SwiftUI
import WebKit
import FirebaseFirestore
import FirebaseStorage

enum AddSalePlatform: String, CaseIterable {
    case mercari, ebay
}

struct AddSaleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var platform: AddSalePlatform = .mercari

    @State private var urlString = ""
    @State private var pushedDetection: MercariInputDetection?

    @State private var pendingItems: [MercariFoundSaleItem] = []
    @State private var selectedIds: Set<String> = []
    @State private var isLoadingPending = true
    @State private var isSyncing = false
    @State private var isImporting = false
    @State private var itemToFix: MercariFoundSaleItem? = nil
    @State private var itemToEdit: MercariFoundSaleItem? = nil
    @State private var retryingIds: Set<String> = []
    @State private var importError: String? = nil
    @State private var showMercariLogin = false

    // Headless — reused for both the pending list's Sync button (discovery) and enrichment.
    @StateObject private var mercariSync = MercariSaleSyncManager()
    @StateObject private var importer: MercariSalesPageImporter

    init() {
        let sync = MercariSaleSyncManager()
        _mercariSync = StateObject(wrappedValue: sync)
        _importer = StateObject(wrappedValue: MercariSalesPageImporter(saleSync: sync))
    }

    private var detection: MercariInputDetection {
        MercariURLDetector.detect(urlString)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Platform", selection: $platform) {
                        Text("Mercari").tag(AddSalePlatform.mercari)
                        Text("eBay").tag(AddSalePlatform.ebay)
                    }
                    .pickerStyle(.segmented)
                }

                if platform == .mercari {
                    Section {
                        urlEntryRow
                    } header: {
                        Text("Add a sale")
                    } footer: {
                        Text("Paste a Mercari item URL, order-status URL, or item ID.")
                    }

                    Section {
                        pendingListHeader
                        if isLoadingPending {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else if pendingItems.isEmpty {
                            Text("No pending sales. Tap Sync to check for new ones.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ForEach(pendingItems) { item in pendingRow(item) }
                        }
                        // What the last scan actually saw — screenshot this if Sync keeps
                        // finding nothing, it pinpoints whether the page loaded, whether
                        // items rendered, and what the links looked like.
                        if importError != nil, let diag = mercariSync.lastScanDiagnostics {
                            DisclosureGroup("Scan details") {
                                Text(diag)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                    } header: {
                        Text("Found on Mercari (\(pendingItems.count))")
                    }
                } else {
                    Section {
                        ebayComingSoon
                    }
                }
            }
            .navigationTitle("Add Sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if platform == .mercari {
                    ToolbarItem(placement: .confirmationAction) {
                        if isImporting {
                            ProgressView()
                        } else {
                            Button("Import (\(selectedIds.count))") { Task { await importSelected() } }
                                .disabled(selectedIds.isEmpty || importer.isEnriching)
                        }
                    }
                }
            }
            .navigationDestination(item: $pushedDetection) { d in
                MercariSaleFinalizeForm(detection: d) {
                    Task { await reloadPending() }
                    dismiss()
                }
            }
            .confirmationDialog(
                "Couldn't sync this item correctly",
                isPresented: Binding(get: { itemToFix != nil }, set: { if !$0 { itemToFix = nil } }),
                titleVisibility: .visible
            ) {
                if let item = itemToFix {
                    Button("Retry") {
                        itemToFix = nil
                        Task { await retry(item) }
                    }
                    Button("Edit & Import") {
                        itemToEdit = item
                        itemToFix = nil
                    }
                    Button("Delete", role: .destructive) {
                        pendingItems.removeAll { $0.id == item.id }
                        selectedIds.remove(item.id)
                        Task { await PendingMercariSaleRepository.shared.delete(item.id) }
                        itemToFix = nil
                    }
                    Button("Cancel", role: .cancel) { itemToFix = nil }
                }
            } message: {
                Text("Missing title, price, take-home, or sold date. Retry the scrape, fill in the missing fields yourself, or delete this item.")
            }
            .sheet(item: $itemToEdit) { item in
                MercariFixSaleSheet(item: item) { savedId in
                    pendingItems.removeAll { $0.id == savedId }
                    selectedIds.remove(savedId)
                    Task { await PendingMercariSaleRepository.shared.delete(savedId) }
                }
            }
            .sheet(isPresented: $showMercariLogin, onDismiss: { Task { await syncNow() } }) {
                MercariSyncLoginSheet(webView: mercariSync.webView) {
                    showMercariLogin = false
                }
            }
            .onChange(of: mercariSync.needsLogin) { _, needs in
                if needs { showMercariLogin = true }
            }
            .task { await reloadPending() }
        }
        // The scan/enrichment webview must live in the view hierarchy — a detached WKWebView
        // throttles callAsyncJavaScript and every scan silently returns nothing (same reason
        // SalesDashboardView embeds its manager's webview at 0.01 opacity).
        .background(
            MercariSheetWebView(webView: mercariSync.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
    }

    private var urlEntryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Paste a Mercari URL or item ID", text: $urlString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if detection != .unrecognized {
                Button("Continue") { pushedDetection = detection }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var ebayComingSoon: some View {
        VStack(spacing: 16) {
            Image(systemName: "cart.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("eBay syncs automatically")
                .font(.headline)
            Text("eBay sales sync via webhook once connected in Settings — no manual import needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var pendingListHeader: some View {
        HStack {
            if isSyncing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.75)
                    Text(importer.isEnriching ? importer.scanStatus : "Checking Mercari…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let err = importError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Spacer()
            }
            Spacer()
            Button("Sync") { Task { await syncNow() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncing)
        }
    }

    private func pendingRow(_ item: MercariFoundSaleItem) -> some View {
        let flagged = isFlagged(item)
        return Button {
            if flagged {
                itemToFix = item
            } else if selectedIds.contains(item.id) {
                selectedIds.remove(item.id)
            } else {
                selectedIds.insert(item.id)
            }
        } label: {
            HStack(spacing: 12) {
                if flagged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                } else {
                    Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIds.contains(item.id) ? Color.accentColor : Color.secondary)
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? item.id).font(.subheadline).lineLimit(2)
                    HStack(spacing: 6) {
                        if flagged {
                            Text(retryingIds.contains(item.id) ? "Retrying…" : "Couldn't sync correctly — tap to fix")
                                .font(.caption2).foregroundStyle(.orange)
                        } else {
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
                }
                Spacer()
                if retryingIds.contains(item.id) {
                    ProgressView().scaleEffect(0.8)
                } else {
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
        }
        .foregroundStyle(.primary)
        .disabled(retryingIds.contains(item.id))
    }

    private func isFlagged(_ item: MercariFoundSaleItem) -> Bool {
        guard !importer.isEnriching, !retryingIds.contains(item.id) else { return false }
        if item.enrichFailed { return true }
        return MercariSaleValidation.needsFix(
            name: item.name, price: item.price, takeHome: item.takeHome, soldAt: item.soldAt
        )
    }

    private func reloadPending() async {
        isLoadingPending = true
        let items = await PendingMercariSaleRepository.shared.fetchAll()
        pendingItems = items
        importer.foundItems = items
        isLoadingPending = false
        // Freshly-loaded pending items may not have take-home/sold-date yet (scanForNewSales
        // only reads the list page) — enrich before showing them as selectable.
        await importer.enrichItems()
        pendingItems = importer.foundItems
        await PendingMercariSaleRepository.shared.upsert(pendingItems)
    }

    private func syncNow() async {
        isSyncing = true
        importError = nil
        defer { isSyncing = false }
        // Known = already-pending + already-imported (incl. soft-deleted, so restored+deleted
        // sales never resurface) — otherwise every Sync re-discovers sales the user already
        // imported, since they stay on Mercari's in_progress page until the order completes.
        async let fetchSales = SaleRepository.shared.fetchSales()
        async let fetchHidden = SaleRepository.shared.fetchHiddenSales()
        let importedIds = (((try? await fetchSales) ?? []) + ((try? await fetchHidden) ?? []))
            .compactMap { $0.platform == "mercari" ? $0.platformOrderId : nil }
        let knownIds = Set(pendingItems.map { $0.id }).union(importedIds)
        let found = await PendingMercariSaleRepository.shared.discoverAndPersist(
            using: mercariSync, knownOrderIds: knownIds, stopBeforeDate: nil
        )
        if mercariSync.needsLogin {
            importError = "Log in to Mercari to sync."
        } else if found.isEmpty && pendingItems.isEmpty {
            importError = "No new sales found."
        }
        await reloadPending()
    }

    private func retry(_ item: MercariFoundSaleItem) async {
        retryingIds.insert(item.id)
        await importer.enrichItem(item.id)
        pendingItems = importer.foundItems
        await PendingMercariSaleRepository.shared.upsert(pendingItems)
        retryingIds.remove(item.id)
    }

    private func importSelected() async {
        isImporting = true
        var succeededIds: Set<String> = []
        for item in pendingItems where selectedIds.contains(item.id) {
            // Flagged items can't be selected (tapping one opens the fix dialog instead), but
            // guard anyway — never write an incomplete Sale doc (github issue #24's failure mode).
            guard !isFlagged(item),
                  let name = item.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let price = item.price, price > 0,
                  let takeHome = item.takeHome,
                  let saleDate = item.soldAt else { continue }
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
                soldAt: Timestamp(date: saleDate)
            )
            do {
                try await SaleRepository.shared.addSale(sale)
                succeededIds.insert(item.id)
                await PendingMercariSaleRepository.shared.delete(item.id)
            } catch {
                print("[AddSaleSheet] Failed to save sale for \(item.id): \(error)")
            }
        }
        isImporting = false
        pendingItems.removeAll { succeededIds.contains($0.id) }
        importer.foundItems.removeAll { succeededIds.contains($0.id) }
        selectedIds.subtract(succeededIds)
    }
}

// MARK: - Single-item finalize form (ported from the old AddSaleByUrlView)

struct MercariSaleFinalizeForm: View {
    let detection: MercariInputDetection
    var onSaved: () -> Void

    @State private var title = ""
    @State private var priceString = ""
    @State private var platformOrderId = ""
    @State private var soldAt = Date()
    @State private var takeHomeString = ""
    @State private var trackingNumber = ""
    @State private var carrier = "USPS"
    @State private var isFetching = true
    @State private var fetchError: String? = nil
    @State private var isSaving = false

    @StateObject private var loader = MercariItemLoader()
    @State private var matchedListingId: String? = nil
    @State private var matchedCoverPhotoPath: String? = nil
    @State private var fetchedThumbnailUrl: String? = nil

    private var canSave: Bool {
        !title.isEmpty && Double(priceString.replacingOccurrences(of: "$", with: "")) != nil
    }

    var body: some View {
        Form {
            if isFetching {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading item…")
                        Spacer()
                    }
                }
            }
            if let err = fetchError {
                Section {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Details") {
                if !platformOrderId.isEmpty {
                    LabeledContent("Item ID", value: platformOrderId)
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

            Section {
                Button(action: { Task { await save() } }) {
                    if isSaving {
                        HStack {
                            ProgressView()
                            Text("Saving...")
                        }
                    } else {
                        Text("Save Sale")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(!canSave || isSaving)
            }
        }
        .navigationTitle("Finalize Sale")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            MercariSheetWebView(webView: loader.webView)
                .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
        )
        .task { await fetchOnAppear() }
    }

    private func fetchOnAppear() async {
        isFetching = true
        guard let itemId = detection.itemId else {
            fetchError = "Couldn't find a Mercari item ID."
            isFetching = false
            return
        }
        platformOrderId = itemId
        await fetchFromOrderStatusPage(itemId: itemId)
        await loadMercariItem(itemId: itemId)
        isFetching = false
    }

    private func loadMercariItem(itemId: String) async {
        await loader.load(itemId: itemId)
        if loader.phase == .loaded {
            if let n = loader.name, !n.isEmpty { title = n }
            if let p = loader.priceDollars, priceString.isEmpty { priceString = String(format: "%.2f", p) }
            fetchedThumbnailUrl = loader.thumbnailUrl
            let match = await ListingRepository.shared.findListingByMercariId(itemId)
            matchedListingId = match?.listingId
            matchedCoverPhotoPath = match?.coverPhotoPath
        } else if title.isEmpty {
            fetchError = "Couldn't load item — make sure you're logged in to Mercari."
        }
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
            thumbnailUrl: matchedCoverPhotoPath == nil ? fetchedThumbnailUrl : nil,
            platform: "mercari",
            platformOrderId: platformOrderId.isEmpty ? nil : platformOrderId,
            priceSoldFor: price,
            takeHome: takeHome,
            trackingNumber: tracking.isEmpty ? nil : tracking,
            carrier: tracking.isEmpty ? nil : carrier,
            status: tracking.isEmpty ? .pending : .shipped,
            soldAt: Timestamp(date: soldAt)
        )
        do {
            try await SaleRepository.shared.addSale(sale)
            if !platformOrderId.isEmpty {
                await PendingMercariSaleRepository.shared.delete(platformOrderId)
            }
            onSaved()
        } catch {
            fetchError = "Couldn't save: \(error.localizedDescription)"
        }
        isSaving = false
    }
}

// MARK: - Fix & Import (for flagged pending items)

/// Lets the user fill in whatever a flagged item's scrape couldn't get (title, price,
/// take-home, sold date) and save it immediately, rather than leaving it stuck unimportable.
private struct MercariFixSaleSheet: View {
    let item: MercariFoundSaleItem
    var onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var priceString: String
    @State private var takeHomeString: String
    @State private var soldAt: Date
    @State private var isSaving = false

    init(item: MercariFoundSaleItem, onSaved: @escaping (String) -> Void) {
        self.item = item
        self.onSaved = onSaved
        _title = State(initialValue: item.name ?? "")
        _priceString = State(initialValue: item.price.map { String(format: "%.2f", $0) } ?? "")
        _takeHomeString = State(initialValue: item.takeHome.map { String(format: "%.2f", $0) } ?? "")
        _soldAt = State(initialValue: item.soldAt ?? Date())
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Double(priceString) != nil
            && Double(takeHomeString) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item \(item.id)") {
                    TextField("Item title", text: $title)
                    HStack {
                        Text("Price sold for")
                        Spacer()
                        TextField("0.00", text: $priceString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Take-home")
                        Spacer()
                        TextField("0.00", text: $takeHomeString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date sold", selection: $soldAt, displayedComponents: .date)
                }
            }
            .navigationTitle("Fix & Import")
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

    private func save() async {
        guard let price = Double(priceString), let takeHome = Double(takeHomeString) else { return }
        isSaving = true
        let match = await ListingRepository.shared.findListingByMercariId(item.id)
        let sale = Sale(
            listingId: match?.listingId,
            listingTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            coverPhotoPath: match?.coverPhotoPath,
            thumbnailUrl: match?.coverPhotoPath == nil ? item.thumbnailUrl : nil,
            platform: "mercari",
            platformOrderId: item.id,
            priceSoldFor: price,
            takeHome: takeHome,
            status: .pending,
            soldAt: Timestamp(date: soldAt)
        )
        do {
            try await SaleRepository.shared.addSale(sale)
            onSaved(item.id)
            dismiss()
        } catch {
            print("[MercariFixSaleSheet] Failed to save sale for \(item.id): \(error)")
        }
        isSaving = false
    }
}

#Preview {
    NavigationStack {
        AddSaleSheet()
    }
}
