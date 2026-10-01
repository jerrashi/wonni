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
