//
//  BulkTextDraftsSheet.swift
//  wonni
//
//  Paste a plain-text inventory list ("wii games (CIB): / bundle 1: a, b, c /
//  super smash bros brawl / …") and get one ready-to-list draft per line —
//  bundles become one listing, headers become shared context. Three steps in
//  one sheet: paste → review the proposals (uncheck any) → create drafts.
//  Opened from the drafts overview toolbar and from Profile › Import.
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
        case creating(done: Int, total: Int, current: String)
        case finished(count: Int)
    }

    @State private var phase: Phase = .input
    @State private var text = ""
    @State private var photoSource: PhotoSource = .ebay
    @State private var response: BulkDraftsFromTextResponse?
    @State private var excludedIndices: Set<Int> = []
    @State private var errorMessage: String?

    /// Shown when the user came from somewhere other than the drafts overview
    /// (Profile › Import) and needs a way to get to the drafts they just made.
    var offersOpenDrafts = false

    private static let placeholder = """
    wii games (CIB):
    bundle 1: just dance 4, just dance 2015, just dance 2014
    bundle 2: need for speed carbon, need for speed pro street
    Super smash bros brawl
    Mario strikers charged
    Link's crossbow training (in cardboard sleeve)
    """

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input, .proposing:
                    inputView
                case .review:
                    reviewView
                case .creating(let done, let total, let current):
                    progressView(done: done, total: total, current: current)
                case .finished(let count):
                    finishedView(count: count)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .creating = phase {
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
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var title: String {
        switch phase {
        case .input, .proposing: return "Drafts from a list"
        case .review: return "Review drafts"
        case .creating: return "Creating drafts"
        case .finished: return "Done"
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .proposing, .creating: return true
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
                Text("Your list")
            } footer: {
                Text("One item per line. A line ending in \":\" is a header that applies to everything under it. \"bundle 1: a, b, c\" becomes one listing with all three items. Notes in parentheses stay with that item.")
            }

            Section {
                Picker("Photos", selection: $photoSource) {
                    Text("Stock photo from eBay").tag(PhotoSource.ebay)
                    Text("AI-generated").tag(PhotoSource.generate)
                }
            } footer: {
                Text("Stock photos come from comparable eBay listings (AI-generated when none is found). Prices are the median of live eBay asking prices. Everything is editable before you publish.")
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
            }
        }
    }

    private func propose() async {
        phase = .proposing
        do {
            let result = try await BulkTextDraftService.shared.propose(text: text, photoSource: photoSource)
            if result.drafts.isEmpty {
                errorMessage = "No listings were found in that text."
                phase = .input
                return
            }
            response = result
            excludedIndices = []
            phase = .review
        } catch {
            errorMessage = error.localizedDescription
            phase = .input
        }
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

    private func progressView(done: Int, total: Int, current: String) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .padding(.horizontal, 32)
            Text("Saving \(min(done + 1, total)) of \(total)…")
                .font(.headline)
            if !current.isEmpty {
                Text(current)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Text("Downloading photos and starting uploads.")
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
