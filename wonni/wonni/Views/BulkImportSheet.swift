//
//  BulkImportSheet.swift
//  wonni
//

import SwiftUI
import FirebaseFunctions

struct BulkImportSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var importManager: BulkImportManager
    
    @State private var profileUrlString: String = ""
    @State private var isAnalyzing: Bool = false
    @State private var analysisError: String? = nil
    
    @State private var availableItems: [ListingPreview] = []
    @State private var selectedItemUrls: Set<String> = []
    @State private var isWeverseSource: Bool = false

    @StateObject private var urlExtractor = URLExtractor()
    @State private var weverseShippingProbe = WeverseShippingProbe()

    // ── Shipping-estimate pipeline state (Weverse only) ─────────────────────
    // See runShippingEstimatePipeline — mirrors WeverseShopImportModal.jsx's
    // pipeline of the same name.
    @State private var isRunningPipeline = false
    @State private var pipelineStatus = ""

    @State private var pendingConfirmVisible = false
    @State private var pendingConfirmItems: [ListingPreview] = []
    @State private var pendingConfirmKnownTypes: [String] = []
    @State private var typeChoices: [String: String] = [:]
    @State private var newTypeDrafts: [String: String] = [:]
    @State private var typeConfirmContinuation: CheckedContinuation<[String: String], Never>?

    @State private var missingAddressVisible = false
    @State private var showAddressWebView = false
    @State private var addressContinuation: CheckedContinuation<String, Never>?
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)
    ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section(header: Text("Profile / Shop URL"), footer: Text("Enter a Mercari profile (e.g. mercari.com/u/123456789/) or a Weverse Shop artist page (e.g. shop.weverse.io/en/shop/USD/artists/255)")) {
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

                                            if let desc = item.description, !desc.isEmpty {
                                                Text(desc)
                                                    .font(.caption2)
                                                    .lineLimit(1)
                                                    .multilineTextAlignment(.leading)
                                                    .foregroundColor(.secondary)
                                            }

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
                        .disabled(isAnalyzing || isRunningPipeline)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selectedItemUrls.count)") {
                        startImport()
                    }
                    .disabled(selectedItemUrls.isEmpty || isAnalyzing || isRunningPipeline)
                }
            }
            .background(
                MercariSheetWebView(webView: urlExtractor.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            )
            .overlay {
                if isRunningPipeline {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(pipelineStatus)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .background(.regularMaterial)
                        .cornerRadius(12)
                        .padding(32)
                    }
                }
            }
            .sheet(isPresented: $pendingConfirmVisible) {
                WeverseTypeConfirmSheet(
                    items: pendingConfirmItems,
                    knownTypes: pendingConfirmKnownTypes,
                    typeChoices: $typeChoices,
                    newTypeDrafts: $newTypeDrafts,
                    onContinue: submitTypeConfirmation
                )
            }
            .sheet(isPresented: $missingAddressVisible) {
                WeverseMissingAddressSheet(
                    onSkip: { resolveAddressPrompt(with: "skip") },
                    onOpenWeverse: {
                        missingAddressVisible = false
                        showAddressWebView = true
                    },
                    onRetry: { resolveAddressPrompt(with: "retry") }
                )
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showAddressWebView, onDismiss: {
                // The user may have added an address and come straight back
                // without tapping "Retry" inside the prompt — re-show it so
                // they still have a way to resume the paused pipeline.
                if addressContinuation != nil {
                    missingAddressVisible = true
                }
            }) {
                WeverseAddressSheet()
            }
        }
    }
    
    private func analyzeProfile() async {
        isAnalyzing = true
        analysisError = nil
        availableItems = []
        selectedItemUrls = []
        
        do {
            let url = profileUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
            let items: [ListingPreview]
            if url.lowercased().contains("weverse.io") {
                isWeverseSource = true
                items = try await fetchWeverseShopPreview(shopUrl: url)
            } else {
                isWeverseSource = false
                items = try await urlExtractor.extractProfileListings(from: url)
            }
            availableItems = items
            // Select all by default
            selectedItemUrls = Set(items.map { $0.url })
        } catch {
            analysisError = error.localizedDescription
        }

        isAnalyzing = false
    }

    // Weverse shop/artist pages are fetched server-side (functions/weverse_shop.js),
    // unlike Mercari profiles which are scraped client-side via URLExtractor —
    // Weverse's HTML embeds a Next.js dehydrated-state JSON blob that's much
    // simpler to parse from a trusted server than from an in-app WKWebView.
    private func fetchWeverseShopPreview(shopUrl: String) async throws -> [ListingPreview] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ListingPreview], Error>) in
            Functions.functions().httpsCallable("weverseShopPreview").call(["shopUrl": shopUrl]) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = result?.data as? [String: Any],
                      let itemsArray = data["items"] as? [[String: Any]] else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                let previews = itemsArray.compactMap { item -> ListingPreview? in
                    guard let url = item["productUrl"] as? String,
                          let title = item["title"] as? String else { return nil }
                    let price = item["price"] as? Double ?? 0.0
                    let thumbnailUrl = item["thumbnailUrl"] as? String ?? ""
                    return ListingPreview(title: title, price: price, thumbnailUrl: thumbnailUrl, url: url, description: nil)
                }
                continuation.resume(returning: previews)
            }
        }
    }

    private func startImport() {
        let itemsToImport = availableItems.filter { selectedItemUrls.contains($0.url) }
        guard isWeverseSource else {
            importManager.startImporting(previews: itemsToImport, source: .mercari)
            dismiss()
            return
        }
        Task { await startWeverseImport(items: itemsToImport) }
    }

    // ── Weverse shipping-estimate pipeline ──────────────────────────────────
    // Mirrors web/src/components/WeverseShopImportModal.jsx's
    // runShippingEstimatePipeline:
    // 1. Classify every chosen item into an itemType (classifyWeverseItemTypes,
    //    Gemini-backed). Items it can't confidently place go through the
    //    "Confirm Item Type" sheet.
    // 2. Group by itemType. Probe only the FIRST item of each type. On
    //    OUT_OF_STOCK, try the next item of that type. On MISSING_ADDRESS,
    //    pause and show WeverseAddressSheet, then retry once the user says
    //    they've added one (or give up on that type if they skip).
    // 3. Every item gets its itemType; only the one item per type whose probe
    //    actually succeeded gets a shippingCost — the server
    //    (weverseBulkImportProducts) resolves the final per-type value and
    //    applies it to every item of that type, probed or not.
    private func startWeverseImport(items: [ListingPreview]) async {
        isRunningPipeline = true
        let (itemTypes, shippingCosts) = await runShippingEstimatePipeline(items: items)
        isRunningPipeline = false

        importManager.startImporting(
            previews: items,
            source: .weverse,
            itemTypes: itemTypes,
            shippingCosts: shippingCosts
        )
        dismiss()
    }

    private func runShippingEstimatePipeline(items: [ListingPreview]) async -> (itemTypes: [String: String], shippingCosts: [String: Double]) {
        pipelineStatus = "Checking item types…"
        var itemTypeByUrl: [String: String] = [:]

        do {
            let (knownTypes, classifications) = try await classifyWeverseItemTypes(items: items)
            itemTypeByUrl = classifications
            let unresolved = items.filter { itemTypeByUrl[$0.url] == nil }
            if !unresolved.isEmpty {
                let manualChoices = await confirmItemTypes(unresolved: unresolved, knownTypes: knownTypes)
                for (url, type) in manualChoices { itemTypeByUrl[url] = type }
            }
        } catch {
            // Best-effort — items still import without shipping estimates if
            // classification fails outright (e.g. Gemini unreachable).
            print("[BulkImportSheet] classifyWeverseItemTypes failed: \(error)")
        }

        var itemsByType: [String: [ListingPreview]] = [:]
        var typeOrder: [String] = []
        for item in items {
            let type = itemTypeByUrl[item.url] ?? "Other"
            itemTypeByUrl[item.url] = type
            if itemsByType[type] == nil {
                itemsByType[type] = []
                typeOrder.append(type)
            }
            itemsByType[type]?.append(item)
        }

        var shippingCostByUrl: [String: Double] = [:]
        for (index, type) in typeOrder.enumerated() {
            pipelineStatus = "Estimating shipping for \"\(type)\" (\(index + 1)/\(typeOrder.count))…"
            guard let candidates = itemsByType[type] else { continue }
            if let (url, cost) = await probeShippingForType(candidates: candidates) {
                shippingCostByUrl[url] = cost
            }
        }

        return (itemTypeByUrl, shippingCostByUrl)
    }

    private func probeShippingForType(candidates: [ListingPreview]) async -> (String, Double)? {
        for candidate in candidates {
            guard let saleId = weverseSaleId(from: candidate.url) else { continue }
            do {
                let cost = try await weverseShippingProbe.probeShippingCost(saleUrl: candidate.url, saleId: saleId)
                return (candidate.url, cost)
            } catch let err as WeverseProbeError {
                switch err.code {
                case .outOfStock:
                    continue // try the next item of this same type
                case .missingAddress:
                    let choice = await promptForAddress()
                    if choice == "retry" {
                        if let cost = try? await weverseShippingProbe.probeShippingCost(saleUrl: candidate.url, saleId: saleId) {
                            return (candidate.url, cost)
                        }
                    }
                    return nil // resolved above, or the user chose to skip — either way, stop trying this type
                case .unknown:
                    return nil
                }
            } catch {
                return nil
            }
        }
        return nil
    }

    private func classifyWeverseItemTypes(items: [ListingPreview]) async throws -> (knownTypes: [String], classifications: [String: String]) {
        let payloadItems: [[String: Any]] = items.compactMap { item in
            guard let saleId = weverseSaleId(from: item.url) else { return nil }
            return ["saleId": saleId, "title": item.title, "thumbnailUrl": item.thumbnailUrl]
        }
        return try await withCheckedThrowingContinuation { continuation in
            Functions.functions().httpsCallable("classifyWeverseItemTypes").call(["items": payloadItems]) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = result?.data as? [String: Any] else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                let knownTypes = data["knownTypes"] as? [String] ?? []
                let classificationsBySaleId = data["classifications"] as? [String: String] ?? [:]
                var byUrl: [String: String] = [:]
                for item in items {
                    if let saleId = weverseSaleId(from: item.url), let type = classificationsBySaleId[saleId] {
                        byUrl[item.url] = type
                    }
                }
                continuation.resume(returning: (knownTypes, byUrl))
            }
        }
    }

    private func confirmItemTypes(unresolved: [ListingPreview], knownTypes: [String]) async -> [String: String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: String], Never>) in
            typeChoices = [:]
            newTypeDrafts = [:]
            pendingConfirmItems = unresolved
            pendingConfirmKnownTypes = knownTypes
            typeConfirmContinuation = continuation
            pendingConfirmVisible = true
        }
    }

    private func submitTypeConfirmation() {
        var resolved: [String: String] = [:]
        for item in pendingConfirmItems {
            let choice = typeChoices[item.url] ?? ""
            let finalType = choice == "__new__"
                ? (newTypeDrafts[item.url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : choice
            resolved[item.url] = finalType.isEmpty ? "Other" : finalType
        }
        pendingConfirmVisible = false
        pendingConfirmItems = []
        typeConfirmContinuation?.resume(returning: resolved)
        typeConfirmContinuation = nil
    }

    private func promptForAddress() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            addressContinuation = continuation
            missingAddressVisible = true
        }
    }

    private func resolveAddressPrompt(with choice: String) {
        missingAddressVisible = false
        addressContinuation?.resume(returning: choice)
        addressContinuation = nil
    }
}
