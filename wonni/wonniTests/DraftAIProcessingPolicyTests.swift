//
//  DraftAIProcessingPolicyTests.swift
//  wonniTests
//

import XCTest
@testable import wonni

final class DraftAIProcessingPolicyTests: XCTestCase {
    private let processed = Date()

    func test_neverProcessed_doesNotSkip() {
        XCTAssertFalse(DraftAIProcessingPolicy.shouldSkip(
            processedAt: nil, processedPhotoIDs: nil, currentPhotoIDs: ["a", "b"]
        ))
        // Even with a snapshot present, no processedAt means the AI never ran.
        XCTAssertFalse(DraftAIProcessingPolicy.shouldSkip(
            processedAt: nil, processedPhotoIDs: ["a", "b"], currentPhotoIDs: ["a", "b"]
        ))
    }

    func test_processedWithNilSnapshot_skips() {
        // Pre-migration drafts (processed before processedPhotoIDs existed) must not re-bill.
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: nil, currentPhotoIDs: ["a", "b"]
        ))
    }

    func test_unchangedPhotos_skips() {
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: ["a", "b"], currentPhotoIDs: ["a", "b"]
        ))
    }

    func test_reorderedPhotos_skips() {
        // Changing the cover photo (reorder) doesn't change the AI's input set.
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: ["a", "b", "c"], currentPhotoIDs: ["c", "a", "b"]
        ))
    }

    func test_addedPhoto_reprocesses() {
        XCTAssertFalse(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: ["a", "b"], currentPhotoIDs: ["a", "b", "c"]
        ))
    }

    func test_removedPhoto_reprocesses() {
        XCTAssertFalse(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: ["a", "b"], currentPhotoIDs: ["a"]
        ))
    }

    func test_swappedPhoto_reprocesses() {
        // Same count, different photo — the case a count-based check would miss.
        XCTAssertFalse(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: ["a", "b"], currentPhotoIDs: ["a", "c"]
        ))
    }

    func test_emptyBothSets_skips() {
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: processed, processedPhotoIDs: [], currentPhotoIDs: []
        ))
    }

    // MARK: Skip requested (list-made drafts, "Skip AI")

    func test_skipRequested_skipsEvenWhenNeverProcessedOrPhotosChanged() {
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: nil, processedPhotoIDs: nil, currentPhotoIDs: ["a"],
            skipRequested: true, isComplete: true
        ))
        // A list-made draft whose placeholder photo was swapped for a real one.
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: Date(), processedPhotoIDs: ["placeholder"], currentPhotoIDs: ["mine"],
            skipRequested: true, isComplete: true
        ))
    }

    func test_skipRequested_isIgnoredWhileTheDraftIsIncomplete() {
        // No title or price: the normal AI pass fills it in, whatever was requested.
        XCTAssertFalse(DraftAIProcessingPolicy.shouldSkip(
            processedAt: nil, processedPhotoIDs: nil, currentPhotoIDs: ["a"],
            skipRequested: true, isComplete: false
        ))
        // ...but an incomplete draft that WAS processed with unchanged photos still skips.
        XCTAssertTrue(DraftAIProcessingPolicy.shouldSkip(
            processedAt: Date(), processedPhotoIDs: ["a"], currentPhotoIDs: ["a"],
            skipRequested: true, isComplete: false
        ))
    }

    func test_missingFields_needsEverythingListingNeeds_notJustTitleAndPrice() {
        func missing(
            title: String? = "Wii Sports", description: String? = "Complete in box.", price: Double? = 12,
            weightLbs: Double? = 0.25, lengthIn: Double? = 7.5, widthIn: Double? = 5.5, heightIn: Double? = 0.5,
            category: String? = "139973"
        ) -> [String] {
            DraftAIProcessingPolicy.missingFields(.init(
                title: title, description: description, price: price,
                weightLbs: weightLbs, lengthIn: lengthIn, widthIn: widthIn, heightIn: heightIn, category: category
            ))
        }
        XCTAssertEqual(missing(), [])
        // A title and a price alone are not enough to skip AI.
        XCTAssertEqual(
            missing(description: nil, weightLbs: nil, lengthIn: nil, widthIn: nil, heightIn: nil, category: nil),
            ["description", "shipping weight", "box size", "category"]
        )
        XCTAssertEqual(missing(title: "  "), ["title"])
        XCTAssertEqual(missing(price: 0), ["price"])
        XCTAssertEqual(missing(price: nil), ["price"])
        XCTAssertEqual(missing(weightLbs: 0), ["shipping weight"])
        XCTAssertEqual(missing(heightIn: nil), ["box size"], "one missing dimension is a missing box size")
        XCTAssertEqual(missing(category: ""), ["category"])
    }

    func test_missingFieldsForADraft_readsUserEditsOverAISuggestions() {
        let draft = Item(firestoreListingId: "p-complete")
        XCTAssertEqual(DraftAIProcessingPolicy.missingFields(for: draft), ["title", "description", "price", "shipping weight", "box size", "category"])
        draft.userEditedTitle = "Wii Sports"
        draft.aiSuggestedDescription = "Complete in box."
        draft.userEditedPrice = 12
        draft.weightLbs = 0.25
        draft.lengthIn = 7.5
        draft.widthIn = 5.5
        draft.heightIn = 0.5
        XCTAssertEqual(DraftAIProcessingPolicy.missingFields(for: draft), ["category"])
        draft.aiSuggestedCategory = "Video Games & Consoles > Video Games"
        XCTAssertEqual(DraftAIProcessingPolicy.missingFields(for: draft), [])
    }
}

