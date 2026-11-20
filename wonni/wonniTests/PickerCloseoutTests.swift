//
//  PickerCloseoutTests.swift
//  wonniTests
//
//  The Sell tab's picker is pushed keyed by a draft id (CameraRoute.picker). These cover
//  the two UploadManager rules that make that safe: an empty draft is created on demand
//  before the push, and a picker that leaves the path closes its draft out — deleted when
//  it never got a photo, left alone when the camera is still building it.
//

import XCTest
import SwiftData
@testable import wonni

@MainActor
final class PickerCloseoutTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let manager = UploadManager.shared

    override func setUpWithError() throws {
        container = try ModelContainer(for: Item.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        manager.activeDraftID = nil
    }

    override func tearDown() {
        manager.activeDraftID = nil
    }

    private func fetch(_ id: UUID) -> Item? {
        var d = FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func test_ensureActiveDraft_createsOneEmptyDraftAndReusesIt() {
        let first = manager.ensureActiveDraft(modelContext: context)
        XCTAssertEqual(manager.activeDraftID, first)
        XCTAssertEqual(fetch(first)?.sourceAssetIdentifiers, [])
        XCTAssertNotNil(fetch(first)?.firestoreListingId)

        let second = manager.ensureActiveDraft(modelContext: context)
        XCTAssertEqual(second, first, "A second push reuses the draft the camera is building")
    }

    func test_pickerDidClose_deletesTheDraftWhenItNeverGotAPhoto() {
        let id = manager.ensureActiveDraft(modelContext: context)
        manager.pickerDidClose(draftID: id, modelContext: context)

        XCTAssertTrue(manager.deletedDraftIDs.contains(id))
        XCTAssertNil(manager.activeDraftID, "Nothing is left to build on")
    }

    func test_pickerDidClose_keepsAnUncommittedDraftWithPhotosActive() {
        let id = manager.ensureActiveDraft(modelContext: context)
        manager.addPhotoToActiveDraft(assetId: "asset-1", imageData: nil, modelContext: context)
        manager.pickerDidClose(draftID: id, modelContext: context)

        XCTAssertFalse(manager.deletedDraftIDs.contains(id))
        XCTAssertEqual(manager.activeDraftID, id, "Back to the camera keeps adding to this draft")
        XCTAssertEqual(fetch(id)?.sourceAssetIdentifiers, ["asset-1"])
    }

    func test_pickerDidClose_ignoresAnAlreadyDeletedDraft() {
        let id = manager.ensureActiveDraft(modelContext: context)
        manager.pickerDidClose(draftID: id, modelContext: context)
        manager.pickerDidClose(draftID: id, modelContext: context)
        XCTAssertTrue(manager.deletedDraftIDs.contains(id))
    }
}

// MARK: - Sell flow resume + pending edits (2026-11-20)

/// Where the Sell tab opens after a restart (`SellResume`): Review when processed drafts
/// wait, an Edit screen left open on top of where it came from, else the camera.
final class SellResumeTests: XCTestCase {
    private let a = UUID(), b = UUID()

    func test_nothingWaiting_opensTheCamera() {
        let path = SellResume.initialPath(drafts: [SellDraftState(id: a)], pendingEditDraftID: nil)
        XCTAssertEqual(path, [])
    }

    func test_processedDraftWaiting_opensReviewOverDrafts() {
        let path = SellResume.initialPath(drafts: [SellDraftState(id: a, isProcessed: true)], pendingEditDraftID: nil)
        XCTAssertEqual(path, [.drafts, .review])
    }

    func test_failedPublishWaiting_opensReview() {
        let path = SellResume.initialPath(drafts: [SellDraftState(id: a, pendingPublish: true)], pendingEditDraftID: nil)
        XCTAssertEqual(path, [.drafts, .review])
    }

    func test_publishedOrPublishingDrafts_areNotReviewable() {
        XCTAssertFalse(SellDraftState(id: a, isPublished: true, isProcessed: true).isReviewable)
        XCTAssertFalse(SellDraftState(id: a, isProcessed: true, isPublishing: true).isReviewable,
                       "A draft mid-publish must not be publishable again from Review")
        XCTAssertFalse(SellDraftState(id: a, isDraft: false, isProcessed: true).isReviewable)
    }

    func test_pendingEditOnProcessedDraft_reopensEditOverReview() {
        let path = SellResume.initialPath(drafts: [SellDraftState(id: a, isProcessed: true)], pendingEditDraftID: a)
        XCTAssertEqual(path, [.drafts, .review, .edit(a)])
    }

    func test_pendingEditOnUnprocessedDraft_reopensEditOverDrafts() {
        let path = SellResume.initialPath(
            drafts: [SellDraftState(id: a), SellDraftState(id: b, isProcessed: true)],
            pendingEditDraftID: a
        )
        XCTAssertEqual(path, [.drafts, .edit(a)])
    }

    func test_pendingEditForAGoneOrPublishedDraft_isIgnored() {
        XCTAssertEqual(SellResume.initialPath(drafts: [], pendingEditDraftID: a), [])
        XCTAssertEqual(SellResume.initialPath(drafts: [SellDraftState(id: a, isPublished: true)], pendingEditDraftID: a), [])
    }
}

/// The Edit screen writes every change to a `PendingDraftEdit`, never the draft, until Save.
@MainActor
final class PendingDraftEditTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Item.self, PendingDraftEdit.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeDraft() -> Item {
        let item = Item(sourceAssetIdentifiers: ["asset-1"])
        item.aiSuggestedTitle = "Game Boy Color"
        item.userEditedPrice = 75
        context.insert(item)
        try? context.save()
        return item
    }

    func test_formRoundTrip_changesNothing() {
        let item = makeDraft()
        let before = DraftEditFields(item: item)
        before.apply(to: item)
        XCTAssertEqual(DraftEditFields(item: item), before)
    }

    func test_record_keepsTheDraftUntouched() {
        let item = makeDraft()
        var fields = DraftEditFields(item: item)
        fields.title = "Game Boy Color, teal"
        fields.priceText = "80.00"
        PendingDraftEdit.record(fields, for: item, in: context)

        XCTAssertEqual(item.userEditedTitle, nil, "Typing must not write to the draft")
        XCTAssertEqual(item.userEditedPrice, 75)
        XCTAssertEqual(PendingDraftEdit.find(item.id, in: context)?.fields, fields)
    }

    func test_recordingTheDraftsOwnValues_removesThePendingCopy() {
        let item = makeDraft()
        var fields = DraftEditFields(item: item)
        fields.title = "changed"
        PendingDraftEdit.record(fields, for: item, in: context)
        fields.title = "Game Boy Color"
        PendingDraftEdit.record(fields, for: item, in: context)
        XCTAssertNil(PendingDraftEdit.find(item.id, in: context), "Nothing left to resume")
    }

    func test_saveApplies_andCancelDiscards() {
        let item = makeDraft()
        var fields = DraftEditFields(item: item)
        fields.title = "Saved title"
        PendingDraftEdit.record(fields, for: item, in: context)

        // Save
        PendingDraftEdit.find(item.id, in: context)?.fields?.apply(to: item)
        PendingDraftEdit.discard(item.id, in: context)
        XCTAssertEqual(item.userEditedTitle, "Saved title")
        XCTAssertNil(PendingDraftEdit.find(item.id, in: context))

        // Cancel
        fields.title = "Thrown away"
        PendingDraftEdit.record(fields, for: item, in: context)
        PendingDraftEdit.discard(item.id, in: context)
        XCTAssertEqual(item.userEditedTitle, "Saved title")
        XCTAssertNil(PendingDraftEdit.find(item.id, in: context))
    }
}
