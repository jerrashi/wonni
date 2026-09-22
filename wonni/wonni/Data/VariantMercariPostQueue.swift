//
//  VariantMercariPostQueue.swift
//  wonni
//
//  Phase 3 — sequential, background batch poster: "post every active variant
//  of this product to Mercari as its own one-item-one-size listing" (Mercari
//  has no variant concept — see CrossPostJob.variantProductId/variantId's
//  doc comment). Reuses MercariAutoPosterView/MercariPostingState
//  (CrossPostWebView.swift) — the exact same headless WKWebView posting
//  engine the single-listing "Re-list on Mercari" flow already runs — for
//  every posting attempt; this type only owns queue order, the
//  retry-then-skip policy, and published status for
//  VariantMercariBatchPostView. It never rebuilds the posting mechanism.
//
//  Sequencing: never posts more than one variant at a time. "Pause" stops
//  starting the *next* queued item once the current one finishes — it never
//  interrupts a listing mid-post. Cancelling a pending item just removes it
//  from the queue before its turn.
//
//  Retry policy: a variant that fails is retried in place up to
//  `maxAttemptsPerVariant` times (a short backoff between attempts) before
//  being marked failed and the queue moving on to the next variant — a
//  single stuck listing never blocks the rest of the batch. Failures are
//  surfaced in the status UI with a manual "Retry" action.
//

import SwiftUI

@MainActor
final class VariantMercariPostQueue: ObservableObject {

    /// One row in the batch — a variant to post, its resolved `CrossPostJob`
    /// (title/photos/price already baked in by the caller — see
    /// `VariantsEditorView.buildMercariBatchItems`), and its state in the queue.
    struct Item: Identifiable {
        enum State {
            case pending
            case posting
            case retrying(attempt: Int)
            case posted(mercariItemId: String)
            case failed(String)
        }

        let variantId: String
        let productId: String
        let styleLabel: String
        let sizeLabel: String?
        var job: CrossPostJob
        var state: State = .pending
        var attempts: Int = 0

        var id: String { variantId }

        var displayLabel: String {
            switch (styleLabel.isEmpty, sizeLabel?.isEmpty ?? true) {
            case (false, false): return "\(styleLabel) \u{00B7} \(sizeLabel ?? "")"
            case (false, true):  return styleLabel
            default:             return job.title
            }
        }
    }

    /// 1 initial attempt + this many retries before giving up on a variant
    /// and moving to the next one ("retry a couple of times" per the design
    /// conversation).
    static let maxAttemptsPerVariant = 3
    /// How long to wait for one headless attempt to resolve before treating
    /// it as stuck — Mercari required something this unattended pass can't
    /// do (pick a category, log back in, confirm a stuck submission) — and
    /// counting it as a failed attempt instead of hanging the whole batch.
    static let attemptTimeoutNanoseconds: UInt64 = 90 * 1_000_000_000

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    /// The job currently mounted headlessly, if any. `VariantMercariPostRunner`
    /// renders `MercariAutoPosterView(job:, headless: true, onOutcome:)` only
    /// while this is non-nil, so exactly one posting attempt is ever in flight.
    @Published fileprivate(set) var currentJob: CrossPostJob?

