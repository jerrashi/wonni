//
//  BulkTextDraftService.swift
//  wonni
//
//  "Paste a list → N ready-to-list drafts." The parsing, comp pricing and
//  stock/generated photo lookup all happen in the `bulkDraftsFromText` Cloud
//  Function (functions/bulk_text_drafts.js); this file turns its proposals
//  into local `Item` drafts that then ride the exact same photo-upload /
//  products-sync / Review & Publish pipeline as a camera-made draft.
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
        item.aiSuggestedPrice = proposal.suggestedPrice
        item.userEditedPrice = nil
        item.condition = GeminiService.canonicalToItemCondition(proposal.condition.rawValue)
        item.aiSuggestedCategory = proposal.category
        item.aiSuggestedBrand = proposal.brand
        item.tags = proposal.tags
        item.aiModel = aiModel
        item.aiPromptVersion = aiPromptVersion
        // The source line is the user's own words — keep it where they can see it.
        item.personalNote = "From list: \(proposal.sourceText)"
    }

    /// Short badge text for the review list.
    static func priceLabel(_ proposal: Draft) -> String {
        switch proposal.priceSource {
        case .comps: return "eBay comps"
        case .ai: return "AI estimate"
        case .none: return "No price found"
        }
    }

    static func photoLabel(_ proposal: Draft) -> String {
        switch proposal.imageSource {
        case .ebay: return proposal.imageUrls.count > 1 ? "\(proposal.imageUrls.count) stock photos" : "Stock photo"
        case .generated: return "AI-generated photo"
        case .none: return "Placeholder — replace before posting"
        }
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

    /// One round trip: the Cloud Function parses, prices and finds photos for every
    /// listing in `text`. Nothing is persisted until `createDrafts`.
    func propose(text: String, photoSource: PhotoSource) async throws -> BulkDraftsFromTextResponse {
        let parameters: [String: Any] = [
            "text": text,
            "photoSource": photoSource.rawValue
        ]
        // Server-side work is one Gemini call plus a comps/photo lookup per listing;
        // the default 70 s callable timeout is too short for a 20-item list.
        let callable = functions.httpsCallable("bulkDraftsFromText")
        callable.timeoutInterval = 300
        let result: HTTPSCallableResult
        do {
            result = try await callable.call(parameters)
        } catch let error as NSError {
            let message = error.userInfo["NSLocalizedDescription"] as? String ?? error.localizedDescription
            throw NSError(domain: "BulkTextDraftService", code: error.code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result.data),
              let response = try? JSONDecoder().decode(BulkDraftsFromTextResponse.self, from: data) else {
            throw NSError(domain: "BulkTextDraftService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not read the AI response."])
        }
        return response
    }

    /// Turns accepted proposals into real drafts: inserts the `Item`, downloads each
    /// photo URL into the draft's local photo store (a placeholder card when there is
    /// none), then hands it to UploadManager exactly like `commitActiveDraft` does —
    /// background Storage upload + products/{id} sync — and marks it processed so it
    /// shows up straight in Review & Publish instead of waiting for another AI pass.
    func createDrafts(
        from proposals: [Draft],
        response: BulkDraftsFromTextResponse,
        modelContext: ModelContext,
        uploadManager: UploadManager,
        progress: @escaping (CreationProgress) -> Void
    ) async -> [Item] {
        var created: [Item] = []
        for (index, proposal) in proposals.enumerated() {
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
        progress(CreationProgress(completed: proposals.count, total: proposals.count, currentTitle: ""))
        return created
    }

    /// Fetches each photo URL and normalises it to a ≤1200 px JPEG, matching what the
    /// camera path stores. A failed download just drops that one photo.
    private func downloadPhotos(_ urls: [String]) async -> [Data] {
        var out: [Data] = []
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            do {
                let (bytes, httpResponse) = try await URLSession.shared.data(from: url)
                if let http = httpResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                guard let image = UIImage(data: bytes), image.size.width > 0, image.size.height > 0 else { continue }
                let resized = ImageCompressor.resize(image: image, maxDimension: 1200)
                if let jpeg = resized.jpegData(compressionQuality: 0.85) { out.append(jpeg) }
            } catch {
                print("[BulkTextDraftService] photo download failed for \(raw): \(error)")
            }
        }
        return out
    }
}
