//
//  Models.swift
//  wonni
//

import Foundation
import ImageIO
import SwiftData
import UIKit

@Model
class Item {
    var id: UUID
    var createdAt: Date
    @Attribute(.externalStorage) var photosData: [Data]
    var blurb: String
    var aiSuggestedTitle: String?
    var aiSuggestedPrice: Double?
    var aiSuggestedDescription: String?
    var userEditedTitle: String?
    var userEditedPrice: Double?
    var userEditedDescription: String?
    var originalUserTitleBeforeAI: String?
    var originalUserDescriptionBeforeAI: String?
    var buyerPaysShipping: Bool
    var handlingFee: Double
    var estimatedShippingDays: Int
    var weightLbs: Double?
    var lengthIn: Double?
    var widthIn: Double?
    var heightIn: Double?
    var isDraft: Bool
    var sourceAssetIdentifiers: [String]
    var tags: [String]
    var personalNote: String?
    /// Maps a photo's local asset identifier to its uploaded Storage path. Keyed by
    /// assetId (not position) so it stays correct across `movePhoto`/`removePhoto`/
    /// `insertPhoto` — a plain positional array would silently desync from
    /// `sourceAssetIdentifiers` the moment a photo is reordered.
    var firebasePhotoPathsByAsset: [String: String]?
    var firestoreListingId: String?
    var processedAt: Date?
    /// Snapshot of `sourceAssetIdentifiers` taken when AI processing completed. The
    /// process skip compares this as a SET against the current photos: reorders never
    /// re-bill the AI, but adding/removing a photo makes the draft eligible for
    /// re-processing (the photos are the AI's actual input). nil (pre-migration drafts)
    /// is treated as unchanged so existing processed drafts aren't re-billed.
    var processedPhotoIDs: [String]?
    /// Set the moment `UploadManager.publishDrafts` successfully writes this item's
    /// Firestore listing doc. Distinguishes "still an unpublished draft" from "kept alive
    /// locally only so a queued cross-post job can read its photos" (the item survives in
    /// SwiftData until the web-autofill queue drains). Delete flows meant for discarding an
    /// unpublished draft (`deleteDraftLocallyAndCloud`) must refuse to touch Firestore/Storage
    /// once this is set — the app's copy is already live, and further deletion has to go
    /// through the real delist flow (`ProfileView.deleteListing`), which also tears down
    /// cross-posted platforms. See github issue: bulk-deleting already-published drafts
    /// deleted the live listing while leaving it posted on eBay/Mercari.
    var publishedAt: Date?
    var visionTitle: String?
    /// True once the user tapped the vision-title suggestion chip to fill the title
    /// field. Vision output is never prefilled as editable text (it polluted the
    /// "user title" hint sent to Gemini); accepting the chip is a deliberate choice,
    /// so accepted text counts as a real user title. Rides to the published listing
    /// doc for model-quality analysis ("% of vision suggestions accepted").
    var visionTitleAccepted: Bool = false
    /// Which Gemini model / prompt revision produced this draft's AI output, as
    /// stamped by the identifyItem Cloud Function at process time. Captured on the
    /// draft (not looked up at publish) so a draft published days later still
    /// records the model that actually wrote its text.
    var aiModel: String?
    var aiPromptVersion: String?
    /// Number of "Undo AI edits" actions taken on this draft (title or description;
    /// a toast-Restore retracts one). Strong negative-quality signal per model.
    var aiUndoCount: Int = 0
    var isLocalPhotoOnly: Bool
    var aiSuggestedCategory: String?
    var aiSuggestedBrand: String?
    var condition: String? // Maps to ItemCondition rawValue

    init(id: UUID = UUID(), createdAt: Date = Date(), photosData: [Data] = [], blurb: String = "", buyerPaysShipping: Bool = true, handlingFee: Double = 0.0, estimatedShippingDays: Int = 3, weightLbs: Double? = nil, lengthIn: Double? = nil, widthIn: Double? = nil, heightIn: Double? = nil, isDraft: Bool = true, sourceAssetIdentifiers: [String] = [], tags: [String] = [], personalNote: String? = nil, firebasePhotoPathsByAsset: [String: String]? = nil, firestoreListingId: String? = nil, processedAt: Date? = nil, visionTitle: String? = nil, isLocalPhotoOnly: Bool = false, originalUserTitleBeforeAI: String? = nil, originalUserDescriptionBeforeAI: String? = nil, aiSuggestedCategory: String? = nil, aiSuggestedBrand: String? = nil, condition: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.photosData = photosData
        self.blurb = blurb
        self.buyerPaysShipping = buyerPaysShipping
        self.handlingFee = handlingFee
        self.estimatedShippingDays = estimatedShippingDays
        self.weightLbs = weightLbs
        self.lengthIn = lengthIn
        self.widthIn = widthIn
        self.heightIn = heightIn
        self.isDraft = isDraft
        self.sourceAssetIdentifiers = sourceAssetIdentifiers
        self.tags = tags
        self.personalNote = personalNote
        self.firebasePhotoPathsByAsset = firebasePhotoPathsByAsset
        self.firestoreListingId = firestoreListingId
        self.processedAt = processedAt
        self.visionTitle = visionTitle
        self.isLocalPhotoOnly = isLocalPhotoOnly
        self.originalUserTitleBeforeAI = originalUserTitleBeforeAI
        self.originalUserDescriptionBeforeAI = originalUserDescriptionBeforeAI
        self.aiSuggestedCategory = aiSuggestedCategory
        self.aiSuggestedBrand = aiSuggestedBrand
        self.condition = condition
    }

