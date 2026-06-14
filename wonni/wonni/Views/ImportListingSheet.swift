//
//  ImportListingSheet.swift
//  wonni
//

import SwiftUI
import FirebaseFunctions
import FirebaseAuth
import FirebaseFirestore

struct ImportListingSheet: View {
    @Environment(\.dismiss) var dismiss

    @State private var urlString: String = ""
    @State private var isImporting: Bool = false
    @State private var importStatus: String = ""
    @State private var importError: String? = nil

    @StateObject private var urlExtractor = URLExtractor()
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Import URL")) {
                    TextField("https://...", text: $urlString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                if isImporting {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(importStatus)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                }
                
                if let error = importError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Import Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task { await performImport() }
                    }
                    .disabled(urlString.isEmpty || isImporting)
                }
            }
            .onReceive(urlExtractor.$currentStatus) { status in
                if !status.isEmpty {
                    self.importStatus = status
                }
            }
            .background(
                MercariSheetWebView(webView: urlExtractor.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            )
        }
    }
    
    private func performImport() async {
        guard let userId = Auth.auth().currentUser?.uid else {
            importError = "Not signed in."
            return
        }
        isImporting = true
        importError = nil
        importStatus = "Analyzing URL..."

        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var extracted: ExtractedListing
            var ebayItemId: String? = nil

            if url.lowercased().contains("ebay.com") {
                guard let itemId = extractEbayItemId(from: url) else {
                    throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Could not find an eBay Item ID in the URL."])
                }
                ebayItemId = itemId
                importStatus = "Fetching from eBay API..."
                extracted = try await fetchFromEbay(itemId: itemId)
            } else {
                extracted = try await urlExtractor.extract(from: url)
            }

            importStatus = "Uploading images..."
            let listingId = UUID().uuidString
            var photoPaths: [String] = []
            let imageUrls = extracted.imageUrls.isEmpty ? [] : extracted.imageUrls
            for (i, urlStr) in imageUrls.prefix(12).enumerated() {
                importStatus = "Uploading image \(i + 1) of \(min(imageUrls.count, 12))…"
                guard let imgUrl = URL(string: urlStr),
                      let (data, _) = try? await URLSession.shared.data(from: imgUrl),
                      let image = UIImage(data: data),
                      let path = try? await StorageService.shared.uploadListingImage(
                          image: image, index: i, userId: userId, listingId: listingId
                      ) else { continue }
                photoPaths.append(path)
            }

            // Build cross-post IDs
            var crossPostIds: [String: String]? = nil
            var crossPostStatus: [String: String]? = nil
            if let ebayId = ebayItemId {
                crossPostIds = ["ebay": ebayId]
                crossPostStatus = ["ebay": "posted"]
            } else if let mercariId = extractMercariItemId(from: url) {
                crossPostIds = ["mercari": mercariId]
                crossPostStatus = ["mercari": "posted"]
            }

            let condition = mapCondition(extracted.condition) ?? .good
            let listing = UserListing(
                id: listingId,
                userId: userId,
                catalogItemId: "",
                customTitle: extracted.title.isEmpty ? nil : extracted.title,
                customDescription: extracted.description.isEmpty ? nil : extracted.description,
                price: extracted.price,
                currency: "USD",
                quantity: 1,
                condition: condition,
                photoPaths: photoPaths,
                coverPhotoPath: photoPaths.first,
                status: .active,
                createdAt: Timestamp(date: Date()),
                updatedAt: Timestamp(date: Date()),
                publishedAt: Timestamp(date: Date()),
                crossPostStatus: crossPostStatus,
                crossPostListingIds: crossPostIds
            )
            _ = try await ListingRepository.shared.saveDraft(listing)

            dismiss()
        } catch {
            importError = error.localizedDescription
        }

        isImporting = false
    }
    
    private func extractEbayItemId(from urlString: String) -> String? {
        // e.g. https://www.ebay.com/itm/123456789012
        let pattern = "/itm/(?:[^/]+/)?(\\d{11,13})"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: urlString, options: [], range: NSRange(location: 0, length: urlString.utf16.count)) {
            if let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }
    
    private func fetchFromEbay(itemId: String) async throws -> ExtractedListing {
        return try await withCheckedThrowingContinuation { continuation in
            Functions.functions().httpsCallable("ebayImportListing").call(["itemId": itemId]) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data = result?.data as? [String: Any] else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                
                let title = data["title"] as? String ?? ""
                let price = data["price"] as? Double ?? 0.0
                let desc = data["description"] as? String ?? ""
                let images = data["imageUrls"] as? [String] ?? []
                let cond = data["condition"] as? String ?? ""
                
                let listing = ExtractedListing(title: title, price: price, description: desc, imageUrls: images)
                // Could store cond in a temporary way
                continuation.resume(returning: listing)
            }
        }
    }
    
    private func extractMercariItemId(from url: String) -> String? {
        if let range = url.range(of: #"/item/(m[A-Za-z0-9]+)"#, options: .regularExpression) {
            return String(url[range]).replacingOccurrences(of: "/item/", with: "")
        }
        if let range = url.range(of: #"\bm\d{6,}\b"#, options: .regularExpression) {
            return String(url[range])
        }
        return nil
    }

    private func mapCondition(_ text: String) -> ItemCondition? {
        let lower = text.lowercased()
        if lower.contains("new") && !lower.contains("other") && !lower.contains("without tags") {
            return .new
        } else if lower.contains("like new") || lower.contains("excellent") {
            return .likeNew
        } else if lower.contains("good") {
            return .good
        } else if lower.contains("fair") {
            return .fair
        } else if lower.contains("poor") || lower.contains("parts") {
            return .poor
        }
        return nil
    }
}
