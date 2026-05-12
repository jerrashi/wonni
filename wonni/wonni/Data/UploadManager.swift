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
    @Published var draftDescriptions: [UUID: String?] = [:]

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
        draftDescriptions = [:]
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

                    // 2. Pre-generate listing ID so photos go straight to the permanent path
                    let listingId = UUID().uuidString
                    var photoPaths: [String] = []
                    for (imgIdx, image) in images.enumerated() {
                        if let path = try? await StorageService.shared.uploadListingImage(
                            image: image, index: imgIdx, userId: userId, listingId: listingId
                        ) {
                            photoPaths.append(path)
                        }
                        let p = Double(imgIdx + 1) / Double(max(images.count, 1))
                        statuses[draft.id] = .uploading(p * 0.7)
                        overallProgress = (Double(index) + p * 0.7) / Double(totalCount)
                    }

                    // 3. Build listing struct with pre-set ID
                    var listing = UserListing.newDraft(
                        userId: userId,
                        sourceAssetIdentifiers: draft.sourceAssetIdentifiers
                    )
                    listing.id = listingId
                    listing.photoPaths = photoPaths
                    listing.coverPhotoPath = photoPaths.first
                    listing.customTitle = draft.userEditedTitle ?? draft.aiSuggestedTitle

                    statuses[draft.id] = .uploading(0.8)
                    overallProgress = (Double(index) + 0.8) / Double(totalCount)

                    // 4. Run Gemini identification (first 3 images for speed)
                    if !images.isEmpty {
                        do {
                            let gemini = try await GeminiService.shared.identifyItem(images: Array(images.prefix(3)))
                            draft.aiSuggestedTitle = gemini.name
                            draft.aiSuggestedPrice = gemini.suggestedPrice
                            draft.aiSuggestedDescription = gemini.description

                            if listing.customTitle == nil { listing.customTitle = gemini.name }
                            listing.customDescription = gemini.description
                            listing.price = draft.userEditedPrice ?? gemini.suggestedPrice
                            listing.geminiIdentificationConfirmed = true
                        } catch {
                            print("[UploadManager] Gemini failed for draft \(draft.id): \(error)")
                        }
                    }

                    // 5. Persist to Firestore as active (not draft)
                    listing.status = .active
                    listing.publishedAt = Timestamp(date: Date())
                    let docId = try await ListingRepository.shared.saveDraft(listing)
                    draftListingIDs[draft.id] = docId

                    // 6. Save receipt data before deleting the SwiftData draft
                    if let firstAsset = draft.sourceAssetIdentifiers.first {
                        draftFirstAssetID[draft.id] = firstAsset
                    }
                    draftPrices[draft.id] = listing.price
                    draftDescriptions[draft.id] = listing.customDescription

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
        draftDescriptions.removeAll()
        uploadStartTime = nil
    }
}
