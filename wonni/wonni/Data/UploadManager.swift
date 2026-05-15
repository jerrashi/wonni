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

    // ── Photo Upload Phase ─────────────────────────────────────────────────
    /// True while any photos are still uploading to Firebase Storage.
    @Published var isUploadingPhotos = false
    /// 0.0 – 1.0 across all queued drafts.
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
    /// Set to true when all items finish processing → triggers navigation to results view.
    @Published var showProcessResults = false
    /// The ordered list of Item IDs that finished processing (for display).
    @Published var processedItemIDs: [UUID] = []
    /// Item IDs where Gemini failed (e.g. 429 / quota exhausted).
    @Published var processingFailedIDs: Set<UUID> = []

    // ── Legacy / Pill visibility (kept for UploadPillView compatibility) ────
    @Published var isPillVisible = false
    @Published var isProcessPillVisible = false

    // ── Internal tracking ───────────────────────────────────────────────────
    /// Maps draft UUID → its Firebase Storage photo paths (set when upload finishes).
    private var draftPhotoPaths: [UUID: [String]] = [:]
    /// Counts how many uploads are in-flight so we know when they're all done.
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

    // MARK: – Phase 1: Background Photo Upload

    /// Call this immediately when the user taps "+" to add a draft.
    func startBackgroundUpload(draft: Item, modelContext: ModelContext) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        guard !draft.sourceAssetIdentifiers.isEmpty else { return }

        // Mark upload state
        if !isUploadingPhotos {
            isUploadingPhotos = true
            isPillVisible = true
            uploadStartTime = Date()
            uploadProgress = 0
        }
        activeUploadCount += 1
        uploadStatuses[draft.id] = .pending

        Task {
            uploadStatuses[draft.id] = .uploading(0)

            // Fetch full-res images from Photos library
            var images: [UIImage] = []
            for assetId in draft.sourceAssetIdentifiers {
                if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                    images.append(img)
                }
            }

            // Upload each image; update per-draft progress
            let listingId = UUID().uuidString
            var photoPaths: [String] = []
            for (imgIdx, image) in images.enumerated() {
                if let path = try? await StorageService.shared.uploadListingImage(
                    image: image, index: imgIdx, userId: userId, listingId: listingId
                ) {
                    photoPaths.append(path)
                }
                let p = Double(imgIdx + 1) / Double(max(images.count, 1))
                uploadStatuses[draft.id] = .uploading(p)
                recalcUploadProgress()
            }

            // Store paths on the SwiftData model
            draft.firebasePhotoPaths = photoPaths
            draftPhotoPaths[draft.id] = photoPaths
            uploadStatuses[draft.id] = .done
            uploadedAssetIDs.append(contentsOf: draft.sourceAssetIdentifiers)
            try? modelContext.save()
            recalcUploadProgress()

            activeUploadCount -= 1
            if activeUploadCount == 0 {
                isUploadingPhotos = false
                // Keep pill for 1.5s then hide
                if !uploadedAssetIDs.isEmpty { showDeletePhotosPrompt = true }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                isPillVisible = false
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

    /// Returns true when all currently registered drafts have finished uploading.
    func areAllUploadsFinished() -> Bool {
        guard !uploadStatuses.isEmpty else { return true }
        return !isUploadingPhotos
    }

    // MARK: – Phase 2: AI Processing

    /// Runs Gemini on each draft. Called from BulkListingOverviewView "Process" button.
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

        for draft in drafts { processStatuses[draft.id] = .pending }

        processTask = Task {
            for (index, draft) in drafts.enumerated() {
                guard !Task.isCancelled else { break }

                processCurrentIndex = index + 1
                processStatuses[draft.id] = .uploading(0)

                // Load images (from Photos; they're already uploaded to Storage but we need UIImage for Gemini)
                var images: [UIImage] = []
                for assetId in draft.sourceAssetIdentifiers {
                    if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                        images.append(img)
                    }
                }

                    do {
                        let gemini = try await GeminiService.shared.identifyItem(
                            images: Array(images.prefix(3)),
                            userTitle: draft.userEditedTitle,
                            userPrice: draft.userEditedPrice,
                            userDescription: draft.userEditedDescription
                        )
                        // Only overwrite fields the user hasn't set
                        if draft.aiSuggestedTitle == nil { draft.aiSuggestedTitle = gemini.name }
                        if draft.aiSuggestedPrice == nil { draft.aiSuggestedPrice = gemini.suggestedPrice }
                        if draft.aiSuggestedDescription == nil { draft.aiSuggestedDescription = gemini.description }
                        // Always store AI shipping estimates (user hasn't filled these in yet)
                        draft.weightLbs = draft.weightLbs ?? gemini.weightLbs
                        draft.lengthIn  = draft.lengthIn  ?? gemini.lengthIn
                        draft.widthIn   = draft.widthIn   ?? gemini.widthIn
                        draft.heightIn  = draft.heightIn  ?? gemini.heightIn
                    } catch {
                        print("[UploadManager] Gemini error for \(draft.id): \(error)")
                        processingFailedIDs.insert(draft.id)
                    }

                processStatuses[draft.id] = .done
                processedItemIDs.append(draft.id)
                processProgress = Double(index + 1) / Double(processTotalCount)
                try? modelContext.save()
            }

            isProcessing = false

            // Brief pause, then collapse pill and navigate to results
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isProcessPillVisible = false
            showProcessResults = true
        }
    }

    // MARK: – Phase 3: Publish to Firestore

    /// Posts finished+reviewed drafts as active listings.
    func publishDrafts(drafts: [Item], modelContext: ModelContext) {
        Task {
            guard let userId = Auth.auth().currentUser?.uid else { return }

            for draft in drafts {
                guard let photoPaths = draft.firebasePhotoPaths, !photoPaths.isEmpty else { continue }

                var listing = UserListing.newDraft(
                    userId: userId,
                    sourceAssetIdentifiers: draft.sourceAssetIdentifiers
                )
                listing.status = .active
                listing.createdAt = Timestamp(date: Date())
                listing.photoPaths = photoPaths
                listing.coverPhotoPath = photoPaths.first
                listing.tags = draft.tags
                listing.personalNote = draft.personalNote
                listing.customTitle = draft.userEditedTitle ?? draft.aiSuggestedTitle
                listing.customDescription = draft.userEditedDescription ?? draft.aiSuggestedDescription
                listing.price = draft.userEditedPrice ?? draft.aiSuggestedPrice
                listing.geminiIdentificationConfirmed = true

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
                listing.publishedAt = Timestamp(date: Date())

                do {
                    _ = try await ListingRepository.shared.saveDraft(listing)
                    modelContext.delete(draft)
                } catch {
                    print("[UploadManager] Publish error for \(draft.id): \(error)")
                }
            }
            try? modelContext.save()
            showProcessResults = false
            shouldReturnToRoot = true
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
        showProcessResults = false
        uploadProgress = 0
        uploadStatuses.removeAll()
        uploadedAssetIDs.removeAll()
        processStatuses.removeAll()
        processedItemIDs.removeAll()
        processingFailedIDs.removeAll()
        shouldReturnToRoot = false
        uploadStartTime = nil
        activeUploadCount = 0
        draftPhotoPaths.removeAll()
    }
}
