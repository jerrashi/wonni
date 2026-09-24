//
//  VariantMercariPostQueueTests.swift
//  wonniTests
//
//  Coverage for `VariantMercariPostQueue` (Data/VariantMercariPostQueue.swift,
//  Phase 3) — but only the slice of it that's actually unit-testable. Read
//  the whole file's doc comments before touching this one.
//
//  WHAT'S TESTED HERE, AND WHY IT'S REAL COVERAGE (not superficial):
//  `items`/`total`/`postedCount`/`failedCount`/`pendingCount`/`inFlightCount`/
//  `isFinished`/`summaryText` are plain, synchronous, side-effect-free
//  computed properties over `[Item]`. `configure(_:)` is the one public,
//  synchronous way to set `items` from outside the class (its setter is
//  `private(set)`), gated only by `guard runTask == nil, !isRunning` — true
//  for every queue this file constructs, since none of these tests ever
//  calls `start()`. So "configure with a hand-built mix of `.posted` /
//  `.failed` / `.pending` / `.retrying` items, then assert the derived
//  counts/summary" is a legitimate, deterministic way to pin down the
//  count-and-summary logic against exactly the terminal states a real run
//  would leave behind — without needing a real run. `cancelPending` is also
//  synchronous and side-effect-free (just `items.remove(at:)`), so it's
//  fully covered directly too.
//
//  WHAT'S DELIBERATELY *NOT* TESTED HERE, AND WHY (an honest gap, not an
//  oversight):
//  The actual retry-then-skip-after-N-attempts loop, "pause doesn't
//  interrupt the current item", and "cancelling mid-run" all live inside
//  `runLoop()` / `postItem(variantId:)` / `runOneAttempt(job:)` — every one
//  of them `private`. The only way an in-flight attempt ever resolves is
//  `reportOutcome(_:)`, which is `fileprivate` (file-scoped access, which
//  `@testable import` does NOT lift — `@testable` only upgrades `internal`
//  declarations to be visible outside the module; it has no effect on
//  `private`/`fileprivate`). In production, `reportOutcome` is only ever
//  called by `VariantMercariPostRunner`'s `MercariAutoPosterView.onOutcome`
//  closure — a real (or headless) `WKWebView`-backed SwiftUI view that this
//  XCTest target never composes into a view hierarchy. So calling `start()`
//  or `retry()` from a test does not hang forever, but it also can never
//  reach a `.posted`/`.failed` outcome the fast way: `currentJob` gets set,
//  nothing observes it, and the ONLY path to resolution is the 90-second
//  `attemptTimeoutNanoseconds` fallback timer inside `runOneAttempt`, times
//  up to `maxAttemptsPerVariant` (3) attempts with a 2-second backoff between
//  each — i.e. a single item reaching `.failed` this way takes several
//  minutes of real wall-clock time, running actual `Task.sleep`s, entirely
//  outside XCTest's control (no fake clock / scheduler seam exists to speed
//  it up). Writing a test that calls `start()` and waits that out would be
//  slow, flaky under CI time pressure, and would leave a background `Task`
//  still running past the test's own completion if the expectation timeout
//  fires first — the appearance of coverage, not real coverage of the retry
//  policy's actual branch logic. That branch logic (`items[idx2].attempts >=
//  Self.maxAttemptsPerVariant` inside `postItem`) is correct by inspection
//  (see VariantMercariPostQueue.swift's own doc comment on the retry
//  policy), but is NOT exercised by this test file. Unlocking real coverage
//  of it without a live WKWebView would need a production-code seam — e.g.
//  making `reportOutcome` `internal` (or injecting an outcome-provider
//  closure in place of the hard-coded `MercariAutoPosterView` call) — which
//  is out of scope here since this task is tests-only.
//

import XCTest
@testable import wonni

@MainActor
final class VariantMercariPostQueueTests: XCTestCase {

    // MARK: - Helpers

    private func job(_ title: String = "Test Listing") -> CrossPostJob {
        CrossPostJob(platform: "mercari", title: title, description: "desc", price: 10)
    }

    private func item(
        _ variantId: String,
        state: VariantMercariPostQueue.Item.State = .pending,
        attempts: Int = 0,
        style: String = "RM",
        size: String? = "M"
    ) -> VariantMercariPostQueue.Item {
        VariantMercariPostQueue.Item(
            variantId: variantId,
            productId: "p",
            styleLabel: style,
            sizeLabel: size,
            job: job(),
            state: state,
            attempts: attempts
        )
    }

    // MARK: - configure

    func test_configure_beforeStart_setsItems() {
        let queue = VariantMercariPostQueue()
        queue.configure([item("v1"), item("v2")])
        XCTAssertEqual(queue.items.map(\.id), ["v1", "v2"])
        XCTAssertEqual(queue.total, 2)
    }

    // MARK: - Summary counts, mirroring what a full run's terminal state looks like

