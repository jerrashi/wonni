//
//  UploadManager.swift
//  wonni
//

import Foundation
import SwiftUI
import SwiftData
import FirebaseAuth
import UIKit

enum DraftUploadStatus: Equatable {
    case pending
    case uploading(Double)
    case done
    case failed
}

@MainActor
class UploadManager: ObservableObject {
    @Published var isPillVisible = false
    @Published var showExpandedModal = false
    @Published var shouldReturnToRoot = false
    @Published var currentIndex = 0
    @Published var totalCount = 0
    @Published var overallProgress: Double = 0
    @Published var currentDraftName = ""
    @Published var statuses: [UUID: DraftUploadStatus] = [:]
    @Published var draftNames: [UUID: String] = [:]
    @Published var orderedDraftIDs: [UUID] = []
    @Published var uploadStartTime: Date? = nil
    @Published var uploadErrors: [UUID: String] = [:]
    @Published var uploadedAssetIDs: [String] = []
    @Published var showDeletePhotosPrompt = false
    // Receipt data — populated as each draft completes, survives SwiftData deletion
    @Published var draftFirstAssetID: [UUID: String] = [:]
    @Published var draftListingIDs: [UUID: String] = [:]
    @Published var draftPrices: [UUID: Double?] = [:]

    // Derived from elapsed time + linear progress — equivalent to bytes_remaining / upload_speed
    // but requires no byte-size measurement.
    var etaString: String? {
        guard let start = uploadStartTime,
              overallProgress > 0.05
        else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed * (1 - overallProgress) / overallProgress
        if remaining < 60 {
            return "~\(max(1, Int(remaining)))s"
        } else {
            return "~\(Int((remaining / 60).rounded(.up))) min"
        }
    }

    private var uploadTask: Task<Void, Never>?

    func startUpload(drafts: [Item], modelContext: ModelContext) {
        guard !drafts.isEmpty else { return }

        uploadTask?.cancel()
        totalCount = drafts.count
        currentIndex = 0
        overallProgress = 0
        isPillVisible = true
        statuses = [:]
        draftNames = [:]
        orderedDraftIDs = []
        uploadErrors = [:]
        uploadedAssetIDs = []
        showDeletePhotosPrompt = false
        draftFirstAssetID = [:]
        draftListingIDs = [:]
        draftPrices = [:]
        uploadStartTime = Date()

        for (i, draft) in drafts.enumerated() {
            statuses[draft.id] = .pending
            draftNames[draft.id] = draft.userEditedTitle ?? draft.aiSuggestedTitle ?? "Draft \(i + 1)"
            orderedDraftIDs.append(draft.id)
        }

        uploadTask = Task {
            guard let userId = Auth.auth().currentUser?.uid else {
                for id in orderedDraftIDs {
                    uploadErrors[id] = "Not signed in."
                    statuses[id] = .failed
                }
                overallProgress = 1.0
                return
            }

            for (index, draft) in drafts.enumerated() {
                guard !Task.isCancelled else { break }

                currentIndex = index + 1
                currentDraftName = draftNames[draft.id] ?? "Draft \(index + 1)"
                statuses[draft.id] = .uploading(0)

                do {
                    // 1. Fetch full-resolution images from Photos library
                    var images: [UIImage] = []
                    for assetId in draft.sourceAssetIdentifiers {
                        if let img = await PhotoAsset(identifier: assetId).fullResolutionImage() {
                            images.append(img)
                        }
                    }

                    // 2. Upload each image to Firebase Storage
                    var photoPaths: [String] = []
                    for (imgIdx, image) in images.enumerated() {
                        if let path = try? await StorageService.shared.uploadTempImage(image: image) {
                            photoPaths.append(path)
                        }
                        let p = Double(imgIdx + 1) / Double(max(images.count, 1))
                        statuses[draft.id] = .uploading(p * 0.7)
                        overallProgress = (Double(index) + p * 0.7) / Double(totalCount)
                    }

                    // 3. Build draft listing struct
                    var listing = UserListing.newDraft(
                        userId: userId,
                        sourceAssetIdentifiers: draft.sourceAssetIdentifiers
                    )
                    listing.photoPaths = photoPaths
                    listing.coverPhotoPath = photoPaths.first
                    listing.customTitle = draft.userEditedTitle ?? draft.aiSuggestedTitle

                    statuses[draft.id] = .uploading(0.8)
                    overallProgress = (Double(index) + 0.8) / Double(totalCount)

                    // 4. Run Gemini identification (first 3 images for speed)
                    if !images.isEmpty,
                       let gemini = try? await GeminiService.shared.identifyItem(images: Array(images.prefix(3))) {
                        // Write AI results back to SwiftData for PublishedListingsView
                        draft.aiSuggestedTitle = gemini.name
                        draft.aiSuggestedPrice = gemini.suggestedPrice
                        draft.aiSuggestedDescription = gemini.description

                        if listing.customTitle == nil { listing.customTitle = gemini.name }
                        listing.customDescription = gemini.description
                        // Respect user-set price — only use Gemini price if user hasn't specified one
                        listing.price = draft.userEditedPrice ?? gemini.suggestedPrice
                    }

                    // 5. Persist to Firestore; capture doc ID for receipt-view edits
                    let docId = try await ListingRepository.shared.saveDraft(listing)
                    draftListingIDs[draft.id] = docId

                    // 6. Save receipt data before deleting the SwiftData draft
                    if let firstAsset = draft.sourceAssetIdentifiers.first {
                        draftFirstAssetID[draft.id] = firstAsset
                    }
                    draftPrices[draft.id] = listing.price

                    statuses[draft.id] = .done
                    uploadedAssetIDs.append(contentsOf: draft.sourceAssetIdentifiers)
                    modelContext.delete(draft)
                    try? modelContext.save()
                    overallProgress = Double(index + 1) / Double(totalCount)

                } catch {
                    uploadErrors[draft.id] = error.localizedDescription
                    statuses[draft.id] = .failed
                    print("[UploadManager] draft \(draft.id) failed: \(error)")
                }
            }

            let allFinished = statuses.values.allSatisfy {
                switch $0 { case .done, .failed: return true; default: return false }
            }
            if allFinished && !Task.isCancelled {
                if !uploadedAssetIDs.isEmpty {
                    showDeletePhotosPrompt = true
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isPillVisible = false
            }
        }
    }

    func cancel() {
        uploadTask?.cancel()
        uploadTask = nil
        isPillVisible = false
        statuses.removeAll()
        orderedDraftIDs.removeAll()
        uploadErrors.removeAll()
        uploadedAssetIDs.removeAll()
        draftFirstAssetID.removeAll()
        draftListingIDs.removeAll()
        draftPrices.removeAll()
        uploadStartTime = nil
    }
}
