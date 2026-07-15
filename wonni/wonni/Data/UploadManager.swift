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
    /// Set when something (a saved-search notification row, a deep link) wants Search
    /// to run a specific query, alongside switching selectedTab to Search.
    /// SearchView observes this to pre-fill and run the query, then clears it.
    @Published var pendingSearchQuery: String? = nil
    /// Set by the Home search bar on tap, alongside switching selectedTab to Search.
    /// SearchView observes this to focus its text field, then clears it.
    @Published var pendingSearchFocus = false

    // ── Active Draft (shared between camera and picker) ──────────────────────
    /// The UUID of the Item currently being built by the user.
    /// Both camera (photo capture) and picker (photo selection) write to this
    /// same Item. Persists across navigation and app restarts.
    @Published var activeDraftID: UUID? = nil

    // ── Photo Upload Phase ─────────────────────────────────────────────────
    @Published var isUploadingPhotos = false
    // uploadProgress/uploadStatuses tick once per photo (often several times a second
    // across a batch). Screens like BulkListingOverviewView hold this object via
    // @EnvironmentObject to call its methods, which means SwiftUI's whole-object
    // ObservableObject invalidation re-runs their entire body — reconstructing the drafts
    // List — on every single tick, even though that screen doesn't display upload progress
    // at all. Backed by plain vars with a throttled objectWillChange (below) instead of
    // @Published, so internal reads stay perfectly current but external re-renders are
    // capped at a sane rate instead of firing dozens of times a second.
    var uploadProgress: Double {
        get { _uploadProgress }
        set { _uploadProgress = newValue; scheduleThrottledChangeNotify() }
    }
    private var _uploadProgress: Double = 0
    var uploadStatuses: [UUID: DraftUploadStatus] {
        get { _uploadStatuses }
        set { _uploadStatuses = newValue; scheduleThrottledChangeNotify() }
    }
    private var _uploadStatuses: [UUID: DraftUploadStatus] = [:]
    @Published var uploadedAssetIDs: [String] = []
    @Published var showDeletePhotosPrompt = false
    @Published var uploadStartTime: Date? = nil

    // ── AI Processing Phase ─────────────────────────────────────────────────
    @Published var isProcessing = false
    // Same throttling rationale as uploadProgress/uploadStatuses above — these tick
    // several times per draft as it moves through identify/analyze/describe.
    var processProgress: Double {
        get { _processProgress }
        set { _processProgress = newValue; scheduleThrottledChangeNotify() }
    }
    private var _processProgress: Double = 0
    var processStatuses: [UUID: DraftUploadStatus] {
        get { _processStatuses }
        set { _processStatuses = newValue; scheduleThrottledChangeNotify() }
    }
    private var _processStatuses: [UUID: DraftUploadStatus] = [:]
    var processCurrentIndex: Int {
        get { _processCurrentIndex }
        set { _processCurrentIndex = newValue; scheduleThrottledChangeNotify() }
    }
    private var _processCurrentIndex = 0
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
    /// Owned here (not as local @State on ProcessResultsOverviewView) because the eBay/Etsy
    /// API cross-post Task that sets this can complete well after that view has already been
    /// dismissed (showResultsOverview = false runs immediately once publish succeeds and
    /// there's no web-autofill queue to wait on — the common case for an API-only publish).
    /// A local @State there would silently discard the error into a torn-down view. Surfaced
    /// from CrossPostStatusView, which is reliably the next screen shown after any publish.
    @Published var crossPostError: String? = nil
    /// Set in publishDrafts when a listing published (and any cross-post proceeded) with fewer
    /// photos than the user selected — a photo silently failed every upload retry. Previously
    /// this was invisible: the publish guard only checked photoPaths wasn't *empty*, so a
    /// partial photo set went out with no error, matching github issue #56's "photos are not
    /// properly posting with the listing" report. Surfaced the same way as crossPostError.
    @Published var photoUploadWarning: String? = nil
    /// Set when Storage/Firestore cleanup fails during `deleteDraftLocallyAndCloud` —
    /// surfaced as a toast from MainView instead of being silently swallowed, mirroring
    /// `crossPostError` above.
    @Published var cleanupError: String? = nil
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
    /// One-shot callback fired when the web autofill queue drains. Set by the flow that
    /// enqueued the jobs (e.g. ProfileView reloads its listings); cleared after firing.
    var onWebQueueDrained: (() -> Void)? = nil

    // ── Web autofill queue (Mercari headless + Facebook visible sheet) ─────────
    /// Owned here (not view @State) so dismissing Review & Publish mid-queue doesn't
    /// strand remaining jobs or leave held drafts undeleted (github issue #45).
    @Published var webAutofillQueue: [CrossPostJob] = []
    /// Facebook requires a visible sheet (unlike Mercari's headless pill). Presented from
    /// MainView, mirroring globalMercariJob, so it isn't torn down with Review & Publish.
    @Published var activeAutofillJob: CrossPostJob? = nil

    // ── Internal tracking ───────────────────────────────────────────────────
    private var activeUploadCount = 0
    private var processTask: Task<Void, Never>?
    private var processingTaskId = UUID()
    private var publishTaskId = UUID()

    // ── Throttled change notifications (perf) ───────────────────────────────
    private var lastChangeNotify: Date = .distantPast
    private var pendingChangeNotify: Task<Void, Never>?
    private let changeNotifyInterval: TimeInterval = 0.15

    /// Shared by uploadProgress/uploadStatuses/processProgress/processStatuses/
    /// processCurrentIndex's setters. Coalesces however many ticks land within the window
    /// into a single objectWillChange, so views like BulkListingOverviewView — which hold
    /// this object just to call its methods, not to display these properties — don't
    /// reconstruct their whole body (and the drafts List inside it) on every single tick.
    private func scheduleThrottledChangeNotify() {
        guard pendingChangeNotify == nil else { return }
        let elapsed = Date().timeIntervalSince(lastChangeNotify)
        let delay = max(0, changeNotifyInterval - elapsed)
        pendingChangeNotify = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self else { return }
            self.lastChangeNotify = Date()
            self.objectWillChange.send()
            self.pendingChangeNotify = nil
        }
    }

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
    /// Safe to discard the removed Storage path here — the active draft hasn't started
    /// its background upload yet, so it never has one.
    func removePhotoFromActiveDraft(assetId: String, modelContext: ModelContext) {
        guard let id = activeDraftID,
              let draft = (try? modelContext.fetch(FetchDescriptor<Item>()))?.first(where: { $0.id == id }) else { return }
        draft.removePhoto(assetId: assetId)
        if draft.sourceAssetIdentifiers.isEmpty {
            deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
            activeDraftID = nil
        }
        try? modelContext.save()
    }
    
    /// Deletes a draft from the local database, Firestore, and deletes uploaded images from Storage.
    /// Only ever safe to call on an item that hasn't been published — see the guard below.
    func deleteDraftLocallyAndCloud(draft: Item, modelContext: ModelContext) {
        // CRITICAL: never let a draft-discard action touch a listing that's already live.
        // draft.firestoreListingId is the SAME id as the published Firestore document, and
        // Firestore rules only check ownership on delete (not status) — nothing server-side
        // stops this from hard-deleting a real, active listing (+ its Storage photos) while
        // leaving it posted on eBay/Mercari untouched. This function is meant for discarding
        // an unpublished draft; once publishDrafts sets publishedAt, this item is a live
        // listing masquerading as a leftover local draft (kept alive so a queued cross-post
        // job can read its photos) and must be left alone — checkAndStartNextWebJob() owns
        // cleaning it up once the cross-post queue drains. Deleting a real listing has to go
        // through ProfileView.deleteListing, which also tears down cross-posted platforms.
        guard draft.publishedAt == nil else {
            print("[UploadManager] Refusing to delete \(draft.id) — already published at \(draft.publishedAt!). It's cleaned up automatically once cross-posting finishes.")
            return
        }
        let listingId = draft.firestoreListingId
        let userId = Auth.auth().currentUser?.uid
        cleanupError = nil
        // Mark immediately (synchronously) so any in-flight background upload/recognition
        // Task for this draft (which may be suspended mid-`await` right now) bails out on
        // its next check instead of touching the model after it's deleted below, and so
        // list views can exclude it from their next render.
        deletedDraftIDs.insert(draft.id)
        Item.deletedIDs.insert(draft.id)

        // Wipe the photo data on the object itself WHILE it's still fully valid — i.e.
        // before it's actually deleted from the context below. SwiftData's @Model macro
        // backs property access with Swift's Observation framework, so this mutation is
        // picked up synchronously by any view reading these properties. That matters
        // because tracking "this draft is deleted" in an external set (Item.deletedIDs,
        // above) turned out not to be sufficient on its own: a SwiftUI row can still hold
        // a stale reference to this exact object (e.g. mid removal-animation) and re-read
        // ITS properties directly, bypassing any lookup keyed by `id` — and once an object
        // is truly detached from its context, EVERY property on it becomes unreadable, not
        // just the externally-stored photosData that was actually crashing (confirmed by
        // even `id` itself faulting once detached). Clearing sourceAssetIdentifiers here
        // means every current photo-rendering call site — which all gate on
        // sourceAssetIdentifiers being non-empty before ever calling image(for:) — simply
        // has nothing to iterate, so photosData is never touched again for this object,
        // regardless of whether some other reference to it is still floating around a view.
        draft.sourceAssetIdentifiers = []
        draft.photosData = []

        // Defer the actual SwiftData delete + save by one run loop tick — belt-and-braces
        // on top of the clearing above, so nothing else races the removal animation either.
        DispatchQueue.main.async { [weak modelContext] in
            guard let modelContext else { return }
            modelContext.delete(draft)
            try? modelContext.save()
        }

        guard userId != nil else { return }

        // Perform background cleanups if uploaded. deleteListing itself deletes Storage
        // photos first, then the Firestore document — so a failed Storage cleanup leaves
        // the document in place as a retry marker instead of orphaning the photos for good.
        if let listingId = listingId {
            Task { [weak self] in
                print("[UploadManager] Cleaning up Cloud files for discarded draft \(listingId)")
                do {
                    try await ListingRepository.shared.deleteListing(id: listingId)
                } catch {
                    print("[UploadManager] Cleanup failed for \(listingId): \(error)")
                    self?.cleanupError = "Couldn't fully delete this draft's photos. It may still be using storage — please try deleting it again."
                }
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
            // Paired with assetId (not a bare [UIImage]) so a fetch failure partway through
            // doesn't shift later images out of sync with the assetId they belong to.
            var images: [(assetId: String, image: UIImage)] = []
            for assetId in assetIdentifiers {
                guard !deletedDraftIDs.contains(draftID) else {
                    print("[UploadManager] Draft \(draftID) deleted mid-upload — aborting")
                    return
                }
                if let img = draft.image(for: assetId) {
                    images.append((assetId, img))
                } else if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                    images.append((assetId, img))
                } else {
                    print("[UploadManager] WARNING: Could not fetch image for asset \(assetId)")
                }
            }
            guard !deletedDraftIDs.contains(draftID) else {
                print("[UploadManager] Draft \(draftID) deleted mid-upload — aborting before network upload")
                return
            }
            print("[UploadManager] Fetched \(images.count)/\(assetIdentifiers.count) images")

            var photoPathsByAsset: [String: String] = [:]
            for (imgIdx, entry) in images.enumerated() {
                var success = false
                var attempts = 0
                let maxAttempts = 5
                var delaySeconds = 2.0

                while !success && attempts < maxAttempts && !Task.isCancelled {
                    attempts += 1
                    do {
                        print("[UploadManager] Uploading image \(imgIdx+1)/\(images.count) for \(draft.id) (attempt \(attempts))...")
                        let path = try await StorageService.shared.uploadListingImage(
                            image: entry.image, index: imgIdx, userId: userId, listingId: listingId
                        )
                        photoPathsByAsset[entry.assetId] = path
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

            let failed = photoPathsByAsset.count < images.count
            if !deletedDraftIDs.contains(draftID) {
                draft.firebasePhotoPathsByAsset = photoPathsByAsset
                try? modelContext.save()
                print("[UploadManager] Upload complete for \(draftID): \(photoPathsByAsset.count) paths saved")
            } else {
                print("[UploadManager] Draft \(draftID) deleted mid-upload — discarding \(photoPathsByAsset.count) uploaded paths")
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
    /// (processedAt is set) with an unchanged photo set (processedPhotoIDs), so
    /// re-tapping "Process" never re-bills the AI unless photos were added/removed.
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

                // Skip Gemini if this draft was already processed in a prior run AND its
                // photo set is unchanged — see DraftAIProcessingPolicy.shouldSkip for the
                // exact semantics (set comparison, nil-snapshot handling).
                let skipAI = DraftAIProcessingPolicy.shouldSkip(
                    processedAt: draft.processedAt,
                    processedPhotoIDs: draft.processedPhotoIDs,
                    currentPhotoIDs: draft.sourceAssetIdentifiers
                )
                if draft.processedAt != nil && !skipAI {
                    print("[UploadManager] Re-processing \(draft.id) — photos changed since last AI run")
                }
                if skipAI {
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
                    // Any non-empty userEditedTitle is a deliberate user signal now: vision
                    // output is never prefilled into the field (it's an explicit-accept chip),
                    // so the old `!= visionTitle` exclusion — which guarded against the prefill
                    // leaking through as a fake user title — no longer applies. An unaccepted
                    // vision suggestion simply leaves the title empty here (no hint sent).
                    let hasUserTitle = draft.userEditedTitle != nil && !draft.userEditedTitle!.isEmpty
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
                        userTitle: hasUserTitle ? draft.userEditedTitle : nil,
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
                    draft.processedPhotoIDs = draft.sourceAssetIdentifiers
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
        guard let listingId = draft.firestoreListingId,
              !Item.deletedIDs.contains(draft.id) else { return }

        // Snapshot every attribute NOW, before the Task body runs. The Task executes a
        // beat later on the main actor, and the draft can be deleted in that gap
        // (publish cleanup, swipe delete, undo-toast delete) — reading any attribute on
        // a detached SwiftData object then traps with "backing data was detached from a
        // context without resolving attribute faults" (seen in the wild on \Item.tags).
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
            data["shippingInfo"] = (try? Firestore.Encoder().encode(shippingInfo)) ?? [:]
        }

        Task {
            // Expected to fail when no Firestore draft exists yet — suppress noise
            try? await ListingRepository.shared.updateListingData(listingId: listingId, data: data)
        }
    }

    // MARK: – Phase 2.5: Inline photo upload (fallback for app-restart scenario)

    /// Uploads photos for a draft that missed the background upload (e.g. after app restart).
    /// Uses the pre-generated listing UUID — no Firestore round-trip needed.
    @discardableResult
    private func uploadPhotosForDraft(_ draft: Item, userId: String, modelContext: ModelContext) async -> [String] {
        if draft.firestoreListingId == nil {
            draft.firestoreListingId = UUID().uuidString
            try? modelContext.save()
        }
        let listingId = draft.firestoreListingId!
        print("[UploadManager] Inline upload starting for \(draft.id) → listing \(listingId)")

        var pathsByAsset: [String: String] = draft.firebasePhotoPathsByAsset ?? [:]
        for (idx, assetId) in draft.sourceAssetIdentifiers.enumerated() {
            if pathsByAsset[assetId] != nil { continue } // already uploaded
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
                pathsByAsset[assetId] = path
                print("[UploadManager] Inline uploaded photo \(idx): \(path)")
            } catch {
                print("[UploadManager] Inline upload failed for photo \(idx): \(error)")
            }
        }

        draft.firebasePhotoPathsByAsset = pathsByAsset
        try? modelContext.save()
        return draft.orderedFirebasePhotoPaths
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
                var photoPaths = draft.orderedFirebasePhotoPaths
                if photoPaths.count < draft.sourceAssetIdentifiers.count {
                    print("[UploadManager] Incomplete photo paths (\(photoPaths.count)/\(draft.sourceAssetIdentifiers.count)) for \(draft.id) — uploading now")
                    photoPaths = await uploadPhotosForDraft(draft, userId: userId, modelContext: modelContext)
                }

                guard !photoPaths.isEmpty else {
                    print("[UploadManager] Skipping \(draft.id) — photo upload failed")
                    failedCount += 1
                    continue
                }

                // Publishing proceeds with whatever subset uploaded (never zero, per the guard
                // above), but the user should know some photos silently failed rather than
                // finding out only by noticing a thin listing later (github issue #56).
                if photoPaths.count < draft.sourceAssetIdentifiers.count {
                    let title = draft.userEditedTitle ?? draft.aiSuggestedTitle ?? "Untitled"
                    let msg = "\"\(title.prefix(40))\" published with \(photoPaths.count) of \(draft.sourceAssetIdentifiers.count) photos — one or more failed to upload."
                    photoUploadWarning = photoUploadWarning.map { "\($0)\n\n\(msg)" } ?? msg
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
                listing.condition = ItemCondition(rawValue: draft.condition ?? "") ?? .good
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
                    // Marks this Item as a live listing everywhere delete flows check it — see
                    // deleteDraftLocallyAndCloud's guard. Set before branching so it's true even
                    // in the kept-alive-for-cross-post case below, which can leave the Item
                    // sitting in SwiftData (still isDraft, still full of photos) for as long as
                    // the web-autofill queue takes to drain.
                    draft.publishedAt = Date()
                    if pendingAutofillJobsCount > 0 {
                        // Web cross-post jobs were selected — keep the SwiftData item alive
                        // until runPublishContinuationIfReady has snapshotted its metadata +
                        // Storage photo paths into plain-value CrossPostJobs (the jobs
                        // themselves no longer reference the item).
                        // checkAndStartNextWebJob() deletes these when the queue empties.
                        publishedPendingDeletionIDs.insert(draft.id)
                    } else {
                        // See deleteDraftLocallyAndCloud — mark and clear before deleting so
                        // no stale view reference can read photosData after this point. Only
                        // safe here because this is the branch where nothing else (no
                        // pending cross-post job) still needs the photos.
                        Item.deletedIDs.insert(draft.id)
                        draft.sourceAssetIdentifiers = []
                        draft.photosData = []
                        modelContext.delete(draft)
                    }
                    // This draft is now a live listing — drop it from the session set so the
                    // discard-on-exit path doesn't even attempt deleteDraftLocallyAndCloud on it
                    // (that function's own publishedAt guard is the actual backstop; Firestore
                    // rules do NOT check status on delete, only ownership, so nothing server-side
                    // protects a published listing from this path).
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

    // MARK: – Web autofill queue

    /// Starts the next queued web-autofill cross-post job (Mercari's headless pill, or
    /// Facebook's visible sheet), or — once the queue is empty — deletes drafts that were
    /// kept alive so the jobs could read their photos, and hands off to CrossPostStatusView.
    /// Called from MainView (both on Mercari pill completion and Facebook sheet dismissal),
    /// so the queue keeps advancing even if Review & Publish has already been dismissed.
    func checkAndStartNextWebJob(modelContext: ModelContext) {
        guard activeAutofillJob == nil, globalMercariJob == nil else { return }
        if !webAutofillQueue.isEmpty {
            let nextJob = webAutofillQueue.removeFirst()
            pendingAutofillJobsCount = webAutofillQueue.count + 1
            if nextJob.platform == "mercari" {
                // Mercari runs headlessly — shown as a pill above the tab bar via MainView.
                globalMercariJob = nextJob
                onMercariJobComplete = { [weak self] in self?.checkAndStartNextWebJob(modelContext: modelContext) }
            } else {
                // Facebook and other web platforms require a visible sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.activeAutofillJob = nextJob
                }
            }
        } else {
            pendingAutofillJobsCount = 0
            // All web cross-posting jobs finished — now safe to delete SwiftData items
            // that were held alive so startPosting() could read their photos.
            let pendingIDs = publishedPendingDeletionIDs
            if !pendingIDs.isEmpty {
                let items = (try? modelContext.fetch(FetchDescriptor<Item>()))?
                    .filter { pendingIDs.contains($0.id) } ?? []
                for item in items {
                    // Mark and clear before deleting — see deleteDraftLocallyAndCloud. This
                    // delete didn't go through that function (these items were kept alive
                    // deliberately for the cross-post jobs, which have now all finished), so
                    // nothing else marks or clears them.
                    Item.deletedIDs.insert(item.id)
                    item.sourceAssetIdentifiers = []
                    item.photosData = []
                    modelContext.delete(item)
                }
                try? modelContext.save()
                publishedPendingDeletionIDs.removeAll()
            }
            // Close the results sheet (if still open) and open CrossPostStatusView globally.
            // Publish-flow only: profile-initiated cross-posts don't set
            // crossPostStatusPending and get their own drain callback instead.
            if crossPostStatusPending {
                showResultsOverview = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.showCrossPostStatus = true
                }
            }
            let drained = onWebQueueDrained
            onWebQueueDrained = nil
            drained?()
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
        crossPostError = nil
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

        let candidates = (classifyReq.results ?? []).map {
            VisionTitlePolicy.Candidate(
                identifier: $0.identifier,
                confidence: $0.confidence,
                passesPrecisionFilter: $0.hasMinimumRecall(0.01, forPrecision: 0.9)
            )
        }
        let ocrText = textReq.results?
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence > 0.7 && $0.string.count > 2 }
            .first?.string
        return VisionTitlePolicy.suggestion(classifications: candidates, ocrText: ocrText)
    }
}

/// Pure selection policy for the on-device vision title suggestion. Factored out of
/// `UploadManager.generateVisionTitle` so it's unit-testable (VisionTitlePolicyTests)
/// without constructing Vision framework observation objects.
///
/// Order: specific classification → OCR text → nil. A confident, specific label
/// ("Compact Disc") is the best suggestion; OCR text (brand names, model numbers) is a
/// solid second; and no suggestion beats a vague one — "Structure" helps nobody.
enum VisionTitlePolicy {
    /// Classification labels below this confidence produce no classification suggestion.
    /// Tunable: raise for fewer/safer suggestions, lower for more coverage.
    static let minClassificationConfidence: Float = 0.6

    /// Broad taxonomy ancestors that are never useful as a listing title. Vision's
    /// taxonomy is hierarchical, so confidence is systematically highest at generic
    /// nodes ("Structure" always outscores "Compact Disc" on confidence) — these are
    /// excluded outright rather than threshold-tuned away. Extend freely; identifiers
    /// are compared lowercased.
    static let genericLabelDenylist: Set<String> = [
        "structure", "material", "object", "objects", "indoor", "outdoor",
        "furniture", "container", "art", "design", "pattern", "texture",
        "still_life", "machine", "device", "instrument", "equipment", "tool",
        "product", "decoration", "adult", "person", "people", "room", "wall",
        "floor", "table", "text", "document", "rectangle", "circle", "line",
    ]

    /// Words that describe materials, surfaces, or photo composition rather than a
    /// sellable subject. An identifier whose tokens are ALL from this set is rejected
    /// even when compound — "wood_processed" (a photo's wooden background, reported
    /// 2026-07-14) is exactly as useless as "structure", and the compound-identifier
    /// preference below would otherwise actively favor it. Token-level so future
    /// taxonomy variants ("metal_brushed", "fabric_woven") are covered without
    /// enumerating every combination; "compact_disc" survives because "compact" and
    /// "disc" aren't material words.
    static let genericTokens: Set<String> = [
        "wood", "processed", "material", "metal", "plastic", "fabric", "paper",
        "cardboard", "glass", "stone", "concrete", "brick", "leather", "textile",
        "surface", "background", "texture", "pattern", "grain", "brushed",
        "woven", "polished", "painted", "abstract", "closeup", "macro", "blur",
        "light", "dark", "shadow",
    ]

    /// A Vision classification observation reduced to what the policy needs.
    struct Candidate {
        /// Raw Vision taxonomy identifier, e.g. "compact_disc".
        let identifier: String
        let confidence: Float
        /// Result of `hasMinimumRecall(0.01, forPrecision: 0.9)` — Apple's recommended
        /// filter for this hierarchical taxonomy.
        let passesPrecisionFilter: Bool
    }

    /// True when the identifier names a sellable subject rather than a generic
    /// concept, material, or photo-composition term.
    static func isDescriptiveIdentifier(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        guard !genericLabelDenylist.contains(id) else { return false }
        let tokens = id.split(separator: "_").map(String.init)
        guard !tokens.isEmpty else { return false }
        return !tokens.allSatisfy { genericTokens.contains($0) }
    }

    static func suggestion(classifications: [Candidate], ocrText: String?) -> String? {
        let eligible = classifications.filter {
            $0.passesPrecisionFilter
                && $0.confidence >= minClassificationConfidence
                && isDescriptiveIdentifier($0.identifier)
        }
        // Compound identifiers ("hot_air_balloon") outrank single words: in a
        // hierarchical taxonomy, multi-word identifiers are almost always leaves —
        // i.e. the descriptive answer. Confidence breaks ties within each group.
        if let best = eligible.max(by: { lhs, rhs in
            let lCompound = lhs.identifier.contains("_")
            let rCompound = rhs.identifier.contains("_")
            if lCompound != rCompound { return rCompound }
            return lhs.confidence < rhs.confidence
        }) {
            return humanReadableLabel(best.identifier)
        }
        if let ocr = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
            return ocr.capitalized
        }
        return nil
    }

    /// Turns a Vision taxonomy identifier (lowercase, often underscore-delimited, e.g.
    /// "hot_air_balloon") into a clean title-cased phrase ("Hot Air Balloon").
    static func humanReadableLabel(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
