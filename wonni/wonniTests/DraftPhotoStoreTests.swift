//
//  DraftPhotoStoreTests.swift
//  wonniTests
//
//  Local draft photos live in per-photo files (DraftPhotoStore) instead of the legacy
//  `Item.photosData` array. Covers the store itself, the legacy attribution rule, and
//  `Item`'s bookkeeping on top of both.
//

import XCTest
import SwiftData
@testable import wonni

/// Points DraftPhotoStore at a scratch directory so tests never touch real drafts.
class DraftPhotoStoreTestCase: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-photo-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DraftPhotoStore.rootOverride = scratch
    }

    override func tearDown() {
        DraftPhotoStore.rootOverride = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func bytes(_ marker: UInt8, count: Int = 64) -> Data {
        Data(repeating: marker, count: count)
    }

    func storedFileCount(for itemID: UUID) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: DraftPhotoStore.directory(for: itemID).path))?.count ?? 0
    }
}

final class DraftPhotoStoreTests: DraftPhotoStoreTestCase {
    func test_writeThenRead_roundTrips() throws {
        let itemID = UUID()
        let name = try DraftPhotoStore.write(bytes(7), itemID: itemID)
        XCTAssertEqual(DraftPhotoStore.read(itemID: itemID, fileName: name), bytes(7))
    }

