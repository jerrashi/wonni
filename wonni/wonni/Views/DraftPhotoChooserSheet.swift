//
//  DraftPhotoChooserSheet.swift
//  wonni
//
//  "Choose photos" for a draft made from a pasted list (2026-10-14, mock agreed
//  2026-10-13). The list importer takes photos from the closest live eBay listing in
//  the same state as ours; when nothing qualified, or the match was only a guess, the
//  draft tile shows a badge that opens this sheet. One list, searched on eBay: every
//  result with a photo, strong matches (same item, same state) first, then the rest —
//  the right listing is often past the first few, so nothing is hidden. Cards look
//  like the draft rows (title and price, photo, chips: source then what the listing
//  says is included). Editing the query searches again.
//
//  Import copies the chosen listing's photos onto the draft — replacing the current
//  placeholder / auto-picked ones, or appended after them — and, with "Include listing
//  details" on, its eBay category and item specifics. The one per-listing eBay call
//  happens here, on Import, not while browsing.
//

import SwiftUI
import SwiftData

struct DraftPhotoChooserSheet: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager

    @State private var query = ""
    @State private var candidates: [PhotoCandidate] = []
    @State private var selectedId: String?
    @State private var includeDetails = true
    @State private var replacePhotos = true
    @State private var isSearching = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    /// Shown after an import on the drafts screen (the sheet closes).
    @State private var searchedOnce = false

    private var listingTitle: String {
        let title = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
        return title.isEmpty ? "Untitled draft" : title
    }

    private var includedState: Included? {
        item.includedState.flatMap(Included.init(rawValue:))
    }

    private var strongCandidates: [PhotoCandidate] { candidates.filter(\.strong) }
    private var otherCandidates: [PhotoCandidate] { candidates.filter { !$0.strong } }
    private var selected: PhotoCandidate? { candidates.first { $0.itemId == selectedId } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                List {
                    Section {
                        searchField
                    }
                    if isSearching {
                        Section {
                            HStack { Spacer(); ProgressView("Searching eBay…"); Spacer() }
                                .listRowBackground(Color.clear)
                        }
                    } else if candidates.isEmpty {
                        Section {
                            Text(searchedOnce ? "No listings with photos found. Try different words." : "Search eBay for a listing to take photos from.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        if !strongCandidates.isEmpty {
                            Section(otherCandidates.isEmpty ? "eBay listings" : "Best matches") {
                                ForEach(strongCandidates, id: \.itemId) { card($0) }
                            }
                        }
                        if !otherCandidates.isEmpty {
                            Section(strongCandidates.isEmpty ? "eBay listings" : "Other results") {
                                ForEach(otherCandidates, id: \.itemId) { card($0) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.immediately)
                footer
            }
            .navigationTitle("Choose photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isImporting)
                }
            }
            .alert("Couldn't import", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .interactiveDismissDisabled(isImporting)
        }
        .task { await load() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Photos for").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(listingTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let state = includedState, let label = BulkTextDraftMapper.includedLabel(state) {
                    Text("· \(label.lowercased())").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search eBay", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
                .accessibilityIdentifier("draftPhotoChooserQuery")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func card(_ candidate: PhotoCandidate) -> some View {
        let isPicked = candidate.itemId == selectedId
        return Button {
            selectedId = isPicked ? nil : candidate.itemId
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isPicked ? Color.accentColor : .secondary)
                    Text(candidate.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let price = candidate.price {
                        Text(price, format: .currency(code: "USD").precision(.fractionLength(2)))
                            .font(.subheadline.weight(.semibold))
                    }
                }
                AsyncImage(url: URL(string: candidate.imageUrl)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Color.gray.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    default: Color.gray.opacity(0.15).overlay(ProgressView().scaleEffect(0.6))
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                chips(for: candidate)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isPicked ? Color.accentColor.opacity(0.08) : nil)
        .accessibilityIdentifier("draftPhotoCandidate")
    }

    /// Source first, then what the listing says is included (green when it matches
    /// ours, orange when it contradicts), then any "different item" markers.
    private func chips(for candidate: PhotoCandidate) -> some View {
        var items: [(text: String, tone: ChipTone)] = [("eBay", .source)]
        if let label = BulkTextDraftMapper.includedLabel(candidate.included) {
            let tone: ChipTone
            if let ours = includedState, ours != .unknown {
                tone = ours == candidate.included ? .match : .warn
            } else {
                tone = candidate.included == .packaging ? .warn : .neutral
            }
            items.append((label, tone))
        }
        for marker in candidate.markers.prefix(3) {
            items.append((marker.capitalized, .warn))
        }
        return HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                Text(entry.element.text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(entry.element.tone.background, in: Capsule())
                    .foregroundStyle(entry.element.tone.foreground)
            }
        }
    }

    private enum ChipTone {
        case source, match, warn, neutral
        var background: Color {
            switch self {
            case .source: return Color.accentColor.opacity(0.14)
            case .match: return Color.green.opacity(0.15)
            case .warn: return Color.orange.opacity(0.18)
            case .neutral: return Color(.tertiarySystemFill)
            }
        }
        var foreground: Color {
            switch self {
            case .source: return .accentColor
            case .match: return .green
            case .warn: return .orange
            case .neutral: return .secondary
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Toggle("Include listing details", isOn: $includeDetails)
                .accessibilityIdentifier("draftPhotoChooserIncludeDetails")
            Toggle("Replace current photos", isOn: $replacePhotos)
                .accessibilityIdentifier("draftPhotoChooserReplace")
            Button {
                Task { await importSelected() }
            } label: {
                HStack {
                    if isImporting { ProgressView().tint(.white) }
                    Text(isImporting ? "Importing…" : "Import")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil || isImporting)
            .accessibilityIdentifier("draftPhotoChooserImport")
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: Actions

    /// Stored candidates first (no network); a draft without any searches at once.
    private func load() async {
        query = item.photoSearchQuery ?? (item.userEditedTitle ?? item.aiSuggestedTitle ?? "")
        candidates = BulkTextDraftMapper.storedCandidates(item.photoCandidatesData)
        if candidates.isEmpty, !query.isEmpty {
            await search()
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            candidates = try await BulkTextDraftService.shared.photoCandidates(query: trimmed, included: item.includedState)
            selectedId = nil
            searchedOnce = true
            if !Item.deletedIDs.contains(item.id) {
                // Remember the search the user settled on, so reopening starts from it.
                item.photoSearchQuery = trimmed
                item.photoCandidatesData = try? JSONEncoder().encode(candidates)
                try? modelContext.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importSelected() async {
        guard let selected, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            try await BulkTextDraftService.shared.importCandidate(
                selected,
                onto: item,
                options: .init(includeDetails: includeDetails, replacePhotos: replacePhotos),
                modelContext: modelContext,
                uploadManager: uploadManager
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The orange "Choose photos" badge on a draft tile. Shown by the drafts screen and
/// the Review & Publish rows only when the automatic photo match was weak or empty.
struct DraftPhotoBadge: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(text)
                Image(systemName: "chevron.right").opacity(0.7)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.orange.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("draftPhotoBadge")
    }
}
