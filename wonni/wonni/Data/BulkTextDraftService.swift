//
//  BulkTextDraftService.swift
//  wonni
//
//  "Paste a list → N ready-to-list drafts." The parsing, comp pricing,
//  "sell similar" detail copy and stock-photo lookup all happen in the
//  `bulkDraftsFromText` Cloud Function (functions/bulk_text_drafts.js); this
//  file turns its proposals into local `Item` drafts that then ride the exact
//  same photo-upload / products-sync / Review & Publish pipeline as a
//  camera-made draft. AI-generated photos are a separate, consent-gated call
//  (`generateListingPhoto`) the sheet only makes after the user says yes.
//

import Foundation
import FirebaseFunctions
import SwiftData
import UIKit

/// Pure mapping from a `bulkDraftsFromText` proposal onto an `Item`, factored out so
/// it is unit-testable without Firebase or the network (BulkTextDraftMappingTests).
enum BulkTextDraftMapper {

    /// Writes every field the proposal carries onto a fresh draft. Nothing here touches
    /// photos — `BulkTextDraftService.createDrafts` handles those after this.
    static func apply(_ proposal: Draft, to item: Item, aiModel: String, aiPromptVersion: String) {
        // Same rule as `UploadManager.processDrafts`: the ≤80-char shortTitle is the
        // listing title the user sees; the long form is only a fallback.
        item.aiSuggestedTitle = proposal.shortTitle.isEmpty ? proposal.title : proposal.shortTitle
        item.userEditedTitle = nil
        item.aiSuggestedDescription = proposal.description
        item.userEditedDescription = nil
        // A price the user wrote in their text is THEIR price, not a suggestion: it goes
        // in the user field, and the comps/AI figure stays alongside as the suggestion.
        if proposal.priceSource == .user {
            item.userEditedPrice = proposal.suggestedPrice
            item.aiSuggestedPrice = proposal.marketPrice
        } else {
            item.aiSuggestedPrice = proposal.suggestedPrice
            item.userEditedPrice = nil
        }
        item.condition = GeminiService.canonicalToItemCondition(proposal.condition.rawValue)
        item.aiSuggestedCategory = proposal.category
        item.aiSuggestedBrand = proposal.brand
        item.tags = proposal.tags
        item.aiModel = aiModel
        item.aiPromptVersion = aiPromptVersion
        // "Sell similar": the comp's real eBay category + item specifics.
        item.ebayCategoryId = proposal.ebayCategoryId
        item.itemSpecifics = proposal.itemSpecifics
        // Shipping estimates — the same fields the photo AI pass fills, so a list-made
        // draft is complete on arrival and never needs that pass.
        item.weightLbs = proposal.weightOz.map { $0 / 16.0 }
        item.lengthIn = proposal.lengthIn
        item.widthIn = proposal.widthIn
        item.heightIn = proposal.heightIn
        // The source snippet is the user's own words — keep it where they can see it.
        item.personalNote = "From list: \(proposal.sourceText)"
    }

    /// Short badge text for the review list.
    static func priceLabel(_ proposal: Draft) -> String {
        switch proposal.priceSource {
        case .user:
            guard let market = proposal.marketPrice else { return "Your price" }
            let amount = market.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
            return proposal.marketPriceSource == .comps ? "Your price · eBay comps \(amount)" : "Your price · AI estimate \(amount)"
        case .comps: return "eBay comps"
        case .ai: return "AI estimate"
        case .none: return "No price found"
        }
    }

    static func photoLabel(_ proposal: Draft) -> String {
        let count = proposal.imageUrls.count
        switch proposal.imageSource {
        case .ebay: return count > 1 ? "\(count) eBay seller photos" : "eBay seller photo"
        case .google: return count > 1 ? "\(count) web photos" : "Web photo"
        case .generated: return "AI-generated photo"
        case .none: return "No photo found — placeholder, replace before posting"
        }
    }

    /// Proposals the user should be asked about: nothing in the eBay → Google chain
    /// produced a photo.
    static func needsPhoto(_ proposal: Draft) -> Bool {
        proposal.imageUrls.isEmpty
    }

    /// How many listings to price and photograph per round trip. The server parses the
    /// whole text once; comps, details and photos are fetched this many at a time.
    static let batchSize = 40

    /// One listing the run did not turn into a draft: the user's own words for it, and
    /// the price they wrote for it (which may have come from a group line like
    /// "$10 each" and so not be in the snippet itself).
    struct LeftoverLine: Equatable {
        let sourceText: String
        let userPrice: Double?

