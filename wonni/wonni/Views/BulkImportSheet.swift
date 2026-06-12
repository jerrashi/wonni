//
//  BulkImportSheet.swift
//  wonni
//

import SwiftUI

struct BulkImportSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var importManager: BulkImportManager
    
    @State private var profileUrlString: String = ""
    @State private var isAnalyzing: Bool = false
    @State private var analysisError: String? = nil
    
    @State private var availableItems: [ListingPreview] = []
    @State private var selectedItemUrls: Set<String> = []
    
    @StateObject private var urlExtractor = URLExtractor()
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)
    ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section(header: Text("Mercari Profile URL"), footer: Text("Enter a link to a Mercari profile (e.g. mercari.com/u/123456789/)")) {
                        HStack {
                            TextField("https://...", text: $profileUrlString)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            if !profileUrlString.isEmpty {
                                Button("Analyze") {
                                    Task { await analyzeProfile() }
                                }
                                .disabled(isAnalyzing)
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    
                    if isAnalyzing {
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                ProgressView()
                                Text(urlExtractor.currentStatus)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding()
                    }
                    
                    if let error = analysisError {
                        Section {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: availableItems.isEmpty ? .infinity : 180)
                
                if !availableItems.isEmpty {
                    Divider()
                    
                    VStack {
                        HStack {
                            Text("Select items to import")
                                .font(.headline)
                            Spacer()
                            Button(selectedItemUrls.count == availableItems.count ? "Deselect All" : "Select All") {
                                if selectedItemUrls.count == availableItems.count {
                                    selectedItemUrls.removeAll()
                                } else {
                                    selectedItemUrls = Set(availableItems.map { $0.url })
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(availableItems) { item in
                                    let isSelected = selectedItemUrls.contains(item.url)
                                    
                                    Button {
                                        if isSelected {
                                            selectedItemUrls.remove(item.url)
                                        } else {
                                            selectedItemUrls.insert(item.url)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ZStack(alignment: .topTrailing) {
                                                AsyncImage(url: URL(string: item.thumbnailUrl)) { image in
                                                    image.resizable().scaledToFill()
                                                } placeholder: {
                                                    Color(.systemGray5)
                                                }
                                                .frame(width: 110, height: 110)
                                                .cornerRadius(8)
                                                
                                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                                    .foregroundColor(isSelected ? .blue : .white.opacity(0.8))
                                                    .padding(6)
                                            }
                                            
                                            Text(item.title)
                                                .font(.caption)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                                .foregroundColor(.primary)
                                            
                                            Text("$\(String(format: "%.2f", item.price))")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(4)
                                        .background(isSelected ? Color.blue.opacity(0.05) : Color.clear)
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("Bulk Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isAnalyzing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selectedItemUrls.count)") {
                        startImport()
                    }
                    .disabled(selectedItemUrls.isEmpty || isAnalyzing)
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
    
    private func analyzeProfile() async {
        isAnalyzing = true
        analysisError = nil
        availableItems = []
        selectedItemUrls = []
        
        do {
            let url = profileUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
            let items = try await urlExtractor.extractProfileListings(from: url)
            availableItems = items
            // Select all by default
            selectedItemUrls = Set(items.map { $0.url })
        } catch {
            analysisError = error.localizedDescription
        }
        
        isAnalyzing = false
    }
    
    private func startImport() {
        let itemsToImport = availableItems.filter { selectedItemUrls.contains($0.url) }
        importManager.startImporting(previews: itemsToImport)
        dismiss()
    }
}
