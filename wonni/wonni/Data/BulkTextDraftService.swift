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
import FirebaseAuth
import FirebaseFunctions
import SwiftData
import UIKit

/// The generated contract names (`textToListings` / `bulkDraftsFromText` share one
/// proposal and one pending-item type since 2026-10-15); the app's own names predate
/// that and are kept as aliases.
typealias Draft = DraftProposal
typealias Remaining = PendingItem

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
        // "3x Mario Kart" → 3 units of one listing (nil = 1, like everywhere else).
        item.quantity = proposal.quantity > 1 ? proposal.quantity : nil
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
        // Photo chooser: how sure the automatic pick was, and everything the chooser
        // needs to open instantly and search again.
        item.photoMatch = proposal.photoMatch?.rawValue
        item.photoSearchQuery = proposal.searchQuery
        item.includedState = proposal.included?.rawValue
        item.photoCandidatesData = proposal.photoCandidates.flatMap { try? JSONEncoder().encode($0) }
    }

    /// The badge a draft tile shows under its photos, or nil for none. Only a weak or
    /// empty automatic match gets one (user decision 2026-10-13): a draft whose photo
    /// came from an explicit same-item, same-state eBay listing is left alone.
    static func photoBadgeText(photoMatch: String?) -> String? {
        switch photoMatch {
        case PhotoMatch.none.rawValue: return "No photo found · Choose photos"
        case PhotoMatch.photoMatchWeak.rawValue: return "Photo may not match · Choose photos"
        default: return nil
        }
    }

    /// Readable form of an `included` state, for the chooser's header and chips.
    static func includedLabel(_ state: Included) -> String? {
        switch state {
        case .complete: return "Complete in box"
        case .partial: return "Missing parts"
        case .loose: return "Loose"
        case .sealed: return "Sealed"
        case .packaging: return "Box or case only"
        case .unknown: return nil
        }
    }

    /// Whether a draft is a bundle, read off its title — the proposal's `isBundle` is
    /// not stored on the Item. Decides whether an imported listing's single-item
    /// specifics (Game Name, UPC…) are dropped, as the server does for the proposal.
    static func looksLikeBundle(title: String) -> Bool {
        let words = Set(title.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["bundle", "lot", "set"])
    }

    /// The stored candidate list, decoded; empty when the draft has none.
    static func storedCandidates(_ data: Data?) -> [PhotoCandidate] {
        guard let data, let list = try? JSONDecoder().decode([PhotoCandidate].self, from: data) else { return [] }
        return list
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
        case .source: return count > 1 ? "\(count) photos from the link" : "Photo from the link"
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

    /// What the placeholder card is drawn as when no photo could be used.
    enum PlaceholderStyle: Equatable {
        /// Plain title card.
        case card
        /// A disc with the title on it — the listing is a bare disc.
        case disc
        /// A cartridge with the title on its label — the listing is a bare cartridge.
        case cartridge
    }

    /// A drawn disc or cartridge only when the listing IS just that ("disc only",
    /// "disc in a generic case", "cartridge only"). The server only uses another
    /// seller's photo when that listing is in the same state as ours
    /// (functions/comp_match.js); when none is, this card says what the buyer gets
    /// instead of showing a boxed copy. Anything else keeps the plain card.
    static func placeholderStyle(for proposal: Draft) -> PlaceholderStyle {
        guard proposal.included == .loose else { return .card }
        switch proposal.media {
        case .disc: return .disc
        case .cartridge: return .cartridge
        default: return .card
        }
    }

    /// A draft without a photo is invisible in the drafts list and skipped by publish,
    /// so a proposal with no usable photo gets a clearly-labelled card instead: a
    /// plain title card, or a drawn disc / cartridge carrying the title (see
    /// `placeholderStyle`). Drawn locally — not a photo and not AI-generated. The user
    /// replaces it like any other photo.
    static func placeholderImage(title: String, style: PlaceholderStyle = .card, size: CGFloat = 1024) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor(white: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            func attrs(_ scale: CGFloat, _ weight: UIFont.Weight, _ color: UIColor) -> [NSAttributedString.Key: Any] {
                [.font: UIFont.systemFont(ofSize: size * scale, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]
            }
            let note = "Placeholder — add a photo" as NSString
            // Where the title and the note go, after the shape (if any) is drawn.
            var titleRect = CGRect(x: size * 0.1, y: size * 0.3, width: size * 0.8, height: size * 0.4)
            var noteRect = CGRect(x: size * 0.1, y: size * 0.78, width: size * 0.8, height: size * 0.1)
            var titleScale: CGFloat = 0.07

            switch style {
            case .card:
                break
            case .disc:
                let center = CGPoint(x: size / 2, y: size / 2)
                func ring(_ radius: CGFloat) -> UIBezierPath {
                    UIBezierPath(arcCenter: center, radius: size * radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                }
                UIColor(white: 0.82, alpha: 1).setFill()
                ring(0.44).fill()
                UIColor(white: 0.97, alpha: 1).setFill()
                ring(0.42).fill()
                UIColor(white: 0.82, alpha: 1).setFill()
                ring(0.11).fill()
                UIColor(white: 0.93, alpha: 1).setFill()
                ring(0.05).fill()
                // Title on the upper half of the disc, note on the lower half.
                titleRect = CGRect(x: size * 0.24, y: size * 0.16, width: size * 0.52, height: size * 0.22)
                noteRect = CGRect(x: size * 0.26, y: size * 0.66, width: size * 0.48, height: size * 0.1)
                titleScale = 0.05
            case .cartridge:
                let body = CGRect(x: size * 0.2, y: size * 0.1, width: size * 0.6, height: size * 0.8)
                UIColor(white: 0.74, alpha: 1).setFill()
                UIBezierPath(roundedRect: body, cornerRadius: size * 0.04).fill()
                // Grip lines across the top, like the ridges on a cartridge shell.
                UIColor(white: 0.66, alpha: 1).setFill()
                for row in 0..<3 {
                    let lineY = size * (0.14 + CGFloat(row) * 0.025)
                    UIBezierPath(roundedRect: CGRect(x: size * 0.27, y: lineY, width: size * 0.46, height: size * 0.01), cornerRadius: size * 0.005).fill()
                }
                let label = CGRect(x: size * 0.26, y: size * 0.26, width: size * 0.48, height: size * 0.44)
                UIColor(white: 0.97, alpha: 1).setFill()
                UIBezierPath(roundedRect: label, cornerRadius: size * 0.02).fill()
                titleRect = label.insetBy(dx: size * 0.03, dy: size * 0.06)
                noteRect = CGRect(x: size * 0.22, y: size * 0.76, width: size * 0.56, height: size * 0.1)
                titleScale = 0.05
            }

            (title as NSString).draw(in: titleRect, withAttributes: attrs(titleScale, .semibold, .darkGray))
            note.draw(in: noteRect, withAttributes: attrs(0.035, .regular, style == .cartridge ? .white : .gray))
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

    // MARK: Photo chooser

    /// A fresh eBay search for the chooser (the user edited the query, or the draft
    /// has no stored candidates). Same shape and order as the list a proposal carries.
    func photoCandidates(query: String, included: String?) async throws -> [PhotoCandidate] {
        let callable = functions.httpsCallable("draftPhotoCandidates")
        callable.timeoutInterval = 30
        var parameters: [String: Any] = ["query": String(query.prefix(200))]
        if let included { parameters["included"] = included }
        let result = try await call(callable, parameters)
        return try decode(DraftPhotoCandidatesResponse.self, from: result).candidates
    }

    /// The chosen listing's full photo set and sell-similar details — one `getItem`,
    /// made only on Import (user decision 2026-10-14: the search result's cover photo
    /// is free, the per-listing detail is the only extra call).
    func candidateDetail(itemId: String, isBundle: Bool) async throws -> DraftPhotoCandidateDetailResponse {
        let callable = functions.httpsCallable("draftPhotoCandidateDetail")
        callable.timeoutInterval = 30
        let result = try await call(callable, ["itemId": itemId, "isBundle": isBundle])
        return try decode(DraftPhotoCandidateDetailResponse.self, from: result)
    }

    struct ImportOptions {
        /// Copy the listing's eBay category, condition and item specifics onto the draft.
        var includeDetails = true
        /// Delete the draft's current (placeholder or auto-picked) photos first; off
        /// appends the chosen photos after them.
        var replacePhotos = true
    }

    enum ImportError: LocalizedError {
        case noPhotos
        var errorDescription: String? { "That listing has no photos to import." }
    }

    /// Puts a chosen eBay listing's photos (and, optionally, details) on the draft and
    /// sends it back through the normal upload + products sync. Returns how many photos
    /// landed. Replaced photos are removed from Storage BEFORE the new upload starts:
    /// uploads are named by index, so a late delete would otherwise remove a new photo.
    @discardableResult
    func importCandidate(
        _ candidate: PhotoCandidate,
        onto item: Item,
        options: ImportOptions,
        modelContext: ModelContext,
        uploadManager: UploadManager
    ) async throws -> Int {
        let detail = try await candidateDetail(itemId: candidate.itemId, isBundle: BulkTextDraftMapper.looksLikeBundle(title: item.userEditedTitle ?? item.aiSuggestedTitle ?? ""))
        let urls = detail.imageUrls.isEmpty ? [candidate.imageUrl] : detail.imageUrls
        let photos = await downloadPhotos(urls)
        guard !photos.isEmpty else { throw ImportError.noPhotos }
        guard !Item.deletedIDs.contains(item.id) else { return 0 }

        if options.replacePhotos {
            let userId = Auth.auth().currentUser?.uid
            for assetId in item.sourceAssetIdentifiers {
                let removed = item.removePhoto(assetId: assetId)
                if let path = removed.firebasePhotoPath, let userId {
                    do { try await StorageService.shared.deletePhoto(path: path, userId: userId) } catch {
                        print("[BulkTextDraftService] couldn't delete replaced photo \(path): \(error)")
                    }
                }
            }
            guard !Item.deletedIDs.contains(item.id) else { return 0 }
        }
        for data in photos {
            let assetId = UUID().uuidString
            Item.prewarmThumbnail(itemID: item.id, assetId: assetId, data: data)
            item.sourceAssetIdentifiers.append(assetId)
            item.setLocalPhoto(data, for: assetId)
        }
        if options.includeDetails {
            if let category = detail.ebayCategoryId { item.ebayCategoryId = category }
            if let specifics = detail.itemSpecifics, !specifics.isEmpty { item.itemSpecifics = specifics }
        }
        // The user chose this by eye: the badge goes away, and the AI pass stays skipped
        // (the photos were never what described this draft).
        item.photoMatch = PhotoMatch.strong.rawValue
        item.processedPhotoIDs = item.sourceAssetIdentifiers
        try? modelContext.save()
        uploadManager.startBackgroundUpload(draft: item, modelContext: modelContext)
        uploadManager.syncProductData(item)
        return photos.count
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
                let card = BulkTextDraftMapper.placeholderImage(
                    title: item.aiSuggestedTitle ?? proposal.title,
                    style: BulkTextDraftMapper.placeholderStyle(for: proposal)
                )
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
