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

/// Phone vs PC drafts (PCDrafts.swift, 2026-11-25): the id says where a draft was made,
/// and which drafts the Drafts screen lists.
final class DraftOriginTests: XCTestCase {
    func test_isMadeOnPC_uuidIsPhone_autoIdIsPC() {
        XCTAssertFalse(DraftOrigin.isMadeOnPC(productId: "1030914D-8CEE-4EB7-9F22-9B91CE423505"))
        XCTAssertTrue(DraftOrigin.isMadeOnPC(productId: "WphLZ61Q9IKvWwjTm06z"))
        XCTAssertFalse(DraftOrigin.isMadeOnPC(productId: nil), "a draft with no product id yet was made here")
        XCTAssertFalse(DraftOrigin.isMadeOnPC(productId: ""))
    }

    func test_showsLocal_phoneByDefault_mixedWithSetting_pcOnlyUnderButton() {
        // default: phone only
        XCTAssertTrue(DraftOrigin.showsLocal(isMadeOnPC: false, pcOnly: false, showPcDrafts: false))
        XCTAssertFalse(DraftOrigin.showsLocal(isMadeOnPC: true, pcOnly: false, showPcDrafts: false))
        // setting on: both
        XCTAssertTrue(DraftOrigin.showsLocal(isMadeOnPC: true, pcOnly: false, showPcDrafts: true))
        XCTAssertTrue(DraftOrigin.showsLocal(isMadeOnPC: false, pcOnly: false, showPcDrafts: true))
        // PC button: PC only, whatever the setting
        XCTAssertTrue(DraftOrigin.showsLocal(isMadeOnPC: true, pcOnly: true, showPcDrafts: false))
        XCTAssertFalse(DraftOrigin.showsLocal(isMadeOnPC: false, pcOnly: true, showPcDrafts: true))
    }

    func test_cloudOnly_dropsDraftsAlreadyDownloaded() {
        XCTAssertEqual(DraftOrigin.cloudOnly(remoteIds: ["a", "b", "c"], localProductIds: ["b"]), ["a", "c"])
    }
}

/// Photo tools (PhotoToolsView.swift): box math and "replace in place" ordering.
final class PhotoToolsGeometryTests: XCTestCase {
    func test_grid_coversTheImageInRowMajorOrder() {
        let g = PhotoToolsGeometry.grid(rows: 2, cols: 3)
        XCTAssertEqual(g.count, 6)
        XCTAssertEqual(g[0], CGRect(x: 0, y: 0, width: 1.0 / 3, height: 0.5))
        XCTAssertEqual(g[5].maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(g[5].maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(PhotoToolsGeometry.rows(3).map(\.width), [1, 1, 1])
    }

    func test_movedRowCut_resizesTheTwoPiecesBesideIt() {
        let cuts = PhotoToolsGeometry.movedCut(PhotoToolsGeometry.evenCuts(3), index: 0, to: 0.2)
        let pieces = PhotoToolsGeometry.grid(rowCuts: cuts, colCuts: [])
        XCTAssertEqual(pieces.map(\.height)[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(pieces.map(\.height)[1], 2.0 / 3 - 0.2, accuracy: 1e-9)
        XCTAssertEqual(pieces.map(\.height)[2], 1.0 / 3, accuracy: 1e-9)
    }

    func test_movedCut_neverCrossesANeighbourOrAnEdge() {
        let cuts: [CGFloat] = [0.3, 0.6]
        XCTAssertEqual(PhotoToolsGeometry.movedCut(cuts, index: 0, to: 0.9)[0], 0.6 - PhotoToolsGeometry.minSide, accuracy: 1e-9)
        XCTAssertEqual(PhotoToolsGeometry.movedCut(cuts, index: 0, to: -1)[0], PhotoToolsGeometry.minSide, accuracy: 1e-9)
        XCTAssertEqual(PhotoToolsGeometry.movedCut(cuts, index: 1, to: 2)[1], 1 - PhotoToolsGeometry.minSide, accuracy: 1e-9)
        XCTAssertEqual(PhotoToolsGeometry.movedCut(cuts, index: 5, to: 0.5), cuts)
    }

    func test_geminiBox_isYXOrderOn1000Scale() {
        let r = PhotoToolsGeometry.rect(fromGeminiBox: [100, 200, 600, 900])
        XCTAssertEqual(r?.minX ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r?.minY ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r?.width ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(r?.height ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(PhotoToolsGeometry.rect(fromGeminiBox: [1, 2, 3]))
        XCTAssertNil(PhotoToolsGeometry.rect(fromGeminiBox: [500, 500, 500, 500]), "a zero-size box is dropped")
    }

    func test_pixelRect_staysInsideTheImage() {
        let px = PhotoToolsGeometry.pixelRect(CGRect(x: 0.5, y: 0.5, width: 0.6, height: 0.6), imageSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(px, CGRect(x: 500, y: 400, width: 500, height: 400))
    }

    func test_resized_squareLockUsesPixelAspect() {
        // 2000×1000 image: a square in pixels is twice as tall as wide in normalized units.
        let r = PhotoToolsGeometry.resized(CGRect(x: 0, y: 0, width: 0.2, height: 0.2), by: .zero, aspect: 1, imageSize: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(r.width * 2000, r.height * 1000, accuracy: 1e-6)
    }

    func test_replacing_putsPiecesWhereThePhotoWas() {
        XCTAssertEqual(PhotoToolsGeometry.replacing("b", with: ["x", "y"], in: ["a", "b", "c"]), ["a", "x", "y", "c"])
        XCTAssertEqual(PhotoToolsGeometry.replacing("z", with: ["x"], in: ["a"]), ["a", "x"])
    }
}

/// Link routing for "Drafts from a List" — the same rules as the web import box.
final class ImportLinkRouterTests: XCTestCase {
    private let sale = "https://shop.weverse.io/en/shop/USD/artists/3/sales/41587"
    private let shop = "https://shop.weverse.io/en/shop/USD/artists/3"
    private let ali = "https://www.aliexpress.us/item/3256806.html"

    func test_loneShopLinkImportsThePage() {
        XCTAssertEqual(ImportLinkRouter.route("  \(shop)  \n"), .weverseShop(shop))
    }

    func test_onlyImporterLinksGoToTheImporters() {
        XCTAssertEqual(ImportLinkRouter.route("\(sale)\n\(ali)"), .importerLinks([sale, ali]))
        XCTAssertEqual(ImportLinkRouter.route(sale), .importerLinks([sale]))
        XCTAssertEqual(ImportLinkRouter.route("https://aliexpress.com/x?id=123"), .importerLinks(["https://aliexpress.com/x?id=123"]))
    }

    func test_anythingElseIsText() {
        XCTAssertEqual(ImportLinkRouter.route("bts hoodie \(sale)"), .text, "a link inside a sentence stays text, like the web")
        XCTAssertEqual(ImportLinkRouter.route("\(shop)\n\(sale)"), .text, "a shop link with other lines is text")
        XCTAssertEqual(ImportLinkRouter.route("https://www.amazon.com/dp/B0CHX1W1XY"), .text)
        XCTAssertEqual(ImportLinkRouter.route(""), .text)
    }
}
