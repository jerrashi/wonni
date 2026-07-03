//
//  UploadManager.swift
//  wonni
//

import Foundation
import SwiftUI
import SwiftData
import FirebaseAuth
import FirebaseFirestore
import UIKit
import Vision

// MARK: - Status Enum

enum DraftUploadStatus: Equatable {
    case pending
    case uploading(Double)
    case done
    case failed
}

// MARK: - UploadManager

@MainActor
class UploadManager: ObservableObject {
    static let shared = UploadManager()

    // ── Tab / Navigation ────────────────────────────────────────────────────
    @Published var selectedTab = 0
    @Published var shouldReturnToRoot = false
    @Published var pendingAutofillJobsCount = 0
    @Published var sessionDraftIDs: [UUID] = []
    /// IDs of drafts marked for deletion. Populated synchronously by
    /// `deleteDraftLocallyAndCloud`, before the underlying SwiftData delete actually runs
    /// (deferred by one run loop tick — see that function). Two things depend on this:
    /// 1. Any in-flight background upload/recognition Task for the draft (which captures
    ///    the `Item` directly and `await`s across suspension points) re-checks this set
    ///    after each `await` and bails out rather than touching a model that may now be
    ///    detached from its context.
    /// 2. Draft-list views (`BulkListingOverviewView.drafts`, `ProcessResultsOverviewView`)
    ///    filter it out of their next render immediately, so SwiftUI never re-renders a row
    ///    against an `Item` whose backing store the deferred delete is about to invalidate.
    @Published private(set) var deletedDraftIDs: Set<UUID> = []

    // ── Active Draft (shared between camera and picker) ──────────────────────
    /// The UUID of the Item currently being built by the user.
    /// Both camera (photo capture) and picker (photo selection) write to this
    /// same Item. Persists across navigation and app restarts.
    @Published var activeDraftID: UUID? = nil

    // ── Photo Upload Phase ─────────────────────────────────────────────────
    @Published var isUploadingPhotos = false
    @Published var uploadProgress: Double = 0
    @Published var uploadStatuses: [UUID: DraftUploadStatus] = [:]
    @Published var uploadedAssetIDs: [String] = []
    @Published var showDeletePhotosPrompt = false
    @Published var uploadStartTime: Date? = nil

    // ── AI Processing Phase ─────────────────────────────────────────────────
    @Published var isProcessing = false
    @Published var processProgress: Double = 0
    @Published var processStatuses: [UUID: DraftUploadStatus] = [:]
    @Published var processCurrentIndex = 0
    @Published var processTotalCount = 0
    @Published var showProcessResults = false
    @Published var showResultsOverview = false
    @Published var processedItemIDs: [UUID] = []
    @Published var processingFailedIDs: Set<UUID> = []
    @Published var processQueuedIDs: [UUID] = []

    // ── Publish Phase ───────────────────────────────────────────────────────
    @Published var isPublishing = false
    @Published var publishError: String? = nil
    @Published var publishedPendingDeletionIDs: Set<UUID> = []
    @Published var crossPostStatusPending = false
    /// Populated just before publishDrafts is called (by ProcessResultsOverviewView).
    /// Kept in UploadManager so MainView can show CrossPostStatusView globally.
    @Published var sessionCrossPostItems: [CrossPostSessionItem] = []
    /// Drives the global CrossPostStatusView sheet in MainView.
    @Published var showCrossPostStatus = false

    // ── Legacy / Pill visibility ─────────────────────────────────────────────
    @Published var isPillVisible = false
    @Published var isProcessPillVisible = false
    @Published var showProgressSheet = false

    // ── Global Mercari cross-post job (shown as pill above tab bar from MainView) ──
    @Published var globalMercariJob: CrossPostJob? = nil
    /// Called by MainView's MercariAutoPosterView onDismiss to advance the queue in the originating view.
    var onMercariJobComplete: (() -> Void)? = nil

