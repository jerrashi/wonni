//
//  Models.swift
//  wonni
//

import Foundation
import ImageIO
import Photos
import SwiftData
import UIKit

@Model
class Item {
    var id: UUID
    var createdAt: Date
    /// LEGACY — no longer written. Local photo bytes live in per-photo files now (see
    /// `localPhotoFilesByAsset` / DraftPhotoStore.swift for why). Kept in the schema so
    /// drafts created before 2026-09-30 can be read and migrated
    /// (`migrateLegacyPhotosIfNeeded`); empty for every migrated or newer draft.
    @Attribute(.externalStorage) var photosData: [Data]
    /// assetId -> file name in DraftPhotoStore, for photos whose bytes this draft keeps
    /// locally (camera shots, photos pulled from another device). Library-picked photos
    /// have no entry — they're read from PhotoKit. Keyed by assetId (not position), so
    /// reordering never touches it. Optional so SwiftData's lightweight migration can
    /// add the column to existing databases.
    var localPhotoFilesByAsset: [String: String]?
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
    /// Per-listing eBay handling time override; nil inherits the account default
    /// (SellingSettings.handlingTimeDays). See ShippingInfo.handlingTimeDays.
    var handlingTimeDays: Int?
    /// Per-listing Facebook Marketplace overrides; nil inherits the account default
    /// (AppStorage `facebookOfferShipping` / `facebookHideFromFriends`, synced from
    /// users/{uid}/settings/facebookPosting). Optional so SwiftData's lightweight
    /// migration adds the columns without a migration plan. Mirrored to products/{id}
    /// as `facebookOfferShipping` / `facebookHideFromFriends`, which is where
    /// FacebookAutoPosterView reads them (the draft is gone by cross-post time).
    var facebookOfferShipping: Bool?
    var facebookHideFromFriends: Bool?
    /// "Sell similar" carry-over from a draft made out of a pasted list
    /// (BulkTextDraftService): the eBay category id and item specifics copied
    /// from the best-matching live eBay listing. Mirrored to products/{id} as
    /// `ebayCategoryId` / `geminiItemSpecifics`, which is where ebayCreateListing
    /// reads them (category pinned over a taxonomy guess, specifics merged into
    /// the offer's aspects). nil for every other draft. Optional so SwiftData's
    /// lightweight migration adds the columns without a migration plan.
    var ebayCategoryId: String?
    var itemSpecifics: [String: String]?
    var isDraft: Bool
    /// Local last-modified time, bumped alongside every `UploadManager.syncProductData`
    /// call. Compared against the shared `products/{id}` doc's own `updatedAt` to decide
    /// sync direction (last-write-wins) when a draft may have been edited on another
    /// client — see `UploadManager.pullProductIfNewer`. Property-level default (not just
    /// the init parameter) so SwiftData's lightweight migration can add this column to
    /// existing local databases without a custom migration plan.
    var updatedAt: Date = Date()
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
    /// Set the moment the user confirms publish (before any network work starts).
    /// Cleared when `publishedAt` is set on Firestore success. On failure or app kill,
    /// stays `true` — items with `pendingPublish == true` but `publishedAt == nil` are
    /// "failed-to-publish" drafts, recovered by `sweepFailedPublishDrafts()` on next launch.
    /// Views that show the active draft queue (carousel, picker grid, AI processing list)
    /// exclude these items; `ProcessResultsOverviewView` retains them so the user can retry.
    var pendingPublish: Bool = false
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

