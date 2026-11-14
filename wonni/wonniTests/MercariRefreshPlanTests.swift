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
        r.soldAt = Date(timeIntervalSince1970: 1_700_000_000)
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
            row("a", price: 5, kind: .discarded),
            row("b", price: 6),
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

    // MARK: Auto-import era (2026-11-14)

    func testRowsMissingPriceOrDateAreNeedsInfo_neverSelected_andCannotBeChecked() {
        var noDate = row("b"); noDate.soldAt = nil
        let noPrice = row("c", price: 0)
        var plan = MercariRefreshPlan(rows: [row("a"), noDate, noPrice])
        XCTAssertEqual(plan.needsInfo.map(\.id), ["b", "c"])
        XCTAssertEqual(plan.ready.map(\.id), ["a"])
        XCTAssertEqual(plan.selected.map(\.id), ["a"])
        XCTAssertFalse(plan.isChecked("b"))
        plan.toggle("b")
        XCTAssertFalse(plan.unchecked.contains("b"))
        XCTAssertEqual(noDate.missing, ["date"])
        XCTAssertEqual(noPrice.missing, ["price"])
    }

    func testEditingFillsTheMissingFieldAndChecksTheRow() {
        var r = row("a"); r.soldAt = nil
        var plan = MercariRefreshPlan(rows: [r])
        plan.unchecked.insert("a")
        r.soldAt = Date()
        plan.update(r)
        XCTAssertEqual(plan.selected.map(\.id), ["a"])
    }

    func testRecordPayloadAllowsUnlinkedRows() {
        let plan = MercariRefreshPlan(rows: [row("a")])
        XCTAssertEqual(plan.recordPayload()["allowUnlinked"] as? Bool, true)
        XCTAssertEqual(plan.product(for: plan.rows[0]), .none)
    }

    func testSuggestedProductIsSentUnlessDeclined_andMatchedRowsNeedNoLink() {
        var s = row("s"); s.suggestedProductId = "p9"; s.suggestedProductTitle = "Lightstick"
        var plan = MercariRefreshPlan(rows: [s, row("m", productId: "p1")])
        var links = plan.recordPayload()["links"] as? [String: [String: Any]]
        XCTAssertEqual(links?.keys.sorted(), ["s"])
        XCTAssertEqual(links?["s"]?["productId"] as? String, "p9")
        plan.unlink("s")
        links = plan.recordPayload()["links"] as? [String: [String: Any]]
        XCTAssertNil(links)
        XCTAssertEqual(plan.product(for: plan.rows[0]), .none)
    }

    func testUserLinkBeatsTheSuggestion() {
        var s = row("s"); s.suggestedProductId = "p9"
        var plan = MercariRefreshPlan(rows: [s])
        plan.link("s", to: MercariLink(productId: "p2", variantSku: "B", productTitle: "Album", variantLabel: "Ver. B"))
        let links = plan.recordPayload()["links"] as? [String: [String: Any]]
        XCTAssertEqual(links?["s"]?["productId"] as? String, "p2")
        XCTAssertEqual(links?["s"]?["variantSku"] as? String, "B")
    }

    func testNeverImportMovesTheRowToHidden() {
        var plan = MercariRefreshPlan(rows: [row("a"), row("b")])
        plan.hide("a")
        XCTAssertEqual(plan.hidden.map(\.id), ["a"])
        XCTAssertEqual(plan.importable.map(\.id), ["b"])
    }

    func testReviewPayloadAsksForAutoImport_andCarriesTheSwitch() {
        let body = MercariRefreshPlan.reviewPayload([row("a")], recordLinked: false)
        XCTAssertEqual(body["autoImport"] as? Bool, true)
        XCTAssertEqual(body["recordLinked"] as? Bool, false)
    }

    func testScrapeDictionaryLeavesOutAMissingPrice_andSendsQuantity() {
        var r = MercariRefreshRow(id: "m1", title: "Wii remote", price: nil)
        r.quantity = 2
        let d = r.scrapeDictionary
        XCTAssertNil(d["priceSoldFor"])
        XCTAssertEqual(d["quantity"] as? Int, 2)
    }

    func testEstimatedTakeHomeIsMercariFees() {
        XCTAssertEqual(MercariRefreshRow.estimatedTakeHome(100), 86.6)
        XCTAssertNil(MercariRefreshRow.estimatedTakeHome(nil))
        XCTAssertNil(MercariRefreshRow.estimatedTakeHome(0))
    }

    func testInboxDecodesEveryDateShape_andBuildsThePlan() throws {
        let json = """
        {"pending":[
          {"item":{"mercariItemId":"m1","title":"A","priceSoldFor":10,"soldAt":"2026-11-12T10:00:00Z"},"inboxState":"pending","productId":"p1","missing":[]},
          {"item":{"mercariItemId":"m2","title":"B","soldDate":"11/10/26"},"inboxState":"pending","suggestedProductId":"p2","suggestedProductTitle":"Bee","missing":["price"]},
          {"item":{"mercariItemId":"m3","priceSoldFor":4,"soldAt":1762941600000},"inboxState":"pending","missing":["title"]}
        ],"discarded":[{"item":{"mercariItemId":"m4"},"inboxState":"discarded","missing":["title","price","date"]}]}
        """
        let inbox = try JSONDecoder().decode(MercariInbox.self, from: Data(json.utf8))
        XCTAssertNotNil(inbox.pending[0].item.soldAt)
        XCTAssertNotNil(inbox.pending[1].item.soldAt)
        XCTAssertNotNil(inbox.pending[2].item.soldAt)
        XCTAssertEqual(inbox.knownIds, ["m1", "m2", "m3", "m4"])
        let plan = MercariRefreshPlan(inbox: inbox)
        XCTAssertEqual(plan.ready.map(\.id), ["m1"])
        XCTAssertEqual(plan.needsInfo.map(\.id), ["m2", "m3"])
        XCTAssertEqual(plan.hidden.map(\.id), ["m4"])
        XCTAssertEqual(plan.product(for: plan.rows[1]), .suggested(id: "p2", title: "Bee"))
    }
}
