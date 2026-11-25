//
//  BulkTextDraftRunner.swift
//  wonni
//
//  Runs one "drafts from a list" job outside any view, so the sheet can close the
//  moment the user taps Create and the app stays usable while drafts land. Progress
//  shows in the shared AppTaskQueue pill ("Creating drafts · 3 of 12"); tapping it
//  reopens BulkTextDraftsSheet, which renders this runner's phase (progress with
//  Stop, or the finish screen with Undo). The AI-photo consent question is presented
//  from MainView, since the sheet may be gone when it comes up.
//
//  The run loop itself (text → parse → price/photos → save, batch by batch, every
//  exit leaving the editor holding exactly what was NOT converted) is unchanged from
//  the sheet it was lifted out of on 2026-10-13.
//

import SwiftUI
import SwiftData

@MainActor
final class BulkTextDraftRunner: ObservableObject {
    static let shared = BulkTextDraftRunner()
    private init() {}

    /// What the progress screen and the pill show while a run is in flight.
    struct RunStatus: Equatable {
        var created = 0
        /// Listings found so far (grows if a very long text is parsed in parts).
        var total = 0
        var step = ""
        var detail = ""
    }

    struct Summary: Equatable {
        var created = 0
        var placeholders = 0
        var unpriced = 0
        /// Listings still in the editor, not converted.
        var leftover = 0
        /// Why the run ended early, if it did.
        var note: String?
        /// What became of each product link in the text (finish screen lines).
        var links: [LinkOutcome] = []
        /// Finish-screen lines for links that went to the Weverse / AliExpress importers.
        var importLines: [String] = []
    }

    enum Phase: Equatable {
        case input
        case reading
        case working(RunStatus)
        case finished(Summary)
    }

    static let pendingTextKey = "bulkTextDraftsPendingText"
    static let aiPhotosAllowedKey = "bulkTextAIPhotosAllowed"

    @Published private(set) var phase: Phase = .input
    /// Surfaced by the sheet as an alert; nil once shown.
    @Published var errorMessage: String?
    /// MainView presents the sheet when the pill (or an error row) is tapped.
    @Published var showSheet = false
    /// Drafts made by the latest run, for Undo.
    @Published private(set) var createdItems: [Item] = []

    // ── AI photo consent (presented from MainView) ──
    @Published var showAIPhotoConsent = false
    @Published private(set) var consentCount = 0
    private var consentContinuation: CheckedContinuation<Bool, Never>?

    // ── "Several items in one entry" (presented from MainView, once per run) ──
    /// Entries waiting for an individual-or-bundle answer; the sheet shows them all.
    @Published private(set) var pendingDecisions: [ListingDecision] = []
    @Published var showDecisionSheet = false
    private var decisionContinuation: CheckedContinuation<[Int: BulkTextDraftMapper.DecisionChoice], Never>?
    /// A "no" applies to the whole current run (not just one batch), and only to it.
    private var aiPhotosDeclinedThisRun = false