    init(id: UUID = UUID(), createdAt: Date = Date(), photosData: [Data] = [], blurb: String = "", buyerPaysShipping: Bool = true, handlingFee: Double = 0.0, estimatedShippingDays: Int = 3, weightLbs: Double? = nil, lengthIn: Double? = nil, widthIn: Double? = nil, heightIn: Double? = nil, handlingTimeDays: Int? = nil, isDraft: Bool = true, updatedAt: Date = Date(), sourceAssetIdentifiers: [String] = [], tags: [String] = [], personalNote: String? = nil, firebasePhotoPathsByAsset: [String: String]? = nil, firestoreListingId: String? = nil, processedAt: Date? = nil, visionTitle: String? = nil, isLocalPhotoOnly: Bool = false, originalUserTitleBeforeAI: String? = nil, originalUserDescriptionBeforeAI: String? = nil, aiSuggestedCategory: String? = nil, aiSuggestedBrand: String? = nil, condition: String? = nil) {
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
        self.handlingTimeDays = handlingTimeDays
        self.isDraft = isDraft
        self.updatedAt = updatedAt
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
    /// the bytes behind an assetId never change after insertion, so entries only need
    /// explicit eviction in `removePhoto`.
    /// `nonisolated(unsafe)` for the same reason as `deletedIDs`: all access is
    /// main-thread by construction (view bodies), and NSCache is thread-safe anyway.
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSString, UIImage>()

    /// Max pixel dimension for cached thumbnails: 160pt (largest on-screen use,
    /// DraftPhotoEditModal) at 3x. One tier keeps every view sharing one cache entry.
    private static let thumbnailMaxPixel = 480

    // MARK: Local photo bytes

    /// Full-resolution bytes this draft keeps locally for a photo; nil for photos that
    /// live only in the photo library.
    func photoData(for assetId: String) -> Data? {
        // A SwiftUI row can still be mid-render against a just-deleted Item — e.g. List's
        // own swipe-to-delete removal animation, or a sibling carousel/stack view driven
        // by an independent @Query, re-evaluating a row's body a beat after the underlying
        // SwiftData delete commits. Reading attributes on a detached object crashes with
        // "backing data was detached from a context without resolving attribute faults."
        // Checking `Item.deletedIDs` here is the one choke point that protects every
        // caller regardless of which view rendered it or render timing.
        guard !Item.deletedIDs.contains(id) else { return nil }
        if let fileName = localPhotoFilesByAsset?[assetId] {
            return DraftPhotoStore.read(itemID: id, fileName: fileName)
        }
        return legacyPhotoData(for: assetId)
    }

    /// Every locally-stored photo keyed by assetId.
    func localPhotoDataByAsset() -> [String: Data] {
        guard !Item.deletedIDs.contains(id) else { return [:] }
        var result: [String: Data] = [:]
        let itemID = id
        for (assetId, fileName) in localPhotoFilesByAsset ?? [:] {
            result[assetId] = DraftPhotoStore.read(itemID: itemID, fileName: fileName)
        }
        let blobs = photosData
        if !blobs.isEmpty {
            let indexes = LegacyDraftPhotos.blobIndexByAsset(assetIds: sourceAssetIdentifiers, blobCount: blobs.count)
            for (assetId, idx) in indexes where result[assetId] == nil {
                result[assetId] = blobs[idx]
            }
        }
        return result
    }

    /// Stores local bytes for a photo (one already in, or about to be added to,
    /// `sourceAssetIdentifiers`). On a write failure (disk full) the bytes are dropped
    /// and the photo falls back to the photo library like a picked one.
    func setLocalPhoto(_ data: Data, for assetId: String) {
        do {
            let fileName = try DraftPhotoStore.write(data, itemID: id)
            var files = localPhotoFilesByAsset ?? [:]
            if let replaced = files[assetId] { DraftPhotoStore.delete(itemID: id, fileName: replaced) }
            files[assetId] = fileName
            localPhotoFilesByAsset = files
            isLocalPhotoOnly = true
        } catch {
            print("[Item] Couldn't store local photo \(assetId) for draft \(id): \(error)")
        }
    }

    /// Drops everything this draft stored locally. Call wherever a draft is deleted,
    /// while the object is still attached.
    func discardLocalPhotos() {
        DraftPhotoStore.deleteAll(itemID: id)
        localPhotoFilesByAsset = nil
        photosData = []
    }

    /// Moves bytes still held in the legacy `photosData` array out to files. Returns
    /// true if this draft changed (the caller saves). No-op for migrated/new drafts.
    /// All-or-nothing: if a file write fails the legacy array is left intact, and the
    /// legacy branches in the mutators below keep it consistent.
    @discardableResult
    func migrateLegacyPhotosIfNeeded() -> Bool {
        guard !Item.deletedIDs.contains(id) else { return false }
        let blobs = photosData
        guard !blobs.isEmpty else { return false }
        let indexes = LegacyDraftPhotos.blobIndexByAsset(assetIds: sourceAssetIdentifiers, blobCount: blobs.count)
        if indexes.isEmpty {
            // Can't tell which photo each blob belongs to. Every photo with a real
            // library id is served by PhotoKit, so the blobs are dead weight — unless a
            // `local_temp_` photo is involved, whose only copy may be in there.
            guard !sourceAssetIdentifiers.contains(where: { $0.hasPrefix("local_temp_") }) else { return false }
            photosData = []
            return true
        }
        let itemID = id
        var written: [String: String] = [:]
        do {
            for (assetId, idx) in indexes {
                written[assetId] = try DraftPhotoStore.write(blobs[idx], itemID: itemID)
            }
        } catch {
            print("[Item] Legacy photo migration failed for draft \(itemID): \(error)")
            for fileName in written.values { DraftPhotoStore.delete(itemID: itemID, fileName: fileName) }
            return false
        }
        localPhotoFilesByAsset = (localPhotoFilesByAsset ?? [:]).merging(written) { current, _ in current }
        photosData = []
        return true
    }

    private func legacyPhotoData(for assetId: String) -> Data? {
        let blobs = photosData
        guard !blobs.isEmpty,
              let idx = LegacyDraftPhotos.blobIndexByAsset(assetIds: sourceAssetIdentifiers, blobCount: blobs.count)[assetId]
        else { return nil }
        return blobs[idx]
    }

    // MARK: Thumbnails

    /// Cached, downsampled thumbnail for list/grid display. Decodes synchronously on a
    /// cache miss, and only knows about locally-stored bytes (nil for library-picked
    /// photos). Views should use `DraftThumbnailView` (Views/DraftThumbnailView.swift)
    /// instead, which keeps the work off the main thread via `cachedThumbnailOnly` +
    /// `loadThumbnailAsync` and handles both photo sources — every draft screen was
    /// migrated to it 2026-09-30.
    func thumbnail(for assetId: String) -> UIImage? {
        guard !Item.deletedIDs.contains(id) else { return nil }
        let key = "\(id)-\(assetId)" as NSString
        if let cached = Item.thumbnailCache.object(forKey: key) { return cached }
        guard let data = photoData(for: assetId),
              let thumb = Item.decodeThumbnail(.data(data)) else { return nil }
        Item.thumbnailCache.setObject(thumb, forKey: key)
        return thumb
    }

    /// Cache-only read, no decode — the fast path `DraftThumbnailView` checks before
    /// falling back to a placeholder + `loadThumbnailAsync`.
    func cachedThumbnailOnly(for assetId: String) -> UIImage? {
        guard !Item.deletedIDs.contains(id) else { return nil }
        return Item.thumbnailCache.object(forKey: "\(id)-\(assetId)" as NSString)
    }

    /// Where a thumbnail's bytes come from. `.file` is read on the background queue;
    /// `.photoLibrary` means the draft holds no local bytes for the photo.
    private enum ThumbnailSource {
        case file(URL)
        case data(Data)
        case photoLibrary
    }

    /// The actual decode. No SwiftData object access here, so it's safe to call from a
    /// background queue (model properties themselves are NOT safe to touch off the main
    /// actor — `loadThumbnailAsync` resolves the source on the main actor first).
    private static func decodeThumbnail(_ source: ThumbnailSource) -> UIImage? {
        let imageSource: CGImageSource?
        switch source {
        case .file(let url): imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data(let data): imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        case .photoLibrary: imageSource = nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Item.thumbnailMaxPixel
        ]
        guard let imageSource,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Cache-miss path for `DraftThumbnailView`: works out where the photo's bytes are
    /// on the main actor (SwiftData model properties aren't safe to touch off it), then
    /// reads and decodes on a background queue so neither the file read nor the ImageIO
    /// work blocks the main thread. Populates the same NSCache `thumbnail(for:)` reads.
    ///
    /// `@MainActor` is load-bearing: a plain `async` method on a non-actor class runs
    /// on the global executor no matter who awaits it, so without the annotation the
    /// model reads below happened OFF the main thread.
    @MainActor
    func loadThumbnailAsync(for assetId: String) async -> UIImage? {
        guard !Item.deletedIDs.contains(id) else { return nil }
        // Captured before the await — `id` itself can fault once the item is deleted.
        let itemID = id
        let key = "\(itemID)-\(assetId)"
        if let cached = Item.thumbnailCache.object(forKey: key as NSString) { return cached }

        let load: Task<UIImage?, Never>
        if let inFlight = Item.thumbnailLoads[key] {
            // Already loading (another cell, or `prewarmThumbnail` at capture time).
            load = inFlight
        } else {
            let source: ThumbnailSource
            if let fileName = localPhotoFilesByAsset?[assetId] {
                source = .file(DraftPhotoStore.url(itemID: itemID, fileName: fileName))
            } else if let legacy = legacyPhotoData(for: assetId) {
                source = .data(legacy)
            } else {
                source = .photoLibrary
            }
            load = Item.startThumbnailLoad(key: key, source: source, assetId: assetId)
        }
        let thumb = await load.value
        guard !Item.deletedIDs.contains(itemID) else { return nil } // deleted while loading
        return thumb
    }

    /// Decodes a just-captured photo's thumbnail straight from the bytes the camera
    /// handed over, before the carousel asks for it — so the new shot's cell never has
    /// to read it back from disk.
    @MainActor
    static func prewarmThumbnail(itemID: UUID, assetId: String, data: Data) {
        let key = "\(itemID)-\(assetId)"
        guard thumbnailCache.object(forKey: key as NSString) == nil, thumbnailLoads[key] == nil else { return }
        _ = startThumbnailLoad(key: key, source: .data(data), assetId: assetId)
    }

    /// In-flight loads keyed like `thumbnailCache`, so concurrent requests for the same
    /// photo share one decode.
    @MainActor private static var thumbnailLoads: [String: Task<UIImage?, Never>] = [:]

    /// Own queue rather than `Task.detached`: the PhotoKit request below is synchronous
    /// and can wait on iCloud, which must not tie up the cooperative thread pool.
    private static let thumbnailQueue = DispatchQueue(
        label: "wonni.item-thumbnails", qos: .userInitiated, attributes: .concurrent)

    @MainActor
    private static func startThumbnailLoad(key: String, source: ThumbnailSource, assetId: String) -> Task<UIImage?, Never> {
        let task = Task<UIImage?, Never> { @MainActor in
            let thumb: UIImage? = await withCheckedContinuation { continuation in
                thumbnailQueue.async {
                    // Local bytes first; the library is the fallback for photos with
                    // none (or whose bytes won't decode).
                    continuation.resume(returning: decodeThumbnail(source) ?? photoLibraryThumbnail(assetId: assetId))
                }
            }
            if let thumb { thumbnailCache.setObject(thumb, forKey: key as NSString) }
            thumbnailLoads[key] = nil
            return thumb
        }
        thumbnailLoads[key] = task
        return task
    }

    /// Thumbnail for a photo that lives only in the photo library. Blocking — call from
    /// `thumbnailQueue` only. `isSynchronous` guarantees exactly one callback.
    private static func photoLibraryThumbnail(assetId: String) -> UIImage? {
        guard !assetId.hasPrefix("local_temp_"),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let side = CGFloat(thumbnailMaxPixel)
        var result: UIImage?
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill, options: options
        ) { image, _ in
            result = image
        }
        return result
    }

    /// Full-resolution image from the draft's local bytes (upload/publish/AI paths).
    func image(for assetId: String) -> UIImage? {
        photoData(for: assetId).flatMap { UIImage(data: $0) }
    }

    // MARK: Photo order & membership

    /// `sourceAssetIdentifiers` reflects the user's current photo order (drag-to-reorder
    /// mutates it directly); this resolves that order into Storage paths via the
    /// assetId-keyed map, so publish/cover-photo logic always matches what's on screen.
    var orderedFirebasePhotoPaths: [String] {
        sourceAssetIdentifiers.compactMap { firebasePhotoPathsByAsset?[$0] }
    }

    // The mutators below first move any legacy `photosData` out to files. The
    // `!photosData.isEmpty` branches only run if that migration failed (disk full) and
    // keep the positional legacy array in step, exactly as before.

    func movePhoto(from: Int, to: Int) {
        migrateLegacyPhotosIfNeeded()
        var ids = sourceAssetIdentifiers
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        sourceAssetIdentifiers = ids

        if isLocalPhotoOnly && from < photosData.count && to < photosData.count {
            var data = photosData
            data.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            photosData = data
        }
        // Nothing else to do — local files and Storage paths are keyed by assetId.
    }

    /// Applies a new photo order (a permutation of the current photos).
    func reorderPhotos(to newOrder: [String]) {
        migrateLegacyPhotosIfNeeded()
        let legacy = photosData
        if !legacy.isEmpty {
            let oldOrder = sourceAssetIdentifiers
            photosData = newOrder.compactMap { assetId in
                oldOrder.firstIndex(of: assetId).flatMap { $0 < legacy.count ? legacy[$0] : nil }
            }
        }
        sourceAssetIdentifiers = newOrder
    }

    /// Removes a photo from this draft. Returns the local photo bytes (if this draft
    /// keeps them locally) and the photo's uploaded Storage path (if it had one), so
    /// callers can either re-insert both elsewhere (cross-draft move) or delete the
    /// Storage path for good (permanent removal).
    @discardableResult
    func removePhoto(assetId: String) -> (data: Data?, firebasePhotoPath: String?) {
        migrateLegacyPhotosIfNeeded()
        guard let idx = sourceAssetIdentifiers.firstIndex(of: assetId) else { return (nil, nil) }
        sourceAssetIdentifiers.remove(at: idx)
        Item.thumbnailCache.removeObject(forKey: "\(id)-\(assetId)" as NSString)
        let path = firebasePhotoPathsByAsset?.removeValue(forKey: assetId)

        if let fileName = localPhotoFilesByAsset?[assetId] {
            let data = DraftPhotoStore.read(itemID: id, fileName: fileName)
            DraftPhotoStore.delete(itemID: id, fileName: fileName)
            localPhotoFilesByAsset?.removeValue(forKey: assetId)
            return (data, path)
        }
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
        migrateLegacyPhotosIfNeeded()
        let hasLegacy = !photosData.isEmpty
        if index >= sourceAssetIdentifiers.count {
            sourceAssetIdentifiers.append(assetId)
            if hasLegacy, let data { photosData.append(data) }
        } else {
            sourceAssetIdentifiers.insert(assetId, at: index)
            if hasLegacy, let data { photosData.insert(data, at: index) }
        }
        if !hasLegacy, let data {
            setLocalPhoto(data, for: assetId)
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
