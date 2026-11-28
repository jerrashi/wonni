//
//  SoldOutRunner.swift
//  wonni
//
//  Runs the sold-out queue outside any view (see SoldOutRun.swift for the rules and
//  BACKEND.md § "Sold-out + sales tracking — product decisions" for the agreement).
//
//  Per listing, in order:
//   1. `markSoldOutAndCascade` — zeroes every active variant and cascades quantity 0
//      to eBay / Etsy / TikTok; also sets `pendingMercariDeactivation`.
//   2. If the listing is on Mercari: `MercariListingStateAutomator` opens the listing by
//      its id, reads its live status and applies `SoldOutPlan.mercariDecision` (which may
//      be nothing), in a web view the progress sheet can show. Mercari has no API.
//  Each step gets `SoldOutPlan.stepTimeout` and one automatic retry. A listing whose
//  Mercari step still fails is put BACK in stock (the server call already went
//  through) and listed at the end as "not marked sold out" — the user asked for
//  exactly the failed-platform list publishing shows, never a half-done listing.
//
//  Progress is the one shared AppTaskQueue pill; tapping it opens SoldOutProgressView
//  (MainView presents it, since the sheet that started the run may be gone). The run
//  is persisted (SoldOutRunStore) so a kill mid-run shows "Marking sold out was
//  interrupted" on the next launch with Resume.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

@MainActor
final class SoldOutRunner: ObservableObject {
    static let shared = SoldOutRunner()
    private init() {}

    enum Phase: Equatable {
        case idle
        case running
        /// Every job ended, at least one failed. Cleared by Retry or Dismiss.
        case finished(failed: [SoldOutJob])
    }

    struct Interrupted: Equatable {
        let remaining: Int
        let total: Int
        var message: String {
            "\(total - remaining) of \(total) listing\(total == 1 ? "" : "s") marked sold out before the app closed."
        }
    }

    @Published private(set) var jobs: [SoldOutJob] = []
    @Published private(set) var phase: Phase = .idle
    /// MainView presents SoldOutProgressView while this is true.
    @Published var showSheet = false
    /// A cut-off run found at launch; MainView shows it as an alert with Resume.
    @Published var interrupted: Interrupted?
    /// The Mercari automation in flight, for the sheet's "Open" web view.
    @Published private(set) var currentAutomator: MercariListingStateAutomator?
    /// The job the automation above belongs to.
    @Published private(set) var currentMercariJobId: UUID?
    /// Bumped whenever a run ends, so the listings screen can reload.
    @Published private(set) var finishedRunCount = 0
    /// Listings waiting on the confirm sheet (MainView presents SoldOutConfirmSheet).
    @Published var pendingConfirmation: [UserListing]?

    private let taskId = UUID()
    private var runTask: Task<Void, Never>?
    /// Set by Stop in the web view: the current Mercari step ends as a failure.
    private var stopRequested = false
    /// Set by Skip on the running Mercari step: it stops and counts as skipped.
    private var skipRequestedJobId: UUID?
    /// How each job's Mercari step ended (the last successful attempt).
    private var mercariOutcomes: [UUID: MercariSoldOutOutcome] = [:]

    var isRunning: Bool { phase == .running }

    // MARK: Control

    /// The account-wide Mercari sold-out setting (Profile › Settings › Mercari).
    static var mercariAction: MercariSoldOutAction {
        MercariSoldOutAction(rawValue: UserDefaults.standard.string(forKey: MercariSoldOutAction.storageKey) ?? "") ?? .deactivate
    }