    var total: Int { items.count }
    var postedCount: Int { items.filter { if case .posted = $0.state { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    var pendingCount: Int { items.filter { if case .pending = $0.state { return true }; return false }.count }
    var inFlightCount: Int {
        items.filter {
            switch $0.state {
            case .posting, .retrying: return true
            default: return false
            }
        }.count
    }
    var isFinished: Bool { !isRunning && pendingCount == 0 && inFlightCount == 0 && !items.isEmpty }

    /// Compact one-line status the collapsed UI shows, e.g.
    /// "3/5 posted. 1 failed. 1 pending."
    var summaryText: String {
        guard !items.isEmpty else { return "" }
        var parts = ["\(postedCount)/\(total) posted"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if pendingCount > 0 { parts.append("\(pendingCount) pending") }
        return parts.joined(separator: ". ") + "."
    }

    private var runTask: Task<Void, Never>?
    private var outcomeContinuation: CheckedContinuation<MercariPostOutcome, Never>?

    /// Sets the queue's initial contents. No-op once a run has started —
    /// call before `start()`.
    func configure(_ items: [Item]) {
        guard runTask == nil, !isRunning else { return }
        self.items = items
    }

    func start() {
        guard !items.isEmpty, runTask == nil else { return }
        isPaused = false
        isRunning = true
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Stops starting the *next* queued item once the current one finishes.
    /// Never interrupts a listing mid-post.
    func pause() { isPaused = true }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if runTask == nil { start() }
    }

    /// Removes a not-yet-started item from the queue — "cancelling a pending
    /// item just removes it from the queue before its turn".
    func cancelPending(variantId: String) {
        guard let idx = items.firstIndex(where: { $0.id == variantId }) else { return }
        guard case .pending = items[idx].state else { return }
        items.remove(at: idx)
    }

    /// Re-queues one failed item — the status UI's per-item "Retry" action.
    func retry(variantId: String) {
        guard let idx = items.firstIndex(where: { $0.id == variantId }) else { return }
        guard case .failed = items[idx].state else { return }
        items[idx].state = .pending
        items[idx].attempts = 0
        if runTask == nil { start() }
    }

    /// Called by `VariantMercariPostRunner`'s `MercariAutoPosterView.onOutcome`
    /// closure — resolves the attempt the run loop is currently awaiting. A
    /// no-op if nothing is currently awaited (e.g. the timeout already fired).
    fileprivate func reportOutcome(_ outcome: MercariPostOutcome) {
        guard let continuation = outcomeContinuation else { return }
        outcomeContinuation = nil
        continuation.resume(returning: outcome)
    }

    private func runLoop() async {
        while !isPaused {
            guard let idx = items.firstIndex(where: { if case .pending = $0.state { return true }; return false }) else { break }
            await postItem(variantId: items[idx].id)
        }
        isRunning = false
        runTask = nil
    }

    private func postItem(variantId: String) async {
        while true {
            guard let idx = items.firstIndex(where: { $0.id == variantId }) else { return }
            items[idx].attempts += 1
            let attempt = items[idx].attempts
            items[idx].state = attempt == 1 ? .posting : .retrying(attempt: attempt)
            let job = items[idx].job

            let outcome = await runOneAttempt(job: job)

            guard let idx2 = items.firstIndex(where: { $0.id == variantId }) else { return }
            switch outcome {
            case .success(let mercariItemId):
                items[idx2].state = .posted(mercariItemId: mercariItemId)
                return
            case .failed(let reason):
                if items[idx2].attempts >= Self.maxAttemptsPerVariant {
                    items[idx2].state = .failed(reason)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // brief backoff before retrying
            }
        }
    }

    /// Mounts one headless `MercariAutoPosterView` (via `currentJob`, picked
    /// up by `VariantMercariPostRunner`) and awaits its terminal outcome, or
    /// a timeout if it needed interaction this unattended pass can't give it.
    private func runOneAttempt(job: CrossPostJob) async -> MercariPostOutcome {
        currentJob = job
        let jobId = job.id
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<MercariPostOutcome, Never>) in
            outcomeContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.attemptTimeoutNanoseconds)
                guard let self, self.currentJob?.id == jobId else { return }
                self.reportOutcome(.failed("Needs manual review on Mercari (category, login, or an unconfirmed submission) — timed out waiting"))
            }
        }
        currentJob = nil
        return outcome
    }
}

// MARK: - Headless runner (mounts MercariAutoPosterView off-screen)

/// Invisible host that mounts `MercariAutoPosterView` in headless mode
/// whenever the queue has a `currentJob`, feeding its outcome back into the
/// queue. Embed this once per `VariantMercariPostQueue` instance — it does
/// no layout of its own, matching the same "invisible background WebView"
/// approach `MercariAutoPosterView`'s own pill mode already uses.
struct VariantMercariPostRunner: View {
    @ObservedObject var queue: VariantMercariPostQueue

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(
                Group {
                    if let job = queue.currentJob {
                        MercariAutoPosterView(
                            job: job,
                            headless: true,
                            onOutcome: { outcome in queue.reportOutcome(outcome) }
                        )
                        .opacity(0.01)
                        .allowsHitTesting(false)
                    }
                }
            )
    }
}