/// DraftHistoryView's selection-mode controls — see the layout notes on
/// `DraftSelectionToolbar`. Lives in this file because the project lists test files
/// explicitly in project.pbxproj.
final class DraftSelectionToolbarTests: XCTestCase {
    func test_nothingSelected_selectAllAndBothActionsDisabled() {
        let toolbar = DraftSelectionToolbar(totalDrafts: 3, fullySelectedDrafts: 0, hasAnySelection: false)
        XCTAssertEqual(toolbar.leading, .selectAll)
        XCTAssertFalse(toolbar.canBulkEdit)
        XCTAssertFalse(toolbar.canDelete)
    }

    func test_oneDraftSelected_deleteOnly() {
        let toolbar = DraftSelectionToolbar(totalDrafts: 3, fullySelectedDrafts: 1, hasAnySelection: true)
        XCTAssertEqual(toolbar.leading, .selectAll)
        XCTAssertFalse(toolbar.canBulkEdit)
        XCTAssertTrue(toolbar.canDelete)
    }

    func test_multipleDraftsSelected_bulkEditAndDelete() {
        let toolbar = DraftSelectionToolbar(totalDrafts: 3, fullySelectedDrafts: 2, hasAnySelection: true)
        XCTAssertEqual(toolbar.leading, .selectAll)
        XCTAssertTrue(toolbar.canBulkEdit)
        XCTAssertTrue(toolbar.canDelete)
    }

    func test_allDraftsSelected_leadingBecomesDeselectAll() {
        let toolbar = DraftSelectionToolbar(totalDrafts: 3, fullySelectedDrafts: 3, hasAnySelection: true)
        XCTAssertEqual(toolbar.leading, .deselectAll)
        XCTAssertTrue(toolbar.canBulkEdit)
        XCTAssertTrue(toolbar.canDelete)
    }

    func test_onlySomePhotosOfADraftSelected_canDeleteButNotBulkEdit() {
        // Photos ticked in two drafts, neither draft whole: Delete applies (it removes
        // individual photos), Bulk Edit doesn't (it acts on whole drafts).
        let toolbar = DraftSelectionToolbar(totalDrafts: 3, fullySelectedDrafts: 0, hasAnySelection: true)
        XCTAssertEqual(toolbar.leading, .selectAll)
        XCTAssertFalse(toolbar.canBulkEdit)
        XCTAssertTrue(toolbar.canDelete)
    }

    func test_singleDraftOnScreenSelected_deselectAllAndNoBulkEdit() {
        // Everything is selected, but there's nothing to bulk-edit across.
        let toolbar = DraftSelectionToolbar(totalDrafts: 1, fullySelectedDrafts: 1, hasAnySelection: true)
        XCTAssertEqual(toolbar.leading, .deselectAll)
        XCTAssertFalse(toolbar.canBulkEdit)
        XCTAssertTrue(toolbar.canDelete)
    }

    func test_noDrafts_offersSelectAllNotDeselectAll() {
        let toolbar = DraftSelectionToolbar(totalDrafts: 0, fullySelectedDrafts: 0, hasAnySelection: false)
        XCTAssertEqual(toolbar.leading, .selectAll)
    }
}

