//
//  RecordSaleSheet.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore
import FirebaseFunctions

struct RecordSaleSheet: View {
    let listing: UserListing
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Sale info
    @State private var platform: String
    @State private var platformOrderId = ""
    @State private var priceSoldFor: Double
    @State private var takeHome: Double? = nil

    // Buyer
    @State private var buyerName = ""
    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zip = ""

    // Shipping
    @State private var trackingNumber = ""
    @State private var carrier = "USPS"

    // Take-home fetch state
    @State private var isFetchingTakeHome = false
    @State private var fetchError: String?
    @State private var mercariListingId: String?

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var savedResult: String?

    private let carriers = ["USPS", "UPS", "FedEx", "Other"]

    init(listing: UserListing, onSaved: @escaping () -> Void) {
        self.listing = listing
        self.onSaved = onSaved
        let platforms = listing.crossPostStatus?.filter { $0.value == "posted" }.map { $0.key }.sorted() ?? []
        _platform = State(initialValue: platforms.first ?? "ebay")
        _priceSoldFor = State(initialValue: listing.price ?? 0)
    }

    private var platformOptions: [String] {
        let posted = listing.crossPostStatus?.filter { $0.value == "posted" }.map { $0.key } ?? []
        let all = Set(posted + ["ebay", "mercari", "etsy"])
        return all.sorted()
    }

    private var mercariId: String? {
        listing.crossPostListingIds?["mercari"]
    }

    // eBay/Etsy can fetch once an order ID is present
    private var canFetchFromAPI: Bool {
        (platform == "ebay" || platform == "etsy") && !platformOrderId.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sale info") {
                    Picker("Platform", selection: $platform) {
                        ForEach(platformOptions, id: \.self) { p in
                            Text(Sale.platformDisplayName(p)).tag(p)
                        }
                    }
                    .onChange(of: platform) { _, _ in
                        fetchError = nil
                        // Auto-fetch Mercari take-home when switching to Mercari
                        if platform == "mercari", let id = mercariId {
                            mercariListingId = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                mercariListingId = id
                            }
                        }
                    }

                    TextField("Order / Receipt ID (optional)", text: $platformOrderId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Text("Sale price")
                        Spacer()
                        Text("$")
                        TextField("0.00", value: $priceSoldFor, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    takeHomeRow
                }

                Section("Buyer address") {
                    TextField("Full name", text: $buyerName)
                    TextField("Address line 1", text: $addressLine1)
                    TextField("Address line 2 (optional)", text: $addressLine2)
                    HStack {
                        TextField("City", text: $city)
                        TextField("State", text: $state).frame(maxWidth: 60)
                        TextField("ZIP", text: $zip).frame(maxWidth: 70).keyboardType(.numberPad)
                    }
                }

                Section("Shipping") {
                    Picker("Carrier", selection: $carrier) {
                        ForEach(carriers, id: \.self) { Text($0) }
                    }
                    TextField("Tracking number (optional)", text: $trackingNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let result = savedResult {
                    Section {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let err = saveError {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Record Sale")
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
                            .disabled(priceSoldFor <= 0)
                    }
                }
            }
            // Hidden Mercari web loader — invisible, runs in background
            .background {
                if let id = mercariListingId {
                    MercariTransactionLoader(listingId: id) { value in
                        takeHome = value
                        isFetchingTakeHome = false
                        fetchError = nil
                    } onError: { err in
                        isFetchingTakeHome = false
                        fetchError = err
                    }
                    .frame(width: 0, height: 0)
                }
            }
            .task {
                // Auto-fetch on open when Mercari is the starting platform
                if platform == "mercari", let id = mercariId {
                    isFetchingTakeHome = true
                    mercariListingId = id
                }
            }
        }
    }

    // MARK: - Take-home row

    @ViewBuilder
    private var takeHomeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Take-home")
                    .fontWeight(.semibold)
                Spacer()
                if isFetchingTakeHome {
                    ProgressView().scaleEffect(0.8)
                } else if canFetchFromAPI {
                    Button("Fetch") { Task { await fetchTakeHome() } }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                Text("$")
                TextField("0.00", value: $takeHome, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .foregroundStyle(takeHome != nil ? .green : .primary)
            }
            if let err = fetchError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                let hint = platform == "mercari"
                    ? "Auto-fetching from Mercari transaction page…"
                    : "Enter order/receipt ID above, then tap Fetch — or enter manually."
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - eBay / Etsy take-home fetch

    private func fetchTakeHome() async {
        isFetchingTakeHome = true
        fetchError = nil
        do {
            let functions = Functions.functions()
            if platform == "ebay" {
                let result = try await functions
                    .httpsCallable("ebayGetOrderTakeHome")
                    .call(["orderId": platformOrderId])
                if let dict = result.data as? [String: Any],
                   let value = dict["takeHome"] as? Double {
                    takeHome = value
                }
            } else if platform == "etsy" {
                let result = try await functions
                    .httpsCallable("etsyGetReceiptTakeHome")
                    .call(["receiptId": platformOrderId])
                if let dict = result.data as? [String: Any],
                   let value = dict["takeHome"] as? Double {
                    takeHome = value
                }
            }
        } catch {
            fetchError = "Could not fetch take-home: \(error.localizedDescription)"
        }
        isFetchingTakeHome = false
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        saveError = nil

        let address = SaleAddress(
            name: buyerName.isEmpty ? nil : buyerName,
            line1: addressLine1.isEmpty ? nil : addressLine1,
            line2: addressLine2.isEmpty ? nil : addressLine2,
            city: city.isEmpty ? nil : city,
            state: state.isEmpty ? nil : state,
            zip: zip.isEmpty ? nil : zip,
            country: "US"
        )

        let sale = Sale(
            userId: "",  // filled by repository
            listingId: listing.id,
            listingTitle: listing.customTitle,
            coverPhotoPath: listing.coverPhotoPath,
            platform: platform,
            platformOrderId: platformOrderId.isEmpty ? nil : platformOrderId,
            priceSoldFor: priceSoldFor,
            takeHome: takeHome,
            buyerAddress: address.oneLiner.isEmpty ? nil : address,
            trackingNumber: trackingNumber.isEmpty ? nil : trackingNumber,
            carrier: trackingNumber.isEmpty ? nil : carrier,
            status: trackingNumber.isEmpty ? .pending : .shipped,
            soldAt: Timestamp(date: Date())
        )

        do {
            let _ = try await SaleRepository.shared.recordSale(sale)

            if let listingId = listing.id {
                try? await Functions.functions()
                    .httpsCallable("decrementAndCascade")
                    .call(["listingId": listingId, "platform": platform])
            }

            let currentQty = listing.quantity ?? 1
            let newQty = max(currentQty - 1, 0)
            savedResult = newQty > 0
                ? "Recorded! \(newQty) unit\(newQty == 1 ? "" : "s") remaining."
                : "Recorded! Listing marked as sold."

            onSaved()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
        isSaving = false
    }
}
