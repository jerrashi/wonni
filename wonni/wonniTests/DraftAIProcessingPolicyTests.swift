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