    /// Every "Mark as sold out" entry point calls this; the confirm sheet (platform
    /// toggles) opens from MainView. The short wait lets a sheet the request came from
    /// (Edit Listing, Bulk Edit) finish dismissing first — two presentations in the
    /// same frame break SwiftUI's presentation stack.
    func requestMarkSoldOut(_ listings: [UserListing]) {
        let usable = listings.filter { $0.id != nil }
        guard !usable.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.pendingConfirmation = usable
        }
    }

    /// Queues one job per listing and starts the loop if it is not already running.
    /// `action` is the account setting; `skip` the platforms turned off on the sheet.
    func enqueue(_ listings: [UserListing], action: MercariSoldOutAction, skip: Set<String> = []) {
        let newJobs = listings.compactMap { listing -> SoldOutJob? in
            guard let id = listing.id else { return nil }
            return SoldOutPlan.makeJob(
                listingId: id,
                title: listing.customTitle,
                coverPhotoPath: listing.coverPhotoPath,
                quantity: listing.quantity,
                crossPostStatus: listing.crossPostStatus,
                crossPostListingIds: listing.crossPostListingIds,
                action: action,
                skip: skip
            )
        }
        guard !newJobs.isEmpty else { return }
        // A finished-with-failures run is over; a new request starts fresh.
        if case .finished = phase { clearFinished() }
        // Re-queuing a listing that is already waiting or running is a no-op.
        let queuedIds = Set(jobs.filter { !$0.ended }.map(\.listingId))
        jobs.append(contentsOf: newJobs.filter { !queuedIds.contains($0.listingId) })
        persist()
        startLoopIfNeeded()
    }

    /// Drops a job that has not started yet.
    func remove(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), !jobs[index].ended,
              jobs[index].serverStep == .waiting else { return }
        jobs.remove(at: index)
        persist()
        refreshPill()
        if jobs.isEmpty { finishRun() }
    }

    /// Re-runs one failed job (from the progress sheet's Retry).
    func retry(_ jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].failure != nil else { return }
        jobs[index] = jobs[index].reset
        if case .finished = phase { phase = .idle }
        persist()
        startLoopIfNeeded()
    }

    /// Re-runs every failed job (end-of-run "Retry all").
    func retryAllFailed() {
        for index in jobs.indices where jobs[index].failure != nil {
            jobs[index] = jobs[index].reset
        }
        if case .finished = phase { phase = .idle }
        persist()
        startLoopIfNeeded()
    }

    /// Skip on a step in the progress list: leave that platform as it is.
    ///  - Mercari, not started: the step is skipped when the job runs.
    ///  - Mercari, running: the page is stopped and the step counts as skipped.
    ///  - Mercari, failed (stock was restored): the job runs again with Mercari
    ///    skipped, which marks the listing sold out on Wonni again.
    ///  - API platforms that failed: accepted as they are (Wonni is already sold out).
    func skip(_ jobId: UUID, mercari: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        if mercari {
            switch jobs[index].mercariStep {
            case .running:
                guard currentMercariJobId == jobId else { return }
                skipRequestedJobId = jobId
                stopRequested = true
            case .failed:
                jobs[index].addSkip(["mercari"])
                jobs[index] = jobs[index].reset
                if case .finished = phase { phase = .idle }
                persist()
                startLoopIfNeeded()
            default:
                jobs[index].addSkip(["mercari"])
                if jobs[index].mercariStep == .waiting { jobs[index].mercariStep = .skipped }
                persist()
                refreshPill()
            }
            return
        }
        guard let errors = jobs[index].platformErrors, !errors.isEmpty else { return }
        jobs[index].addSkip(Array(errors.keys))
        jobs[index].platformErrors = nil
        jobs[index].serverStep = .done
        if jobs[index].ended, !Self.isFailed(jobs[index].mercariStep) { jobs[index].failure = nil }
        persist()
        refreshPill()
        settleFinishedRun()
    }

    private static func isFailed(_ step: SoldOutJob.StepState) -> Bool {
        if case .failed = step { return true }
        return false
    }

    /// After a Skip on a finished run: once nothing failed any more, the run is over.
    private func settleFinishedRun() {
        guard case .finished = phase else { return }
        let failed = jobs.filter { $0.failure != nil }
        if failed.isEmpty {
            finishedRunCount += 1
            clearFinished()
        } else {
            phase = .finished(failed: failed)
            AppTaskQueue.shared.update(id: taskId, label: SoldOutPlan.failurePillLabel(failed.count))
        }
    }

    /// Stops the Mercari step in flight; the job ends as a failure and the queue moves on.
    func stopCurrentMercariStep() {
        guard currentAutomator != nil else { return }
        stopRequested = true
    }

    /// End-of-run Dismiss: the failed listings stay in stock, the pill goes away.
    func dismissFinished() {
        clearFinished()
    }

    /// Launch / foreground check for a run the process did not live to finish.
    func checkInterrupted() {
        guard !isRunning, interrupted == nil, jobs.isEmpty,
              let run = SoldOutRunStore.load(), run.hasUnfinishedJobs,
              run.userId == Auth.auth().currentUser?.uid else { return }
        // Carry the finished ones over so the progress list still shows them.
        jobs = run.jobs.map { $0.ended ? $0 : $0.reset }
        interrupted = Interrupted(remaining: run.jobs.filter { !$0.ended }.count, total: run.jobs.count)
    }

    func resumeInterrupted() {
        interrupted = nil
        startLoopIfNeeded()
    }

    func dismissInterrupted() {
        interrupted = nil
        jobs = []
        SoldOutRunStore.clear()
    }

    // MARK: Loop

    private func startLoopIfNeeded() {
        guard runTask == nil, jobs.contains(where: { !$0.ended }) else { return }
        phase = .running
        AppTaskQueue.shared.dismiss(id: taskId)
        AppTaskQueue.shared.begin(
            id: taskId,
            label: SoldOutPlan.pillLabel(jobs: jobs),
            detail: SoldOutPlan.pillDetail(jobs: jobs),
            progress: SoldOutPlan.progress(jobs: jobs),
            accentColor: .red,
            onTap: { [weak self] in self?.showSheet = true }
        )
        runTask = Task { [weak self] in
            guard let self else { return }
            while let index = self.jobs.firstIndex(where: { !$0.ended }) {
                await self.process(jobId: self.jobs[index].id)
            }
            self.runTask = nil
            self.finishRun()
        }
    }

    private func process(jobId: UUID) async {
        guard let job = self.job(jobId) else { return }
        let listingId = job.listingId

        // 1. Server side: Wonni + every API platform in one call.
        update(jobId) { $0.serverStep = .running("Updating stock") }
        let skipList = job.skipPlatforms ?? []
        let reply = ServerReply()
        let serverResult = await attempt(times: SoldOutPlan.stepAttempts) {
            var payload: [String: Any] = ["productId": listingId]
            if !skipList.isEmpty { payload["skipPlatforms"] = skipList }
            let result = try await Functions.functions().httpsCallable("markSoldOutAndCascade").call(payload)
            reply.errors = (result.data as? [String: Any])?["errors"] as? [String: String] ?? [:]
            if let previous = (result.data as? [String: Any])?["previousQuantity"] as? Int, previous > 0 {
                reply.previousQuantity = previous
            }
        }
        switch serverResult {
        case .failure(let message):
            update(jobId) {
                $0.serverStep = .failed(message)
                if $0.hasMercariStep { $0.mercariStep = .waiting }
                $0.failure = message
                $0.ended = true
            }
            return
        case .success:
            // Wonni is sold out either way; a platform the server could not update is
            // shown with its reason (Retry, or Skip to accept it). Not a stock restore:
            // that rule is for Mercari, where nothing was confirmed at all.
            let errors = reply.errors
            update(jobId) {
                if errors.isEmpty {
                    $0.serverStep = .done
                } else {
                    $0.platformErrors = errors
                    $0.serverStep = .failed(SoldOutPlan.platformFailureText(errors))
                }
            }
        }
        let platformFailure = reply.errors.isEmpty ? nil : SoldOutPlan.platformFailureText(reply.errors)

        // 2. Mercari, if the listing is there and not skipped.
        guard let mercariId = job.mercariItemId, !(self.job(jobId)?.skipsMercari ?? false) else {
            update(jobId) {
                if $0.hasMercariStep { $0.mercariStep = .skipped } else { $0.mercariStep = .done }
                $0.failure = platformFailure
                $0.ended = true
            }
            return
        }
        update(jobId) { $0.mercariStep = .running("Checking Mercari") }
        let mercariResult = await attempt(times: SoldOutPlan.stepAttempts) {
            try await self.runMercari(itemId: mercariId, action: job.mercariAction, jobId: jobId)
        }
        switch mercariResult {
        case .success:
            await finishMercari(listingId: listingId, outcome: mercariOutcomes.removeValue(forKey: jobId))
            update(jobId) { $0.mercariStep = .done; $0.failure = platformFailure; $0.ended = true }
        case .failure where skipRequestedJobId == jobId:
            // Skip on the running step: left as it is on Mercari, the listing stays sold out.
            skipRequestedJobId = nil
            update(jobId) {
                $0.addSkip(["mercari"])
                $0.mercariStep = .skipped
                $0.failure = platformFailure
                $0.ended = true
            }
        case .failure(let message):
            // The server call already zeroed stock; put it back so nothing is half done.
            // If even that fails, say so: the listing is then sold out on Wonni/API
            // platforms but still live on Mercari, and the user has to look at it.
            let restored = await restoreStock(listingId: listingId, quantity: reply.previousQuantity ?? job.previousQuantity)
            let failure = restored ? message : "\(message). Stock could not be restored either — this listing is sold out here but still live on Mercari; check it."
            update(jobId) {
                $0.mercariStep = .failed(message)
                $0.failure = failure
                $0.ended = true
            }
        }
    }

    private enum StepResult { case success, failure(String) }

    /// What the server call answered, filled inside the retried closure.
    private final class ServerReply: @unchecked Sendable {
        var errors: [String: String] = [:]
        /// Stock the server zeroed; the Mercari-failure restore puts back this, not the
        /// listing doc's quantity (often unset or stale, so it restored 1).
        var previousQuantity: Int?
    }

    /// Runs `body` up to `times` times, each bounded by the step timeout.
    private func attempt(times: Int, _ body: @escaping () async throws -> Void) async -> StepResult {
        var lastMessage = "Failed"
        for attemptNumber in 1...max(times, 1) {
            do {
                try await withStepTimeout(SoldOutPlan.stepTimeout, body)
                return .success
            } catch is CancellationError {
                return .failure("Stopped")
            } catch let failed as StepFailed where failed.reason == "Stopped" {
                // Stop / Skip from the user: never retried automatically.
                return .failure(failed.reason)
            } catch {
                lastMessage = Self.message(for: error)
                if attemptNumber < times {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        return .failure(lastMessage)
    }

    private struct StepTimeout: Error {}
    private struct StepFailed: Error { let reason: String }
    private struct Stopped: Error {}

    private func withStepTimeout(_ seconds: TimeInterval, _ body: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw StepTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func runMercari(itemId: String, action: MercariSoldOutAction, jobId: UUID) async throws {
        let automator = MercariListingStateAutomator(
            mercariItemId: itemId,
            action: action,
            registersOwnTask: false
        )
        currentAutomator = automator
        currentMercariJobId = jobId
        stopRequested = false
        defer {
            if currentAutomator === automator {
                currentAutomator = nil
                currentMercariJobId = nil
            }
        }
        // Mirror the automator's step into the job so the list and pill follow along.
        let stepMirror = Task { [weak self] in
            for await _ in automator.$stepText.values {
                guard let self, !Task.isCancelled else { return }
                let step = automator.stepText
                if !step.isEmpty, let job = self.job(jobId), case .running = job.mercariStep {
                    self.update(jobId) { $0.mercariStep = .running(step) }
                }
            }
        }
        defer { stepMirror.cancel() }

        let stopWatch = Task { [weak self] in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 250_000_000)
                if self?.stopRequested == true { throw Stopped() }
            }
        }
        defer { stopWatch.cancel() }

        let phase = try await withThrowingTaskGroup(of: MercariListingStateAutomator.Phase.self) { group in
            group.addTask { await automator.run() }
            group.addTask {
                try await stopWatch.value
                throw Stopped()
            }
            defer { group.cancelAll() }
            do {
                return try await group.next() ?? .manualFallback("No result")
            } catch is Stopped {
                throw StepFailed(reason: "Stopped")
            }
        }
        switch phase {
        case .success:
            mercariOutcomes[jobId] = automator.outcome
        case .manualFallback(let reason): throw StepFailed(reason: reason)
        case .running: throw StepFailed(reason: "Mercari did not finish")
        }
    }

    /// After Mercari confirmed: the server's reminder flag is stale; once the listing no
    /// longer exists there the Mercari pointers go too (a restock re-posts from scratch).
    private func finishMercari(listingId: String, outcome: MercariSoldOutOutcome?) async {
        let removed = outcome?.removedFromMercari == true
        let listingRef = Firestore.firestore().collection("listings").document(listingId)
        var listingUpdate: [String: Any] = ["pendingMercariDeactivation": FieldValue.delete()]
        if removed {
            listingUpdate["crossPostStatus.mercari"] = FieldValue.delete()
            listingUpdate["crossPostListingIds.mercari"] = FieldValue.delete()
            listingUpdate["crossPostUrls.mercari"] = FieldValue.delete()
            listingUpdate["mercariSmartPricingOn"] = FieldValue.delete()
        }
        try? await listingRef.updateData(listingUpdate)
        if removed {
            await ProductRepository.shared.clearMercariPosted(productId: listingId)
        } else {
            try? await Firestore.firestore().collection("products").document(listingId)
                .updateData(["pendingMercariDeactivation": FieldValue.delete()])
        }
    }

    /// Puts the listing back in stock on Wonni and every API platform. Returns false
    /// when either write failed, so the failure text can say the state is uncertain.
    private func restoreStock(listingId: String, quantity: Int) async -> Bool {
        var restored = true
        do {
            try await ListingRepository.shared.restockListing(id: listingId, quantity: quantity)
        } catch {
            print("[SoldOutRunner] restockListing failed for \(listingId): \(error)")
            restored = false
        }
        do {
            _ = try await callCloudFunction("restockAndCascade", ["productId": listingId, "quantity": quantity])
        } catch {
            print("[SoldOutRunner] restockAndCascade failed for \(listingId): \(error)")
            restored = false
        }
        return restored
    }

    // MARK: Bookkeeping

    private func job(_ id: UUID) -> SoldOutJob? { jobs.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout SoldOutJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persist()
        refreshPill()
    }

    private func persist() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        SoldOutRunStore.sync(jobs: jobs, userId: uid)
    }

    private func refreshPill() {
        guard isRunning else { return }
        AppTaskQueue.shared.update(
            id: taskId,
            label: SoldOutPlan.pillLabel(jobs: jobs),
            detail: SoldOutPlan.pillDetail(jobs: jobs),
            progress: SoldOutPlan.progress(jobs: jobs)
        )
    }

    /// Every job ended. No failures: pill and sheet close by themselves. Failures: the
    /// pill turns red and the sheet lists what is still in stock.
    private func finishRun() {
        finishedRunCount += 1
        let failed = jobs.filter { $0.failure != nil }
        if failed.isEmpty {
            AppTaskQueue.shared.complete(id: taskId)
            showSheet = false
            jobs = []
            phase = .idle
            SoldOutRunStore.clear()
        } else {
            phase = .finished(failed: failed)
            AppTaskQueue.shared.update(
                id: taskId,
                label: SoldOutPlan.failurePillLabel(failed.count),
                detail: "Still in stock. Tap to review.",
                progress: 1,
                isError: true
            )
            SoldOutRunStore.clear()
        }
    }

    private func clearFinished() {
        AppTaskQueue.shared.dismiss(id: taskId)
        showSheet = false
        jobs = []
        phase = .idle
        SoldOutRunStore.clear()
    }

    private static func message(for error: Error) -> String {
        if error is StepTimeout { return "Timed out after \(Int(SoldOutPlan.stepTimeout)) s" }
        if let failed = error as? StepFailed { return failed.reason }
        let nsError = error as NSError
        if let server = nsError.userInfo["NSLocalizedDescription"] as? String, !server.isEmpty { return server }
        return nsError.localizedDescription
    }
}
