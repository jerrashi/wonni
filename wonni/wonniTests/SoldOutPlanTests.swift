//
//  SoldOutPlanTests.swift
//  wonniTests
//
//  The sold-out queue's rules (SoldOutRun.swift): which platforms a job covers, the
//  pill text, the confirm copy per Mercari action, and the persisted store's
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

    func testConfirmationNamesTheMercariAction() {
        let deactivate = SoldOutPlan.confirmation(count: 4, mercariCount: 3, action: .deactivate)
        XCTAssertEqual(deactivate.title, "Mark 4 listings as sold out?")
        XCTAssertTrue(deactivate.message.contains("3 are on Mercari and will be deactivated"))
        XCTAssertEqual(deactivate.button, "Mark Sold Out")

        let delete = SoldOutPlan.confirmation(count: 1, mercariCount: 1, action: .delete)
        XCTAssertEqual(delete.title, "Mark as sold out?")
        XCTAssertTrue(delete.message.contains("Delete out-of-stock listings on Mercari?"))
        XCTAssertEqual(delete.button, "Mark Sold Out & Delete on Mercari")

        let none = SoldOutPlan.confirmation(count: 2, mercariCount: 0, action: .delete)
        XCTAssertFalse(none.message.contains("Mercari"))
        XCTAssertEqual(none.button, "Mark Sold Out")
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