    /// Marked by `UploadManager.deleteDraftLocallyAndCloud` the instant a delete is
    /// requested — a `modelContext != nil` check turned out NOT to reliably reflect
    /// deletion in practice, so this is the one signal `image(for:)` actually trusts.
    /// `nonisolated(unsafe)` because every reader/writer is on the main thread (SwiftUI
    /// view bodies, `@MainActor` UploadManager) by construction, just not provably so to
    /// the compiler across this static/instance-method boundary.
    nonisolated(unsafe) static var deletedIDs: Set<UUID> = []

    /// Decoded-thumbnail cache for `thumbnail(for:)`. Keyed by "\(item.id)-\(assetId)":
    /// the bytes behind an assetId never change after insertion (reorder/remove remap
    /// `sourceAssetIdentifiers` and `photosData` together, keeping the assetId→data
    /// mapping stable), so entries only need explicit eviction in `removePhoto`.
    /// `nonisolated(unsafe)` for the same reason as `deletedIDs`: all access is
    /// main-thread by construction (view bodies), and NSCache is thread-safe anyway.
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSString, UIImage>()

    /// Max pixel dimension for cached thumbnails: 160pt (largest on-screen use,
    /// DraftPhotoEditModal) at 3x. One tier keeps every view sharing one cache entry.
    private static let thumbnailMaxPixel = 480

    /// Cached, downsampled thumbnail for list/grid display. Views must use this instead
    /// of `image(for:)`: that faults the entire externally-stored `photosData` array and
    /// decodes the photo at full camera resolution on every call, which — invoked from a
    /// row `body` that re-evaluates per keystroke — was the source of major typing lag
    /// in the listing flow. Upload/publish paths still use `image(for:)` for full res.
    func thumbnail(for assetId: String) -> UIImage? {
        guard !Item.deletedIDs.contains(id) else { return nil }
        let key = "\(id)-\(assetId)" as NSString
        if let cached = Item.thumbnailCache.object(forKey: key) { return cached }
        guard let idx = sourceAssetIdentifiers.firstIndex(of: assetId),
              idx < photosData.count else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Item.thumbnailMaxPixel
        ]
        guard let source = CGImageSourceCreateWithData(photosData[idx] as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumb = UIImage(cgImage: cgImage)
        Item.thumbnailCache.setObject(thumb, forKey: key)
        return thumb
    }

    func image(for assetId: String) -> UIImage? {
        // A SwiftUI row can still be mid-render against a just-deleted Item — e.g. List's
        // own swipe-to-delete removal animation, or a sibling carousel/stack view driven
        // by an independent @Query, re-evaluating a row's body a beat after the underlying
        // SwiftData delete commits. Reading `photosData` (externally stored) on a detached
        // object crashes with "backing data was detached from a context without resolving
        // attribute faults." Checking `Item.deletedIDs` here is the one choke point that
        // protects every caller regardless of which view rendered it or render timing.
        guard !Item.deletedIDs.contains(id) else { return nil }
        if let idx = sourceAssetIdentifiers.firstIndex(of: assetId) {
            if idx < photosData.count {
                return UIImage(data: photosData[idx])
            }
        }
        return nil
    }

    /// `sourceAssetIdentifiers` reflects the user's current photo order (drag-to-reorder
    /// mutates it directly); this resolves that order into Storage paths via the
    /// assetId-keyed map, so publish/cover-photo logic always matches what's on screen.
    var orderedFirebasePhotoPaths: [String] {
        sourceAssetIdentifiers.compactMap { firebasePhotoPathsByAsset?[$0] }
    }

