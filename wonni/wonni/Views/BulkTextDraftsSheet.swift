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
//  Since 2026-10-13 the run happens in `BulkTextDraftRunner`, not here: tapping
//  Create closes the sheet and the app stays usable while the pill shows
//  "Creating drafts · 3 of 12". Tapping the pill reopens this sheet on the
//  progress screen (with Stop); once the run ends, the next open shows the finish
//  screen (with Undo). Photos come from eBay sellers' comps, then Google; when
//  neither had one, the user is asked ONCE (from MainView, so it reaches them
//  wherever they are) whether AI-generated photos are acceptable. Opened from the
//  camera, the photo picker, the drafts overview and Profile › Import.
//

import SwiftUI
import SwiftData

struct BulkTextDraftsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager
    @ObservedObject private var runner = BulkTextDraftRunner.shared

    /// Persisted so an unfinished list survives closing the sheet (or the app). The
    /// runner rewrites the same key when a run ends, so this editor updates.
    @AppStorage(BulkTextDraftRunner.pendingTextKey) private var text = ""
    @State private var showUndoConfirm = false

    /// Shown when the user came from somewhere other than the drafts overview
    /// (Profile › Import) and needs a way to get to the drafts they just made.
    var offersOpenDrafts = false

    private static let placeholder = """
    Clearing out my Wii stuff, all complete in box. Super Smash Bros Brawl for $30, \
    Mario Strikers Charged, and Just Dance 4 + Just Dance 2015 together as a bundle. \
    Also Link's Crossbow Training (in cardboard sleeve), 8 bucks. \
    iPhone case I never opened https://www.amazon.com/dp/B0CHX1W1XY
    """

    var body: some View {
        NavigationStack {
            Group {
                switch runner.phase {
                case .input:
                    inputView
                case .reading:
                    workingView(BulkTextDraftRunner.RunStatus(step: "Reading your list…"))
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
                    Button("Close") { dismiss() }
                }
            }
            .alert("Couldn't build drafts", isPresented: Binding(get: { runner.errorMessage != nil }, set: { if !$0 { runner.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runner.errorMessage ?? "")
            }
            .confirmationDialog(
                "Delete the \(runner.createdItems.count) draft\(runner.createdItems.count == 1 ? "" : "s") this list just created?",
                isPresented: $showUndoConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(runner.createdItems.count) draft\(runner.createdItems.count == 1 ? "" : "s")", role: .destructive) {
                    runner.undo(modelContext: modelContext, uploadManager: uploadManager)
                }
                Button("Keep them", role: .cancel) {}
            } message: {
                Text("Your text goes back in the editor.")
            }
        }
    }

    private var title: String {
        switch runner.phase {
        case .input: return "Drafts from a list"
        case .reading, .working: return "Creating drafts"
        case .finished: return "Done"
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
                        .accessibilityIdentifier("bulkTextDraftsEditor")
                }
            } header: {
                Text("What are you selling?")
            } footer: {
                Text("Write it however you like, and paste product links where you have them: Amazon, eBay, AliExpress, Weverse or any store page. Each item becomes one draft, in order. A link gives its draft the page's photos and what you paid; the asking price still comes from eBay comps. Items you say are sold together become one bundle listing.")
            }

            Section {
                Button {
                    startRun()
                } label: {
                    HStack {
                        Spacer()
                        Label("Create drafts", systemImage: "sparkles")
                        Spacer()
                    }
                    .fontWeight(.semibold)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("bulkTextDraftsGenerate")
            } footer: {
                Text("Drafts are created in the background — you can keep using the app and watch progress in the pill at the bottom. They land in your drafts, where you can edit or delete any of them. Each is priced from live eBay comps and copies the closest eBay listing's category and item specifics. Photos come from eBay sellers' listings, then the web.")
            }
        }
    }

    /// Hands the text to the runner and closes the sheet; the pill takes over.
    private func startRun(continuing: Bool = false) {
        guard runner.start(text: text, modelContext: modelContext, uploadManager: uploadManager, continuing: continuing) else { return }
        dismiss()
    }

    // MARK: Progress / done

    private func workingView(_ status: BulkTextDraftRunner.RunStatus) -> some View {
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
            Button(runner.stopRequested ? "Stopping…" : "Stop") { runner.stop() }
                .disabled(runner.stopRequested)
                .padding(.top, 8)
                .accessibilityIdentifier("bulkTextDraftsStop")
            Text("You can close this and keep working — drafts keep coming in the background. Anything not converted stays in the editor.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishedView(_ summary: BulkTextDraftRunner.Summary) -> some View {
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
                ForEach(Array(BulkTextDraftMapper.linkSummaryLines(summary.links).enumerated()), id: \.offset) { entry in
                    Label(entry.element, systemImage: entry.element.contains("could not") ? "exclamationmark.triangle" : "link")
                        .foregroundStyle(entry.element.contains("could not") ? .orange : .secondary)
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
                    startRun(continuing: true)
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
                    runner.acknowledge()
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
            Button("Done") {
                runner.acknowledge()
                dismiss()
            }
            Button("Undo", role: .destructive) { showUndoConfirm = true }
                .font(.footnote)
                .accessibilityIdentifier("bulkTextDraftsUndo")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
