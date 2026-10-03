//
//  BulkTextDraftsSheet.swift
//  wonni
//
//  Paste or type anything describing what you're selling — a list, a paragraph,
//  a message, a pasted table — and get one ready-to-list draft per item, in the
//  order written. Items sold together become one listing, group notes become
//  shared context, and a price you wrote is kept as the price.
//
//  One step: text in, drafts out. There is no review-and-uncheck screen (removed
//  2026-10-03) — whatever is in the text is meant to be listed, and a wrong draft
//  is fixed or deleted in the drafts drawer like any other. The whole run can be
//  undone from the finish screen. Lists of any length work: the server parses the
//  text once and prepares 40 listings per round trip; drafts are saved as each
//  batch lands. Text that did NOT become drafts (run stopped, a batch failed)
//  stays in the editor — and persists across closing the sheet — to run again.
//
//  Photos come from eBay sellers' comps, then Google; when neither had one, the
//  user is asked ONCE whether AI-generated photos are acceptable, and only a yes
//  triggers generation. Opened from the camera, the photo picker, the drafts
//  overview and Profile › Import.
//

import SwiftUI
import SwiftData

struct BulkTextDraftsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager

    /// What the progress screen shows while a run is in flight.
    private struct RunStatus: Equatable {
        var created = 0
        /// Listings found so far (grows if a very long text is parsed in parts).
        var total = 0
        var step = ""
        var detail = ""
    }

    private struct Summary: Equatable {
        var created = 0
        var placeholders = 0
        var unpriced = 0
        /// Listings still in the editor, not converted.
        var leftover = 0
        /// Why the run ended early, if it did.
        var note: String?
    }

    private enum Phase: Equatable {
        case input
        case reading
        case working(RunStatus)
        case finished(Summary)
    }

    @State private var phase: Phase = .input
    /// Persisted so an unfinished list survives closing the sheet (or the app). Cleared
    /// when a run converts everything; left holding only the unconverted part otherwise.
    @AppStorage("bulkTextDraftsPendingText") private var text = ""
    @State private var errorMessage: String?
    @State private var stopRequested = false
    /// Drafts made by the latest run, for Undo.
    @State private var createdItems: [Item] = []
    /// The editor's contents when the latest run started, restored by Undo.
    @State private var textBeforeRun = ""
    @State private var showUndoConfirm = false

    // ── AI photo consent ──
    @State private var showAIPhotoConsent = false
    @State private var consentContinuation: CheckedContinuation<Bool, Never>?
    @State private var consentCount = 0
    /// A "no" applies to the whole current run (not just one batch), and only to it.
    @State private var aiPhotosDeclinedThisRun = false
    /// Remembered "yes" to AI-generated photos. Only ever set to true: a "no" applies
    /// to that run alone, so the question comes back next time rather than silently
    /// locking the option out forever.
    @AppStorage("bulkTextAIPhotosAllowed") private var aiPhotosAllowed = false

    /// Shown when the user came from somewhere other than the drafts overview
    /// (Profile › Import) and needs a way to get to the drafts they just made.
    var offersOpenDrafts = false

    private static let placeholder = """
    Clearing out my Wii stuff, all complete in box. Super Smash Bros Brawl for $30, \
    Mario Strikers Charged, and Just Dance 4 + Just Dance 2015 together as a bundle. \
    Also Link's Crossbow Training (in cardboard sleeve), 8 bucks.
    """

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input, .reading:
                    inputView
                case .working(let status):
                    workingView(status)
                case .finished(let summary):
                    finishedView(summary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isBusy {
                        EmptyView()
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .alert("Couldn't build drafts", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Use AI-generated photos?", isPresented: $showAIPhotoConsent) {
                Button("Use AI photos") { answerConsent(true) }
                Button("Skip", role: .cancel) { answerConsent(false) }
            } message: {
                Text("No seller or web photo was found for \(consentCount) of these listings. AI can generate a realistic product photo for them, but it won't be a photo of your actual item. You can always replace it on the draft.")
            }
            .confirmationDialog(
                "Delete the \(createdItems.count) draft\(createdItems.count == 1 ? "" : "s") this list just created?",
                isPresented: $showUndoConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(createdItems.count) draft\(createdItems.count == 1 ? "" : "s")", role: .destructive) { undo() }
                Button("Keep them", role: .cancel) {}
            } message: {
                Text("Your text goes back in the editor.")
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var title: String {
        switch phase {
        case .input, .reading: return "Drafts from a list"
        case .working: return "Creating drafts"
        case .finished: return "Done"
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .reading, .working: return true
        default: return false
        }
    }

    // MARK: Input

    private var inputView: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                        .disabled(phase == .reading)
                        .accessibilityIdentifier("bulkTextDraftsEditor")
                }
            } header: {
                Text("What are you selling?")
            } footer: {
                Text("Write it however you like: a list, a paragraph, a pasted message or table. Each item becomes one draft, in the order you wrote them. Items you say are sold together become one bundle listing. Prices you include are kept; the rest are priced from eBay comps.")
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Spacer()
                        if phase == .reading {
                            ProgressView().padding(.trailing, 6)
                            Text("Reading your list…")
                        } else {
                            Label("Create drafts", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                    .fontWeight(.semibold)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .reading)
                .accessibilityIdentifier("bulkTextDraftsGenerate")
            } footer: {
                Text(phase == .reading
                     ? "A long list can take a minute or two to read."
                     : "Drafts are created straight away and land in your drafts, where you can edit or delete any of them. Each is priced from live eBay comps and copies the closest eBay listing's category and item specifics. Photos come from eBay sellers' listings, then the web.")
            }
        }
    }

    // MARK: The run

    /// Text → drafts, batch by batch. Every exit path leaves `text` holding exactly
    /// what was NOT converted, so nothing the user wrote is ever lost.
    private func run() async {
        let service = BulkTextDraftService.shared
        textBeforeRun = text
        stopRequested = false
        aiPhotosDeclinedThisRun = false
        createdItems = []
        phase = .reading

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

        while !stopRequested {
            let response: BulkDraftsFromTextResponse
            do {
                if !queue.isEmpty {
                    let batch = Array(queue.prefix(BulkTextDraftMapper.batchSize))
                    status.step = "Pricing and finding photos…"
                    status.detail = "Next \(batch.count) of \(queue.count) remaining"
                    phase = .working(status)
                    response = try await service.propose(pending: batch, context: context)
                    queue.removeFirst(batch.count)
                } else if let source = unparsed {
                    if !createdItems.isEmpty {
                        status.step = "Reading the rest of your list…"
                        status.detail = ""
                        phase = .working(status)
                    }
                    response = try await service.propose(text: source, context: context)
                    queue = response.remaining
                    if !response.context.isEmpty { context = response.context }
                    status.total += response.drafts.count + response.remaining.count
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
                phase = .working(status)
            }

            let alreadyCreated = status.created
            let made = await service.createDrafts(
                from: prepared,
                response: response,
                modelContext: modelContext,
                uploadManager: uploadManager,
                shouldStop: { stopRequested },
                progress: { progress in
                    status.created = alreadyCreated + progress.completed
                    status.step = "Saving drafts…"
                    status.detail = progress.currentTitle
                    phase = .working(status)
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

        // Whatever did not become a draft goes back in the editor.
        let leftoverLines = unsaved.map(BulkTextDraftMapper.LeftoverLine.init) + queue.map(BulkTextDraftMapper.LeftoverLine.init)
        let leftover = BulkTextDraftMapper.leftoverText(context: context, lines: leftoverLines, unparsedText: unparsed ?? "")
        summary.created = createdItems.count
        summary.leftover = leftoverLines.count

        if createdItems.isEmpty {
            // Nothing was made: the editor keeps the user's text exactly as written.
            text = textBeforeRun
            errorMessage = summary.note ?? (stopRequested ? nil : "No listings were found in that text.")
            phase = .input
            return
        }
        text = leftover
        if stopRequested && summary.note == nil && !leftover.isEmpty {
            summary.note = "Stopped."
        }
        phase = .finished(summary)
    }

    // MARK: AI photos (consent-gated)

    /// Photo priority: eBay sellers → web → ask about AI, once per run. A remembered
    /// "yes" skips the question; a "no" applies to the rest of this run only.
    private func fillMissingPhotos(_ drafts: [Draft], report: (String, String) -> Void) async -> [Draft] {
        let missing = drafts.enumerated().filter { BulkTextDraftMapper.needsPhoto($0.element) }
        guard !missing.isEmpty, !stopRequested, !aiPhotosDeclinedThisRun else { return drafts }
        if !aiPhotosAllowed {
            guard await askAIPhotoConsent(count: missing.count) else {
                aiPhotosDeclinedThisRun = true
                return drafts
            }
            aiPhotosAllowed = true
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
                print("[BulkTextDraftsSheet] photo generation failed for \(entry.element.shortTitle): \(error)")
            }
        }
        return out
    }

    private func askAIPhotoConsent(count: Int) async -> Bool {
        consentCount = count
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            showAIPhotoConsent = true
        }
    }

    private func answerConsent(_ allowed: Bool) {
        consentContinuation?.resume(returning: allowed)
        consentContinuation = nil
    }

    // MARK: Undo

    /// Deletes every draft the latest run created and puts the text back.
    private func undo() {
        for item in createdItems where !Item.deletedIDs.contains(item.id) {
            uploadManager.deleteDraftLocallyAndCloud(draft: item, modelContext: modelContext)
        }
        createdItems = []
        text = textBeforeRun
        phase = .input
    }

    // MARK: Progress / done

    private func workingView(_ status: RunStatus) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(status.created), total: Double(max(status.total, status.created, 1)))
                .padding(.horizontal, 32)
            Text("\(status.created) of \(max(status.total, status.created)) drafts created")
                .font(.headline)
                .monospacedDigit()
            Text(status.step)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal)
            }
            Button(stopRequested ? "Stopping…" : "Stop") { stopRequested = true }
                .disabled(stopRequested)
                .padding(.top, 8)
                .accessibilityIdentifier("bulkTextDraftsStop")
            Text("Drafts already created are kept. Anything not converted stays in the editor.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishedView(_ summary: Summary) -> some View {
        VStack(spacing: 16) {
            Image(systemName: summary.leftover > 0 || summary.note != nil ? "checkmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(summary.created == 1 ? "1 draft created" : "\(summary.created) drafts created")
                .font(.title3.weight(.semibold))

            VStack(spacing: 6) {
                if summary.placeholders > 0 {
                    Label("\(summary.placeholders) \(summary.placeholders == 1 ? "has" : "have") a placeholder photo to replace", systemImage: "photo")
                        .foregroundStyle(.orange)
                }
                if summary.unpriced > 0 {
                    Label("\(summary.unpriced) \(summary.unpriced == 1 ? "has" : "have") no price yet", systemImage: "dollarsign.circle")
                        .foregroundStyle(.orange)
                }
                if !text.isEmpty {
                    Label(summary.leftover > 0
                          ? "\(summary.leftover) item\(summary.leftover == 1 ? " was" : "s were") not converted and \(summary.leftover == 1 ? "is" : "are") still in the editor"
                          : "Part of your text was not converted and is still in the editor",
                          systemImage: "text.badge.xmark")
                        .foregroundStyle(.orange)
                }
                if let note = summary.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

            Text("Photos are uploading in the background. Edit or delete any draft in your drafts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !text.isEmpty {
                Button {
                    Task { await continueWithRest() }
                } label: {
                    Text("Continue with the rest")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("bulkTextDraftsContinue")
            }
            if offersOpenDrafts {
                Button {
                    uploadManager.openDraftsOverview = true
                    uploadManager.selectedTab = 2
                    dismiss()
                } label: {
                    Text("Open drafts")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 32)
            }
            Button("Done") { dismiss() }
            Button("Undo", role: .destructive) { showUndoConfirm = true }
                .font(.footnote)
                .accessibilityIdentifier("bulkTextDraftsUndo")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Runs the unconverted text. The drafts already made stay undoable together with
    /// the new ones, and Undo still restores the text from before the FIRST run.
    private func continueWithRest() async {
        let earlier = createdItems
        let original = textBeforeRun
        await run()
        createdItems = earlier.filter { !Item.deletedIDs.contains($0.id) } + createdItems
        textBeforeRun = original
        if case .finished(var summary) = phase {
            summary.created = createdItems.count
            phase = .finished(summary)
        }
    }
}