    private(set) var stopRequested = false
    /// The editor's contents when the latest run started, restored by Undo.
    private(set) var textBeforeRun = ""
    private var taskId = UUID()
    private var runTask: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .reading, .working: return true
        default: return false
        }
    }

    /// The unconverted text, shared with the sheet's editor through UserDefaults so
    /// a run can rewrite it after the sheet has closed.
    var pendingText: String {
        get { UserDefaults.standard.string(forKey: Self.pendingTextKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingTextKey) }
    }

    // MARK: Control

    /// Starts a run over `text`. Returns false (and does nothing) when one is already
    /// in flight. `continuing` keeps the earlier drafts undoable together with the new
    /// ones ("Continue with the rest" on the finish screen).
    @discardableResult
    func start(text: String, modelContext: ModelContext, uploadManager: UploadManager, continuing: Bool = false) -> Bool {
        guard !isBusy else { return false }
        let earlier = continuing ? createdItems.filter { !Item.deletedIDs.contains($0.id) } : []
        let original = continuing ? textBeforeRun : text
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(text: text, modelContext: modelContext, uploadManager: uploadManager)
            if continuing {
                self.createdItems = earlier + self.createdItems
                self.textBeforeRun = original
                if case .finished(var summary) = self.phase {
                    summary.created = self.createdItems.count
                    self.phase = .finished(summary)
                }
            }
        }
        return true
    }

    func stop() {
        stopRequested = true
        // A run waiting on the decision sheet should end too, not hang on it.
        if decisionContinuation != nil { answerDecisions([:]) }
    }

    /// Back to the editor; the finish screen is gone and the drafts stay.
    func acknowledge() {
        if case .finished = phase { phase = .input }
    }

    func answerConsent(_ allowed: Bool) {
        consentContinuation?.resume(returning: allowed)
        consentContinuation = nil
    }

    /// The decision sheet's Continue (or its dismissal: missing answers default to
    /// individual). The chosen listings join the run's queue.
    func answerDecisions(_ choices: [Int: BulkTextDraftMapper.DecisionChoice]) {
        decisionContinuation?.resume(returning: choices)
        decisionContinuation = nil
        showDecisionSheet = false
    }

    /// Deletes every draft the latest run created and puts the text back.
    func undo(modelContext: ModelContext, uploadManager: UploadManager) {
        for item in createdItems where !Item.deletedIDs.contains(item.id) {
            uploadManager.deleteDraftLocallyAndCloud(draft: item, modelContext: modelContext)
        }
        createdItems = []
        pendingText = textBeforeRun
        phase = .input
    }

    // MARK: The run

    private func run(text: String, modelContext: ModelContext, uploadManager: UploadManager) async {
        let service = BulkTextDraftService.shared
        textBeforeRun = text
        stopRequested = false
        aiPhotosDeclinedThisRun = false
        createdItems = []
        phase = .reading
        taskId = UUID()
        AppTaskQueue.shared.begin(
            id: taskId,
            label: "Creating drafts",
            detail: "Reading your list…",
            onTap: { [weak self] in self?.showSheet = true }
        )

        var status = RunStatus()
        var summary = Summary()
        var context = ""
        /// Parsed listings not yet priced / photographed.
        var queue: [Remaining] = []
        /// Text not yet parsed: the whole input at first; afterwards only the tail a
        /// very long text's parse did not reach.
        var unparsed: String? = text.trimmingCharacters(in: .whitespacesAndNewlines)
        /// Prepared listings that were never saved because the run was stopped.
        var unsaved: [Draft] = []
        /// Multi-item entries the user has not answered yet. Asked once per run, as a
        /// side task, so the other entries keep turning into drafts meanwhile; the
        /// answer is collected when the queue runs dry.
        var decisions: [ListingDecision] = []
        var decisionTask: Task<[Remaining], Never>?

        func report(_ s: RunStatus) {
            status = s
            phase = .working(s)
            let total = max(s.total, s.created)
            AppTaskQueue.shared.update(
                id: taskId,
                detail: total > 0 ? "\(s.created) of \(total) · \(s.step)" : s.step,
                progress: total > 0 ? Double(s.created) / Double(total) : -1
            )
        }

        // Weverse shop pages and pure Weverse / AliExpress link lists go to the same
        // importers the web uses (variants, duplicate checks); everything else is text.
        let route = ImportLinkRouter.route(text)
        if route != .text {
            await runImport(route, modelContext: modelContext, uploadManager: uploadManager)
            return
        }

        while !stopRequested {
            let response: ProposeResponse
            do {
                if !queue.isEmpty {
                    let batch = Array(queue.prefix(BulkTextDraftMapper.batchSize))
                    status.step = "Pricing and finding photos…"
                    status.detail = "Next \(batch.count) of \(queue.count) remaining"
                    report(status)
                    response = try await service.propose(pending: batch, context: context)
                    queue.removeFirst(batch.count)
                } else if let source = unparsed {
                    if !createdItems.isEmpty {
                        status.step = "Reading the rest of your list…"
                        status.detail = ""
                        report(status)
                    }
                    response = try await service.propose(text: source, context: context)
                    queue = response.remaining
                    if !response.context.isEmpty { context = response.context }
                    status.total += response.drafts.count + response.remaining.count
                    summary.links += response.links ?? []
                    if let asked = response.needsDecision, !asked.isEmpty {
                        decisions += asked
                        status.total += asked.count
                        decisionTask = decisionTask ?? Task { [weak self] in
                            // Resolved when the user answers; `decisions` is read then,
                            // so entries from a later parse of the same text are included.
                            guard let self else { return [] }
                            return await self.askDecisions(decisions)
                        }
                    }
                    // Anything the parse didn't reach comes back as text, to parse next.
                    let tail = response.unparsedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if tail.isEmpty {
                        unparsed = nil
                    } else if response.drafts.isEmpty && response.remaining.isEmpty {
                        // No progress on this text: keep it for the user rather than
                        // asking for the same thing forever.
                        unparsed = tail
                        summary.note = "Part of the text couldn't be read. It's still in the editor."
                        break
                    } else {
                        unparsed = tail
                    }
                } else if let waiting = decisionTask {
                    // Everything else is done; now the user's answer decides the rest.
                    status.step = "Waiting for your answer…"
                    status.detail = decisions.count == 1 ? "1 entry names several items" : "\(decisions.count) entries name several items"
                    report(status)
                    let chosen = await waiting.value
                    decisionTask = nil
                    status.total += chosen.count - decisions.count
                    decisions = []
                    queue = chosen
                    continue
                } else {
                    break
                }
            } catch {
                summary.note = error.localizedDescription
                break
            }

            if stopRequested {
                unsaved = response.drafts
                break
            }
            guard !response.drafts.isEmpty else { continue }

            let prepared = await fillMissingPhotos(response.drafts) { step, detail in
                status.step = step
                status.detail = detail
                report(status)
            }

            let alreadyCreated = status.created
            let made = await service.createDrafts(
                from: prepared,
                response: response,
                modelContext: modelContext,
                uploadManager: uploadManager,
                shouldStop: { [weak self] in self?.stopRequested ?? true },
                progress: { progress in
                    status.created = alreadyCreated + progress.completed
                    status.step = "Saving drafts…"
                    status.detail = progress.currentTitle
                    report(status)
                }
            )
            createdItems.append(contentsOf: made)
            status.created = createdItems.count
            let saved = prepared.prefix(made.count)
            summary.placeholders += saved.filter(BulkTextDraftMapper.needsPhoto).count
            summary.unpriced += saved.filter { $0.suggestedPrice == nil }.count
            if made.count < prepared.count {
                unsaved = Array(prepared.dropFirst(made.count))
                break
            }
        }

        // A stopped run never asked: those entries go back in the editor as written.
        if decisionTask != nil { answerDecisions([:]); decisionTask?.cancel(); decisionTask = nil }
        // Whatever did not become a draft goes back in the editor.
        let leftoverLines = unsaved.map(BulkTextDraftMapper.LeftoverLine.init)
            + queue.map(BulkTextDraftMapper.LeftoverLine.init)
            + decisions.map { BulkTextDraftMapper.LeftoverLine(sourceText: $0.sourceText, userPrice: $0.asBundle.userPrice) }
        let leftover = BulkTextDraftMapper.leftoverText(context: context, lines: leftoverLines, unparsedText: unparsed ?? "")
        summary.created = createdItems.count
        summary.leftover = leftoverLines.count

        if createdItems.isEmpty {
            // Nothing was made: the editor keeps the user's text exactly as written.
            pendingText = textBeforeRun
            let message = summary.note ?? (stopRequested ? nil : "No listings were found in that text.")
            errorMessage = message
            phase = .input
            if let message, !stopRequested {
                // Red pill with Retry → reopens the sheet (the text is still there).
                AppTaskQueue.shared.update(id: taskId, label: "Couldn't build drafts", detail: message, isError: true)
            } else {
                AppTaskQueue.shared.dismiss(id: taskId)
            }
            return
        }
        pendingText = leftover
        if stopRequested && summary.note == nil && !leftover.isEmpty {
            summary.note = "Stopped."
        }
        phase = .finished(summary)
        AppTaskQueue.shared.update(
            id: taskId,
            label: summary.created == 1 ? "1 draft created" : "\(summary.created) drafts created",
            detail: summary.leftover > 0 ? "\(summary.leftover) not converted — still in the editor" : nil,
            progress: 1
        )
        AppTaskQueue.shared.complete(id: taskId)
    }

    // MARK: Importer links (Weverse shop / sale links, AliExpress items)

    private func runImport(_ route: ImportLinkRouter.Route, modelContext: ModelContext, uploadManager: UploadManager) async {
        let service = BulkTextDraftService.shared
        var status = RunStatus()
        var summary = Summary()
        func report() {
            phase = .working(status)
            let total = max(status.total, status.created)
            AppTaskQueue.shared.update(id: taskId,
                                       detail: total > 0 ? "\(status.created) of \(total) · \(status.step)" : status.step,
                                       progress: total > 0 ? Double(status.created) / Double(total) : -1)
        }

        var jobs: [BulkTextDraftService.ImportJob] = []
        var shopUrl: String?
        switch route {
        case .text: return
        case .weverseShop(let url):
            shopUrl = url
            status.step = "Reading the Weverse page…"
            report()
            do {
                jobs = try await service.weverseShopItems(url)
            } catch {
                finishImport(summary: summary, leftover: url, failure: (error as NSError).userInfo["NSLocalizedDescription"] as? String ?? error.localizedDescription)
                return
            }
        case .importerLinks(let urls):
            jobs = urls.map { BulkTextDraftService.ImportJob(url: $0, productId: UUID().uuidString) }
        }
        status.total = jobs.count

        var outcome = BulkTextDraftService.ImportOutcome()
        var remaining = jobs[...]
        while !remaining.isEmpty, !stopRequested {
            // Weverse sales go 25 to a call (the bulk importer); AliExpress one by one.
            let batch: [BulkTextDraftService.ImportJob]
            let result: BulkTextDraftService.ImportOutcome
            if ImportLinkRouter.isWeverseSale(remaining.first!.url) {
                batch = Array(remaining.prefix { ImportLinkRouter.isWeverseSale($0.url) }.prefix(25))
                status.step = "Importing from Weverse…"
                status.detail = "\(batch.count) item\(batch.count == 1 ? "" : "s")"
                report()
                result = await service.importWeverseSales(batch)
            } else {
                batch = [remaining.first!]
                status.step = "Importing from AliExpress…"
                report()
                result = await service.importOne(batch[0])
            }
            remaining = remaining.dropFirst(batch.count)
            outcome.alreadyImported += result.alreadyImported
            outcome.failures += result.failures

            // Download each new product into a phone draft (its doc id is our UUID, so
            // it is tagged Phone), the same way a PC draft is opened.
            for productId in result.created {
                status.step = "Downloading photos…"
                report()
                if let item = await uploadManager.adoptProduct(productId: productId, modelContext: modelContext) {
                    createdItems.append(item)
                    status.created = createdItems.count
                    report()
                }
            }
        }

        summary.created = createdItems.count
        if outcome.alreadyImported > 0 {
            summary.importLines.append(outcome.alreadyImported == 1
                ? "1 link was already imported, so no new draft was made for it."
                : "\(outcome.alreadyImported) links were already imported, so no new drafts were made for them.")
        }
        for failure in outcome.failures.prefix(5) {
            summary.importLines.append("\(failure.url) could not be imported: \(failure.reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))).")
        }
        if outcome.failures.count > 5 { summary.importLines.append("\(outcome.failures.count - 5) more could not be imported.") }
        if shopUrl != nil, !createdItems.isEmpty {
            summary.importLines.append("Shipping estimates are not run from the phone; the web's shop preview does that.")
        }
        // Stopped: the links not tried yet go back in the editor (a shop page as its sale links).
        let leftoverUrls = remaining.map(\.url) + outcome.failures.map(\.url).filter { $0.hasPrefix("http") }
        summary.leftover = leftoverUrls.count
        if stopRequested, !remaining.isEmpty { summary.note = "Stopped." }
        finishImport(summary: summary, leftover: leftoverUrls.joined(separator: "\n"), failure: nil)
    }

    private func finishImport(summary: Summary, leftover: String, failure: String?) {
        if createdItems.isEmpty {
            pendingText = textBeforeRun
            let message = failure ?? summary.importLines.first ?? (stopRequested ? nil : "Nothing was imported.")
            errorMessage = message
            phase = .input
            if let message, !stopRequested {
                AppTaskQueue.shared.update(id: taskId, label: "Couldn't import", detail: message, isError: true)
            } else {
                AppTaskQueue.shared.dismiss(id: taskId)
            }
            return
        }
        pendingText = leftover
        phase = .finished(summary)
        AppTaskQueue.shared.update(
            id: taskId,
            label: summary.created == 1 ? "1 draft created" : "\(summary.created) drafts created",
            detail: summary.leftover > 0 ? "\(summary.leftover) not imported — still in the editor" : nil,
            progress: 1
        )
        AppTaskQueue.shared.complete(id: taskId)
    }

    // MARK: AI photos (consent-gated)

    /// Photo priority: eBay sellers → web → ask about AI, once per run. A remembered
    /// "yes" skips the question; a "no" applies to the rest of this run only.
    private func fillMissingPhotos(_ drafts: [Draft], report: (String, String) -> Void) async -> [Draft] {
        let missing = drafts.enumerated().filter { BulkTextDraftMapper.needsPhoto($0.element) }
        guard !missing.isEmpty, !stopRequested, !aiPhotosDeclinedThisRun else { return drafts }
        if !UserDefaults.standard.bool(forKey: Self.aiPhotosAllowedKey) {
            guard await askAIPhotoConsent(count: missing.count) else {
                aiPhotosDeclinedThisRun = true
                return drafts
            }
            // Only ever set to true: a "no" applies to that run alone, so the question
            // comes back next time rather than silently locking the option out forever.
            UserDefaults.standard.set(true, forKey: Self.aiPhotosAllowedKey)
        }
        var out = drafts
        for (done, entry) in missing.enumerated() {
            if stopRequested { break }
            report("Generating photo \(done + 1) of \(missing.count)…", entry.element.shortTitle)
            do {
                if let url = try await BulkTextDraftService.shared.generatePhoto(for: entry.element) {
                    out[entry.offset] = entry.element.with(imageSource: .generated, imageUrls: [url])
                }
            } catch {
                // One failed image is not a reason to stop — that listing just keeps
                // its placeholder.
                print("[BulkTextDraftRunner] photo generation failed for \(entry.element.shortTitle): \(error)")
            }
        }
        return out
    }

    /// One sheet per run listing every multi-item entry; resolved by `answerDecisions`.
    private func askDecisions(_ asked: [ListingDecision]) async -> [Remaining] {
        pendingDecisions = asked
        let choices = await withCheckedContinuation { continuation in
            decisionContinuation = continuation
            showDecisionSheet = true
        }
        let out = BulkTextDraftMapper.pendingItems(for: pendingDecisions, choices: choices)
        pendingDecisions = []
        return out
    }

    private func askAIPhotoConsent(count: Int) async -> Bool {
        consentCount = count
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            showAIPhotoConsent = true
        }
    }
}
