//
//  MercariRefreshPlanTests.swift
//  wonniTests
//
//  The Mercari Refresh review rules (MercariRefresh.swift): opt-out selection, what is
//  sent to the server, linking, "Never import", and the server's classification.
//

import XCTest
@testable import wonni

final class MercariRefreshPlanTests: XCTestCase {

    private func row(_ id: String, price: Double = 12, kind: MercariRefreshRow.Kind = .new,
                     productId: String? = nil, title: String = "Item") -> MercariRefreshRow {
        var r = MercariRefreshRow(id: id, title: title, price: price)
        r.kind = kind
        r.productId = productId
        return r
    }

    func testEveryNewRowStartsChecked_andOnlyNewRowsAreImportable() {
        let plan = MercariRefreshPlan(rows: [row("a"), row("b", kind: .recorded), row("c", kind: .discarded), row("d", kind: .invalid), row("e")])
        XCTAssertEqual(plan.importable.map(\.id), ["a", "e"])
        XCTAssertEqual(plan.selected.map(\.id), ["a", "e"])
        XCTAssertEqual(plan.selectedCount, 2)
    }

    func testUncheckingLeavesTheRowOutOfTheImport_andTogglingTwiceRestoresIt() {
        var plan = MercariRefreshPlan(rows: [row("a"), row("b")])
        plan.toggle("a")
        XCTAssertEqual(plan.selected.map(\.id), ["b"])
        XCTAssertFalse(plan.isChecked("a"))
        plan.toggle("a")
        XCTAssertEqual(plan.selected.map(\.id), ["a", "b"])
    }

    func testTogglingANonNewRowDoesNothing() {
        var plan = MercariRefreshPlan(rows: [row("a", kind: .recorded)])
        plan.toggle("a")
        XCTAssertTrue(plan.unchecked.isEmpty)
    }

    func testRecordPayloadSendsOnlyCheckedRows() {
        var plan = MercariRefreshPlan(rows: [row("a"), row("b"), row("c", kind: .recorded)])
        plan.toggle("b")
        let items = plan.recordPayload()["items"] as? [[String: Any]]
        XCTAssertEqual(items?.compactMap { $0["mercariItemId"] as? String }, ["a"])
    }

    func testLinkingChecksTheRow_andOnlyLinksOfCheckedRowsAreSent() {
        var plan = MercariRefreshPlan(rows: [row("a"), row("b")])
        plan.toggle("a")
        plan.link("a", to: MercariLink(productId: "p1", variantSku: "S", productTitle: "Tee", variantLabel: "Small"))
        plan.link("b", to: MercariLink(productId: "p2", variantSku: nil, productTitle: "Mug", variantLabel: nil))
        plan.toggle("b")                       // b is unchecked again, so its link must not be sent
        let payload = plan.recordPayload()
        let links = payload["links"] as? [String: [String: Any]]
        XCTAssertEqual(links?.keys.sorted(), ["a"])
        XCTAssertEqual(links?["a"]?["productId"] as? String, "p1")
        XCTAssertEqual(links?["a"]?["variantSku"] as? String, "S")
    }

    func testNoLinksKeyWhenNothingIsLinked() {
        let plan = MercariRefreshPlan(rows: [row("a")])
        XCTAssertNil(plan.recordPayload()["links"])
    }

    func testIsMatchedByServerOrByUserLink() {
        var plan = MercariRefreshPlan(rows: [row("a", productId: "p1"), row("b")])
        XCTAssertTrue(plan.isMatched(plan.rows[0]))
        XCTAssertFalse(plan.isMatched(plan.rows[1]))
        plan.link("b", to: MercariLink(productId: "p2", variantSku: nil, productTitle: "Mug", variantLabel: nil))
        XCTAssertTrue(plan.isMatched(plan.rows[1]))
    }

    func testNeverImportRemovesTheRowAndItsLinkAndSelection() {
        var plan = MercariRefreshPlan(rows: [row("a"), row("b")])
        plan.link("a", to: MercariLink(productId: "p1", variantSku: nil, productTitle: "Tee", variantLabel: nil))
        plan.toggle("b")
        plan.remove(["a", "b"])
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertTrue(plan.links.isEmpty)
        XCTAssertTrue(plan.unchecked.isEmpty)
    }