// MARK: - Failure reason shown on the processing sheet

final class ProcessingFailureReasonTests: XCTestCase {
    private func error(_ message: String) -> Error {
        NSError(domain: "GeminiService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func testDepletedGeminiCreditsIsNamedAsBilling() {
        // Verbatim shape of the Cloud Function error from the 2026-10-01 outage.
        let reason = UploadManager.processingFailureReason(for: error(
            "Identification failed: [GoogleGenerativeAI Error]: Error fetching from https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent: [402 Payment Required] Your prepayment credits are depleted."
        ))
        XCTAssertTrue(reason.contains("credits are used up"), reason)
        XCTAssertTrue(reason.contains("ai.studio"), reason)
    }

    func testRateLimitIsNamed() {
        XCTAssertTrue(UploadManager.processingFailureReason(for: error("[429 Too Many Requests] quota exceeded")).contains("rate-limited"))
    }

    func testUnknownErrorKeepsTheMessageButDropsThePrefix() {
        let reason = UploadManager.processingFailureReason(for: error("Identification failed: model returned no candidates"))
        XCTAssertEqual(reason, "AI identification failed: model returned no candidates")
    }
}

// MARK: - Listing photo strings: bare path vs URL form

final class PhotoLocationTests: XCTestCase {
    private let bucket = "wonni-app.firebasestorage.app"
    private let path = "users/vKZZ83xRQOU9ghkNIN7XSl18dIS2/21E7324A-B919-4324-8770-86C4DF672553/0.jpg"

    func testBarePathIsStoragePath() {
        XCTAssertEqual(StorageService.photoLocation(for: path, bucket: bucket), .storagePath(path))
    }

    func testOwnBucketPublicURLBecomesStoragePath() {
        // Exactly what postToWonni writes into listings.photoPaths (copied from products.images).
        let url = "https://storage.googleapis.com/\(bucket)/\(path)"
        XCTAssertEqual(StorageService.photoLocation(for: url, bucket: bucket), .storagePath(path))
    }

    func testOwnBucketFirebaseDownloadURLBecomesStoragePath() {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o/\(encoded)?alt=media&token=abc"
        XCTAssertEqual(StorageService.photoLocation(for: url, bucket: bucket), .storagePath(path))
    }

    func testOtherBucketURLStaysExternal() {
        let url = "https://storage.googleapis.com/wonni-dropship.firebasestorage.app/dropship/x/edits/y/1.jpg"
        XCTAssertEqual(StorageService.photoLocation(for: url, bucket: bucket), .externalURL(URL(string: url)!))
    }

    func testEmptyIsNil() {
        XCTAssertNil(StorageService.photoLocation(for: "  ", bucket: bucket))
    }
}

// MARK: - eBay/Etsy status lives on products/{id}; the app shows it on the listing

final class APIPlatformStatusOverlayTests: XCTestCase {
    func testProductActiveBecomesListingPosted() {
        let api = ProductRepository.apiPlatformStatus(fromProductData: [
            "crossPostStatus": ["ebay": "active", "wonni": "active"],
            "crossPostListingIds": ["ebay": "147612911453", "wonni": "21E7"],
        ])
        XCTAssertEqual(api.status, ["ebay": "posted"])
        XCTAssertEqual(api.listingIds, ["ebay": "147612911453"])
    }

    func testOverlayKeepsWebPlatformStateFromTheListingDoc() {
        var listing = UserListing(userId: "u", catalogItemId: "")
        listing.crossPostStatus = ["mercari": "posted"]
        listing.crossPostListingIds = ["mercari": "m123"]
        var api = ProductRepository.APIPlatformStatus()
        api.status = ["ebay": "posted"]
        api.listingIds = ["ebay": "147612911453"]

        let merged = ListingRepository.applyingAPIPlatformStatus(api, to: listing)
        XCTAssertEqual(merged.crossPostStatus, ["mercari": "posted", "ebay": "posted"])
        XCTAssertEqual(merged.crossPostListingIds, ["mercari": "m123", "ebay": "147612911453"])
    }

    func testNoProductDataLeavesListingUntouched() {
        var listing = UserListing(userId: "u", catalogItemId: "")
        listing.crossPostStatus = ["mercari": "pending"]
        let merged = ListingRepository.applyingAPIPlatformStatus(nil, to: listing)
        XCTAssertEqual(merged.crossPostStatus, ["mercari": "pending"])
    }
}
