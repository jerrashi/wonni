//
//  ImportListingSheet.swift
//  wonni
//

import SwiftUI
import FirebaseFunctions

struct ImportListingSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager
    
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
        isImporting = true
        importError = nil
        importStatus = "Analyzing URL..."
        
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        do {
            var extracted: ExtractedListing
            
            if url.lowercased().contains("ebay.com") {
                // Extract eBay Item ID
                guard let itemId = extractEbayItemId(from: url) else {
                    throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Could not find an eBay Item ID in the URL."])
                }
                
                importStatus = "Fetching from eBay API..."
                extracted = try await fetchFromEbay(itemId: itemId)
            } else {
                // Web scrape (Mercari, etc.)
                extracted = try await urlExtractor.extract(from: url)
            }
            
            importStatus = "Downloading images..."
            let photosData = try await downloadImages(urls: extracted.imageUrls)
            
            // Create Draft Item
            let draft = Item(
                photosData: photosData,
                buyerPaysShipping: true,
                handlingFee: 0.0,
                estimatedShippingDays: 3,
                isDraft: true,
                sourceAssetIdentifiers: [], // We don't have local PHAssets for these
                isLocalPhotoOnly: true, // We will treat them as local NSData since they aren't uploaded yet
                originalUserTitleBeforeAI: extracted.title,
                originalUserDescriptionBeforeAI: extracted.description
            )
            
            // Pre-fill user edits
            draft.userEditedTitle = extracted.title
            draft.userEditedPrice = extracted.price
            draft.userEditedDescription = extracted.description
            
            if !extracted.condition.isEmpty {
                // simple mapping if possible, otherwise leave it
                draft.condition = mapCondition(extracted.condition)
            }
            
            // Insert and save
            modelContext.insert(draft)
            try modelContext.save()
            
            // Set it as active draft so we can immediately edit it
            uploadManager.activeDraftID = draft.id
            
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
    
    private func downloadImages(urls: [String]) async throws -> [Data] {
        var dataArray: [Data] = []
        for urlStr in urls.prefix(12) { // Cap at 12 images
            if let url = URL(string: urlStr) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    dataArray.append(data)
                } catch {
                    print("Failed to download image: \(urlStr)")
                }
            }
        }
        return dataArray
    }
    
    private func mapCondition(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("new") && !lower.contains("other") && !lower.contains("without tags") {
            return "new"
        } else if lower.contains("like new") || lower.contains("excellent") {
            return "likeNew"
        } else if lower.contains("good") {
            return "good"
        } else if lower.contains("fair") {
            return "fair"
        } else if lower.contains("poor") || lower.contains("parts") {
            return "poor"
        }
        return nil
    }
}
