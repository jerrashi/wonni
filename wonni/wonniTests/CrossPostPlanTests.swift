//
//  CrossPostPlanTests.swift
//  wonniTests
//
//  Rules of the shared cross-post sheet (CrossPostSheet.swift): which candidates
//  a platform still needs, the skip note under a row, and when the confirm
//  button is live.
//

import XCTest
@testable import wonni

final class CrossPostPlanTests: XCTestCase {
    private func candidate(_ id: String, on platforms: Set<String> = []) -> CrossPostCandidate {
        CrossPostCandidate(id: id, title: id, price: 10, postedPlatforms: platforms)
    }

    func test_remaining_skipsCandidatesAlreadyOnThePlatform() {
        let list = [candidate("a", on: ["mercari"]), candidate("b"), candidate("c", on: ["ebay"])]
        XCTAssertEqual(CrossPostPlan.remaining(list, for: "mercari").map(\.id), ["b", "c"])
        XCTAssertEqual(CrossPostPlan.remaining(list, for: "ebay").map(\.id), ["a", "b"])
        XCTAssertEqual(CrossPostPlan.remaining(list, for: "facebook").map(\.id), ["a", "b", "c"])
    }

    func test_skipNote_wording() {
        let list = [candidate("a", on: ["mercari"]), candidate("b", on: ["mercari"]), candidate("c")]
        XCTAssertEqual(
            CrossPostPlan.skipNote(list, for: "mercari", name: "Mercari"),
            "2 of 3 are already on Mercari and will be skipped"
        )
        XCTAssertNil(CrossPostPlan.skipNote(list, for: "ebay", name: "eBay"))
        let all = [candidate("a", on: ["ebay"]), candidate("b", on: ["ebay"])]
        XCTAssertEqual(CrossPostPlan.skipNote(all, for: "ebay", name: "eBay"), "All 2 are already on eBay")
        XCTAssertEqual(CrossPostPlan.skipNote([all[0]], for: "ebay", name: "eBay"), "Already on eBay")
    }

    func test_canSelect_needsConnectionAndSomethingLeftToPost() {
        let list = [candidate("a", on: ["ebay"]), candidate("b")]
        XCTAssertFalse(CrossPostPlan.canSelect("ebay", connected: false, candidates: list))
        XCTAssertTrue(CrossPostPlan.canSelect("ebay", connected: true, candidates: list))
        // Autofill platforms never need a connection.
        XCTAssertTrue(CrossPostPlan.canSelect("mercari", connected: false, candidates: list))
        // Every candidate already there: nothing to do, so the toggle is off-limits.
        let allOn = [candidate("a", on: ["ebay"])]
        XCTAssertFalse(CrossPostPlan.canSelect("ebay", connected: true, candidates: allOn))
    }

    func test_canConfirm_emptyIsOnlyAllowedWhenPublishing() {
        XCTAssertTrue(CrossPostPlan.canConfirm([], mode: .publish))
        XCTAssertFalse(CrossPostPlan.canConfirm([], mode: .crossPost))
        XCTAssertTrue(CrossPostPlan.canConfirm(["mercari"], mode: .crossPost))
    }

    func test_candidateFromListing_readsPostedAndPendingAndActive() {
        var listing = UserListing.newDraft(userId: "u")
        listing.customTitle = "Case"
        listing.price = 18
        listing.crossPostStatus = ["mercari": "posted", "ebay": "pending", "etsy": "failed", "facebook": "active"]
        let c = CrossPostCandidate(listing: listing)
        XCTAssertEqual(c.title, "Case")
        XCTAssertEqual(c.price, 18)
        XCTAssertEqual(c.postedPlatforms, ["mercari", "ebay", "facebook"])
    }
}
