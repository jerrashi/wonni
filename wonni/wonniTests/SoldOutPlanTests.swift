//
//  SoldOutPlanTests.swift
//  wonniTests
//
//  The sold-out queue's rules (SoldOutRun.swift): which platforms a job covers, the
//  task bar text, which platforms can be skipped, and the persisted store's
//  clear-when-finished behaviour.
//

import XCTest
@testable import wonni

final class SoldOutPlanTests: XCTestCase {

    private func job(status: [String: String]? = nil, ids: [String: String]? = nil, quantity: Int? = nil,
                     action: MercariSoldOutAction = .deactivate) -> SoldOutJob {
        SoldOutPlan.makeJob(listingId: "L1", title: "Nike Dunk", coverPhotoPath: nil, quantity: quantity,
                            crossPostStatus: status, crossPostListingIds: ids, action: action)
    }

    // MARK: Mercari decision table (live status × seller preference)

    func testActiveListingFollowsThePreference() {
        XCTAssertEqual(SoldOutPlan.mercariDecision(state: .active, preference: .deactivate), .deactivate)
        XCTAssertEqual(SoldOutPlan.mercariDecision(state: .active, preference: .delete), .delete)
    }

    func testInactiveListingIsLeftAloneUnlessThePreferenceIsDelete() {
        XCTAssertEqual(SoldOutPlan.mercariDecision(state: .inactive, preference: .deactivate), .nothing(.alreadyInactive))
        XCTAssertEqual(SoldOutPlan.mercariDecision(state: .inactive, preference: .delete), .delete)
    }

    func testUnavailablePageOnlyTriesDeleteWhenThePreferenceIsDelete() {
        XCTAssertEqual(SoldOutPlan.mercariDecision(state: .unavailable, preference: .deactivate), .nothing(.alreadyInactive))
        XCTAssertEqual(SoldOutPlan.mercariDecision(state: .unavailable, preference: .delete), .delete)
    }

    func testSoldListingIsNeverTouched() {
        for preference in MercariSoldOutAction.allCases {
            XCTAssertEqual(SoldOutPlan.mercariDecision(state: .sold, preference: preference), .nothing(.alreadySold))
        }
    }

    func testUnreadableStatusNeverActs() {
        for preference in MercariSoldOutAction.allCases {
            XCTAssertEqual(SoldOutPlan.mercariDecision(state: .unknown, preference: preference), .stop)
        }
    }

    func testOnlyARemovedListingLosesItsMercariId() {
        XCTAssertTrue(MercariSoldOutOutcome.deleted.removedFromMercari)
        XCTAssertTrue(MercariSoldOutOutcome.alreadyGone.removedFromMercari)
        XCTAssertFalse(MercariSoldOutOutcome.deactivated.removedFromMercari)
        XCTAssertFalse(MercariSoldOutOutcome.alreadyInactive.removedFromMercari)
        XCTAssertFalse(MercariSoldOutOutcome.alreadySold.removedFromMercari)
    }

    func testJobCoversWonniPlusLiveAPIPlatformsOnly() {
        let built = job(status: ["ebay": "posted", "etsy": "failed", "tiktok": "active", "mercari": "posted"],
                    ids: ["mercari": "m123"])
        XCTAssertEqual(built.serverPlatforms, ["wonni", "ebay", "tiktok"])
        XCTAssertEqual(built.mercariItemId, "m123")
        XCTAssertTrue(built.hasMercariStep)
        XCTAssertEqual(built.mercariStep, .waiting)
    }

    func testNoMercariMeansMercariStepIsAlreadyDone() {
        let built = job(status: ["ebay": "posted"])
        XCTAssertNil(built.mercariItemId)
        XCTAssertEqual(built.mercariStep, .done)
        XCTAssertEqual(built.serverPlatforms, ["wonni", "ebay"])
    }

    func testEmptyMercariIdCountsAsNotOnMercari() {
        XCTAssertFalse(job(ids: ["mercari": ""]).hasMercariStep)
    }

    func testPreviousQuantityDefaultsToOne() {
        XCTAssertEqual(job(quantity: nil).previousQuantity, 1)
        XCTAssertEqual(job(quantity: 0).previousQuantity, 1)
        XCTAssertEqual(job(quantity: 3).previousQuantity, 3)
    }

    func testResetClearsAttemptButKeepsMercariDoneWhenNotOnMercari() {
        var withMercari = job(ids: ["mercari": "m1"])
        withMercari.serverStep = .done; withMercari.mercariStep = .failed("x"); withMercari.failure = "x"; withMercari.ended = true
        let restored = withMercari.reset
        XCTAssertEqual(restored.serverStep, .waiting); XCTAssertEqual(restored.mercariStep, .waiting)
        XCTAssertNil(restored.failure); XCTAssertFalse(restored.ended)

        var without = job()
        without.serverStep = .failed("y"); without.failure = "y"; without.ended = true
        XCTAssertEqual(without.reset.mercariStep, .done)
    }

    func testPillLabelCountsTheListingBeingWorkedOn() {
        var jobs = [job(), job(), job(), job()]
        XCTAssertEqual(SoldOutPlan.pillLabel(jobs: jobs), "Marking sold out · 1 of 4")
        jobs[0].ended = true
        XCTAssertEqual(SoldOutPlan.pillLabel(jobs: jobs), "Marking sold out · 2 of 4")
        for index in jobs.indices { jobs[index].ended = true }
        XCTAssertEqual(SoldOutPlan.pillLabel(jobs: jobs), "Marking sold out · 4 of 4")
        XCTAssertEqual(SoldOutPlan.progress(jobs: jobs), 1)
    }