        init(sourceText: String, userPrice: Double?) {
            self.sourceText = sourceText
            self.userPrice = userPrice
        }
        /// Parsed but never priced / photographed.
        init(_ pending: Remaining) {
            self.init(sourceText: pending.sourceText, userPrice: pending.userPrice)
        }
        /// Fully prepared but never saved (the run was stopped first).
        init(_ proposal: Draft) {
            self.init(sourceText: proposal.sourceText, userPrice: proposal.priceSource == .user ? proposal.suggestedPrice : nil)
        }
    }

    /// The part of a run that did NOT become drafts, as text the user can run again:
    /// the shared context as a header line, one line per unconverted listing, then
    /// whatever the parser never reached. Empty when everything was converted.
    static func leftoverText(context: String, lines: [LeftoverLine], unparsedText: String) -> String {
        var out: [String] = []
        for item in lines {
            var line = item.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let price = item.userPrice {
                let amount = price == price.rounded() ? String(Int(price)) : String(format: "%.2f", price)
                if !line.contains(amount) { line += " $\(amount)" }
            }
            out.append(line)
        }
        let header = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty && !header.isEmpty {
            out.insert(header.hasSuffix(":") ? header : header + ":", at: 0)
        }
        let tail = unparsedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.joined(separator: "\n")
    }

    /// A draft without a photo is invisible in the drafts list and skipped by publish,
    /// so a proposal with no usable photo gets a clearly-labelled title card instead.
    /// The user replaces it like any other photo.
    static func placeholderImage(title: String, size: CGFloat = 1024) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor(white: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.07, weight: .semibold),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: paragraph
            ]
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.035, weight: .regular),
                .foregroundColor: UIColor.gray,
                .paragraphStyle: paragraph
            ]
            let inset = size * 0.1
            let titleRect = CGRect(x: inset, y: size * 0.3, width: size - 2 * inset, height: size * 0.4)
            (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)
            let noteRect = CGRect(x: inset, y: size * 0.78, width: size - 2 * inset, height: size * 0.1)
            ("Placeholder — add a photo" as NSString).draw(in: noteRect, withAttributes: noteAttrs)
        }
    }
}

@MainActor
final class BulkTextDraftService {
    static let shared = BulkTextDraftService()

    private lazy var functions = Functions.functions()
    private init() {}

    struct CreationProgress {
        var completed: Int
        var total: Int
        var currentTitle: String
    }

    /// One round trip: the Cloud Function parses, prices, copies sell-similar details
    /// and finds photos for every listing in `text`. Nothing is persisted until
    /// `createDrafts`.
    ///
    /// The first call sends the text: the server parses ALL of it, fully prepares the
    /// first batch, and returns the rest as `remaining`. Follow-up calls send those
    /// back with `propose(pending:)`, so a long list is never cut off at the batch size.
    /// `context` carries the shared context when continuing after `unparsedText`.
    func propose(text: String, context: String = "") async throws -> BulkDraftsFromTextResponse {
        var parameters: [String: Any] = ["text": text, "maxItems": BulkTextDraftMapper.batchSize]
        if !context.isEmpty { parameters["context"] = String(context.prefix(500)) }
        return try await proposeCall(parameters)
    }

    /// Prices and photographs listings a previous response returned in `remaining`.
    func propose(pending: [Remaining], context: String) async throws -> BulkDraftsFromTextResponse {
        let data = try JSONEncoder().encode(pending)
        let items = try JSONSerialization.jsonObject(with: data)
        var parameters: [String: Any] = ["pendingItems": items, "maxItems": BulkTextDraftMapper.batchSize]
        if !context.isEmpty { parameters["context"] = String(context.prefix(500)) }
        return try await proposeCall(parameters)
    }

    private func proposeCall(_ parameters: [String: Any]) async throws -> BulkDraftsFromTextResponse {
        // Server-side work is one Gemini call over the whole text (about half a second
        // per listing) plus comps / item-detail / photo lookups for the batch; the
        // default 70 s callable timeout is far too short. Matches the function's 540 s.
        let callable = functions.httpsCallable("bulkDraftsFromText")
        callable.timeoutInterval = 540
        let result = try await call(callable, parameters)
        return try decode(BulkDraftsFromTextResponse.self, from: result)
    }

    /// Consent-gated: only called after the user has agreed to AI-generated photos for
    /// listings the eBay → Google chain couldn't cover. Returns the public URL, or nil
    /// when the model produced no image.
    func generatePhoto(for proposal: Draft) async throws -> String? {
        let callable = functions.httpsCallable("generateListingPhoto")
        callable.timeoutInterval = 90
        let result = try await call(callable, [
            "title": proposal.shortTitle.isEmpty ? proposal.title : proposal.shortTitle,
            "bundleItems": proposal.bundleItems,
            "condition": proposal.condition.rawValue
        ])
        return try decode(GenerateListingPhotoResponse.self, from: result).url
    }

