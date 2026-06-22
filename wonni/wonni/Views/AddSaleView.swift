//
//  AddSaleView.swift
//  wonni
//

import SwiftUI
import WebKit
import FirebaseFirestore
import FirebaseStorage

struct AddSaleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: AddSaleTab = .pasteUrl
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                Picker("Add Sale Method", selection: $selectedTab) {
                    ForEach(AddSaleTab.allCases, id: \.self) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.systemGroupedBackground))

                // Tab content
                TabView(selection: $selectedTab) {
                    AddSaleByUrlView(onSaved: { dismiss() })
                        .tag(AddSaleTab.pasteUrl)

                    AddSaleByItemIdView(onSaved: { dismiss() })
                        .tag(AddSaleTab.itemId)

                    BrowseMercariListingsView(onSaved: { dismiss() })
                        .tag(AddSaleTab.browseMercari)

                    BrowseEbayListingsView(onSaved: { dismiss() })
                        .tag(AddSaleTab.browseEbay)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Add Sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Tab Enum

enum AddSaleTab: String, CaseIterable {
    case pasteUrl = "URL"
    case itemId = "Item ID"
    case browseMercari = "Mercari"
    case browseEbay = "eBay"

    var label: String {
        switch self {
        case .pasteUrl:
            return "Paste URL"
        case .itemId:
            return "Item ID"
        case .browseMercari:
            return "Mercari"
        case .browseEbay:
            return "eBay"
        }
    }
}

// MARK: - Paste URL Tab

struct AddSaleByUrlView: View {
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
        .background(
            MercariSheetWebView(webView: loader.webView)
                .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
        )
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
        isSaving = false
    }
}

// MARK: - Item ID Tab

struct AddSaleByItemIdView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var itemIdString = ""
    @State private var platform = "mercari"
    @State private var isFetching = false
    @State private var fetchError: String? = nil

    @State private var title = ""
    @State private var priceString = ""
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
        Form {
            Section {
                HStack(spacing: 8) {
                    Picker("Platform", selection: $platform) {
                        Text("Mercari").tag("mercari")
                        Text("eBay").tag("ebay")
                        Text("Etsy").tag("etsy")
                    }
                    TextField("Paste item ID", text: $itemIdString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let err = fetchError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Item Details")
            } footer: {
                Text("Enter the item ID from \(platform.capitalized) to look up sale details.")
            }

            Section("Sale Details") {
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
        .background(
            MercariSheetWebView(webView: loader.webView)
                .frame(width: 1, height: 1).opacity(0).allowsHitTesting(false)
        )
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
            platformOrderId: itemIdString.isEmpty ? nil : itemIdString,
            priceSoldFor: price,
            takeHome: takeHome,
            trackingNumber: tracking.isEmpty ? nil : tracking,
            carrier: tracking.isEmpty ? nil : carrier,
            status: tracking.isEmpty ? .pending : .shipped,
            soldAt: Timestamp(date: soldAt)
        )
        try? await SaleRepository.shared.addSale(sale)
        onSaved()
        isSaving = false
    }
}

// MARK: - Browse Mercari Listings Tab

struct BrowseMercariListingsView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var importer = MercariSalesPageImporter()
    @State private var selectedIds: Set<String> = []
    @State private var isImporting = false
    @State private var soldAt = Date()

    var body: some View {
        if importer.foundItems.isEmpty {
            browserView
        } else {
            resultsView
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
                    Text("Go to Sold Items, then tap Scan")
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
            .toolbar {
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
    }

    private func importSelected() async {
        isImporting = true
        for item in importer.foundItems where selectedIds.contains(item.id) {
            let sale = Sale(
                listingTitle: item.name,
                thumbnailUrl: item.thumbnailUrl,
                platform: "mercari",
                platformOrderId: item.id,
                priceSoldFor: item.price ?? 0,
                status: .pending,
                soldAt: Timestamp(date: soldAt)
            )
            try? await SaleRepository.shared.addSale(sale)
        }
        onSaved()
        isImporting = false
    }
}

// MARK: - Browse eBay Listings Tab

struct BrowseEbayListingsView: View {
    var onSaved: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cart.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("eBay Integration Coming Soon")
                .font(.title3.weight(.semibold))

            Text("Browse your eBay sold listings and quickly add them to your sales dashboard. Enable webhook integration in Settings to see completed eBay sales automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

#Preview {
    NavigationStack {
        AddSaleView()
    }
}