    func testPillDetailNamesTheRunningStep() {
        var built = job(ids: ["mercari": "m1"])
        built.serverStep = .done
        built.mercariStep = .running("Deactivating on Mercari")
        XCTAssertEqual(SoldOutPlan.pillDetail(jobs: [built]), "Deactivating on Mercari: Nike Dunk")
        XCTAssertNil(SoldOutPlan.pillDetail(jobs: []))
    }

    // MARK: Skipping platforms (2026-11-19)

    func testTogglesListOnlyPlatformsTheSelectionIsOn() {
        let ebayOnly = job(status: ["ebay": "active"])
        let mercariOnly = job(ids: ["mercari": "m1"])
        XCTAssertEqual(SoldOutPlan.togglePlatforms([ebayOnly]), ["ebay"])
        XCTAssertEqual(SoldOutPlan.togglePlatforms([ebayOnly, mercariOnly]), ["ebay", "mercari"])
        XCTAssertEqual(SoldOutPlan.togglePlatforms([job()]), [])
    }

    func testSkippedMercariStartsSkippedAndSurvivesReset() {
        let built = SoldOutPlan.makeJob(listingId: "L1", title: "Nike Dunk", coverPhotoPath: nil, quantity: 1,
                                        crossPostStatus: ["ebay": "active"], crossPostListingIds: ["mercari": "m1"],
                                        action: .deactivate, skip: ["mercari", "etsy"])
        XCTAssertEqual(built.skipPlatforms, ["mercari"], "a platform the listing isn't on is dropped")
        XCTAssertEqual(built.mercariStep, .skipped)
        XCTAssertEqual(built.reset.mercariStep, .skipped)
        XCTAssertEqual(SoldOutPlan.serverRowTitle(built), "Wonni + eBay")
    }

    func testSkippedEbayDropsOutOfTheServerRow() {
        var built = job(status: ["ebay": "active", "etsy": "active"])
        built.addSkip(["ebay"])
        XCTAssertEqual(SoldOutPlan.serverRowTitle(built), "Wonni + Etsy")
        XCTAssertTrue(SoldOutJob.StepState.skipped.isTerminal)
    }

    func testPlatformFailureTextNamesEachPlatform() {
        XCTAssertEqual(SoldOutPlan.platformFailureText(["ebay": "System error"]), "eBay: System error")
    }

    func testResetClearsPlatformErrors() {
        var built = job(status: ["ebay": "active"])
        built.platformErrors = ["ebay": "x"]; built.failure = "eBay: x"; built.ended = true
        XCTAssertNil(built.reset.platformErrors)
    }

    func testRunsSavedByOlderBuildsStillDecode() throws {
        // Persisted before skipPlatforms / platformErrors existed.
        let old = #"{"id":"6B1C1D52-2A0E-4D8E-9F8A-0D1F2C3B4A59","listingId":"L1","title":"T","previousQuantity":1,"serverPlatforms":["wonni"],"mercariAction":"deactivate","serverStep":{"waiting":{}},"mercariStep":{"done":{}},"ended":false}"#
        let decoded = try JSONDecoder().decode(SoldOutJob.self, from: Data(old.utf8))
        XCTAssertNil(decoded.skipPlatforms)
        XCTAssertFalse(decoded.skipsMercari)
    }

    func testFailureSummaryAndPill() {
        XCTAssertNil(SoldOutPlan.failureSummary([]))
        XCTAssertEqual(SoldOutPlan.failureSummary([job()]), "1 listing was not marked sold out and is still in stock.")
        XCTAssertEqual(SoldOutPlan.failurePillLabel(2), "2 not marked sold out")
    }

    func testStoreClearsOnceEveryJobEnded() {
        guard let defaults = UserDefaults(suiteName: "SoldOutPlanTests.\(UUID().uuidString)") else { return XCTFail("no defaults") }
        var jobs = [job(), job()]
        SoldOutRunStore.sync(jobs: jobs, userId: "u1", defaults: defaults)
        XCTAssertEqual(SoldOutRunStore.load(defaults: defaults)?.jobs.count, 2)
        jobs[0].ended = true
        SoldOutRunStore.sync(jobs: jobs, userId: "u1", defaults: defaults)
        XCTAssertTrue(SoldOutRunStore.load(defaults: defaults)?.hasUnfinishedJobs == true)
        jobs[1].ended = true
        SoldOutRunStore.sync(jobs: jobs, userId: "u1", defaults: defaults)
        XCTAssertNil(SoldOutRunStore.load(defaults: defaults))
    }

    func testShippingModeFromSettingsPage() {
        XCTAssertEqual(MercariSettingsView.shippingMode(useMercariLabels: false, carriers: [.usps]), .shipOnOwn)
        XCTAssertEqual(MercariSettingsView.shippingMode(useMercariLabels: true, carriers: Set(Carrier.allCases)), .cheapestPrepaid)
        XCTAssertEqual(MercariSettingsView.shippingMode(useMercariLabels: true, carriers: [.usps, .ups]), .cheapestAmongCarriers)
    }
}