    private func call(_ callable: HTTPSCallable, _ parameters: [String: Any]) async throws -> Any {
        do {
            return try await callable.call(parameters).data
        } catch let error as NSError {
            let message = error.userInfo["NSLocalizedDescription"] as? String ?? error.localizedDescription
            throw NSError(domain: "BulkTextDraftService", code: error.code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: Any) throws -> T {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw NSError(domain: "BulkTextDraftService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not read the server response."])
        }
        return decoded
    }

    /// Turns accepted proposals into real drafts: inserts the `Item`, downloads each
    /// photo URL into the draft's local photo store (a placeholder card when there is
    /// none), then hands it to UploadManager exactly like `commitActiveDraft` does —
    /// background Storage upload + products/{id} sync — and marks it processed so it
    /// shows up straight in Review & Publish instead of waiting for another AI pass.
    /// `shouldStop` is checked between drafts so a cancelled run stops cleanly with
    /// every draft made so far intact.
    func createDrafts(
        from proposals: [Draft],
        response: BulkDraftsFromTextResponse,
        modelContext: ModelContext,
        uploadManager: UploadManager,
        shouldStop: () -> Bool = { false },
        progress: @escaping (CreationProgress) -> Void
    ) async -> [Item] {
        var created: [Item] = []
        for (index, proposal) in proposals.enumerated() {
            if shouldStop() { break }
            progress(CreationProgress(completed: index, total: proposals.count, currentTitle: proposal.shortTitle))

            let item = Item(firestoreListingId: UUID().uuidString)
            BulkTextDraftMapper.apply(proposal, to: item, aiModel: response.aiModel, aiPromptVersion: response.aiPromptVersion)
            modelContext.insert(item)

            var photos = await downloadPhotos(proposal.imageUrls)
            if photos.isEmpty {
                let card = BulkTextDraftMapper.placeholderImage(title: item.aiSuggestedTitle ?? proposal.title)
                if let data = card.jpegData(compressionQuality: 0.85) { photos = [data] }
            }
            for data in photos {
                let assetId = UUID().uuidString
                Item.prewarmThumbnail(itemID: item.id, assetId: assetId, data: data)
                item.sourceAssetIdentifiers.append(assetId)
                item.setLocalPhoto(data, for: assetId)
            }

            // Fields are already filled — skip the per-draft Gemini pass and surface it
            // in Review & Publish immediately (same bookkeeping processDrafts does).
            item.processedAt = Date()
            item.processedPhotoIDs = item.sourceAssetIdentifiers
            // ...and keep skipping it even after the user swaps the stock/placeholder
            // photo for their own — the text, not the photo, is what described the item.
            item.skipAIProcessing = true
            try? modelContext.save()

            if !uploadManager.sessionDraftIDs.contains(item.id) {
                uploadManager.sessionDraftIDs.append(item.id)
            }
            if !uploadManager.processedItemIDs.contains(item.id) {
                uploadManager.processedItemIDs.append(item.id)
            }
            uploadManager.startBackgroundUpload(draft: item, modelContext: modelContext)
            uploadManager.syncProductData(item)
            created.append(item)
        }
        progress(CreationProgress(completed: created.count, total: proposals.count, currentTitle: ""))
        return created
    }

    /// Fetches each photo URL and normalises it to a ≤1200 px JPEG, matching what the
    /// camera path stores. A draft's photos (at most four) download together; order is
    /// kept, and a failed download just drops that one photo.
    private func downloadPhotos(_ urls: [String]) async -> [Data] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, raw) in urls.enumerated() {
                group.addTask { (index, await Self.downloadPhoto(raw)) }
            }
            var byIndex: [Int: Data] = [:]
            for await (index, data) in group {
                if let data { byIndex[index] = data }
            }
            return urls.indices.compactMap { byIndex[$0] }
        }
    }

    private nonisolated static func downloadPhoto(_ raw: String) async -> Data? {
        guard let url = URL(string: raw) else { return nil }
        do {
            let (bytes, httpResponse) = try await URLSession.shared.data(from: url)
            if let http = httpResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let image = UIImage(data: bytes), image.size.width > 0, image.size.height > 0 else { return nil }
            let resized = ImageCompressor.resize(image: image, maxDimension: 1200)
            return resized.jpegData(compressionQuality: 0.85)
        } catch {
            print("[BulkTextDraftService] photo download failed for \(raw): \(error)")
            return nil
        }
    }
}
