//
//  BulkTextDraftsSheet.swift
//  wonni
//
//  Paste or type anything describing what you're selling — a list, a paragraph,
//  a message, a pasted table — and get one ready-to-list draft per item, in the
//  order written. Items sold together become one listing, group notes become
//  shared context, and a price you wrote is kept as the price. Three steps in
//  one sheet: paste → review the proposals (uncheck any) → create drafts.
//  Photos come from eBay sellers' comps, then Google; when neither had one,
//  the user is asked ONCE whether AI-generated photos are acceptable, and only
//  a yes triggers generation. Opened from the drafts overview toolbar and from
//  Profile › Import.
//

import SwiftUI
import SwiftData

struct BulkTextDraftsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager

    private enum Phase: Equatable {
        case input
        case proposing
        case review
        case generating(done: Int, total: Int)
        case creating(done: Int, total: Int, current: String)
        case finished(count: Int)
    }

    @State private var phase: Phase = .input
    @State private var text = ""
    @State private var response: BulkDraftsFromTextResponse?
    @State private var excludedIndices: Set<Int> = []
    @State private var errorMessage: String?
    @State private var showAIPhotoConsent = false

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
                case .input, .proposing:
                    inputView
                case .review:
                    reviewView
                case .generating(let done, let total):
                    progressView(title: "Generating \(min(done + 1, total)) of \(total) photos…", detail: "", footnote: "AI-generated photos for listings nothing else covered.", done: done, total: total)
                case .creating(let done, let total, let current):
                    progressView(title: "Saving \(min(done + 1, total)) of \(total)…", detail: current, footnote: "Downloading photos and starting uploads.", done: done, total: total)
                case .finished(let count):
                    finishedView(count: count)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isBusy {
                        EmptyView()
                    } else {
                        Button(phase == .review ? "Back" : "Close") {
                            if phase == .review { phase = .input } else { dismiss() }
                        }
                    }
                }
            }
            .alert("Couldn't build drafts", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Use AI-generated photos?", isPresented: $showAIPhotoConsent) {
                Button("Use AI photos") {
                    aiPhotosAllowed = true
                    Task { await generateMissingPhotos() }
                }
                Button("Skip", role: .cancel) {}
            } message: {
                Text("No seller or web photo was found for \(missingPhotoCount) of these listings. AI can generate a realistic product photo for them, but it won't be a photo of your actual item. You can always replace it on the draft.")
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var title: String {
        switch phase {
        case .input, .proposing: return "Drafts from a list"
        case .review: return "Review drafts"
        case .generating: return "Generating photos"
        case .creating: return "Creating drafts"
        case .finished: return "Done"
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .proposing, .generating, .creating: return true
        default: return false
        }
    }

    // MARK: Step 1 — paste

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
                Text("Write it however you like: a list, a paragraph, a pasted message or table. Each item becomes one draft, in the order you wrote them. Items you say are sold together become one bundle listing. Prices you include are kept; the rest are priced from eBay comps.")
            }

            Section {
                Button {
                    Task { await propose() }
                } label: {
                    HStack {
                        Spacer()
                        if phase == .proposing {
                            ProgressView().padding(.trailing, 6)
                            Text("Reading your list…")
                        } else {
                            Label("Generate drafts", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                    .fontWeight(.semibold)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .proposing)
                .accessibilityIdentifier("bulkTextDraftsGenerate")
            } footer: {
                Text("Each listing is priced from live eBay comps and copies the closest eBay listing's category and item specifics. Photos come from eBay sellers' listings, then the web. Everything is editable before you publish.")
            }
        }
    }

    private func propose() async {
        phase = .proposing
        do {
            let result = try await BulkTextDraftService.shared.propose(text: text)
            if result.drafts.isEmpty {
                errorMessage = "No listings were found in that text."
                phase = .input
                return
            }
            response = result
            excludedIndices = []
            phase = .review
            // Photo priority: eBay sellers → web → ask about AI, once. A remembered
            // "yes" skips the question; a "no" only ever applies to this run.
            if missingPhotoCount > 0 {
                if aiPhotosAllowed {
                    await generateMissingPhotos()
                } else {
                    showAIPhotoConsent = true
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .input
        }
    }

    // MARK: AI photos (consent-gated)

    private var missingPhotoCount: Int {
        (response?.drafts ?? []).filter(BulkTextDraftMapper.needsPhoto).count
    }

    private func generateMissingPhotos() async {
        guard let current = response else { return }
        let missing = current.drafts.enumerated().filter { BulkTextDraftMapper.needsPhoto($0.element) }
        guard !missing.isEmpty else { return }
        var drafts = current.drafts
        for (done, entry) in missing.enumerated() {
            phase = .generating(done: done, total: missing.count)
            do {
                if let url = try await BulkTextDraftService.shared.generatePhoto(for: entry.element) {
                    drafts[entry.offset] = entry.element.with(imageSource: .generated, imageUrls: [url])
                }
            } catch {
                // One failed image is not a reason to lose the whole review — that
                // listing just keeps its placeholder.
                print("[BulkTextDraftsSheet] photo generation failed for \(entry.element.shortTitle): \(error)")
            }
        }
        response = current.with(drafts: drafts)
        phase = .review
    }

    // MARK: Step 2 — review

    private var includedCount: Int {
        (response?.drafts.count ?? 0) - excludedIndices.count
    }

    private var reviewView: some View {
        VStack(spacing: 0) {
            List {
                if let context = response?.context, !context.isEmpty {
                    Section {
                        Label(context, systemImage: "text.quote")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(Array((response?.drafts ?? []).enumerated()), id: \.offset) { index, proposal in
                        ProposalRow(proposal: proposal, isIncluded: !excludedIndices.contains(index)) {
                            if excludedIndices.contains(index) { excludedIndices.remove(index) } else { excludedIndices.insert(index) }
                        }
                    }
                } footer: {
                    Text("Uncheck anything you don't want. Titles, prices, descriptions and photos can all be edited on the draft afterwards.")
                }
            }
            .listStyle(.insetGrouped)

            Divider()
            Button {
                Task { await create() }
            } label: {
                Text(includedCount == 1 ? "Create 1 draft" : "Create \(includedCount) drafts")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(includedCount == 0)
            .padding()
            .accessibilityIdentifier("bulkTextDraftsCreate")
        }
    }

    private func create() async {
        guard let response else { return }
        let accepted = response.drafts.enumerated().filter { !excludedIndices.contains($0.offset) }.map(\.element)
        phase = .creating(done: 0, total: accepted.count, current: "")
        let created = await BulkTextDraftService.shared.createDrafts(
            from: accepted,
            response: response,
            modelContext: modelContext,
            uploadManager: uploadManager
        ) { progress in
            phase = .creating(done: progress.completed, total: progress.total, current: progress.currentTitle)
        }
        phase = .finished(count: created.count)
    }

    // MARK: Step 3 — progress / done

    private func progressView(title: String, detail: String, footnote: String, done: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .padding(.horizontal, 32)
            Text(title)
                .font(.headline)
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishedView(count: Int) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(count == 1 ? "1 draft created" : "\(count) drafts created")
                .font(.title3.weight(.semibold))
            Text("Photos are uploading in the background. Each draft is ready to review and publish.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 32)
            }
            Button("Done") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct ProposalRow: View {
    let proposal: Draft
    let isIncluded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.shortTitle.isEmpty ? proposal.title : proposal.shortTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if proposal.isBundle && !proposal.bundleItems.isEmpty {
                        Text(proposal.bundleItems.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let price = proposal.suggestedPrice {
                            Text(price, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                                .font(.caption.weight(.semibold))
                        }
                        Text(BulkTextDraftMapper.priceLabel(proposal))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if proposal.ebayCategoryId != nil {
                            Text("· eBay details copied")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(BulkTextDraftMapper.photoLabel(proposal))
                        .font(.caption2)
                        .foregroundStyle(proposal.imageSource == .none ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .opacity(isIncluded ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let first = proposal.imageUrls.first, let url = URL(string: first) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.systemGray5)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5))
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)
        }
    }
}
