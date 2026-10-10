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