    func testDiscardPayloadCarriesTitleAndPrice() {
        let plan = MercariRefreshPlan(rows: [row("a", price: 21, title: "Karma album")])
        let body = plan.discardPayload(ids: ["a", "missing"], discarded: true)
        XCTAssertEqual(body["discarded"] as? Bool, true)
        let items = body["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?["title"] as? String, "Karma album")
        XCTAssertEqual(items?.first?["priceSoldFor"] as? Double, 21)
    }

    func testScrapeDictionaryOmitsEmptyAndBadOptionalFields() {
        var r = MercariRefreshRow(id: "m1", title: "", price: 9)
        r.thumbnailUrl = "not a url"
        r.trackingNumber = ""
        let d = r.scrapeDictionary
        XCTAssertEqual(d["mercariItemId"] as? String, "m1")
        XCTAssertEqual(d["priceSoldFor"] as? Double, 9)
        XCTAssertNil(d["title"])
        XCTAssertNil(d["thumbnailUrl"])
        XCTAssertNil(d["trackingNumber"])
        XCTAssertNil(d["takeHome"])

        r.thumbnailUrl = "https://u.mercdn.net/a.jpg"
        r.takeHome = 7.5
        r.soldAt = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(r.scrapeDictionary["thumbnailUrl"] as? String, "https://u.mercdn.net/a.jpg")
        XCTAssertEqual(r.scrapeDictionary["takeHome"] as? Double, 7.5)
        XCTAssertEqual(r.scrapeDictionary["soldAt"] as? String, "1970-01-01T00:00:00Z")
    }

    func testApplyingTheServerReviewSetsKindAndMatch() {
        let review = ReviewMercariSalesResponse(firstRecordedIndex: 2, rows: [
            MercariReviewRow(mercariItemId: "a", productId: "p1", productTitle: "Tee", reviewState: .new, variantSku: "S", warning: nil),
            MercariReviewRow(mercariItemId: "b", productId: nil, productTitle: nil, reviewState: .discarded, variantSku: nil, warning: nil),
            MercariReviewRow(mercariItemId: "c", productId: nil, productTitle: nil, reviewState: .recorded, variantSku: nil, warning: nil),
        ])
        let out = MercariRefreshPlan.applying(review, to: [row("a"), row("b"), row("c"), row("untouched")])
        XCTAssertEqual(out.map(\.kind), [.new, .discarded, .recorded, .new])
        XCTAssertEqual(out[0].productId, "p1")
        XCTAssertEqual(out[0].variantSku, "S")
        XCTAssertEqual(out[0].productTitle, "Tee")
    }

    func testStopRuleKeepsOnlyRowsNewerThanTheFirstRecorded() {
        let rows = [row("a"), row("b"), row("c"), row("d")]
        XCTAssertEqual(MercariRefreshPlan.newerThanFirstRecorded(rows, firstRecordedIndex: 2).map(\.id), ["a", "b"])
        XCTAssertEqual(MercariRefreshPlan.newerThanFirstRecorded(rows, firstRecordedIndex: 0).map(\.id), [])
        XCTAssertEqual(MercariRefreshPlan.newerThanFirstRecorded(rows, firstRecordedIndex: nil).map(\.id), ["a", "b", "c", "d"])
    }

    func testLinkSearchNeedsEveryWordAndIgnoresCase() {
        let candidates = [
            MercariRefreshService.LinkCandidate(id: "1", title: "Stray Kids Karma album", variants: []),
            MercariRefreshService.LinkCandidate(id: "2", title: "Stray Kids Maxident photocard", variants: []),
        ]
        XCTAssertEqual(MercariRefreshService.filter(candidates, query: "stray KARMA").map(\.id), ["1"])
        XCTAssertEqual(MercariRefreshService.filter(candidates, query: "").count, 2)
        XCTAssertEqual(MercariRefreshService.filter(candidates, query: "zzz").count, 0)
    }

    func testRestoreMovesAHiddenRowBackToTheImportList() {
        var plan = MercariRefreshPlan(rows: [
            MercariRefreshRow(id: "a", title: "A", price: 5, kind: .discarded),
            MercariRefreshRow(id: "b", title: "B", price: 6, kind: .new),
        ])
        XCTAssertEqual(plan.hidden.map(\.id), ["a"])
        XCTAssertEqual(plan.importable.map(\.id), ["b"])
        plan.restore("a")
        XCTAssertTrue(plan.hidden.isEmpty)
        XCTAssertEqual(plan.importable.map(\.id), ["a", "b"])
        XCTAssertTrue(plan.isChecked("a"))
        plan.restore("b") // only hidden rows can be restored; a new row is untouched
        XCTAssertEqual(plan.importable.count, 2)
    }

    func testSaleTabsAreTheMercariUrlSegments() {
        XCTAssertEqual(MercariSaleTab.allCases.map(\.rawValue), ["in_progress", "complete"])
    }
}