    // ── Internal tracking ───────────────────────────────────────────────────
    private var activeUploadCount = 0
    private var processTask: Task<Void, Never>?
    private var processingTaskId = UUID()
    private var publishTaskId = UUID()

    // ── ETA helper ─────────────────────────────────────────────────────────
    var uploadEtaString: String? {
        guard let start = uploadStartTime, uploadProgress > 0.05 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1 - uploadProgress) / uploadProgress
        if remaining < 60 { return "~\(max(1, Int(remaining)))s" }
        return "~\(Int((remaining / 60).rounded(.up))) min"
    }

    // MARK: – Active Draft Management

    /// Adds a photo to the current active draft, creating one if needed.
    /// Called by camera (after capture) and picker (on photo tap).
    func addPhotoToActiveDraft(assetId: String, imageData: Data?, modelContext: ModelContext) {
        let draft: Item
        if let existingID = activeDraftID,
           let existing = (try? modelContext.fetch(FetchDescriptor<Item>()))?.first(where: { $0.id == existingID }) {
            draft = existing
        } else {
            draft = Item(firestoreListingId: UUID().uuidString)
            modelContext.insert(draft)
            activeDraftID = draft.id
        }

        draft.sourceAssetIdentifiers.append(assetId)
        if let data = imageData {
            draft.photosData.append(data)
            draft.isLocalPhotoOnly = true
        }
        try? modelContext.save()
    }

    /// Removes a photo from the active draft (deselect in picker, or delete in carousel).
    func removePhotoFromActiveDraft(assetId: String, modelContext: ModelContext) {
        guard let id = activeDraftID,
              let draft = (try? modelContext.fetch(FetchDescriptor<Item>()))?.first(where: { $0.id == id }) else { return }
        _ = draft.removePhoto(assetId: assetId)
        if draft.sourceAssetIdentifiers.isEmpty {
            deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
            activeDraftID = nil
        }
        try? modelContext.save()
    }
    
    /// Deletes a draft from the local database, Firestore, and deletes uploaded images from Storage.
    func deleteDraftLocallyAndCloud(draft: Item, modelContext: ModelContext) {
        let listingId = draft.firestoreListingId
        let userId = Auth.auth().currentUser?.uid
        // Mark immediately (synchronously) so:
        // 1. Any in-flight background upload/recognition Task for this draft (which may be
        //    suspended mid-`await` right now) bails out on its next check instead of
        //    touching the model after it's deleted below.
        // 2. List rows watching this set (BulkListingOverviewView.drafts,
        //    ProcessResultsOverviewView.results, ActiveDraftCarouselView.committedDrafts)
        //    can exclude it from their next render.
        // 3. Item.image(for:) refuses to read photosData for it regardless of which view
        //    (if any) still renders it and regardless of render timing — see Item.deletedIDs.
        deletedDraftIDs.insert(draft.id)
        Item.deletedIDs.insert(draft.id)

        // Defer the actual SwiftData delete + save by one run loop tick. Calling
        // modelContext.delete()+save() synchronously from a List's .onDelete handler races
        // SwiftUI's own swipe/removal animation: the row can still be mid-render against
        // `draft` in the same frame SwiftData invalidates its backing store, which crashes
        // with "backing data was detached from a context without resolving attribute
        // faults" the next time the row body reads a model property (e.g. photosData).
        // Deferring lets that frame finish before the object is actually torn down.
        DispatchQueue.main.async { [weak modelContext] in
            guard let modelContext else { return }
            modelContext.delete(draft)
            try? modelContext.save()
        }

        guard let userId else { return }

        // Perform background cleanups if uploaded
        if let listingId = listingId {
            Task {
                print("[UploadManager] Cleaning up Cloud files for discarded draft \(listingId)")
                // Delete photos from Storage
                try? await StorageService.shared.deleteListingImages(userId: userId, listingId: listingId)
                // Delete document from Firestore
                try? await ListingRepository.shared.deleteListing(id: listingId)
            }
        }
    }

    /// Commits the active draft: starts background upload, resets activeDraftID.
    /// "Starting a new stack" in either view calls this.
    func commitActiveDraft(modelContext: ModelContext) {
        guard let id = activeDraftID,
              let draft = (try? modelContext.fetch(FetchDescriptor<Item>()))?.first(where: { $0.id == id }),
              !draft.sourceAssetIdentifiers.isEmpty else {
            activeDraftID = nil
            return
        }
        sessionDraftIDs.append(draft.id)
        startBackgroundUpload(draft: draft, modelContext: modelContext)
        runLocalRecognition(draft: draft, modelContext: modelContext)
        activeDraftID = nil
        try? modelContext.save()
    }

    // MARK: – Phase 1: Background Photo Upload

    /// Called immediately when the user adds a draft. Uploads photos to Storage
    /// using the pre-generated listing ID — no Firestore round-trip needed.
    func startBackgroundUpload(draft: Item, modelContext: ModelContext) {
        print("[UploadManager] startBackgroundUpload called for draft \(draft.id) with \(draft.sourceAssetIdentifiers.count) photos")

        guard let userId = Auth.auth().currentUser?.uid else {
            print("[UploadManager] ERROR: No authenticated user")
            return
        }
        guard !draft.sourceAssetIdentifiers.isEmpty else {
            print("[UploadManager] ERROR: No photos for draft \(draft.id)")
            return
        }

        // Listing ID must be set at draft creation time. If somehow missing, generate one now.
        if draft.firestoreListingId == nil {
            draft.firestoreListingId = UUID().uuidString
            try? modelContext.save()
        }
        let listingId = draft.firestoreListingId!

        if !isUploadingPhotos {
            isUploadingPhotos = true
            uploadStartTime = Date()
            uploadProgress = 0
        }
        activeUploadCount += 1
        uploadStatuses[draft.id] = .pending

        let draftID = draft.id
        let assetIdentifiers = draft.sourceAssetIdentifiers
        Task {
            uploadStatuses[draftID] = .uploading(0)

            print("[UploadManager] Fetching \(assetIdentifiers.count) images for \(draftID)...")
            var images: [UIImage] = []
            for assetId in assetIdentifiers {
                guard !deletedDraftIDs.contains(draftID) else {
                    print("[UploadManager] Draft \(draftID) deleted mid-upload — aborting")
                    return
                }
                if let img = draft.image(for: assetId) {
                    images.append(img)
                } else if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                    images.append(img)
                } else {
                    print("[UploadManager] WARNING: Could not fetch image for asset \(assetId)")
                }
            }
            guard !deletedDraftIDs.contains(draftID) else {
                print("[UploadManager] Draft \(draftID) deleted mid-upload — aborting before network upload")
                return
            }
            print("[UploadManager] Fetched \(images.count)/\(assetIdentifiers.count) images")

            var photoPaths: [String] = []
            for (imgIdx, image) in images.enumerated() {
                var success = false
                var attempts = 0
                let maxAttempts = 5
                var delaySeconds = 2.0
                
                while !success && attempts < maxAttempts && !Task.isCancelled {
                    attempts += 1
                    do {
                        print("[UploadManager] Uploading image \(imgIdx+1)/\(images.count) for \(draft.id) (attempt \(attempts))...")
                        let path = try await StorageService.shared.uploadListingImage(
                            image: image, index: imgIdx, userId: userId, listingId: listingId
                        )
                        photoPaths.append(path)
                        uploadStatuses[draft.id] = .uploading(Double(imgIdx + 1) / Double(images.count))
                        recalcUploadProgress()
                        success = true
                    } catch {
                        print("[UploadManager] Upload error for \(draft.id) index \(imgIdx) (attempt \(attempts)): \(error)")
                        if attempts < maxAttempts {
                            print("[UploadManager] Retrying in \(delaySeconds) seconds...")
                            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                            delaySeconds *= 2.0 // Exponential backoff
                        }
                    }
                }
            }

            let failed = photoPaths.count < images.count
            if !deletedDraftIDs.contains(draftID) {
                draft.firebasePhotoPaths = photoPaths
                try? modelContext.save()
                print("[UploadManager] Upload complete for \(draftID): \(photoPaths.count) paths saved")
            } else {
                print("[UploadManager] Draft \(draftID) deleted mid-upload — discarding \(photoPaths.count) uploaded paths")
            }
            uploadStatuses[draftID] = failed ? .failed : .done
            activeUploadCount -= 1
            if activeUploadCount <= 0 {
                isUploadingPhotos = false
            }
        }
    }

    private func recalcUploadProgress() {
        let statuses = uploadStatuses.values
        guard !statuses.isEmpty else { uploadProgress = 0; return }
        var sum: Double = 0
        for s in statuses {
            switch s {
            case .done: sum += 1.0
            case .uploading(let p): sum += p
            default: break
            }
        }
        uploadProgress = sum / Double(statuses.count)
    }

    func areAllUploadsFinished() -> Bool {
        guard !uploadStatuses.isEmpty else { return true }
        return !isUploadingPhotos
    }

    // MARK: – Phase 2: AI Processing

    /// Runs Gemini on each draft. Skips drafts that have already been processed
    /// (processedAt is set), so re-tapping "Process" never re-bills the AI.
    func processDrafts(drafts: [Item], modelContext: ModelContext) {
        guard !drafts.isEmpty else { return }

        processTask?.cancel()
        isProcessing = true
        isProcessPillVisible = true
        showProcessResults = false
        processProgress = 0
        processCurrentIndex = 0
        processTotalCount = drafts.count
        processingTaskId = UUID()
        AppTaskQueue.shared.begin(
            id: processingTaskId,
            label: "Processing with AI",
            detail: "0 of \(drafts.count)",
            progress: 0,
            accentColor: Color(red: 0.1, green: 0, blue: 0.35),
            onTap: { [weak self] in self?.showProgressSheet = true }
        )
        processStatuses = [:]
        processedItemIDs = []
        processingFailedIDs = []
        processQueuedIDs = drafts.map { $0.id }

        for draft in drafts { processStatuses[draft.id] = .pending }

        processTask = Task {
            for (index, draft) in drafts.enumerated() {
                guard !Task.isCancelled else { break }

                processCurrentIndex = index + 1
                AppTaskQueue.shared.update(
                    id: processingTaskId,
                    detail: "\(index + 1) of \(processTotalCount)"
                )

                // Skip Gemini if this draft was already processed in a prior run
                if draft.processedAt != nil {
                    print("[UploadManager] Skipping Gemini for \(draft.id) — already processed")
                    processedItemIDs.append(draft.id)
                    processStatuses[draft.id] = .done
                    processProgress = Double(index + 1) / Double(processTotalCount)
                    AppTaskQueue.shared.update(id: processingTaskId, progress: processProgress)
                    await MainActor.run { try? modelContext.save() }
                    continue
                }

                processStatuses[draft.id] = .uploading(0)  // Identifying...

                var images: [UIImage] = []
                for assetId in draft.sourceAssetIdentifiers {
                    if let img = draft.image(for: assetId) {
                        images.append(img)
                    } else if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                        images.append(img)
                    }
                }

                processStatuses[draft.id] = .uploading(0.35)  // Analyzing with AI...

                do {
                    let hasUserTitle = draft.userEditedTitle != nil && !draft.userEditedTitle!.isEmpty && draft.userEditedTitle != draft.visionTitle
                    let hasUserDesc = draft.userEditedDescription != nil && !draft.userEditedDescription!.isEmpty

                    if hasUserTitle {
                        draft.originalUserTitleBeforeAI = draft.userEditedTitle
                    }
                    if hasUserDesc {
                        draft.originalUserDescriptionBeforeAI = draft.userEditedDescription
                    }

                    print("[UploadManager] Running Gemini for draft \(draft.id)...")
                    let gemini = try await GeminiService.shared.identifyItem(
                        images: Array(images.prefix(3)),
                        userTitle: draft.userEditedTitle,
                        userPrice: draft.userEditedPrice,
                        userDescription: draft.userEditedDescription
                    )
                    print("[UploadManager] Gemini success for \(draft.id): \(gemini.name ?? "Untitled")")
                    processStatuses[draft.id] = .uploading(0.7)  // Generating description...
                    
                    // Use Gemini's shortTitle (≤80 chars) as the primary listing title —
                    // it already incorporates the user's title hints from the prompt.
                    // Fall back to name if shortTitle wasn't returned.
                    let primaryTitle = (gemini.shortTitle?.isEmpty == false) ? gemini.shortTitle : gemini.name
                    if hasUserTitle {
                        draft.userEditedTitle = primaryTitle
                    } else {
                        draft.aiSuggestedTitle = primaryTitle
                        draft.userEditedTitle = nil
                    }

                    // Condition from AI if user hasn't set one
                    if draft.condition == nil {
                        draft.condition = gemini.condition
                    }

                    if draft.aiSuggestedPrice == nil { draft.aiSuggestedPrice = gemini.suggestedPrice }

                    // Description merging
                    if hasUserDesc, let userDesc = draft.userEditedDescription, !userDesc.isEmpty, let geminiDesc = gemini.description, !geminiDesc.isEmpty {
                        let cleanString: (String) -> String = { s in
                            s.lowercased().filter { $0.isLetter || $0.isNumber }
                        }
                        let cu = cleanString(userDesc)
                        let cg = cleanString(geminiDesc)
                        if cg.contains(cu) {
                            draft.userEditedDescription = geminiDesc
                        } else {
                            draft.userEditedDescription = "\(userDesc)\n\n\(geminiDesc)"
                        }
                    } else {
                        draft.aiSuggestedDescription = gemini.description
                        draft.userEditedDescription = nil
                    }

                    draft.weightLbs = draft.weightLbs ?? gemini.weightLbs
                    draft.lengthIn  = draft.lengthIn  ?? gemini.lengthIn
                    draft.widthIn   = draft.widthIn   ?? gemini.widthIn
                    draft.heightIn  = draft.heightIn  ?? gemini.heightIn
                    draft.aiSuggestedCategory = draft.aiSuggestedCategory ?? gemini.category
                    draft.aiSuggestedBrand = draft.aiSuggestedBrand ?? gemini.brand
                    draft.processedAt = Date()
                    processedItemIDs.append(draft.id)
                    processStatuses[draft.id] = .done
                } catch {
                    print("[UploadManager] Gemini error for \(draft.id): \(error)")
                    processingFailedIDs.insert(draft.id)
                    processStatuses[draft.id] = .failed
                }

                processProgress = Double(index + 1) / Double(processTotalCount)
                AppTaskQueue.shared.update(id: processingTaskId, progress: processProgress)
                await MainActor.run { try? modelContext.save() }
            }

            isProcessing = false
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isProcessPillVisible = false
            AppTaskQueue.shared.complete(id: processingTaskId)
            showProgressSheet = false
            showProcessResults = true
        }
    }

    /// Syncs metadata to Firestore if the listing document already exists.
    /// Fire-and-forget — failures are logged but not surfaced.
    func syncDraftData(_ draft: Item) {
        guard let listingId = draft.firestoreListingId else { return }

        Task {
            do {
                var data: [String: Any] = [:]
                data["customTitle"] = draft.userEditedTitle ?? draft.aiSuggestedTitle
                data["customDescription"] = draft.userEditedDescription ?? draft.aiSuggestedDescription
                data["price"] = draft.userEditedPrice ?? draft.aiSuggestedPrice
                data["tags"] = draft.tags
                data["personalNote"] = draft.personalNote
                data["updatedAt"] = Timestamp(date: Date())

                if let l = draft.lengthIn, let w = draft.widthIn, let h = draft.heightIn {
                    let dimensions = PackageDimensions(lengthIn: l, widthIn: w, heightIn: h)
                    let shippingInfo = ShippingInfo(
                        buyerPaysShipping: draft.buyerPaysShipping,
                        handlingFee: draft.handlingFee,
                        estimatedShippingDays: draft.estimatedShippingDays,
                        weightLbs: draft.weightLbs,
                        packageDimensions: dimensions
                    )
                    data["shippingInfo"] = try Firestore.Encoder().encode(shippingInfo)
                }

                try await ListingRepository.shared.updateListingData(listingId: listingId, data: data)
            } catch {
                // Expected to fail when no Firestore draft exists yet — suppress noise
            }
        }
    }

    // MARK: – Phase 2.5: Inline photo upload (fallback for app-restart scenario)

    /// Uploads photos for a draft that missed the background upload (e.g. after app restart).
    /// Uses the pre-generated listing UUID — no Firestore round-trip needed.
    private func uploadPhotosForDraft(_ draft: Item, userId: String, modelContext: ModelContext) async -> [String] {
        if draft.firestoreListingId == nil {
            draft.firestoreListingId = UUID().uuidString
            try? modelContext.save()
        }
        let listingId = draft.firestoreListingId!
        print("[UploadManager] Inline upload starting for \(draft.id) → listing \(listingId)")

        var paths: [String] = []
        for (idx, assetId) in draft.sourceAssetIdentifiers.enumerated() {
            let img: UIImage
            if let localImg = draft.image(for: assetId) {
                img = localImg
            } else if let phImg = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                img = phImg
            } else {
                print("[UploadManager] Could not load photo \(idx) for \(draft.id)")
                continue
            }
            do {
                let path = try await StorageService.shared.uploadListingImage(
                    image: img, index: idx, userId: userId, listingId: listingId
                )
                paths.append(path)
                print("[UploadManager] Inline uploaded photo \(idx): \(path)")
            } catch {
                print("[UploadManager] Inline upload failed for photo \(idx): \(error)")
            }
        }

        draft.firebasePhotoPaths = paths
        try? modelContext.save()
        return paths
    }

    // MARK: – Phase 3: Publish to Firestore

    /// Posts finished drafts as active listings. Uploads photos first if they
    /// weren't already uploaded (e.g. app was restarted between phases).
    /// `onComplete` fires on the main actor after the publish task finishes (success or
    /// failure). Callers must use it — not `.onChange(of: isPublishing)` — to sequence
    /// post-publish work: when photos are already uploaded the task completes in
    /// milliseconds, so `isPublishing` can flip true→false before SwiftUI renders and
    /// an `.onChange` observer never sees the transition.
    func publishDrafts(drafts: [Item], modelContext: ModelContext, onComplete: (() -> Void)? = nil) {
        guard !drafts.isEmpty else { return }
        print("[UploadManager] publishDrafts called for \(drafts.count) items")
        isPublishing = true
        publishError = nil
        publishTaskId = UUID()
        let taskId = publishTaskId
        AppTaskQueue.shared.begin(
            id: taskId,
            label: "Publishing \(drafts.count == 1 ? "listing" : "\(drafts.count) listings")",
            progress: -1,
            accentColor: .blue,
            onTap: { [weak self] in self?.showResultsOverview = true }
        )

        Task {
            defer {
                isPublishing = false
                AppTaskQueue.shared.complete(id: taskId)
                onComplete?()
            }

            guard let userId = Auth.auth().currentUser?.uid else {
                print("[UploadManager] Publish aborted: No authenticated user")
                publishError = "Not signed in. Please sign in and try again."
                return
            }

            var publishedCount = 0
            var failedCount = 0

            for draft in drafts {
                print("[UploadManager] Publishing draft \(draft.id)")

                // Upload photos if background upload didn't complete fully
                var photoPaths = draft.firebasePhotoPaths ?? []
                if photoPaths.count < draft.sourceAssetIdentifiers.count {
                    print("[UploadManager] Incomplete photo paths (\(photoPaths.count)/\(draft.sourceAssetIdentifiers.count)) for \(draft.id) — uploading now")
                    photoPaths = await uploadPhotosForDraft(draft, userId: userId, modelContext: modelContext)
                }

                guard !photoPaths.isEmpty else {
                    print("[UploadManager] Skipping \(draft.id) — photo upload failed")
                    failedCount += 1
                    continue
                }

                // Build the active listing using the pre-generated listing ID
                var listing = UserListing.newDraft(
                    userId: userId,
                    sourceAssetIdentifiers: []
                )
                listing.id = draft.firestoreListingId  // use pre-generated UUID
                listing.status = .active
                listing.createdAt = Timestamp(date: Date())
                listing.publishedAt = Timestamp(date: Date())
                listing.photoPaths = photoPaths
                listing.coverPhotoPath = photoPaths.first
                listing.tags = draft.tags
                listing.personalNote = draft.personalNote
                listing.customTitle = draft.userEditedTitle ?? draft.aiSuggestedTitle
                listing.customDescription = draft.userEditedDescription ?? draft.aiSuggestedDescription
                listing.price = draft.userEditedPrice ?? draft.aiSuggestedPrice
                listing.geminiIdentificationConfirmed = draft.processedAt != nil
                listing.category = draft.aiSuggestedCategory
                // eBay category is resolved server-side from eBay's own taxonomy suggestions
                // (using the title + this Gemini category string). The old static client-side map
                // produced wrong leaf categories — e.g. mapping items into "Music > CDs", whose
                // required "Artist"/"Release Title" item specifics then failed the eBay publish.
                listing.ebayCategory = nil
                listing.brand = draft.aiSuggestedBrand
                listing.sourceAssetIdentifiers = []

                var packageDimensions: PackageDimensions? = nil
                if let l = draft.lengthIn, let w = draft.widthIn, let h = draft.heightIn {
                    packageDimensions = PackageDimensions(lengthIn: l, widthIn: w, heightIn: h)
                }
                listing.shippingInfo = ShippingInfo(
                    buyerPaysShipping: draft.buyerPaysShipping,
                    handlingFee: draft.handlingFee,
                    estimatedShippingDays: draft.estimatedShippingDays,
                    weightLbs: draft.weightLbs,
                    packageDimensions: packageDimensions
                )

                print("[UploadManager] Writing listing to Firestore: \(listing.id ?? "nil"), \(photoPaths.count) photos")

                do {
                    let docID = try await ListingRepository.shared.saveDraft(listing)
                    print("[UploadManager] Published listing \(docID)")
                    if pendingAutofillJobsCount > 0 {
                        // Cross-posting jobs are queued — keep the SwiftData item alive so
                        // startPosting() can read photos directly without copying or re-downloading.
                        // ProcessResultsOverviewView.checkAndStartNextWebJob() deletes when the queue empties.
                        publishedPendingDeletionIDs.insert(draft.id)
                    } else {
                        // See Item.deletedIDs — mark before deleting so no view can read
                        // photosData on this object after this point.
                        Item.deletedIDs.insert(draft.id)
                        modelContext.delete(draft)
                    }
                    // This draft is now a live listing — drop it from the session set so the
                    // discard-on-exit path can't call deleteDraftLocallyAndCloud on it and try to
                    // delete the published Firestore document (which the rules correctly reject).
                    sessionDraftIDs.removeAll { $0 == draft.id }
                    publishedCount += 1
                } catch {
                    print("[UploadManager] Firestore write failed for \(draft.id): \(error)")
                    failedCount += 1
                }
            }

            try? modelContext.save()
            print("[UploadManager] Publish complete: \(publishedCount) published, \(failedCount) failed")

            if publishedCount > 0 {
                showProcessResults = false
                // Transition to CrossPostStatusView is handled by ProcessResultsOverviewView
                // via the onComplete callback (runPublishContinuationIfReady). shouldReturnToRoot
                // is set when the user taps Done in CrossPostStatusView (onDone closure).
            } else {
                publishError = "Could not publish listings. Check your connection and try again."
            }
        }
    }

    // MARK: – Cancel / Reset

    func cancelProcessing() {
        processTask?.cancel()
        processTask = nil
        isProcessing = false
        isProcessPillVisible = false
        AppTaskQueue.shared.complete(id: processingTaskId)
        processStatuses.removeAll()
        processedItemIDs.removeAll()
        processingFailedIDs.removeAll()
    }

    func resetAll() {
        processTask?.cancel()
        processTask = nil
        isUploadingPhotos = false
        isPillVisible = false
        isProcessPillVisible = false
        AppTaskQueue.shared.complete(id: processingTaskId)
        isProcessing = false
        isPublishing = false
        showProcessResults = false
        showResultsOverview = false
        sessionCrossPostItems = []
        showCrossPostStatus = false
        publishError = nil
        uploadProgress = 0
        uploadStatuses.removeAll()
        uploadedAssetIDs.removeAll()
        processStatuses.removeAll()
        processedItemIDs.removeAll()
        processingFailedIDs.removeAll()
        shouldReturnToRoot = false
        uploadStartTime = nil
        activeUploadCount = 0
        sessionDraftIDs.removeAll()
        activeDraftID = nil
        crossPostStatusPending = false
        globalMercariJob = nil
        onMercariJobComplete = nil
    }

    // MARK: – On-device Vision Recognition

    func runLocalRecognition(draft: Item, modelContext: ModelContext) {
        guard let assetId = draft.sourceAssetIdentifiers.first else { return }
        let draftRef = draft
        let draftID = draft.id
        Task {
            let image: UIImage
            if let localImg = draftRef.image(for: assetId) {
                image = localImg
            } else if let phImg = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                image = phImg
            } else {
                return
            }
            guard let cgImage = image.cgImage else { return }
            let title = await Task.detached(priority: .userInitiated) {
                UploadManager.generateVisionTitle(cgImage: cgImage)
            }.value
            guard !deletedDraftIDs.contains(draftID) else {
                print("[UploadManager] Draft \(draftID) deleted mid-recognition — discarding vision title")
                return
            }
            draftRef.visionTitle = title
            try? modelContext.save()
        }
    }

    private nonisolated static func generateVisionTitle(cgImage: CGImage) -> String? {
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.usesLanguageCorrection = false

        let classifyReq = VNClassifyImageRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([textReq, classifyReq])

        // Prefer OCR text (brand names, model numbers)
        if let topText = textReq.results?
            .compactMap({ $0.topCandidates(1).first })
            .filter({ $0.confidence > 0.7 && $0.string.count > 2 })
            .first?.string, !topText.isEmpty {
            return topText.capitalized
        }

        // Fall back to a SINGLE human-readable classification label (e.g. "Butterfly"),
        // not a concatenation of abstract taxonomy terms ("structure wood person").
        // Apple recommends filtering VNClassifyImageRequest results by precision/recall rather
        // than a raw confidence threshold, since the taxonomy is hierarchical; among those that
        // clear the bar we take the most confident, falling back to the top result overall.
        let observations = classifyReq.results ?? []
        guard let best = observations.filter({ $0.hasMinimumRecall(0.01, forPrecision: 0.9) })
                .max(by: { $0.confidence < $1.confidence })
                ?? observations.max(by: { $0.confidence < $1.confidence }),
              best.confidence > 0.4 else {
            return nil
        }
        return humanReadableLabel(best.identifier)
    }

    /// Turns a Vision taxonomy identifier (lowercase, often underscore-delimited, e.g.
    /// "hot_air_balloon") into a clean title-cased phrase ("Hot Air Balloon").
    private nonisolated static func humanReadableLabel(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