    func movePhoto(from: Int, to: Int) {
        var ids = sourceAssetIdentifiers
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        sourceAssetIdentifiers = ids

        if isLocalPhotoOnly && from < photosData.count && to < photosData.count {
            var data = photosData
            data.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            photosData = data
        }
        // No firebasePhotoPathsByAsset change needed — it's keyed by assetId, not position.
    }

    /// Removes a photo from this draft. Returns the local photo bytes (if this draft
    /// keeps them locally) and the photo's uploaded Storage path (if it had one), so
    /// callers can either re-insert both elsewhere (cross-draft move) or delete the
    /// Storage path for good (permanent removal).
    @discardableResult
    func removePhoto(assetId: String) -> (data: Data?, firebasePhotoPath: String?) {
        guard let idx = sourceAssetIdentifiers.firstIndex(of: assetId) else { return (nil, nil) }
        sourceAssetIdentifiers.remove(at: idx)
        Item.thumbnailCache.removeObject(forKey: "\(id)-\(assetId)" as NSString)
        let path = firebasePhotoPathsByAsset?.removeValue(forKey: assetId)

        if isLocalPhotoOnly && idx < photosData.count {
            return (photosData.remove(at: idx), path)
        }
        return (nil, path)
    }

    /// Inserts a photo into this draft. Pass `firebasePhotoPath` when relocating an
    /// already-uploaded photo from another draft, so the map continues to resolve it —
    /// note the underlying Storage object still physically lives under the source
    /// draft's listing ID until/unless it's explicitly re-uploaded.
    func insertPhoto(assetId: String, data: Data?, at index: Int, firebasePhotoPath: String? = nil) {
        if index >= sourceAssetIdentifiers.count {
            sourceAssetIdentifiers.append(assetId)
            if let data = data {
                photosData.append(data)
            }
        } else {
            sourceAssetIdentifiers.insert(assetId, at: index)
            if let data = data {
                photosData.insert(data, at: index)
            }
        }
        if let firebasePhotoPath {
            if firebasePhotoPathsByAsset == nil { firebasePhotoPathsByAsset = [:] }
            firebasePhotoPathsByAsset?[assetId] = firebasePhotoPath
        }
    }
}

enum Platform: String, Codable {
    case ebay = "eBay"
    case etsy = "Etsy"
    case mercari = "Mercari"
    case facebook = "Facebook Marketplace"
}

@Model
class Listing {
    var id: UUID
    var item: Item?
    var platform: Platform
    var platformListingId: String?
    var status: String
    var listedPrice: Double
    var listedDate: Date?
    var soldDate: Date?
    var views: Int
    var likes: Int
    
    init(id: UUID = UUID(), item: Item? = nil, platform: Platform, platformListingId: String? = nil, status: String = "drafted", listedPrice: Double = 0.0, listedDate: Date? = nil, soldDate: Date? = nil, views: Int = 0, likes: Int = 0) {
        self.id = id
        self.item = item
        self.platform = platform
        self.platformListingId = platformListingId
        self.status = status
        self.listedPrice = listedPrice
        self.listedDate = listedDate
        self.soldDate = soldDate
        self.views = views
        self.likes = likes
    }
}

@Model
class Expense {
    var id: UUID
    var date: Date
    var title: String
    var amount: Double
    var category: String
    @Attribute(.externalStorage) var receiptPhotoData: Data?
    
    init(id: UUID = UUID(), date: Date = Date(), title: String, amount: Double, category: String, receiptPhotoData: Data? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.amount = amount
        self.category = category
        self.receiptPhotoData = receiptPhotoData
    }
}

@Model
class Mileage {
    var id: UUID
    var date: Date
    var title: String
    var miles: Double

    init(id: UUID = UUID(), date: Date = Date(), title: String, miles: Double) {
        self.id = id
        self.date = date
        self.title = title
        self.miles = miles
    }
}

/// Pure policy for whether a draft's AI processing can be skipped. Factored out of
/// `UploadManager.processDrafts` so the set-comparison semantics are unit-testable
/// (see DraftAIProcessingPolicyTests).
enum DraftAIProcessingPolicy {
    /// Skip when the draft was processed before AND its photo set is unchanged.
    /// Compared as a Set: reordering photos (e.g. changing the cover) never re-bills
    /// the AI, but adding, removing, or swapping a photo changes the AI's actual
    /// input, so those drafts are re-processed. A nil snapshot means the draft was
    /// processed before `processedPhotoIDs` existed — treated as unchanged so
    /// pre-migration drafts aren't re-billed.
    static func shouldSkip(processedAt: Date?, processedPhotoIDs: [String]?, currentPhotoIDs: [String]) -> Bool {
        guard processedAt != nil else { return false }
        guard let snapshot = processedPhotoIDs else { return true }
        return Set(snapshot) == Set(currentPhotoIDs)
    }
}
