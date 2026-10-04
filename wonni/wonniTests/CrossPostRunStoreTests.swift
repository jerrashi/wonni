//
//  CrossPostRunStoreTests.swift
//  wonniTests
//
//  The durable cross-post run: what is written, when a run clears itself, and what
//  the "17 of 40 posted — retry?" summary says after an interruption.
//

import XCTest
@testable import wonni

final class CrossPostRunStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "CrossPostRunStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func job(_ platform: String, _ listing: String, kind: PersistedCrossPostJob.Kind = .web, ended: Bool = false) -> PersistedCrossPostJob {
        PersistedCrossPostJob(id: UUID(), kind: kind, platform: platform, title: "Listing \(listing)", listingId: listing, ended: ended)
    }

    // MARK: Store

    func testARunSurvivesAReloadAndClearsItselfOnceEveryJobEnded() {
        let jobs = [job("mercari", "a"), job("mercari", "b")]
        CrossPostRunStore.add(jobs, userId: "u1", defaults: defaults)
        XCTAssertEqual(CrossPostRunStore.load(defaults: defaults)?.jobs.count, 2)

        let afterFirst = CrossPostRunStore.markEnded(where: { $0.id == jobs[0].id }, defaults: defaults)
        XCTAssertEqual(afterFirst?.jobs.map(\.ended), [true, false])
        XCTAssertEqual(CrossPostRunStore.load(defaults: defaults)?.hasUnfinishedJobs, true)

        // The last job ending means the run finished normally: nothing is left behind
        // to be mistaken for an interruption on the next launch.
        XCTAssertNil(CrossPostRunStore.markEnded(where: { $0.id == jobs[1].id }, defaults: defaults))
        XCTAssertNil(CrossPostRunStore.load(defaults: defaults))
    }

    func testJobsQueuedDuringAnUnfinishedRunJoinIt() {
        CrossPostRunStore.add([job("mercari", "a")], userId: "u1", defaults: defaults)
        CrossPostRunStore.add([job("facebook", "a")], userId: "u1", defaults: defaults)
        XCTAssertEqual(CrossPostRunStore.load(defaults: defaults)?.jobs.map(\.platform), ["mercari", "facebook"])
    }

    func testAnotherUsersRunIsReplacedNotExtended() {
        CrossPostRunStore.add([job("mercari", "a")], userId: "u1", defaults: defaults)
        CrossPostRunStore.add([job("mercari", "z")], userId: "u2", defaults: defaults)
        let run = CrossPostRunStore.load(defaults: defaults)
        XCTAssertEqual(run?.userId, "u2")
        XCTAssertEqual(run?.jobs.map(\.listingId), ["z"])
    }

    func testMarkingAnUnknownJobChangesNothing() {
        CrossPostRunStore.add([job("mercari", "a")], userId: "u1", defaults: defaults)
        let run = CrossPostRunStore.markEnded(where: { _ in false }, defaults: defaults)
        XCTAssertEqual(run?.jobs.map(\.ended), [false])
        XCTAssertNil(CrossPostRunStore.markEnded(where: { _ in true }, defaults: UserDefaults(suiteName: "empty-\(UUID().uuidString)")!))
    }

    // MARK: Summary

    func testSummaryCountsPerPlatformAndKeepsOnlyUnpostedJobsForRetry() {
        // 5 Mercari jobs: 2 confirmed posted in Firestore, 3 not. eBay: both posted.
        let mercari = (1...5).map { job("mercari", "m\($0)") }
        let ebay = [job("ebay", "m1", kind: .api, ended: true), job("ebay", "m2", kind: .api, ended: true)]
        let run = CrossPostRun(userId: "u1", jobs: mercari + ebay)
        let postedListings: Set<String> = ["m1", "m2"]

        let summary = InterruptedCrossPostSummary.make(run: run) { postedListings.contains($0.listingId ?? "") }
        XCTAssertEqual(summary?.lines, [.init(platform: "mercari", posted: 2, total: 5)], "a platform with nothing left gets no line")
        XCTAssertEqual(summary?.remaining.map(\.listingId), ["m3", "m4", "m5"])
        XCTAssertEqual(summary?.message, "2 of 5 listings posted to Mercari.")
    }

    func testFirestoreOverridesTheLocalEndedFlagBothWays() {
        // Ended locally but Firestore says it never posted (the attempt failed): retry it.
        // Not ended locally but Firestore says posted (cut off after submit): don't.
        let failed = job("mercari", "a", ended: true)
        let cutOffAfterPosting = job("mercari", "b", ended: false)
        let run = CrossPostRun(userId: "u1", jobs: [failed, cutOffAfterPosting])
        let summary = InterruptedCrossPostSummary.make(run: run) { $0.listingId == "b" }
        XCTAssertEqual(summary?.remaining.map(\.listingId), ["a"])
        XCTAssertEqual(summary?.lines, [.init(platform: "mercari", posted: 1, total: 2)])
    }

    func testWithNoFirestoreAnswerTheLocalFlagStands() {
        let run = CrossPostRun(userId: "u1", jobs: [job("facebook", "a", ended: true), job("facebook", "b")])
        let summary = InterruptedCrossPostSummary.make(run: run) { _ in nil }
        XCTAssertEqual(summary?.remaining.map(\.listingId), ["b"])
        XCTAssertEqual(summary?.message, "1 of 2 listings posted to Facebook Marketplace.")
    }

    func testNothingLeftMeansNoSummary() {
        let run = CrossPostRun(userId: "u1", jobs: [job("mercari", "a"), job("etsy", "a", kind: .api)])
        XCTAssertNil(InterruptedCrossPostSummary.make(run: run) { _ in true })
    }

    func testSingularWording() {
        let run = CrossPostRun(userId: "u1", jobs: [job("etsy", "a", kind: .api)])
        XCTAssertEqual(InterruptedCrossPostSummary.make(run: run) { _ in false }?.message, "0 of 1 listing posted to Etsy.")
    }

    // MARK: Replay

    func testAWebJobRoundTripsThroughTheStoreWithEverythingARetryNeeds() {
        let original = CrossPostJob(
            platform: "mercari", title: "Mario Kart Wii", description: "CIB", price: 12,
            listingId: "L1", photoFirebasePaths: ["users/u/listings/L1/0.jpg"],
            buyerPaysShipping: true, condition: "likeNew", suggestedCategory: "Video Games",
            suggestedBrand: "Nintendo", weightLbs: 0.25, lengthIn: 7.5, widthIn: 5.5, heightIn: 0.5
        )
        let persisted = PersistedCrossPostJob(original)
        XCTAssertEqual(persisted.id, original.id, "the queue marks this exact entry ended by id")
        XCTAssertEqual(persisted.kind, .web)

        let data = try? JSONEncoder().encode(persisted)
        let decoded = data.flatMap { try? JSONDecoder().decode(PersistedCrossPostJob.self, from: $0) }
        XCTAssertEqual(decoded, persisted)

        let replay = persisted.replayJob
        XCTAssertNotEqual(replay.id, original.id, "a retry is a new attempt")
        XCTAssertNil(replay.item)
        XCTAssertEqual(replay.listingId, "L1")
        XCTAssertEqual(replay.photoFirebasePaths, ["users/u/listings/L1/0.jpg"])
        XCTAssertEqual(replay.price, 12)
        XCTAssertEqual(replay.condition, "likeNew")
        XCTAssertEqual(replay.buyerPaysShipping, true)
        XCTAssertEqual(replay.weightLbs, 0.25)
        XCTAssertEqual(replay.suggestedBrand, "Nintendo")
    }
}