    /// Simulates the terminal state of "a full run just finished": some
    /// posted, one failed after exhausting retries, one still pending
    /// (e.g. the run was paused before it got to it). Every count must add
    /// up, and `summaryText` must reflect exactly these three buckets — this
    /// is the "summary counts staying consistent through a full run" case
    /// the task calls out, exercised via the queue's real state shape
    /// instead of a fabricated one.
    func test_summaryCounts_mixedTerminalStates_addUpCorrectly() {
        let queue = VariantMercariPostQueue()
        queue.configure([
            item("v1", state: .posted(mercariItemId: "m1")),
            item("v2", state: .posted(mercariItemId: "m2")),
            item("v3", state: .failed("Needs manual review"), attempts: 3),
            item("v4", state: .pending),
        ])

        XCTAssertEqual(queue.total, 4)
        XCTAssertEqual(queue.postedCount, 2)
        XCTAssertEqual(queue.failedCount, 1)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(queue.summaryText, "2/4 posted. 1 failed. 1 pending.")
    }

    /// `summaryText`'s failed/pending clauses are conditionally appended —
    /// confirms the all-succeeded case reads as a clean "posted" line with
    /// no trailing "0 failed. 0 pending." noise.
    func test_summaryText_allPosted_omitsFailedAndPendingClauses() {
        let queue = VariantMercariPostQueue()
        queue.configure([
            item("v1", state: .posted(mercariItemId: "m1")),
            item("v2", state: .posted(mercariItemId: "m2")),
        ])
        XCTAssertEqual(queue.summaryText, "2/2 posted.")
    }

    func test_summaryText_emptyQueue_isEmptyString() {
        let queue = VariantMercariPostQueue()
        XCTAssertEqual(queue.summaryText, "")
    }

    /// `.posting` and `.retrying` both count toward `inFlightCount`, not
    /// `pendingCount` — a mid-run snapshot (the queue never actually posts
    /// more than one at a time, but a paused/inspected snapshot can still
    /// have exactly one `.posting`/`.retrying` row alongside `.pending` ones
    /// waiting their turn).
    func test_inFlightCount_countsPostingAndRetrying_notPending() {
        let queue = VariantMercariPostQueue()
        queue.configure([
            item("v1", state: .posting),
            item("v2", state: .retrying(attempt: 2), attempts: 1),
            item("v3", state: .pending),
        ])
        XCTAssertEqual(queue.inFlightCount, 2)
        XCTAssertEqual(queue.pendingCount, 1)
    }

    // MARK: - isFinished

    func test_isFinished_falseBeforeAnyRunStarts_evenWithNoInFlightWork() {
        // isRunning is false (start() was never called) but the definition
        // of isFinished also requires items not to be empty — a queue that
        // was configured but never started should NOT read as "finished".
        let queue = VariantMercariPostQueue()
        queue.configure([item("v1", state: .pending)])
        XCTAssertFalse(queue.isFinished, "a configured-but-never-started queue isn't 'finished'")
    }

    func test_isFinished_emptyQueue_isFalse() {
        let queue = VariantMercariPostQueue()
        XCTAssertFalse(queue.isFinished)
    }

    // MARK: - cancelPending

    /// "Cancelling a pending item just removes it from the queue before its
    /// turn" — the exact behavior the task calls out.
    func test_cancelPending_removesOnlyThatPendingItem() {
        let queue = VariantMercariPostQueue()
        queue.configure([item("v1"), item("v2"), item("v3")])
        queue.cancelPending(variantId: "v2")
        XCTAssertEqual(queue.items.map(\.id), ["v1", "v3"])
    }

    /// Cancelling only ever applies to a `.pending` row — an item that's
    /// already posting, retrying, posted, or failed is left alone (matches
    /// the doc comment: pause/cancel never interrupt in-flight work).
    func test_cancelPending_nonPendingItem_isLeftInPlace() {
        let queue = VariantMercariPostQueue()
        queue.configure([
            item("v1", state: .posting),
            item("v2", state: .posted(mercariItemId: "m2")),
            item("v3", state: .failed("boom")),
        ])
        queue.cancelPending(variantId: "v1")
        queue.cancelPending(variantId: "v2")
        queue.cancelPending(variantId: "v3")
        XCTAssertEqual(queue.items.map(\.id), ["v1", "v2", "v3"], "none of these are .pending, so cancel is a no-op for all three")
    }

    func test_cancelPending_unknownVariantId_isNoOp() {
        let queue = VariantMercariPostQueue()
        queue.configure([item("v1")])
        queue.cancelPending(variantId: "does-not-exist")
        XCTAssertEqual(queue.items.map(\.id), ["v1"])
    }

    // MARK: - Item.displayLabel (small pure helper, cheap to cover alongside the above)

    func test_displayLabel_styleAndSize_joinsWithMiddleDot() {
        let i = item("v1", style: "RM", size: "M")
        XCTAssertEqual(i.displayLabel, "RM \u{00B7} M")
    }

    func test_displayLabel_styleOnly_noSize() {
        let i = item("v1", style: "RM", size: nil)
        XCTAssertEqual(i.displayLabel, "RM")
    }

    func test_displayLabel_neitherStyleNorSize_fallsBackToJobTitle() {
        let i = item("v1", style: "", size: nil)
        XCTAssertEqual(i.displayLabel, "Test Listing")
    }
}
