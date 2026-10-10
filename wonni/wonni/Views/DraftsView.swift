//
//  DraftsView.swift
//  wonni
//
//  The one drafts screen on the Sell tab (2026-10-10). It replaces two screens that
//  showed the same drafts with different toolbars: the "drafts drawer" (photo strips,
//  per-draft "+", drag-and-drop between drafts) and the post-Proceed "overview"
//  (title/price fields, Process). Reached from both carousels' stack icon, Proceed on
//  the camera and the picker, Profile › "Open drafts" and the list importer — all push
//  `CameraRoute.drafts`.
//
//  Per draft: an inline title, an optional price under it, the photo strip (drag to
//  reorder within the draft), a "+" that pushes the picker for that draft, and a
//  pencil that opens the full edit sheet. Select mode selects photos (a draft's circle
//  selects all of its photos); the selection is moved with "Move to…" or deleted, and
//  whole drafts can be bulk-edited or set to skip AI. Dragging photos between drafts
//  and onto a trash target is gone on purpose: the user found it easy to delete when
//  meaning to reorder, and the four drop delegates behind it were the most fragile
//  part of the old drawer.
//

import SwiftUI
import SwiftData
import FirebaseAuth

struct DraftsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager
    @Query(filter: #Predicate<Item> { $0.isDraft == true }, sort: \Item.createdAt, order: .reverse)
    private var allItems: [Item]
    /// The Sell tab's one PhotoCollection; only its thumbnail cache is used here.
    @ObservedObject var photoCollection: PhotoCollection
    /// "+" on a draft: the host pushes a picker for that draft on top of this screen.
    let onAddPhotos: (UUID) -> Void

    @State private var isSelectMode = false
    /// Selected photos as "draftID|assetID". A draft is "fully selected" when every one
    /// of its photos is in here; the whole-draft actions act on those.
    @State private var selectedPhotos = Set<String>()
    @FocusState private var focusedField: DraftFocusField?
    @State private var lastFocusMoveDelta = 1
    @State private var showProcessFullScreen = false
    @State private var showDraftBulkEdit = false
    @State private var showDesktopDrafts = false
    @State private var showBulkTextDrafts = false
    @State private var showMoveTarget = false
    @State private var showDeleteConfirm = false
    @State private var skipAIMessage: String?
    @State private var editingDraft: Item?

    /// Every unpublished draft with photos. `deletedDraftIDs` drops a row the instant a
    /// delete starts (the SwiftData delete is deferred a tick); `publishedAt == nil`
    /// keeps a listing that is only still local for a queued cross-post job out of the
    /// bulk delete (see UploadManager.deleteDraftLocallyAndCloud).
    private var drafts: [Item] {
        allItems.filter {
            !$0.sourceAssetIdentifiers.isEmpty && !$0.pendingPublish && $0.publishedAt == nil
                && !uploadManager.deletedDraftIDs.contains($0.id)
        }
    }

    private func compositeIDs(_ draft: Item) -> [String] {
        draft.sourceAssetIdentifiers.map { "\(draft.id.uuidString)|\($0)" }
    }

    private var fullySelectedDrafts: [Item] {
        drafts.filter { draft in
            let ids = Set(compositeIDs(draft))
            return !ids.isEmpty && ids.isSubset(of: selectedPhotos)
        }
    }

    private var selectionToolbar: DraftSelectionToolbar {
        DraftSelectionToolbar(
            totalDrafts: drafts.count,
            fullySelectedDrafts: fullySelectedDrafts.count,
            hasAnySelection: !selectedPhotos.isEmpty
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if uploadManager.isProcessing { processingBanner }
            if drafts.isEmpty {
                emptyState
            } else {
                draftList
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Drafts")
        .navigationBarTitleDisplayMode(.inline)
        // Selection mode is left via Cancel only — the back chevron would otherwise
        // crowd Select All and pop the screen mid-selection.
        .navigationBarBackButtonHidden(isSelectMode)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { moveFocus(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(focusedIndex == nil || focusedIndex == 0)
                    .accessibilityIdentifier("draftsFocusUpButton")
                Button { moveFocus(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(focusedIndex == nil || focusedIndex == drafts.count * 2 - 1)
                    .accessibilityIdentifier("draftsFocusDownButton")
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onChange(of: focusedField) { _, _ in
            try? modelContext.save()
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelectMode)
        .fullScreenCover(isPresented: $showProcessFullScreen) {
            NavigationStack {
                ProcessProgressView(onMinimize: {
                    showProcessFullScreen = false
                    // Defer the tab switch past the cover dismiss animation so SwiftUI
                    // doesn't get two presentation changes in one frame.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        uploadManager.selectedTab = 0
                    }
                })
            }
            .environmentObject(uploadManager)
        }
        .sheet(isPresented: $showDraftBulkEdit) {
            DraftBulkEditSheet(items: fullySelectedDrafts) { exitSelectMode() }
                .environmentObject(uploadManager)
        }
        .sheet(isPresented: $showDesktopDrafts) {
            NavigationStack { DesktopDraftsView() }
        }
        .sheet(isPresented: $showBulkTextDrafts) {
            BulkTextDraftsSheet()
                .environmentObject(uploadManager)
        }
        .sheet(isPresented: $showMoveTarget) {
            MoveToDraftSheet(
                targets: drafts.filter { !fullySelectedDrafts.contains($0) },
                photoCount: selectedPhotos.count
            ) { target in
                moveSelectedPhotos(to: target)
            }
        }
        .sheet(item: $editingDraft) { draft in
            DraftEditSheet(item: draft)
                .environmentObject(uploadManager)
        }
        .alert("Delete Selected?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelectedPhotos() }
        } message: {
            Text(deleteSummary)
        }
        .alert("Skip AI", isPresented: Binding(get: { skipAIMessage != nil }, set: { if !$0 { skipAIMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(skipAIMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("No drafts yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var draftList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(drafts) { draft in
                    DraftCard(
                        draft: draft,
                        isSelectMode: isSelectMode,
                        selectedPhotos: selectedPhotos,
                        focusedField: $focusedField,
                        onToggleDraft: { toggleDraft(draft) },
                        onTogglePhoto: { assetId in togglePhoto(draft, assetId: assetId) },
                        onAddPhotos: { onAddPhotos(draft.id) },
                        onEdit: { editingDraft = draft }
                    )
                    .id(draft.id)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .onDelete { offsets in
                    guard !isSelectMode else { return }
                    for offset in offsets {
                        uploadManager.deleteDraftLocallyAndCloud(draft: drafts[offset], modelContext: modelContext)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedField) { oldValue, newValue in
                if let focus = newValue, focus.itemID != oldValue?.itemID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(focus.itemID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var processingBanner: some View {
        VStack(spacing: 4) {
            ProgressView(value: uploadManager.processProgress)
                .tint(.purple)
                .padding(.horizontal)
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                Text("Processing \(uploadManager.processCurrentIndex) of \(uploadManager.processTotalCount)…")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("View") { showProcessFullScreen = true }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if isSelectMode {
                switch selectionToolbar.leading {
                case .selectAll:
                    Button("Select All") { selectAll() }
                        .accessibilityIdentifier("draftHistorySelectAllButton")
                case .deselectAll:
                    Button("Deselect All") { selectedPhotos.removeAll() }
                        .accessibilityIdentifier("draftHistoryDeselectAllButton")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if isSelectMode {
                selectionActionsMenu
            } else {
                Menu {
                    Button {
                        showBulkTextDrafts = true
                    } label: {
                        Label("Drafts from a List", systemImage: "text.badge.plus")
                    }
                    .accessibilityIdentifier("draftsFromTextButton")
                    Button {
                        showDesktopDrafts = true
                    } label: {
                        Label("Desktop Drafts", systemImage: "desktopcomputer")
                    }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .accessibilityIdentifier("draftsImportMenu")
            }
        }
        // Declared last so it is the outermost (far-right) item.
        ToolbarItem(placement: .navigationBarTrailing) {
            if isSelectMode {
                Button("Cancel") { exitSelectMode() }
                    .accessibilityIdentifier("draftHistoryCancelButton")
            } else {
                Button("Select") { isSelectMode = true }
                    .disabled(drafts.isEmpty)
                    .accessibilityIdentifier("draftHistorySelectButton")
            }
        }
    }

    /// One explicit Menu for the whole-selection actions. Loose trailing buttons get
    /// collapsed by iOS 26 into a system "…" overflow that did nothing when tapped.
    private var selectionActionsMenu: some View {
        let toolbar = selectionToolbar
        return Menu {
            Button {
                showDraftBulkEdit = true
            } label: {
                Label("Bulk Edit \(fullySelectedDrafts.count) drafts", systemImage: "slider.horizontal.3")
            }
            .disabled(!toolbar.canBulkEdit)
            .accessibilityIdentifier("draftHistoryBulkEditButton")
            Button {
                skipAI()
            } label: {
                Label("Skip AI", systemImage: "sparkles.slash")
            }
            .disabled(fullySelectedDrafts.isEmpty)
            .accessibilityIdentifier("draftsSkipAIButton")
            Button {
                showMoveTarget = true
            } label: {
                Label("Move to…", systemImage: "folder")
            }
            .disabled(!toolbar.canDelete)
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!toolbar.canDelete)
            .accessibilityIdentifier("draftHistoryDeleteButton")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(!toolbar.canDelete)
        .accessibilityIdentifier("draftHistorySelectionMenu")
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if isSelectMode {
                Text(selectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Move to…") { showMoveTarget = true }
                    .font(.subheadline.weight(.semibold))
                    .disabled(selectedPhotos.isEmpty)
                Button("Delete", role: .destructive) { showDeleteConfirm = true }
                    .font(.subheadline.weight(.semibold))
                    .disabled(selectedPhotos.isEmpty)
            } else {
                uploadStatus
                Spacer()
                processButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private var uploadStatus: some View {
        HStack(spacing: 6) {
            Text("\(drafts.count) draft\(drafts.count == 1 ? "" : "s")")
            if uploadManager.isUploadingPhotos {
                Image(systemName: "icloud.and.arrow.up")
                ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
            } else if !drafts.isEmpty {
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var processButton: some View {
        let processing = uploadManager.isProcessing
        return Button {
            // Start AI right away — Gemini reads the on-device photos, so it never waits
            // for the Storage upload; publish re-uploads anything that didn't finish.
            guard !processing, !drafts.isEmpty else { return }
            focusedField = nil
            uploadManager.processDrafts(drafts: drafts, modelContext: modelContext)
            showProcessFullScreen = true
        } label: {
            HStack(spacing: 6) {
                Text(processing ? "Processing…" : "Process")
                    .fontWeight(.semibold)
                if !processing {
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(processing || drafts.isEmpty)
        .accessibilityIdentifier("draftsProcessButton")
    }

    // MARK: - Selection

    private var selectionSummary: String {
        let photos = selectedPhotos.count
        let whole = fullySelectedDrafts.count
        if photos == 0 { return "Select photos or drafts" }
        if whole > 0 && fullySelectedDrafts.reduce(0, { $0 + $1.sourceAssetIdentifiers.count }) == photos {
            return "\(whole) draft\(whole == 1 ? "" : "s") selected"
        }
        return "\(photos) photo\(photos == 1 ? "" : "s") selected"
    }

    private var deleteSummary: String {
        let whole = fullySelectedDrafts.count
        let photos = selectedPhotos.count
        if whole > 0 {
            return "\(whole) whole draft\(whole == 1 ? "" : "s") and any other selected photos will be deleted."
        }
        return "\(photos) photo\(photos == 1 ? "" : "s") will be removed."
    }

    private func toggleDraft(_ draft: Item) {
        let ids = compositeIDs(draft)
        if Set(ids).isSubset(of: selectedPhotos) {
            for id in ids { selectedPhotos.remove(id) }
        } else {
            for id in ids { selectedPhotos.insert(id) }
        }
    }

    private func togglePhoto(_ draft: Item, assetId: String) {
        let id = "\(draft.id.uuidString)|\(assetId)"
        if selectedPhotos.contains(id) { selectedPhotos.remove(id) } else { selectedPhotos.insert(id) }
    }

    private func selectAll() {
        for draft in drafts { for id in compositeIDs(draft) { selectedPhotos.insert(id) } }
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedPhotos.removeAll()
    }

    private func skipAI() {
        let chosen = fullySelectedDrafts
        let result = uploadManager.skipAIProcessing(for: chosen, modelContext: modelContext)
        var lines: [String] = []
        if result.marked > 0 {
            lines.append("\(result.marked) draft\(result.marked == 1 ? "" : "s") will skip AI processing.")
        }
        if result.incomplete > 0 {
            lines.append("\(result.incomplete) \(result.incomplete == 1 ? "is" : "are") missing \(result.missing.formatted(.list(type: .or))), so AI will still process \(result.incomplete == 1 ? "it" : "them").")
        }
        skipAIMessage = lines.joined(separator: " ")
        exitSelectMode()
    }

    /// Whole drafts (every photo selected) are deleted outright; a partial selection
    /// removes just those photos, locally and from Storage.
    private func deleteSelectedPhotos() {
        for draft in drafts {
            let ids = compositeIDs(draft)
            let chosen = ids.filter { selectedPhotos.contains($0) }
            guard !chosen.isEmpty else { continue }
            if chosen.count == ids.count {
                uploadManager.deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
            } else {
                for assetId in draft.sourceAssetIdentifiers where selectedPhotos.contains("\(draft.id.uuidString)|\(assetId)") {
                    let removed = draft.removePhoto(assetId: assetId)
                    if let path = removed.firebasePhotoPath { deletePhotoFromStorage(path: path) }
                }
                uploadManager.syncProductData(draft)
            }
        }
        try? modelContext.save()
        exitSelectMode()
    }

    /// Moves every selected photo to `target` (nil = a new draft), appended in order.
    /// Sources left empty are deleted. A new draft is uploaded and synced like a
    /// committed one; the photos' existing Storage paths belong to their old listing
    /// ids, so a full upload is the correct thing.
    private func moveSelectedPhotos(to target: Item?) {
        let destination: Item
        let isNew: Bool
        if let target {
            destination = target
            isNew = false
        } else {
            destination = Item(firestoreListingId: UUID().uuidString)
            modelContext.insert(destination)
            isNew = true
        }
        var touched: [Item] = []
        for draft in drafts where draft.id != destination.id {
            let moving = draft.sourceAssetIdentifiers.filter { selectedPhotos.contains("\(draft.id.uuidString)|\($0)") }
            guard !moving.isEmpty else { continue }
            for assetId in moving {
                let removed = draft.removePhoto(assetId: assetId)
                destination.insertPhoto(
                    assetId: assetId,
                    data: removed.data,
                    at: destination.sourceAssetIdentifiers.count,
                    firebasePhotoPath: isNew ? nil : removed.firebasePhotoPath
                )
            }
            touched.append(draft)
        }
        try? modelContext.save()
        for draft in touched {
            if draft.sourceAssetIdentifiers.isEmpty {
                uploadManager.deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
            } else {
                uploadManager.syncProductData(draft)
            }
        }
        if isNew {
            uploadManager.startBackgroundUpload(draft: destination, modelContext: modelContext)
        }
        uploadManager.syncProductData(destination)
        exitSelectMode()
    }

    /// Best-effort delete of one already-uploaded photo (not a whole-draft wipe).
    private func deletePhotoFromStorage(path: String) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        Task {
            do {
                try await StorageService.shared.deletePhoto(path: path, userId: userId)
            } catch {
                print("[DraftsView] Failed to delete photo at \(path): \(error)")
                uploadManager.cleanupError = "Couldn't fully delete a removed photo. It may still be using storage."
            }
        }
    }

    // MARK: - Keyboard focus (title → price → next draft's title …)

    private var focusedIndex: Int? {
        guard let focus = focusedField, let row = drafts.firstIndex(where: { $0.id == focus.itemID }) else { return nil }
        return row * 2 + (focus.field == .price ? 1 : 0)
    }

    private func moveFocus(by delta: Int) {
        lastFocusMoveDelta = delta
        guard let current = focusedIndex else { return }
        let next = current + delta
        guard next >= 0, next < drafts.count * 2 else { return }
        focusedField = DraftFocusField(itemID: drafts[next / 2].id, field: next % 2 == 0 ? .title : .price)
    }
}

// MARK: - DraftCard

/// One draft: title, optional price, photo strip with "+", pencil. Equatable on the
/// inputs that change its look so the List doesn't rebuild every card on each
/// UploadManager tick while the user is typing.
struct DraftCard: View {
    let draft: Item
    let isSelectMode: Bool
    let selectedPhotos: Set<String>
    var focusedField: FocusState<DraftFocusField?>.Binding
    let onToggleDraft: () -> Void
    let onTogglePhoto: (String) -> Void
    let onAddPhotos: () -> Void
    let onEdit: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var localTitle = ""
    @State private var localPrice = ""
    @State private var draggedAssetId: String?

    private var compositeIDs: [String] { draft.sourceAssetIdentifiers.map { "\(draft.id.uuidString)|\($0)" } }
    private var selectedCount: Int { compositeIDs.filter { selectedPhotos.contains($0) }.count }
    private var isFullySelected: Bool { selectedCount > 0 && selectedCount == compositeIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if isSelectMode {
                    Button(action: onToggleDraft) {
                        Image(systemName: isFullySelected ? "checkmark.circle.fill" : (selectedCount > 0 ? "minus.circle.fill" : "circle"))
                            .font(.title3)
                            .foregroundStyle(selectedCount > 0 ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("draftFullSelectToggle")
                }

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Add title…", text: $localTitle, axis: .vertical)
                        .lineLimit(1...2)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.userEditedTitle != nil ? .primary : .secondary)
                        .focused(focusedField, equals: DraftFocusField(itemID: draft.id, field: .title))
                        .submitLabel(.next)
                        .onSubmit { focusedField.wrappedValue = DraftFocusField(itemID: draft.id, field: .price) }
                        .disabled(isSelectMode)
                        .accessibilityIdentifier("draftRowTitleField")
                    HStack(spacing: 3) {
                        Text("$").font(.subheadline).foregroundStyle(localPrice.isEmpty ? .tertiary : .secondary)
                        TextField("Price (Optional)", text: $localPrice)
                            .font(.subheadline)
                            .keyboardType(.decimalPad)
                            .focused(focusedField, equals: DraftFocusField(itemID: draft.id, field: .price))
                            .disabled(isSelectMode)
                            .accessibilityIdentifier("draftRowPriceField")
                    }
                    if let vision = draft.visionTitle, !vision.isEmpty, draft.processedAt == nil, localTitle.isEmpty {
                        VisionTitleSuggestionChip(suggestion: vision) {
                            localTitle = vision
                            draft.userEditedTitle = vision
                            draft.visionTitleAccepted = true
                            try? modelContext.save()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isSelectMode {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("draftEditButton")
                }
            }

            photoStrip

            if draft.processedAt != nil {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                    Text(draft.skipAIProcessing == true ? "Skips AI" : "AI identified")
                        .font(.caption2).foregroundStyle(.purple.opacity(0.8))
                }
            } else if draft.skipAIProcessing == true {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles.slash").font(.caption2).foregroundStyle(.secondary)
                    Text("Skips AI").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            localTitle = draft.userEditedTitle ?? draft.aiSuggestedTitle ?? ""
            localPrice = draft.userEditedPrice.map { String(format: "%.2f", $0) } ?? ""
        }
        .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
            if oldFocus?.itemID == draft.id && newFocus?.itemID != draft.id { save() }
        }
        .onChange(of: draft.userEditedTitle) { _, newVal in
            localTitle = newVal ?? draft.aiSuggestedTitle ?? ""
        }
        .onChange(of: draft.userEditedPrice) { _, newVal in
            localPrice = newVal.map { String(format: "%.2f", $0) } ?? ""
        }
        .onDisappear { save() }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // LazyHStack: only visible cells decode (a draft can hold 20+ photos).
            LazyHStack(spacing: 10) {
                ForEach(draft.sourceAssetIdentifiers, id: \.self) { assetId in
                    photoCell(assetId)
                }
                if !isSelectMode {
                    Button(action: onAddPhotos) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(.secondary)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("draftAddPhotosButton")
                }
            }
        }
        // LazyHStack is greedy on the cross axis — pin the row to its 80pt cells.
        .frame(height: 80)
    }

    @ViewBuilder
    private func photoCell(_ assetId: String) -> some View {
        let composite = "\(draft.id.uuidString)|\(assetId)"
        let isSelected = selectedPhotos.contains(composite)
        let isDragged = draggedAssetId == assetId
        DraftThumbnailView(item: draft, assetId: assetId)
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                if isSelectMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(5)
                }
            }
            .opacity(isDragged ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectMode { onTogglePhoto(assetId) }
            }
            .onDrag {
                draggedAssetId = assetId
                return NSItemProvider(object: assetId as NSString)
            }
            .onDrop(of: [.text], delegate: ActiveDraftPhotoDropDelegate(
                targetAssetId: assetId,
                draft: draft,
                draggedAssetId: $draggedAssetId,
                modelContext: modelContext
            ))
            .accessibilityIdentifier("draftPhotoCell")
    }

    /// Writes the inline fields back. Guarded against a draft deleted while this card
    /// was still on screen (onDisappear runs during the removal animation).
    private func save() {
        guard !Item.deletedIDs.contains(draft.id) else { return }
        let title = String(localTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        let placeholder = draft.aiSuggestedTitle ?? ""
        if title.isEmpty {
            if draft.userEditedTitle != nil { draft.userEditedTitle = nil }
        } else if title != placeholder || draft.userEditedTitle != nil {
            if draft.userEditedTitle != title { draft.userEditedTitle = title }
        }
        let cleaned = localPrice.filter { $0.isNumber || $0 == "." }
        let price = cleaned.isEmpty ? nil : Double(cleaned)
        if draft.userEditedPrice != price { draft.userEditedPrice = price }
    }
}

// MARK: - Move to…

/// Target picker for "Move to…": every other draft, or a new one.
struct MoveToDraftSheet: View {
    let targets: [Item]
    let photoCount: Int
    let onPick: (Item?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        onPick(nil)
                    } label: {
                        Label("New draft", systemImage: "plus.square.on.square")
                    }
                    .accessibilityIdentifier("moveToNewDraftButton")
                }
                if !targets.isEmpty {
                    Section("Existing drafts") {
                        ForEach(targets) { draft in
                            Button {
                                dismiss()
                                onPick(draft)
                            } label: {
                                HStack(spacing: 12) {
                                    if let assetId = draft.sourceAssetIdentifiers.first {
                                        DraftThumbnailView(item: draft, assetId: assetId)
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    let title = draft.userEditedTitle ?? draft.aiSuggestedTitle ?? draft.visionTitle ?? ""
                                    Text(title.isEmpty ? "Untitled draft" : title)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(draft.sourceAssetIdentifiers.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move \(photoCount) photo\(photoCount == 1 ? "" : "s") to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