/// An edit saved to `listings/{id}` has to reach `products/{id}` before the eBay /
/// Etsy update functions run — they read the product doc. Until 2026-10-03 nothing
/// copied it over, so edited photos and prices never reached eBay.
final class ListingEditProductPatchTests: XCTestCase {
    private func url(_ path: String) -> String { "https://storage.googleapis.com/bucket/\(path)" }

    func testAnEditedListingMapsToTheFieldsTheUpdateFunctionsRead() {
        let listing = UserListing(
            id: "L1", userId: "u1", catalogItemId: "c1",
            customTitle: "Fire Emblem The Sacred Stones GBA CIB",
            customDescription: "Complete in box.",
            price: 174.99,
            quantity: 2,
            condition: .likeNew,
            photoPaths: ["users/u1/L1/NEW-A.jpg", "https://cdn.example.com/b.jpg"],
            shippingInfo: ShippingInfo(
                buyerPaysShipping: false, handlingFee: 0, estimatedShippingDays: 3,
                weightLbs: 0.5, packageDimensions: PackageDimensions(lengthIn: 6, widthIn: 4, heightIn: 1),
                handlingTimeDays: 2
            ),
            crossPostStatus: ["mercari": "posted", "ebay": "posted"],
            crossPostListingIds: ["ebay": "147617462316"]
        )
        let patch = ProductRepository.editPatch(from: listing, publicURL: url)

        XCTAssertEqual(patch["title"] as? String, "Fire Emblem The Sacred Stones GBA CIB")
        XCTAssertEqual(patch["description"] as? String, "Complete in box.")
        XCTAssertEqual(patch["listingPrice"] as? Double, 174.99)
        XCTAssertEqual(patch["quantity"] as? Int, 2)
        XCTAssertEqual(patch["condition"] as? String, "likenew")
        // Bare Storage keys become public URLs; a full URL is left alone.
        XCTAssertEqual(patch["images"] as? [String], [
            "https://storage.googleapis.com/bucket/users/u1/L1/NEW-A.jpg",
            "https://cdn.example.com/b.jpg"
        ])
        XCTAssertEqual(patch["buyerPaysShipping"] as? Bool, false)
        XCTAssertEqual(patch["weightLbs"] as? Double, 0.5)
        XCTAssertEqual(patch["lengthIn"] as? Double, 6)
        XCTAssertEqual(patch["widthIn"] as? Double, 4)
        XCTAssertEqual(patch["heightIn"] as? Double, 1)
        XCTAssertEqual(patch["handlingTimeDays"] as? Int, 2)
    }

    func testThePatchNeverTouchesWhatTheCloudFunctionsOwn() {
        let listing = UserListing(
            id: "L1", userId: "u1", catalogItemId: "c1", customTitle: "T", price: 5,
            crossPostStatus: ["ebay": "posted"], crossPostListingIds: ["ebay": "1"]
        )
        let patch = ProductRepository.editPatch(from: listing, publicURL: url)
        // products says "active" where the app says "posted"; overwriting it would make
        // ebayCreateListing think the product is not live and post a duplicate.
        for key in ["crossPostStatus", "crossPostListingIds", "isDraft", "userId", "ebayOfferId", "source"] {
            XCTAssertNil(patch[key], "\(key) must not be written by an edit")
        }
    }

    func testAbsentValuesAreLeftOutRatherThanNulled() {
        let listing = UserListing(id: "L1", userId: "u1", catalogItemId: "c1")
        let patch = ProductRepository.editPatch(from: listing, publicURL: url)
        for key in ["title", "description", "listingPrice", "quantity", "weightLbs", "lengthIn", "category", "brand", "buyerPaysShipping"] {
            XCTAssertNil(patch[key], "\(key) should be absent")
        }
        XCTAssertEqual(patch["images"] as? [String], [])
    }
}