    func test_eachWriteGetsItsOwnFile() throws {
        let itemID = UUID()
        let first = try DraftPhotoStore.write(bytes(1), itemID: itemID)
        let second = try DraftPhotoStore.write(bytes(2), itemID: itemID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(DraftPhotoStore.read(itemID: itemID, fileName: first), bytes(1))
        XCTAssertEqual(DraftPhotoStore.read(itemID: itemID, fileName: second), bytes(2))
    }

    func test_delete_removesOnlyThatPhoto() throws {
        let itemID = UUID()
        let keep = try DraftPhotoStore.write(bytes(1), itemID: itemID)
        let drop = try DraftPhotoStore.write(bytes(2), itemID: itemID)
        DraftPhotoStore.delete(itemID: itemID, fileName: drop)
        XCTAssertNil(DraftPhotoStore.read(itemID: itemID, fileName: drop))
        XCTAssertEqual(DraftPhotoStore.read(itemID: itemID, fileName: keep), bytes(1))
    }

    func test_deleteAll_removesOnlyThatDraft() throws {
        let gone = UUID(), kept = UUID()
        _ = try DraftPhotoStore.write(bytes(1), itemID: gone)
        let keptName = try DraftPhotoStore.write(bytes(2), itemID: kept)
        DraftPhotoStore.deleteAll(itemID: gone)
        XCTAssertEqual(storedFileCount(for: gone), 0)
        XCTAssertEqual(DraftPhotoStore.read(itemID: kept, fileName: keptName), bytes(2))
    }

    func test_sweepOrphans_removesOnlyFoldersOfDeadDrafts() throws {
        let live = UUID(), dead = UUID()
        let liveName = try DraftPhotoStore.write(bytes(1), itemID: live)
        _ = try DraftPhotoStore.write(bytes(2), itemID: dead)
        // Not named like a draft — must be left alone.
        let stranger = DraftPhotoStore.root.appendingPathComponent("not-a-draft")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)

        XCTAssertEqual(DraftPhotoStore.sweepOrphans(keeping: [live]), 1)
        XCTAssertEqual(DraftPhotoStore.read(itemID: live, fileName: liveName), bytes(1))
        XCTAssertEqual(storedFileCount(for: dead), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    func test_sweepOrphans_withNothingStored_isANoOp() {
        DraftPhotoStore.rootOverride = DraftPhotoStore.root.appendingPathComponent("never-created")
        XCTAssertEqual(DraftPhotoStore.sweepOrphans(keeping: []), 0)
    }
}

final class LegacyDraftPhotosTests: XCTestCase {
    func test_noBlobs_attributesNothing() {
        XCTAssertEqual(LegacyDraftPhotos.blobIndexByAsset(assetIds: ["a", "b"], blobCount: 0), [:])
    }

    func test_oneBlobPerPhoto_isPositional() {
        XCTAssertEqual(
            LegacyDraftPhotos.blobIndexByAsset(assetIds: ["a", "b", "c"], blobCount: 3),
            ["a": 0, "b": 1, "c": 2]
        )
    }

    func test_mixedDraftWithRealLibraryIds_attributesNothing() {
        // Library pick "lib" then two camera shots saved to the camera roll: 3 photos,
        // 2 blobs, and no way to tell which two. PhotoKit serves all three.
        XCTAssertEqual(LegacyDraftPhotos.blobIndexByAsset(assetIds: ["lib", "cam1", "cam2"], blobCount: 2), [:])
    }

    func test_mixedDraftWithLocalOnlyShots_attributesThoseInOrder() {
        // "Save to camera roll" off: the camera shots are the local_temp_ ids, and
        // their blobs were appended in shot order.
        XCTAssertEqual(
            LegacyDraftPhotos.blobIndexByAsset(
                assetIds: ["lib1", "local_temp_A", "lib2", "local_temp_B"], blobCount: 2),
            ["local_temp_A": 0, "local_temp_B": 1]
        )
    }

    func test_localOnlyCountMismatch_attributesNothing() {
        XCTAssertEqual(
            LegacyDraftPhotos.blobIndexByAsset(assetIds: ["lib", "local_temp_A", "local_temp_B"], blobCount: 1),
            [:]
        )
    }
}

final class ItemLocalPhotoTests: DraftPhotoStoreTestCase {
    func test_setLocalPhoto_storesBytesUnderTheAssetId() {
        let item = Item(sourceAssetIdentifiers: ["a"])
        item.setLocalPhoto(bytes(1), for: "a")
        XCTAssertEqual(item.photoData(for: "a"), bytes(1))
        XCTAssertTrue(item.photosData.isEmpty, "new photos must not go into the legacy array")
        XCTAssertEqual(storedFileCount(for: item.id), 1)
    }

    func test_libraryPickedPhoto_hasNoLocalBytes() {
        let item = Item(sourceAssetIdentifiers: ["picked", "shot"])
        item.setLocalPhoto(bytes(2), for: "shot")
        XCTAssertNil(item.photoData(for: "picked"))
        // The old positional array returned the shot's bytes for index 0 here.
        XCTAssertEqual(item.photoData(for: "shot"), bytes(2))
        XCTAssertEqual(item.localPhotoDataByAsset(), ["shot": bytes(2)])
    }

    func test_movePhoto_keepsBytesWithTheirPhoto() {
        let item = Item(sourceAssetIdentifiers: ["a", "b", "c"])
        for (marker, assetId) in zip([UInt8(1), 2, 3], ["a", "b", "c"]) { item.setLocalPhoto(bytes(marker), for: assetId) }
        item.movePhoto(from: 0, to: 2)
        XCTAssertEqual(item.sourceAssetIdentifiers, ["b", "c", "a"])
        XCTAssertEqual(item.photoData(for: "a"), bytes(1))
        XCTAssertEqual(item.photoData(for: "b"), bytes(2))
        XCTAssertEqual(item.photoData(for: "c"), bytes(3))
    }

    func test_removePhoto_returnsBytesAndDeletesTheFile() {
        let item = Item(sourceAssetIdentifiers: ["a", "b"])
        item.setLocalPhoto(bytes(1), for: "a")
        item.setLocalPhoto(bytes(2), for: "b")
        let removed = item.removePhoto(assetId: "a")
        XCTAssertEqual(removed.data, bytes(1))
        XCTAssertEqual(item.sourceAssetIdentifiers, ["b"])
        XCTAssertNil(item.photoData(for: "a"))
        XCTAssertEqual(item.photoData(for: "b"), bytes(2))
        XCTAssertEqual(storedFileCount(for: item.id), 1)
    }

    func test_movingAPhotoBetweenDrafts_carriesItsBytes() {
        let source = Item(sourceAssetIdentifiers: ["a"])
        source.setLocalPhoto(bytes(9), for: "a")
        let target = Item(sourceAssetIdentifiers: ["x"])

        let removed = source.removePhoto(assetId: "a")
        target.insertPhoto(assetId: "a", data: removed.data, at: 0)

        XCTAssertEqual(target.sourceAssetIdentifiers, ["a", "x"])
        XCTAssertEqual(target.photoData(for: "a"), bytes(9))
        XCTAssertEqual(storedFileCount(for: source.id), 0)
    }

    func test_reorderPhotos_appliesTheNewOrder() {
        let item = Item(sourceAssetIdentifiers: ["a", "b", "c"])
        item.setLocalPhoto(bytes(1), for: "a")
        item.reorderPhotos(to: ["c", "a", "b"])
        XCTAssertEqual(item.sourceAssetIdentifiers, ["c", "a", "b"])
        XCTAssertEqual(item.photoData(for: "a"), bytes(1))
    }

    func test_discardLocalPhotos_removesEverything() {
        let item = Item(sourceAssetIdentifiers: ["a"])
        item.setLocalPhoto(bytes(1), for: "a")
        item.discardLocalPhotos()
        XCTAssertEqual(storedFileCount(for: item.id), 0)
        XCTAssertNil(item.localPhotoFilesByAsset)
    }

    // MARK: Legacy migration

    func test_legacyDraft_isReadableBeforeMigration() {
        let item = Item(photosData: [bytes(1), bytes(2)], sourceAssetIdentifiers: ["a", "b"], isLocalPhotoOnly: true)
        XCTAssertEqual(item.photoData(for: "b"), bytes(2))
        XCTAssertEqual(item.localPhotoDataByAsset(), ["a": bytes(1), "b": bytes(2)])
    }

    func test_migration_movesBytesToFilesAndEmptiesTheLegacyArray() {
        let item = Item(photosData: [bytes(1), bytes(2)], sourceAssetIdentifiers: ["a", "b"], isLocalPhotoOnly: true)
        XCTAssertTrue(item.migrateLegacyPhotosIfNeeded())
        XCTAssertTrue(item.photosData.isEmpty)
        XCTAssertEqual(storedFileCount(for: item.id), 2)
        XCTAssertEqual(item.photoData(for: "a"), bytes(1))
        XCTAssertEqual(item.photoData(for: "b"), bytes(2))
        XCTAssertFalse(item.migrateLegacyPhotosIfNeeded(), "second run must be a no-op")
    }

    func test_migration_ofNewStyleDraft_isANoOp() {
        let item = Item(sourceAssetIdentifiers: ["a"])
        item.setLocalPhoto(bytes(1), for: "a")
        XCTAssertFalse(item.migrateLegacyPhotosIfNeeded())
        XCTAssertEqual(item.photoData(for: "a"), bytes(1))
    }

    func test_migration_ofUnattributableBlobs_dropsThemWhenTheLibraryHasEveryPhoto() {
        let item = Item(photosData: [bytes(1)], sourceAssetIdentifiers: ["lib", "cam"], isLocalPhotoOnly: true)
        XCTAssertTrue(item.migrateLegacyPhotosIfNeeded())
        XCTAssertTrue(item.photosData.isEmpty)
        XCTAssertNil(item.photoData(for: "lib"))
        XCTAssertNil(item.photoData(for: "cam"))
        XCTAssertEqual(storedFileCount(for: item.id), 0)
    }

    func test_migration_keepsUnattributableBlobsWhenALocalOnlyPhotoCouldBeAmongThem() {
        // Two local-only shots but one blob: can't attribute, and the blob may be a
        // photo's only copy — leave the legacy array alone.
        let item = Item(photosData: [bytes(1)], sourceAssetIdentifiers: ["local_temp_A", "local_temp_B"], isLocalPhotoOnly: true)
        XCTAssertFalse(item.migrateLegacyPhotosIfNeeded())
        XCTAssertEqual(item.photosData, [bytes(1)])
    }

    func test_mutatingALegacyDraft_migratesItFirst() {
        let item = Item(photosData: [bytes(1), bytes(2), bytes(3)], sourceAssetIdentifiers: ["a", "b", "c"], isLocalPhotoOnly: true)
        let removed = item.removePhoto(assetId: "b")
        XCTAssertEqual(removed.data, bytes(2))
        XCTAssertTrue(item.photosData.isEmpty)
        XCTAssertEqual(item.sourceAssetIdentifiers, ["a", "c"])
        XCTAssertEqual(item.photoData(for: "a"), bytes(1))
        XCTAssertEqual(item.photoData(for: "c"), bytes(3))
        XCTAssertEqual(storedFileCount(for: item.id), 2)
    }

    // MARK: Persistence

    @MainActor
    func test_launchSweep_migratesPersistedLegacyDraftsAndSweepsOrphans() throws {
        let container = try ModelContainer(
            for: Item.self, Listing.self, Expense.self, Mileage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let legacy = Item(photosData: [bytes(1), bytes(2)], sourceAssetIdentifiers: ["a", "b"], isLocalPhotoOnly: true)
        context.insert(legacy)
        try context.save()
        // A folder left behind by a draft that no longer exists.
        let orphan = UUID()
        _ = try DraftPhotoStore.write(bytes(9), itemID: orphan)

        UploadManager.shared.migrateDraftPhotoStorage(modelContext: context)

        let reloaded = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Item>()).first)
        XCTAssertTrue(reloaded.photosData.isEmpty)
        XCTAssertEqual(reloaded.photoData(for: "a"), bytes(1))
        XCTAssertEqual(reloaded.photoData(for: "b"), bytes(2))
        XCTAssertEqual(storedFileCount(for: orphan), 0)
    }
}
