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
    @Published var processedItemIDs: [UUID] = []
    @Published var processingFailedIDs: Set<UUID> = []
    @Published var processQueuedIDs: [UUID] = []

    // ── Publish Phase ───────────────────────────────────────────────────────
    @Published var isPublishing = false
    @Published var publishError: String? = nil
    /// IDs of SwiftData drafts that have been published to Firestore but whose
    /// deletion is deferred until all cross-posting jobs for the session complete.
    @Published var publishedPendingDeletionIDs: Set<UUID> = []

    // ── Legacy / Pill visibility ─────────────────────────────────────────────
    @Published var isPillVisible = false
    @Published var isProcessPillVisible = false

    // ── Internal tracking ───────────────────────────────────────────────────
    private var activeUploadCount = 0
    private var processTask: Task<Void, Never>?

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
        guard let userId = Auth.auth().currentUser?.uid else {
            modelContext.delete(draft)
            try? modelContext.save()
            return
        }
        
        // 1. Delete from SwiftData context
        modelContext.delete(draft)
        try? modelContext.save()
        
        // 2. Perform background cleanups if uploaded
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

        Task {
            uploadStatuses[draft.id] = .uploading(0)

            print("[UploadManager] Fetching \(draft.sourceAssetIdentifiers.count) images for \(draft.id)...")
            var images: [UIImage] = []
            for assetId in draft.sourceAssetIdentifiers {
                if let img = draft.image(for: assetId) {
                    images.append(img)
                } else if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                    images.append(img)
                } else {
                    print("[UploadManager] WARNING: Could not fetch image for asset \(assetId)")
                }
            }
            print("[UploadManager] Fetched \(images.count)/\(draft.sourceAssetIdentifiers.count) images")

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

            draft.firebasePhotoPaths = photoPaths
            try? modelContext.save()
            print("[UploadManager] Upload complete for \(draft.id): \(photoPaths.count) paths saved")

            let failed = photoPaths.count < images.count
            uploadStatuses[draft.id] = failed ? .failed : .done
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
        processStatuses = [:]
        processedItemIDs = []
        processingFailedIDs = []
        processQueuedIDs = drafts.map { $0.id }

        for draft in drafts { processStatuses[draft.id] = .pending }

        processTask = Task {
            for (index, draft) in drafts.enumerated() {
                guard !Task.isCancelled else { break }

                processCurrentIndex = index + 1

                // Skip Gemini if this draft was already processed in a prior run
                if draft.processedAt != nil {
                    print("[UploadManager] Skipping Gemini for \(draft.id) — already processed")
                    processedItemIDs.append(draft.id)
                    processStatuses[draft.id] = .done
                    processProgress = Double(index + 1) / Double(processTotalCount)
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
                await MainActor.run { try? modelContext.save() }
            }

            isProcessing = false
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isProcessPillVisible = false
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
    func publishDrafts(drafts: [Item], modelContext: ModelContext) {
        guard !drafts.isEmpty else { return }
        print("[UploadManager] publishDrafts called for \(drafts.count) items")
        isPublishing = true
        publishError = nil

        Task {
            defer { isPublishing = false }

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
                        modelContext.delete(draft)
                    }
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
                if pendingAutofillJobsCount == 0 {
                    shouldReturnToRoot = true
                }
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
        isProcessing = false
        isPublishing = false
        showProcessResults = false
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
    }

    // MARK: – On-device Vision Recognition

    func runLocalRecognition(draft: Item, modelContext: ModelContext) {
        guard let assetId = draft.sourceAssetIdentifiers.first else { return }
        let draftRef = draft
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
        let topText = textReq.results?
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence > 0.7 && $0.string.count > 2 }
            .first?.string

        // Fall back to classification category
        let topCategory = classifyReq.results?
            .filter { $0.confidence > 0.4 }
            .prefix(2)
            .map { $0.identifier }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        var parts: [String] = []
        if let t = topText, !t.isEmpty { parts.append(t) }
        if let c = topCategory, !c.isEmpty, topText == nil { parts.append(c) }
        return parts.isEmpty ? nil : parts.joined(separator: " ").capitalized
    }
}
