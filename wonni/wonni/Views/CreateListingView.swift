//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
import PhotosUI
import SwiftData
import Photos
import UniformTypeIdentifiers
import Vision
import UIKit
import FirebaseFirestore
import FirebaseAuth



struct DraftsStackIcon: View {
    var drafts: [Item]
    var cache: CachedImageManager
    var bouncing: Bool = false

    private static let cardW: CGFloat = 30
    private static let cardH: CGFloat = 38
    private static let rotations: [Double] = [-14, 0, 14]

    var body: some View {
        // Always show 3 slots. Most recent draft = top (index 2 in ZStack = rendered on top).
        let allAssets: [PhotoAsset] = drafts.compactMap {
            $0.sourceAssetIdentifiers.first.map(PhotoAsset.init(identifier:))
        }
        // suffix(3) keeps the 3 newest; pad the front with nils for empty ghost cards.
        let recent = Array(allAssets.suffix(3))
        let slots: [PhotoAsset?] = Array(repeating: nil, count: 3 - recent.count) + recent.map { .some($0) }

        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let rotation = Self.rotations[index]
                Group {
                    if let asset = slots[index] {
                        PhotoItemView(asset: asset, cache: cache,
                                      imageSize: CGSize(width: Self.cardW * 2, height: Self.cardH * 2))
                            .scaledToFill()
                            .frame(width: Self.cardW, height: Self.cardH)
                            .cornerRadius(4)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray2))
                            .frame(width: Self.cardW, height: Self.cardH)
                    }
                }
                .rotationEffect(.degrees(rotation), anchor: .bottom)
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
            }
        }
        .frame(width: 70, height: 62)
        .scaleEffect(bouncing ? 1.25 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.45), value: bouncing)
    }
}

struct SelectablePhotoGridItem: View {
    let asset: PhotoAsset
    let activeAssetIDs: Set<String>       // IDs in the current active draft
    let activeAssetOrder: [String]         // Ordered IDs for badge numbering
    let usedAssetIDs: Set<String>          // All used IDs (active + committed)
    let cache: CachedImageManager
    let imageSize: CGSize
    let toggleAction: () -> Void

    var isSelected: Bool { activeAssetIDs.contains(asset.id) }
    var isDrafted: Bool { !isSelected && usedAssetIDs.contains(asset.id) }
    var selectionIndex: Int? { activeAssetOrder.firstIndex(of: asset.id) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    PhotoItemView(asset: asset, cache: cache, imageSize: imageSize)
                        .scaledToFill()
                )
                .clipped()
                .opacity((isSelected || isDrafted) ? 0.5 : 1.0)
                .onTapGesture {
                    toggleAction()
                }
                .onAppear {
                    Task { await cache.startCaching(for: [asset], targetSize: imageSize) }
                }

            if let index = selectionIndex {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 24, height: 24)
                    .overlay(Text("\(index + 1)").foregroundColor(.white).font(.caption))
                    .padding(4)
            } else if isDrafted {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "checkmark").foregroundColor(.white).font(.caption))
                    .padding(4)
            } else {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .padding(4)
            }
        }
    }
}

struct CustomPhotoPickerView: View {
        /// Called when the user taps the green checkmark. The parent navigation
        /// controller should handle pushing the drafts overview.
        var onProceed: (() -> Void)? = nil

        @StateObject var photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
        /// Single pushed destination off this view (two navigationDestination(isPresented:)
        /// modifiers at one level collide — same pattern as CameraView.CameraRoute).
        private enum PickerRoute: Hashable {
            case overview
            case draftHistory
        }
        @State private var pickerRoute: PickerRoute?
        @State private var hidePreviouslySelected = false
        @State private var photoAccessLimited = false
        @Environment(\.dismiss) private var dismiss

        @Environment(\.modelContext) private var modelContext
        @Query(filter: #Predicate<Item> { $0.isDraft == true })
        private var allItems: [Item]

        @EnvironmentObject private var uploadManager: UploadManager

        @Environment(\.displayScale) private var displayScale
        private static let itemSpacing = 2.0
        private var imageSize: CGSize {
            return CGSize(width: 100 * min(displayScale, 2), height: 100 * min(displayScale, 2))
        }

        let columns = [
            GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 2)
        ]

        /// Active draft being built right now
        private var activeDraft: Item? {
            guard let id = uploadManager.activeDraftID else { return nil }
            return allItems.first { $0.id == id }
        }

        /// Asset IDs in the active draft — used for grid badges
        private var activeDraftAssetIDs: Set<String> {
            Set(activeDraft?.sourceAssetIdentifiers ?? [])
        }

        /// Committed drafts (not the active one)
        private var committedDrafts: [Item] {
            let activeID = uploadManager.activeDraftID
            return allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty && $0.id != activeID }
        }

        /// Asset IDs already saved into a committed draft — for the "Hide previously selected" toggle.
        /// Deliberately excludes the active (not-yet-committed) draft's selections, since those
        /// should stay visible with their number badge until the user commits the draft.
        private var allUsedAssetIDs: Set<String> {
            Set(committedDrafts.flatMap { $0.sourceAssetIdentifiers })
        }
        
        var body: some View {
            let currentUsedAssetIDs = allUsedAssetIDs

            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.itemSpacing) {
                    if hidePreviouslySelected {
                        ForEach(photoCollection.photoAssets.filter { !currentUsedAssetIDs.contains($0.id) }) { asset in
                            SelectablePhotoGridItem(
                                asset: asset,
                                activeAssetIDs: activeDraftAssetIDs,
                                activeAssetOrder: activeDraft?.sourceAssetIdentifiers ?? [],
                                usedAssetIDs: currentUsedAssetIDs,
                                cache: photoCollection.cache,
                                imageSize: imageSize,
                                toggleAction: { togglePhoto(asset) }
                            )
                        }
                    } else {
                        ForEach(photoCollection.photoAssets) { asset in
                            SelectablePhotoGridItem(
                                asset: asset,
                                activeAssetIDs: activeDraftAssetIDs,
                                activeAssetOrder: activeDraft?.sourceAssetIdentifiers ?? [],
                                usedAssetIDs: currentUsedAssetIDs,
                                cache: photoCollection.cache,
                                imageSize: imageSize,
                                toggleAction: { togglePhoto(asset) }
                            )
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if photoAccessLimited {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                            Text("You've allowed access to only some photos.")
                                .font(.caption)
                            Spacer()
                            Button("Select More") { presentLimitedLibraryPicker() }
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                    }
                    if !photoCollection.photoAssets.isEmpty {
                        Toggle(isOn: $hidePreviouslySelected) {
                            HStack(spacing: 6) {
                                Image(systemName: hidePreviouslySelected ? "eye.slash" : "eye")
                                Text("Hide previously selected")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        }
                        .disabled(currentUsedAssetIDs.isEmpty)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Unified carousel — identical to camera view bottom panel
                let hasContent = activeDraft?.sourceAssetIdentifiers.isEmpty == false
                    || !committedDrafts.isEmpty
                if hasContent {
                    VStack(spacing: 0) {
                        Divider()
                        ActiveDraftCarouselView(
                            cache: photoCollection.cache,
                            onOpenDraftHistory: { pickerRoute = .draftHistory }
                        )
                        .padding(.bottom, 4)
                    }
                    .background(Color(.systemBackground))
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                            Text("Camera")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    let hasActiveDraft = uploadManager.activeDraftID != nil
                        && !(activeDraft?.sourceAssetIdentifiers.isEmpty ?? true)
                    let canProceed = hasActiveDraft || !committedDrafts.isEmpty
                    Button {
                        if hasActiveDraft {
                            uploadManager.commitActiveDraft(modelContext: modelContext)
                        }
                        if let proceed = onProceed {
                            proceed()
                        } else {
                            pickerRoute = .overview
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(canProceed ? .green : .secondary)
                    }
                    .disabled(!canProceed)
                }
            }
            .task {
                guard await PhotoLibrary.checkAuthorization() else {
                    print("Photo library access not authorized for picker")
                    return
                }
                photoAccessLimited = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
                do {
                    try await photoCollection.load()
                } catch {
                    print("Failed to load photos: \(error)")
                }
            }
            .navigationDestination(item: $pickerRoute) { destination in
                switch destination {
                case .overview:
                    BulkListingOverviewView()
                case .draftHistory:
                    // N2: "+" on a draft pops back to THIS picker with that draft
                    // active in the carousel — no nested sheet.
                    DraftHistoryView(photoCollection: photoCollection, onAddPhotos: { pickerRoute = nil })
                }
            }
        }
        
        /// Present the system sheet that lets a limited-access user add more photos
        /// to the app's allowed selection. PhotoCollection observes library changes,
        /// so the grid refreshes automatically once the selection expands.
        private func presentLimitedLibraryPicker() {
            guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
        }

        /// Toggle a photo in/out of the active draft.
        private func togglePhoto(_ asset: PhotoAsset) {
            if activeDraftAssetIDs.contains(asset.id) {
                // Deselect: remove from active draft
                withAnimation {
                    uploadManager.removePhotoFromActiveDraft(assetId: asset.id, modelContext: modelContext)
                }
            } else {
                // Select: add to active draft
                withAnimation {
                    uploadManager.addPhotoToActiveDraft(assetId: asset.id, imageData: nil, modelContext: modelContext)
                }
            }
        }
    }

    // MARK: - Pending selection preview stack (photos not yet committed)
    struct PendingSelectionStackView: View {
        let assets: [PhotoAsset]
        let cache: CachedImageManager
        var body: some View {
            ZStack {
                ForEach(0..<min(3, assets.count), id: \.self) { index in
                    let offset = CGFloat(index) * 5
                    PhotoItemView(asset: assets[index], cache: cache, imageSize: CGSize(width: 120, height: 120))
                        .frame(width: 60, height: 60)
                        .cornerRadius(10)
                        .clipped()
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 2, y: 2)
                        .offset(x: offset, y: -offset)
                        .zIndex(Double(3 - index))
                }
            }
            .frame(width: 76, height: 76)
            .opacity(0.7) // slightly dimmed to indicate uncommitted
        }
    }
    
    
    // MARK: - DropDelegate
    struct PhotoAssetDropDelegate: DropDelegate {
        let item: PhotoAsset
        @Binding var items: [PhotoAsset]
        @Binding var draggedItem: PhotoAsset?
        
        func dropEntered(info: DropInfo) {
            guard let draggedItem = self.draggedItem else { return }
            if draggedItem != item {
                let from = items.firstIndex(of: draggedItem)!
                let to = items.firstIndex(of: item)!
                withAnimation {
                    items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                }
            }
        }
        
        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }
        
        func performDrop(info: DropInfo) -> Bool {
            self.draggedItem = nil
            return true
        }
    }
    
    // MARK: - DraftPhotoDropDelegate
    struct DraftPhotoDropDelegate: DropDelegate {
        let targetAssetId: String
        let draft: Item
        @Binding var draggedCompositeId: String?
        let modelContext: ModelContext
        let drafts: [Item]
        let uploadManager: UploadManager

        func dropEntered(info: DropInfo) {
            guard let dragged = draggedCompositeId else { return }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return }
            let sourceDraftId = parts[0]
            let assetId = parts[1]

            if sourceDraftId == draft.id.uuidString {
                if assetId != targetAssetId {
                    if let from = draft.sourceAssetIdentifiers.firstIndex(of: assetId),
                       let to = draft.sourceAssetIdentifiers.firstIndex(of: targetAssetId) {
                        withAnimation {
                            draft.movePhoto(from: from, to: to)
                        }
                    }
                }
            } else {
                if let sourceDraft = drafts.first(where: { $0.id.uuidString == sourceDraftId }) {
                    let toIdx = draft.sourceAssetIdentifiers.firstIndex(of: targetAssetId) ?? draft.sourceAssetIdentifiers.count
                    withAnimation {
                        let removed = sourceDraft.removePhoto(assetId: assetId)
                        draft.insertPhoto(assetId: assetId, data: removed.data, at: toIdx, firebasePhotoPath: removed.firebasePhotoPath)
                        draggedCompositeId = "\(draft.id.uuidString)|\(assetId)"
                    }
                }
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            for d in drafts {
                if d.sourceAssetIdentifiers.isEmpty {
                    uploadManager.deleteDraftLocallyAndCloud(draft: d, modelContext: modelContext)
                }
            }
            draggedCompositeId = nil
            return true
        }
    }

    // MARK: - DraftSectionDropDelegate
    struct DraftSectionDropDelegate: DropDelegate {
        let draft: Item
        @Binding var draggedCompositeId: String?
        let modelContext: ModelContext
        let allDrafts: [Item]
        let uploadManager: UploadManager

        func dropEntered(info: DropInfo) {
            guard let dragged = draggedCompositeId else { return }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return }
            let sourceDraftId = parts[0], assetId = parts[1]
            
            if sourceDraftId != draft.id.uuidString {
                if let sourceDraft = allDrafts.first(where: { $0.id.uuidString == sourceDraftId }) {
                    withAnimation {
                        let removed = sourceDraft.removePhoto(assetId: assetId)
                        draft.insertPhoto(assetId: assetId, data: removed.data, at: draft.sourceAssetIdentifiers.count, firebasePhotoPath: removed.firebasePhotoPath)
                        draggedCompositeId = "\(draft.id.uuidString)|\(assetId)"
                    }
                }
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard let dragged = draggedCompositeId else { return DropProposal(operation: .cancel) }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return DropProposal(operation: .cancel) }
            return parts[0] != draft.id.uuidString
                ? DropProposal(operation: .move)
                : DropProposal(operation: .cancel)
        }

        func performDrop(info: DropInfo) -> Bool {
            for d in allDrafts {
                if d.sourceAssetIdentifiers.isEmpty {
                    uploadManager.deleteDraftLocallyAndCloud(draft: d, modelContext: modelContext)
                }
            }
            draggedCompositeId = nil
            return true
        }
    }

    // MARK: - CancelDropDelegate
    struct CancelDropDelegate: DropDelegate {
        @Binding var draggedCompositeId: String?
        let modelContext: ModelContext
        let drafts: [Item]
        
        let originalDraftID: UUID?
        let originalAssetID: String?
        let originalIndex: Int?
        let originalPhotoData: Data?

        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            guard let dragged = draggedCompositeId else { return false }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return false }
            let currentDraftId = parts[0], assetId = parts[1]
            
            if let origID = originalDraftID, let origAsset = originalAssetID, let origIdx = originalIndex {
                if currentDraftId != origID.uuidString || drafts.first(where: { $0.id == origID })?.sourceAssetIdentifiers.firstIndex(of: assetId) != origIdx {
                    withAnimation {
                        if let currentDraft = drafts.first(where: { $0.id.uuidString == currentDraftId }) {
                            let removed = currentDraft.removePhoto(assetId: assetId)
                            if let origDraft = drafts.first(where: { $0.id == origID }) {
                                origDraft.insertPhoto(assetId: origAsset, data: removed.data ?? originalPhotoData, at: origIdx, firebasePhotoPath: removed.firebasePhotoPath)
                            }
                        }
                    }
                    try? modelContext.save()
                }
            }
            
            draggedCompositeId = nil
            return true
        }
    }

    // MARK: - DraftHistoryView
    /// Draft history: every committed draft with photos, titles, selection mode, and a
    /// per-draft "+" that reopens the draft in the photo picker. Pushed full-screen on
    /// the host's NavigationStack (spec N1) — until Phase 4 this was a sheet stacked
    /// over the live camera, with a further nested picker sheet behind "+".
    struct DraftHistoryView: View {
        @Environment(\.dismiss) private var dismiss
        @Query(filter: #Predicate<Item> { $0.isDraft == true })
        private var allItems: [Item]
        @ObservedObject var photoCollection: PhotoCollection
        /// Host navigation for the per-draft "+": return to the picker AFTER this view
        /// has made that draft the active one (camera swaps its route to .picker;
        /// the picker pops back to itself).
        let onAddPhotos: () -> Void
        @Environment(\.modelContext) private var modelContext
        @EnvironmentObject private var uploadManager: UploadManager

        @State private var isSelectionMode = false
        @State private var selectedPhotos = Set<String>()
        @State private var showingDeleteConfirm = false
        @State private var draggedCompositeId: String?
        @State private var isTrashTargeted = false
        @State private var showingDraftBulkEdit = false
        @FocusState private var focusedDraftID: UUID?

        private var fullySelectedDrafts: [Item] {
            drafts.filter { draft in
                let ids = Set(draft.sourceAssetIdentifiers.map { "\(draft.id.uuidString)|\($0)" })
                return !ids.isEmpty && ids.isSubset(of: selectedPhotos)
            }
        }

        // Track drag original state for cancel/restoration
        @State private var originalDraftID: UUID?
        @State private var originalAssetID: String?
        @State private var originalIndex: Int?
        @State private var originalPhotoData: Data?

        var drafts: [Item] {
            // See UploadManager.deletedDraftIDs — deletion is deferred a tick, so this
            // filter is what actually drops the row from the grid immediately.
            // publishedAt == nil excludes items kept alive only for a queued cross-post job —
            // this modal's multi-select delete (deleteSelectedItems, below) is exactly the path
            // that previously let a bulk "delete selected drafts" hard-delete an already-live
            // listing (see UploadManager.deleteDraftLocallyAndCloud's guard).
            allItems.filter {
                $0.isDraft && !$0.pendingPublish && !$0.sourceAssetIdentifiers.isEmpty && !uploadManager.deletedDraftIDs.contains($0.id) && $0.publishedAt == nil
            }
        }

        var body: some View {
                Group {
                    if drafts.isEmpty {
                        VStack {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                                .padding()
                            Text("No active drafts found.")
                                .foregroundColor(.gray)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 20) {
                                ForEach(drafts) { draft in
                                    VStack(alignment: .leading, spacing: 8) {
                                        let draftCompositeIDs = draft.sourceAssetIdentifiers.map { "\(draft.id.uuidString)|\($0)" }
                                        let selectedCount = draftCompositeIDs.filter { selectedPhotos.contains($0) }.count
                                        let isFullySelected = selectedCount > 0 && selectedCount == draftCompositeIDs.count
                                        let isPartiallySelected = selectedCount > 0 && selectedCount < draftCompositeIDs.count

                                        HStack(spacing: 8) {
                                            if isSelectionMode {
                                                Image(systemName: isFullySelected ? "checkmark.circle.fill" : (isPartiallySelected ? "minus.circle.fill" : "circle"))
                                                    .foregroundColor(selectedCount > 0 ? .blue : .gray)
                                                    .font(.title3)
                                                    .onTapGesture {
                                                        if isFullySelected {
                                                            for id in draftCompositeIDs { selectedPhotos.remove(id) }
                                                        } else {
                                                            for id in draftCompositeIDs { selectedPhotos.insert(id) }
                                                        }
                                                    }
                                            }
                                            
                                            let hasUserTitle = draft.userEditedTitle != nil
                                            if isSelectionMode {
                                                // In selection mode the title is read-only — tapping it toggles
                                                // the draft's selection instead of focusing the field, so picking
                                                // drafts to edit/delete isn't fighting the keyboard.
                                                // visionTitle last: display-only fallback so unpicked suggestions
                                                // still label the row, but never outrank a real (AI) title.
                                                let title = draft.userEditedTitle ?? draft.aiSuggestedTitle ?? draft.visionTitle
                                                Text(title?.isEmpty == false ? title! : "Untitled draft")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(hasUserTitle ? .primary : .secondary)
                                                    .lineLimit(1)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .contentShape(Rectangle())
                                                    .onTapGesture {
                                                        if isFullySelected {
                                                            for id in draftCompositeIDs { selectedPhotos.remove(id) }
                                                        } else {
                                                            for id in draftCompositeIDs { selectedPhotos.insert(id) }
                                                        }
                                                    }
                                            } else {
                                                DraftHistoryTitleField(draft: draft, focusedDraftID: $focusedDraftID)
                                            }
                                        }
                                        .padding(.horizontal)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 12) {
                                                ForEach(draft.sourceAssetIdentifiers, id: \.self) { assetId in
                                                    let compositeId = "\(draft.id.uuidString)|\(assetId)"
                                                    let asset = PhotoAsset(identifier: assetId)

                                                    ZStack(alignment: .topTrailing) {
                                                        Group {
                                                            if let uiImage = draft.thumbnail(for: assetId) {
                                                                Image(uiImage: uiImage)
                                                                    .resizable()
                                                                    .scaledToFill()
                                                            } else {
                                                                PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: CGSize(width: 80, height: 80))
                                                            }
                                                        }
                                                        .frame(width: 80, height: 80)
                                                        .cornerRadius(8)
                                                        .clipped()
                                                        .onDrag {
                                                            if !isSelectionMode {
                                                                draggedCompositeId = compositeId
                                                                originalDraftID = draft.id
                                                                originalAssetID = assetId
                                                                originalIndex = draft.sourceAssetIdentifiers.firstIndex(of: assetId)
                                                                if let idx = originalIndex, idx < draft.photosData.count {
                                                                    originalPhotoData = draft.photosData[idx]
                                                                } else {
                                                                    originalPhotoData = nil
                                                                }
                                                                return NSItemProvider(object: compositeId as NSString)
                                                            }
                                                            return NSItemProvider()
                                                        }
                                                        .onDrop(of: [.text], delegate: DraftPhotoDropDelegate(
                                                            targetAssetId: assetId,
                                                            draft: draft,
                                                            draggedCompositeId: $draggedCompositeId,
                                                            modelContext: modelContext,
                                                            drafts: drafts,
                                                            uploadManager: uploadManager
                                                        ))

                                                        if isSelectionMode {
                                                            Image(systemName: selectedPhotos.contains(compositeId) ? "checkmark.circle.fill" : "circle")
                                                                .foregroundColor(selectedPhotos.contains(compositeId) ? .blue : .white)
                                                                .background(Circle().fill(Color.white.opacity(0.5)))
                                                                .padding(4)
                                                        }
                                                    }
                                                    .onTapGesture {
                                                        if isSelectionMode {
                                                            if selectedPhotos.contains(compositeId) {
                                                                selectedPhotos.remove(compositeId)
                                                            } else {
                                                                selectedPhotos.insert(compositeId)
                                                            }
                                                        }
                                                    }
                                                }

                                                // "+" tile — always the last item in the scroll
                                                if !isSelectionMode {
                                                    Button {
                                                        // Keep any in-progress active draft safe by
                                                        // committing it, then reopen THIS draft as the
                                                        // active one — the host navigates back to the
                                                        // picker with it in the carousel (spec N2).
                                                        if uploadManager.activeDraftID != nil {
                                                            uploadManager.commitActiveDraft(modelContext: modelContext)
                                                        }
                                                        uploadManager.activeDraftID = draft.id
                                                        onAddPhotos()
                                                    } label: {
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
                                                }
                                            }
                                            .padding(.horizontal)
                                        }

                                        Divider()
                                            .padding(.horizontal)
                                    }
                                    .onDrop(of: [.text], delegate: DraftSectionDropDelegate(
                                        draft: draft,
                                        draggedCompositeId: $draggedCompositeId,
                                        modelContext: modelContext,
                                        allDrafts: drafts,
                                        uploadManager: uploadManager
                                    ))
                                }
                            }
                            .padding(.top)
                            Spacer(minLength: 150) // Drag to cancel zone
                        }
                        .onDrop(of: [.text], delegate: CancelDropDelegate(
                            draggedCompositeId: $draggedCompositeId,
                            modelContext: modelContext,
                            drafts: drafts,
                            originalDraftID: originalDraftID,
                            originalAssetID: originalAssetID,
                            originalIndex: originalIndex,
                            originalPhotoData: originalPhotoData
                        ))
                    }
                }
                .overlay(alignment: .bottom) {
                    if draggedCompositeId != nil {
                        trashZone
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: draggedCompositeId != nil)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Text("Drafts")
                                .font(.headline)
                            if uploadManager.isUploadingPhotos {
                                HStack(spacing: 3) {
                                    Image(systemName: "icloud.and.arrow.up")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ProgressView()
                                        .scaleEffect(0.65)
                                        .frame(width: 14, height: 14)
                                }
                            } else if !drafts.isEmpty {
                                Image(systemName: "checkmark.icloud.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        if isSelectionMode {
                            Button("Cancel") {
                                isSelectionMode = false
                                selectedPhotos.removeAll()
                            }
                        } else {
                            Button("Select") {
                                isSelectionMode = true
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSelectionMode {
                            HStack(spacing: 16) {
                                if !fullySelectedDrafts.isEmpty {
                                    Button("Bulk Edit") { showingDraftBulkEdit = true }
                                        .foregroundStyle(Color.accentColor)
                                }
                                Button("Delete") { showingDeleteConfirm = true }
                                    .foregroundColor(.red)
                                    .disabled(selectedPhotos.isEmpty)
                            }
                        } else {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Button { moveFocusByDraft(-1) } label: { Image(systemName: "chevron.up") }
                            .disabled(focusedDraftID == nil || drafts.first?.id == focusedDraftID)
                        Button { moveFocusByDraft(1) } label: { Image(systemName: "chevron.down") }
                            .disabled(focusedDraftID == nil || drafts.last?.id == focusedDraftID)
                        Spacer()
                        Button("Done") { focusedDraftID = nil }
                    }
                }
                .onChange(of: focusedDraftID) { _, _ in
                    try? modelContext.save()
                }
                .alert("Delete Selected?", isPresented: $showingDeleteConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        deleteSelectedItems()
                    }
                } message: {
                    Text("Are you sure you want to delete the selected items?")
                }
                .sheet(isPresented: $showingDraftBulkEdit) {
                    DraftBulkEditSheet(items: fullySelectedDrafts) {
                        isSelectionMode = false
                        selectedPhotos.removeAll()
                    }
                    .environmentObject(uploadManager)
                }
        }


        private func moveFocusByDraft(_ delta: Int) {
            guard let current = focusedDraftID,
                  let idx = drafts.firstIndex(where: { $0.id == current }) else { return }
            let next = idx + delta
            guard next >= 0 && next < drafts.count else { return }
            focusedDraftID = drafts[next].id
        }

        private func deleteSelectedItems() {
            for draft in allItems {
                let draftCompositeIDs = draft.sourceAssetIdentifiers.map { "\(draft.id.uuidString)|\($0)" }
                let selectedCount = draftCompositeIDs.filter { selectedPhotos.contains($0) }.count

                if selectedCount > 0 {
                    if selectedCount == draftCompositeIDs.count {
                        uploadManager.deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
                    } else {
                        var toRemove: [String] = []
                        for assetId in draft.sourceAssetIdentifiers {
                            if selectedPhotos.contains("\(draft.id.uuidString)|\(assetId)") {
                                toRemove.append(assetId)
                            }
                        }
                        for assetId in toRemove {
                            let removed = draft.removePhoto(assetId: assetId)
                            if let path = removed.firebasePhotoPath {
                                deletePhotoFromStorage(path: path)
                            }
                        }
                    }
                }
            }

            try? modelContext.save()
            isSelectionMode = false
            selectedPhotos.removeAll()
        }

        @ViewBuilder
        private var trashZone: some View {
            HStack {
                Spacer()
                Image(systemName: isTrashTargeted ? "trash.circle.fill" : "trash.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(.red)
                    .scaleEffect(isTrashTargeted ? 1.15 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTrashTargeted)
                    .padding(.bottom, 16)
                Spacer()
            }
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .onDrop(of: [.text], isTargeted: $isTrashTargeted) { _ in
                deletePhoto(compositeId: draggedCompositeId)
            }
        }

        @discardableResult
        private func deletePhoto(compositeId: String?) -> Bool {
            guard let dragged = compositeId else { return false }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return false }
            let sourceDraftId = parts[0], assetId = parts[1]
            if let sourceDraft = allItems.first(where: { $0.id.uuidString == sourceDraftId }) {
                let removed = sourceDraft.removePhoto(assetId: assetId)
                if sourceDraft.sourceAssetIdentifiers.isEmpty {
                    // Whole draft is now empty — deleteDraftLocallyAndCloud wipes its entire
                    // Storage folder (including this photo), so no separate delete needed.
                    uploadManager.deleteDraftLocallyAndCloud(draft: sourceDraft, modelContext: modelContext)
                } else if let path = removed.firebasePhotoPath {
                    deletePhotoFromStorage(path: path)
                }
                try? modelContext.save()
            }
            draggedCompositeId = nil
            return true
        }

        /// Permanently deletes one already-uploaded photo from Storage (not a whole-draft
        /// wipe). Best-effort background call — failures surface via the same
        /// `cleanupError` toast as `deleteDraftLocallyAndCloud`.
        private func deletePhotoFromStorage(path: String) {
            guard let userId = Auth.auth().currentUser?.uid else { return }
            Task {
                do {
                    try await StorageService.shared.deletePhoto(path: path, userId: userId)
                } catch {
                    print("[DraftHistoryView] Failed to delete photo at \(path): \(error)")
                    uploadManager.cleanupError = "Couldn't fully delete a removed photo. It may still be using storage."
                }
            }
        }
    }

struct DraftHistoryTitleField: View {
    let draft: Item
    var focusedDraftID: FocusState<UUID?>.Binding
    @State private var localTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Add title…", text: $localTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(draft.userEditedTitle != nil ? .primary : .secondary)
                .focused(focusedDraftID, equals: draft.id)
                .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                    guard let tf = notification.object as? UITextField else { return }
                    if focusedDraftID.wrappedValue == draft.id {
                        DispatchQueue.main.async { tf.selectAll(nil) }
                    }
                }

            if let vision = draft.visionTitle, !vision.isEmpty,
               draft.processedAt == nil, localTitle.isEmpty {
                VisionTitleSuggestionChip(suggestion: vision) {
                    localTitle = vision
                    draft.userEditedTitle = vision
                    draft.visionTitleAccepted = true
                }
            }
        }
        .onAppear {
            // Vision output deliberately NOT seeded — offered via the chip instead
            // (prefilled vision text used to ride along into "user" titles).
            localTitle = draft.userEditedTitle ?? draft.aiSuggestedTitle ?? ""
        }
        .onChange(of: focusedDraftID.wrappedValue) { oldFocus, newFocus in
            if oldFocus == draft.id && newFocus != draft.id {
                commitLocalTitle()
            }
        }
        .onDisappear {
            commitLocalTitle()
        }
    }

    private func commitLocalTitle() {
        // onDisappear-driven commit can race a delete of this draft; writing to a
        // detached SwiftData object traps.
        guard !Item.deletedIDs.contains(draft.id) else { return }
        let v = localTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = draft.aiSuggestedTitle ?? ""
        if v.isEmpty {
            // User cleared the field — remove user title.
            if draft.userEditedTitle != nil { draft.userEditedTitle = nil }
        } else if v != placeholder || draft.userEditedTitle != nil {
            // Commit if it differs from the placeholder, or if there was already a user title.
            // If v == placeholder and userEditedTitle == nil, the user just tapped and left —
            // don't turn an untouched AI suggestion into a "user edited" title.
            if draft.userEditedTitle != v {
                draft.userEditedTitle = v
            }
        }
    }
}
// eBay & Mercari: 80 chars · Facebook: 99 · Etsy: 140
struct TitleCharCountView: View {
    let count: Int

    private var color: Color {
        if count > 140 { return Color(red: 0.75, green: 0.0, blue: 0.0) }
        if count > 99  { return .red }
        if count > 80  { return .orange }
        return .secondary
    }

    private var message: String? {
        if count > 140 { return "Truncated on all platforms" }
        if count > 99  { return "Only shows fully on Etsy" }
        if count > 80  { return "Facebook & Etsy only" }
        return nil
    }

    var body: some View {
        // Only surface the counter once the title is long enough to matter (>= 70 chars).
        // Below that it renders nothing and takes no vertical space.
        if count >= 70 {
            HStack(spacing: 4) {
                if let msg = message {
                    Text(msg).font(.caption2)
                }
                Spacer()
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(count > 80 ? .semibold : .regular))
            }
            .foregroundStyle(color)
            .animation(.easeInOut(duration: 0.2), value: count)
        }
    }
}

// MARK: - VisionTitleSuggestionChip
/// On-device Vision's title guess, offered as an explicit suggestion instead of
/// prefilled editable text. Prefilling polluted the "user title" hint sent to Gemini
/// (any edit dragged the vision text along as if the user wrote it) and even leaked
/// into `userEditedTitle` on scroll-away. Tapping the chip is a deliberate acceptance:
/// it fills the field and marks `visionTitleAccepted` for model-quality tracking.
/// Shown only pre-AI (`processedAt == nil`) while the title field is empty; an
/// unaccepted suggestion is simply dropped at process time.
struct VisionTitleSuggestionChip: View {
    let suggestion: String
    let onAccept: () -> Void

    var body: some View {
        Button(action: onAccept) {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                Text("Use: \u{201C}\(suggestion)\u{201D}")
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DraftRow (redesigned)
struct DraftRow: View, Equatable {
    let item: Item
    var focusedField: FocusState<DraftFocusField?>.Binding
    let cache: CachedImageManager
    var isSelectable: Bool = false
    var isSelected: Bool = false
    var onToggle: (() -> Void)? = nil
    /// Called when the description sheet — opened via arrow-key navigation landing on this
    /// row's description slot, not a direct tap — is dismissed. Lets the keyboard toolbar's
    /// up/down arrows continue on to the next field instead of stopping dead at description,
    /// which (unlike title/price) isn't a real focusable text field.
    var onDescriptionAutoAdvance: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var priceText: String = ""
    @State private var titleText: String = ""
    @State private var showDescriptionEditor = false
    @State private var descriptionEditorOpenedViaFocus = false

    // BulkListingOverviewView.body re-evaluates on every uploadManager @Published change
    // (isProcessing/processProgress are read directly there) — which fires repeatedly while
    // background photo uploads are still finishing, i.e. exactly while the user might be
    // typing on this screen. That reconstructs every row with a fresh `onToggle` closure,
    // and SwiftUI's default diffing treats closures as always "changed," so every row's body
    // re-evaluates on every tick regardless of whether it has anything to do with that row.
    // Equatable + `.equatable()` at the call site lets SwiftUI skip re-evaluating a row whose
    // actual rendered inputs haven't changed. Compares every `item` field this row reads —
    // add to this list if the body starts reading a new one.
    static func == (lhs: DraftRow, rhs: DraftRow) -> Bool {
        lhs.isSelectable == rhs.isSelectable &&
        lhs.isSelected == rhs.isSelected &&
        lhs.focusedField.wrappedValue == rhs.focusedField.wrappedValue &&
        lhs.item.sourceAssetIdentifiers == rhs.item.sourceAssetIdentifiers &&
        lhs.item.userEditedTitle == rhs.item.userEditedTitle &&
        lhs.item.userEditedPrice == rhs.item.userEditedPrice &&
        lhs.item.userEditedDescription == rhs.item.userEditedDescription &&
        lhs.item.aiSuggestedDescription == rhs.item.aiSuggestedDescription &&
        lhs.item.originalUserTitleBeforeAI == rhs.item.originalUserTitleBeforeAI &&
        lhs.item.originalUserDescriptionBeforeAI == rhs.item.originalUserDescriptionBeforeAI &&
        lhs.item.processedAt == rhs.item.processedAt &&
        lhs.item.visionTitle == rhs.item.visionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Top row: photo + title/price + edit button ─────────────────
            HStack(alignment: .top, spacing: 14) {
                if isSelectable {
                    Button(action: { onToggle?() }) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                // Photo thumbnail
                Group {
                    if let assetId = item.sourceAssetIdentifiers.first {
                        Group {
                            if let uiImage = item.thumbnail(for: assetId) {
                                Image(uiImage: uiImage).resizable().scaledToFill()
                            } else {
                                PhotoItemView(asset: PhotoAsset(identifier: assetId), cache: cache, imageSize: CGSize(width: 160, height: 160))
                            }
                        }
                    } else {
                        Color(.systemGray5)
                            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .clipped()

                // Title + price (constrained to photo height)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Add title…", text: $titleText, axis: .vertical)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(item.userEditedTitle != nil ? .primary : .secondary)
                        .lineLimit(2)
                        .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))
                        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                            // Scoped to this row's own title field — the original version of
                            // this fired unconditionally, so every draft row in the list
                            // subscribed to every UITextField gaining focus anywhere in the
                            // view (any row's title *or* price field), each dispatching a
                            // select-all. With many drafts on screen that's O(rows) redundant
                            // work on every single focus change — a real source of the
                            // lagginess reported when editing. Matches the guard
                            // `DraftHistoryTitleField` already uses correctly.
                            guard focusedField.wrappedValue == DraftFocusField(itemID: item.id, field: .title),
                                  let tf = notification.object as? UITextField else { return }
                            DispatchQueue.main.async { tf.selectAll(nil) }
                        }

                    TitleCharCountView(count: titleText.count)

                    if let vision = item.visionTitle, !vision.isEmpty,
                       item.processedAt == nil, titleText.isEmpty {
                        VisionTitleSuggestionChip(suggestion: vision) {
                            titleText = vision
                            item.userEditedTitle = vision
                            item.visionTitleAccepted = true
                            try? modelContext.save()
                        }
                    }

                    HStack(spacing: 3) {
                        Text("$").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Price", text: $priceText)
                            .font(.subheadline)
                            .keyboardType(.decimalPad)
                            .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .price))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── Description (full width) ────────────────────────────────────
            let descText = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            Button { showDescriptionEditor = true } label: {
                Text(descText.isEmpty ? "Add description…" : descText)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundStyle(descText.isEmpty ? Color(.placeholderText) : (item.userEditedDescription != nil ? .primary : .secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(item.originalUserDescriptionBeforeAI != nil ? Color.purple.opacity(0.08) : Color(.systemGray6))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(item.originalUserDescriptionBeforeAI != nil ? Color.purple.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDescriptionEditor) {
                DescriptionEditorSheet(
                    initialText: descText,
                    onSave: { newText in
                        item.userEditedDescription = newText.isEmpty ? nil : newText
                    },
                    hasAIPurple: item.originalUserDescriptionBeforeAI != nil
                )
            }


            // ── AI badge / undo row ─────────────────────────────────────────
            let hasAIEdits = item.originalUserTitleBeforeAI != nil || item.originalUserDescriptionBeforeAI != nil
            if hasAIEdits || item.processedAt != nil {
                HStack(spacing: 0) {
                    if item.processedAt != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                            Text(hasAIEdits ? "AI edited" : "AI identified")
                                .font(.caption2).foregroundStyle(.purple.opacity(0.8))
                        }
                    }
                    Spacer()
                    if hasAIEdits {
                        Button {
                            withAnimation {
                                if let origTitle = item.originalUserTitleBeforeAI {
                                    // Drive the visible field on the tap frame (same optimistic
                                    // treatment as ResultDraftRow.undoAITitle) — the .onChange
                                    // round-trip alone is what made undo feel unresponsive.
                                    titleText = origTitle
                                    item.userEditedTitle = origTitle
                                    item.originalUserTitleBeforeAI = nil
                                }
                                if let origDesc = item.originalUserDescriptionBeforeAI {
                                    item.userEditedDescription = origDesc
                                    item.originalUserDescriptionBeforeAI = nil
                                }
                                item.aiUndoCount += 1
                            }
                            Task { @MainActor in
                                guard !Item.deletedIDs.contains(item.id) else { return }
                                try? modelContext.save()
                            }
                        } label: {
                            Text("Undo").font(.caption2.weight(.medium)).foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            // Vision output deliberately NOT seeded here — prefilled vision text used to be
            // committed as `userEditedTitle` by saveLocalStateToModel the moment the row
            // scrolled away, and dragged into any user edit. It's offered via the chip instead.
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            if let p = item.userEditedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
            // When focus changes from this item's title/price to somewhere else or nil, save
            if oldFocus?.itemID == item.id && newFocus?.itemID != item.id {
                saveLocalStateToModel()
            }
            // Description isn't a real focusable field (it's a button that opens a sheet),
            // so the keyboard arrows can't land real focus there. Landing "on" it via arrow
            // navigation instead opens the sheet directly, so up/down keeps working through it.
            if newFocus == DraftFocusField(itemID: item.id, field: .description) {
                descriptionEditorOpenedViaFocus = true
                showDescriptionEditor = true
            }
        }
        .onChange(of: item.userEditedTitle) { _, newVal in
            // Sync local title state when the model is updated externally (e.g. bulk edit)
            titleText = newVal ?? item.aiSuggestedTitle ?? ""
        }
        .onChange(of: item.userEditedPrice) { _, newVal in
            // Sync local price state when the model is updated externally (e.g. bulk edit)
            if let p = newVal {
                priceText = String(format: "%.2f", p)
            } else {
                priceText = ""
            }
        }
        .onChange(of: showDescriptionEditor) { _, isShowing in
            // Fires whether the sheet was saved or swiped away — either way, continue the
            // arrow-key flow onward once the user's done with the description.
            if !isShowing && descriptionEditorOpenedViaFocus {
                descriptionEditorOpenedViaFocus = false
                onDescriptionAutoAdvance?()
            }
        }
        .onDisappear {
            saveLocalStateToModel()
        }
    }

    private func saveLocalStateToModel() {
        // onDisappear also fires when the row vanishes because the draft was deleted —
        // touching attributes on a detached SwiftData object traps.
        guard !Item.deletedIDs.contains(item.id) else { return }
        let v = String(titleText.prefix(140))
        if item.userEditedTitle != (v.isEmpty ? nil : v) {
            item.userEditedTitle = v.isEmpty ? nil : v
        }

        let cleaned = priceText.filter { $0.isNumber || $0 == "." }
        let newPrice = cleaned.isEmpty ? nil : Double(cleaned)
        if item.userEditedPrice != newPrice {
            item.userEditedPrice = newPrice
        }
    }
}

// MARK: - DraftEditSheet (full listing editor)
struct DraftEditSheet: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var cache = CachedImageManager()
    @State private var title: String = ""
    @State private var priceText: String = ""
    @State private var description: String = ""
    @State private var personalNote: String = ""
    @State private var buyerPaysShipping: Bool = true
    @State private var handlingFee: String = ""
    @State private var estimatedDays: String = ""
    @State private var selectedCondition: ItemCondition = .good
    @State private var tagsText: String = ""

    @State private var showPhotoEditModal = false
    @State private var selectedItems: [PhotosPickerItem] = []

    // Shipping & Dimensions state
    @State private var weightText: String = ""
    @State private var lengthText: String = ""
    @State private var widthText: String = ""
    @State private var heightText: String = ""

    @State private var showTemplatePicker = false
    @State private var isApplyingTemplate = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Photos")
                                .font(.headline)
                            Spacer()
                            if !item.sourceAssetIdentifiers.isEmpty {
                                Button {
                                    showPhotoEditModal = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                            }
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(item.sourceAssetIdentifiers, id: \.self) { assetId in
                                    ZStack(alignment: .topTrailing) {
                                        Group {
                                            if let uiImage = item.thumbnail(for: assetId) {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .scaledToFill()
                                            } else {
                                                PhotoItemView(
                                                    asset: PhotoAsset(identifier: assetId),
                                                    cache: cache,
                                                    imageSize: CGSize(width: 160, height: 160)
                                                )
                                            }
                                        }
                                        .frame(width: 80, height: 80)
                                        .cornerRadius(8)
                                        .clipped()
                                    }
                                }
                                
                                PhotosPicker(selection: $selectedItems, matching: .images) {
                                        VStack {
                                            Image(systemName: "plus.circle")
                                                .font(.title2)
                                            Text("Add Photo")
                                                .font(.caption2)
                                        }
                                        .foregroundColor(.accentColor)
                                        .frame(width: 80, height: 80)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(8)
                                    }
                                    .onChange(of: selectedItems) { _, newItems in
                                        Task {
                                            for phItem in newItems {
                                                if let data = try? await phItem.loadTransferable(type: Data.self) {
                                                    let assetId = UUID().uuidString
                                                    item.insertPhoto(assetId: assetId, data: data, at: item.sourceAssetIdentifiers.count)
                                                }
                                            }
                                            selectedItems = []
                                            try? modelContext.save()
                                        }
                                    }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Title & Price") {
                    TextField("Title", text: $title)
                        .font(.body.weight(.medium))
                        .onChange(of: title) { _, v in
                            if v.count > 140 { title = String(v.prefix(140)) }
                        }
                    TitleCharCountView(count: title.count)
                    HStack {
                        Text("$")
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Description") {
                    TextEditor(text: $description)
                        .frame(minHeight: 80)
                }

                Section("Condition") {
                    Picker("Condition", selection: $selectedCondition) {
                        ForEach(ItemCondition.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                }

                Section("Tags") {
                    TextField("e.g. photocard, kpop, sealed", text: $tagsText)
                }

                Section("Note (hidden from buyer)") {
                    TextField("e.g. stored in basement", text: $personalNote)
                }

                Section("Shipping & Dimensions") {
                    Toggle("Buyer pays shipping", isOn: $buyerPaysShipping)
                    if !buyerPaysShipping {
                        HStack {
                            Text("Handling fee")
                            Spacer()
                            Text("$")
                            TextField("0.00", text: $handlingFee)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                    HStack {
                        Text("Est. shipping days")
                        Spacer()
                        TextField("3", text: $estimatedDays)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    
                    HStack {
                        Text("Weight (lbs)")
                        Spacer()
                        TextField("lbs", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dimensions (inches)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 12) {
                            HStack {
                                Text("L:")
                                TextField("Length", text: $lengthText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                            }
                            HStack {
                                Text("W:")
                                TextField("Width", text: $widthText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                            }
                            HStack {
                                Text("H:")
                                TextField("Height", text: $heightText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Edit Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showTemplatePicker = true
                    } label: {
                        Label("Templates", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveToDraft()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showTemplatePicker) {
                TemplatePickerSheet { template in
                    applyTemplateToDraft(template)
                }
            }
            .fullScreenCover(isPresented: $showPhotoEditModal) {
                DraftPhotoEditModal(item: item)
            }
            .onAppear { loadFromDraft() }
        }
    }


    private func applyTemplateToDraft(_ template: ListingTemplate) {
        if let t = template.title, !t.isEmpty { title = t }
        if let d = template.customDescription, !d.isEmpty { description = d }
        if let c = template.condition, let cond = ItemCondition(rawValue: c) { selectedCondition = cond }
        if let free = template.isFreeShipping { buyerPaysShipping = !free }
        if let w = template.weightLbs { weightText = String(format: "%.2f", w) }
        if let dims = template.packageDimensions {
            lengthText = String(format: "%.2f", dims.lengthIn)
            widthText = String(format: "%.2f", dims.widthIn)
            heightText = String(format: "%.2f", dims.heightIn)
        }
        guard !template.photoPaths.isEmpty else { return }
        isApplyingTemplate = true
        Task {
            for path in template.photoPaths {
                if let data = try? await StorageService.shared.downloadImageData(path: path),
                   let img = UIImage(data: data) {
                    let fakeId = "tpl_\(UUID().uuidString)"
                    item.insertPhoto(assetId: fakeId, data: img.jpegData(compressionQuality: 0.85), at: item.sourceAssetIdentifiers.count)
                    try? modelContext.save()
                }
            }
            isApplyingTemplate = false
        }
    }

    private func loadFromDraft() {
        title = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
        if let p = item.userEditedPrice {
            priceText = String(format: "%.2f", p)
        }
        description = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
        personalNote = item.personalNote ?? ""
        if let c = item.condition, let parsed = ItemCondition(rawValue: c) {
            selectedCondition = parsed
        } else {
            selectedCondition = .good
        }
        buyerPaysShipping = item.buyerPaysShipping
        handlingFee = item.handlingFee > 0 ? String(format: "%.2f", item.handlingFee) : ""
        estimatedDays = "\(item.estimatedShippingDays)"
        tagsText = item.tags.joined(separator: ", ")
        
        // Dimensions & Weight
        if let w = item.weightLbs { weightText = String(format: "%.2f", w) } else { weightText = "" }
        if let l = item.lengthIn { lengthText = String(format: "%.2f", l) } else { lengthText = "" }
        if let w = item.widthIn { widthText = String(format: "%.2f", w) } else { widthText = "" }
        if let h = item.heightIn { heightText = String(format: "%.2f", h) } else { heightText = "" }
    }

    private func saveToDraft() {
        // Editing an AI-changed title/description here counts as taking ownership,
        // same as inline edits in ResultDraftRow: a real change retires the AI diff
        // (Review & Publish then shows a normal field, not the word-diff).
        if item.originalUserTitleBeforeAI != nil,
           title != (item.userEditedTitle ?? item.aiSuggestedTitle ?? "") {
            item.originalUserTitleBeforeAI = nil
        }
        if item.originalUserDescriptionBeforeAI != nil,
           description != (item.userEditedDescription ?? item.aiSuggestedDescription ?? "") {
            item.originalUserDescriptionBeforeAI = nil
        }
        item.userEditedTitle = title.isEmpty ? nil : title
        item.userEditedPrice = Double(priceText.filter { $0.isNumber || $0 == "." })
        item.userEditedDescription = description.isEmpty ? nil : description
        item.personalNote = personalNote.isEmpty ? nil : personalNote
        item.condition = selectedCondition.rawValue
        item.buyerPaysShipping = buyerPaysShipping
        item.handlingFee = Double(handlingFee.filter { $0.isNumber || $0 == "." }) ?? 0
        item.estimatedShippingDays = Int(estimatedDays) ?? 3
        item.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        // Dimensions & Weight
        item.weightLbs = Double(weightText.filter { $0.isNumber || $0 == "." })
        item.lengthIn = Double(lengthText.filter { $0.isNumber || $0 == "." })
        item.widthIn = Double(widthText.filter { $0.isNumber || $0 == "." })
        item.heightIn = Double(heightText.filter { $0.isNumber || $0 == "." })
        
        try? modelContext.save()
    }
    }


// MARK: - DescriptionEditorSheet
private struct DescriptionEditorSheet: View {
    var initialText: String
    var onSave: (String) -> Void
    var hasAIPurple: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    
    @State private var localText: String = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $localText)
                .focused($focused)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .background(hasAIPurple ? Color.purple.opacity(0.05) : Color(.systemBackground))
                .navigationTitle("Description")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onSave(localText)
                            dismiss()
                        }
                    }
                }
        }
        .onAppear {
            localText = initialText
            focused = true
        }
    }
}

// MARK: - BulkListingOverviewView (Drafts)
struct BulkListingOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Item> { $0.isDraft == true }, sort: \Item.createdAt, order: .reverse)
    private var allItems: [Item]
    @EnvironmentObject private var uploadManager: UploadManager

    @FocusState private var focusedField: DraftFocusField?
    @State private var cache = CachedImageManager()
    @State private var showProcessFullScreen = false
    @State private var isSelectMode = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var showDraftBulkEdit = false
    /// Direction of the last arrow-key move, so continuing past a description slot (see
    /// DraftRow.onDescriptionAutoAdvance) keeps going the same way the user was already moving.
    @State private var lastFocusMoveDelta = 1

    // Always show every not-yet-published draft with photos, regardless of which
    // app session created it — sessionDraftIDs only tracks the current session's
    // drafts for the camera exit "discard?" prompt, not what belongs in this list.
    private var drafts: [Item] {
        // Show ALL persisted drafts, not just the ones committed this app session.
        // `sessionDraftIDs` is in-memory only and resets on every launch, so filtering by
        // it silently hid drafts created before an app restart (issue #41). SwiftData is
        // the source of truth for what's still an unpublished draft.
        // Excluding `deletedDraftIDs` here matters: deletion is deferred by a run loop tick
        // (see UploadManager.deleteDraftLocallyAndCloud) to avoid a SwiftData crash, so this
        // filter is what actually removes the row from the List immediately.
        // Excluding `publishedAt != nil` matters even more: an item selected for a web
        // cross-post is kept alive in SwiftData (still isDraft, still has photos) until the
        // queue drains, so without this it lingers here looking like an ordinary editable,
        // swipeable draft — which is exactly how a bulk "delete selected drafts" ended up
        // hard-deleting an already-published listing (see UploadManager.deleteDraftLocallyAndCloud).
        allItems.filter { !$0.sourceAssetIdentifiers.isEmpty && !uploadManager.deletedDraftIDs.contains($0.id) && $0.publishedAt == nil && !$0.pendingPublish }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Photo upload runs silently in the background — no blocking bar here. AI processing
            // reads photos straight from on-device storage, so it never has to wait on the upload,
            // and publish re-uploads anything that didn't finish. Upload progress, when relevant,
            // is surfaced inside ProcessProgressView instead.

            // ── Processing banner ──────────────────────────────────────
            if uploadManager.isProcessing {
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
                Divider()
            }

            // ── Draft list ─────────────────────────────────────────────
            ScrollViewReader { proxy in
                List {
                    ForEach(drafts) { item in
                        DraftRow(
                            item: item,
                            focusedField: $focusedField,
                            cache: cache,
                            isSelectable: isSelectMode,
                            isSelected: selectedItemIDs.contains(item.id),
                            onToggle: {
                                if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
                                else { selectedItemIDs.insert(item.id) }
                            },
                            onDescriptionAutoAdvance: { moveFocus(by: lastFocusMoveDelta) }
                        )
                        .equatable()
                        .id(item.id)
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            uploadManager.deleteDraftLocallyAndCloud(draft: drafts[i], modelContext: modelContext)
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: focusedField) { oldValue, newValue in
                    try? modelContext.save()
                    // Only re-center when focus actually lands on a *different draft* — title,
                    // price, and description of the same row are already all visible together,
                    // so scrolling on every sub-field move (as this used to) fought the user's
                    // own scroll gesture on every single field-to-field tap or arrow press.
                    if let fv = newValue, fv.itemID != oldValue?.itemID {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(fv.itemID, anchor: .center)
                            }
                        }
                    }
                }
            }

            if isSelectMode && !selectedItemIDs.isEmpty {
                Divider()
                HStack {
                    Text("\(selectedItemIDs.count) selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit \(selectedItemIDs.count) selected") {
                        showDraftBulkEdit = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule())
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelectMode && !selectedItemIDs.isEmpty)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelectMode {
                    Button("Cancel") {
                        isSelectMode = false
                        selectedItemIDs.removeAll()
                    }
                } else {
                    Button("Select") { isSelectMode = true }
                        .disabled(drafts.isEmpty)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isSelectMode { processButton }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button { moveFocus(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(focusedIndex == nil || focusedIndex == 0)
                Button { moveFocus(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(focusedIndex == nil || focusedIndex == (drafts.count * 3 - 1))
                Spacer()
                Button("Done") {
                    focusedField = nil
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .fullScreenCover(isPresented: $showProcessFullScreen) {
            NavigationStack {
                ProcessProgressView(onMinimize: {
                    showProcessFullScreen = false
                    // Defer the tab switch past the cover dismiss animation so
                    // SwiftUI doesn't get two simultaneous nav mutations in one frame.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        uploadManager.selectedTab = 0
                    }
                })
            }
            .environmentObject(uploadManager)
        }
        .sheet(isPresented: $showDraftBulkEdit) {
            DraftBulkEditSheet(items: drafts.filter { selectedItemIDs.contains($0.id) }) {
                isSelectMode = false
                selectedItemIDs.removeAll()
            }
            .environmentObject(uploadManager)
        }
    }

    // MARK: Process Button
    @ViewBuilder
    private var processButton: some View {
        let processing = uploadManager.isProcessing
        Button {
            // Start AI immediately — never make the user wait for the photo upload. Gemini reads
            // the on-device images directly, so processing is independent of the Storage upload.
            if !processing && !drafts.isEmpty {
                uploadManager.processDrafts(drafts: drafts, modelContext: modelContext)
                showProcessFullScreen = true
            }
        } label: {
            Text(processing ? "Processing…" : "Process")
                .fontWeight(.semibold)
                .foregroundStyle(processing || drafts.isEmpty ? .secondary : Color.accentColor)
        }
        .disabled(processing || drafts.isEmpty)
    }

    // MARK: Keyboard navigation helpers
    /// Flattened index: row*3 = title, row*3+1 = price, row*3+2 = description
    private var focusedIndex: Int? {
        guard let fv = focusedField else { return nil }
        guard let row = drafts.firstIndex(where: { $0.id == fv.itemID }) else { return nil }
        let fieldOffset: Int
        switch fv.field {
        case .title: fieldOffset = 0
        case .price: fieldOffset = 1
        case .description: fieldOffset = 2
        }
        return row * 3 + fieldOffset
    }

    private func moveFocus(by delta: Int) {
        lastFocusMoveDelta = delta
        guard let current = focusedIndex else { return }
        let next = current + delta
        let maxIndex = drafts.count * 3 - 1
        guard next >= 0 && next <= maxIndex else { return }
        let row = next / 3
        let field: DraftFocusSubfield
        switch next % 3 {
        case 0: field = .title
        case 1: field = .price
        default: field = .description
        }
        focusedField = DraftFocusField(itemID: drafts[row].id, field: field)
    }
}

// MARK: - Draft Focus Types (shared between BulkListingOverviewView & ProcessResultsOverviewView)

struct DraftFocusField: Hashable {
    let itemID: UUID
    let field: DraftFocusSubfield
}
enum DraftFocusSubfield: Hashable { case title, price, description }

// MARK: - ProcessResultsOverviewView


struct ProcessResultsOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Item> { $0.isDraft == true })
    private var allItems: [Item]
    @EnvironmentObject private var uploadManager: UploadManager

    @State private var cache = CachedImageManager()
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingEditSheet: Item? = nil
    @FocusState private var focusedField: DraftFocusField?
    /// Measured height of the List container, used to compute per-item description size.
    @State private var listHeight: CGFloat = 0
    /// Direction of the last arrow-key move, so continuing past a description slot (see
    /// ResultDraftRow.onDescriptionAutoAdvance) keeps going the same way the user was already moving.
    @State private var lastFocusMoveDelta = 1

    @State private var showPublishConfirmation = false
    // The post-publish continuation (deferred API triggers, web autofill job building,
    // its gating flags) lives on UploadManager — see its "Publish continuation" section.
    // It was @State here once, and dismissing this sheet mid-publish discarded it.

    // Only show the items that went through AI processing
    private var results: [Item] {
        let processedSet = Set(uploadManager.processedItemIDs)
        // See UploadManager.deletedDraftIDs — deletion is deferred a tick, so this filter is
        // what actually drops the row from the List immediately.
        // publishedAt != nil means this item already published successfully and is only
        // still in SwiftData because a queued web cross-post job needs its photos — drop it
        // from the reviewable/swipeable list the moment that happens, instead of leaving a
        // live listing looking like an ordinary draft (see deleteDraftLocallyAndCloud).
        // pendingPublish=true items ARE kept here intentionally — they are failed-to-publish
        // drafts that the user is retrying. They appear with an orange highlight below.
        return allItems.filter { processedSet.contains($0.id) && !uploadManager.deletedDraftIDs.contains($0.id) && $0.publishedAt == nil }
    }

    private var toPublish: [Item] {
        selectedIDs.isEmpty ? results : results.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(results) { item in
                    ResultDraftRow(
                        item: item,
                        cache: cache,
                        isSelected: selectedIDs.contains(item.id),
                        onToggle: { toggleSelection(item) },
                        focusedField: $focusedField,
                        isGeminiFailed: uploadManager.processingFailedIDs.contains(item.id),
                        descriptionLineLimit: descriptionLineLimit,
                        onDescriptionAutoAdvance: { moveFocus(by: lastFocusMoveDelta) }
                    )
                    .equatable()
                    // Orange tint for items that previously failed to publish
                    // (pendingPublish=true but not yet successfully written to Firestore).
                    .listRowBackground(item.pendingPublish ? Color.orange.opacity(0.10) : nil)
                }
                .onDelete { offsets in
                    for i in offsets {
                        uploadManager.deleteDraftLocallyAndCloud(draft: results[i], modelContext: modelContext)
                    }
                }
            }
            .listStyle(.plain)
            .background(GeometryReader { geo in
                Color.clear.onAppear { listHeight = geo.size.height }
            })
            .onAppear { selectedIDs = Set(results.map { $0.id }) }

            // ── Bottom action bar ────────────────────────────────────────
            // The Mercari autofill pill lives in MainView, underneath this sheet — surface
            // its activity here so the user isn't staring at a seemingly frozen screen.
            if uploadManager.globalMercariJob != nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Posting to Mercari in the background…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.08))
            }
            Divider()
            HStack(spacing: 16) {
                Button(selectedIDs.count == results.count ? "Deselect All" : "Select All") {
                    if selectedIDs.count == results.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(results.map { $0.id })
                    }
                }
                .font(.subheadline)

                Spacer()

                Button {
                    focusedField = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        uploadManager.publishConfirmationSheetVisible = true
                        showPublishConfirmation = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        let busy = uploadManager.isUploadingPhotos || uploadManager.isPublishing
                        let countLabel: String = selectedIDs.isEmpty ? "All" : "\(selectedIDs.count)"
                        let buttonLabel: String = uploadManager.isPublishing ? "Publishing…" : uploadManager.isUploadingPhotos ? "Uploading Photos…" : "Publish \(countLabel)"
                        if busy {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                        Text(buttonLabel)
                        .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        (uploadManager.isUploadingPhotos || uploadManager.isPublishing) ? Color.secondary : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .disabled(results.isEmpty || uploadManager.isUploadingPhotos || uploadManager.isPublishing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Review & Publish")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Spec N4: full-screen view with an explicit way back — returns to the
            // camera with drafts saved. Safe even mid-publish: the continuation lives
            // on UploadManager (Phase 3) and the queue pill re-opens this view.
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    uploadManager.showResultsOverview = false
                    uploadManager.returnToCameraRoot = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                let atFirst: Bool = focusedIndex == nil || focusedIndex == 0
                let atLast: Bool = focusedIndex == nil || focusedIndex == results.count * 3 - 1
                Button(action: { moveFocus(by: -1) }) { Image(systemName: "chevron.up") }
                    .disabled(atFirst)
                Button(action: { moveFocus(by: 1) }) { Image(systemName: "chevron.down") }
                    .disabled(atLast)
                Spacer()
                Button("Done") {
                    focusedField = nil
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .alert("Publish Failed", isPresented: Binding(
            get: { uploadManager.publishError != nil },
            set: { if !$0 { uploadManager.publishError = nil } }
        )) {
            Button("OK", role: .cancel) { uploadManager.publishError = nil }
        } message: {
            Text(uploadManager.publishError ?? "")
        }
        // The eBay/Etsy cross-post error (crossPostError) is NOT surfaced here — see
        // UploadManager.crossPostError. The API-trigger Task that sets it typically completes
        // after this view has already been dismissed (showResultsOverview = false runs
        // immediately once publish succeeds and there's no web-autofill queue to wait on), so
        // a local alert here would silently discard it. It's shown from CrossPostStatusView
        // instead, which is reliably the next screen the user lands on either way.
        .sheet(isPresented: $showPublishConfirmation, onDismiss: {
            // Fires once the sheet is FULLY gone — only now is it safe to run the
            // post-publish continuation that mutates other sheet state.
            uploadManager.publishConfirmationSheetVisible = false
            uploadManager.runPublishContinuationIfReady(modelContext: modelContext)
            // If beginPublish was called (i.e. user didn't cancel), swap to PublishProgressView.
            // Delay matches the existing AI→results transition to avoid overlapping covers.
            if uploadManager.isPublishing || !uploadManager.publishStatuses.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    uploadManager.showResultsOverview = false
                    uploadManager.showPublishProgress = true
                }
            }
        }) {
            publishConfirmationSheetContent
        }
    }
    
    @ViewBuilder private var publishConfirmationSheetContent: some View {
        PublishConfirmationSheet(itemsToPublish: toPublish) { selectedPlatforms in
            // Web autofill jobs are BUILT in UploadManager.runPublishContinuationIfReady,
            // after publish completes — at this point firestoreListingId can be nil and the
            // Storage photo uploads unfinished, so a job snapshotted now would carry empty
            // paths / no listing ID (the old fragility: jobs held the live draft instead and
            // broke whenever the draft was deleted or its photos still uploading). Here we
            // only record what to build; beginPublish stores it all on the manager.
            let webPlatforms = selectedPlatforms.filter { $0 == "mercari" || $0 == "facebook" }.sorted()
            // Capture per-listing cross-post info now (before the drafts are deleted) so the
            // post-publish status overview can show per-platform status and offer retries.
            let attemptedPlatforms = Array(selectedPlatforms).sorted()
            // Always populate so CrossPostStatusView (global sheet) can show at minimum
            // "Wonni - posted" even when no cross-posting was selected.
            uploadManager.sessionCrossPostItems = toPublish.compactMap { item in
                guard let listingId = item.firestoreListingId else { return nil }
                return CrossPostSessionItem(
                    id: listingId,
                    title: item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled",
                    description: item.userEditedDescription ?? item.aiSuggestedDescription ?? "",
                    price: item.userEditedPrice ?? item.aiSuggestedPrice ?? 0.0,
                    coverPhotoPath: item.orderedFirebasePhotoPaths.first,
                    photoPaths: item.orderedFirebasePhotoPaths,
                    platforms: attemptedPlatforms,
                    buyerPaysShipping: item.buyerPaysShipping,
                    condition: item.condition ?? ItemCondition.good.rawValue
                )
            }
            if !attemptedPlatforms.isEmpty {
                uploadManager.crossPostStatusPending = true
            }
            // API cross-posts are deferred to the publish completion (the continuation)
            // so the Firestore write completes before the Cloud Function reads the listing.
            let apiPlatforms = selectedPlatforms.filter { $0 == "ebay" || $0 == "etsy" }
            let apiTriggers: [UploadManager.PendingAPITrigger] = apiPlatforms.isEmpty ? [] : toPublish.compactMap { item in
                guard let listingId = item.firestoreListingId else { return nil }
                let title = item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled"
                return UploadManager.PendingAPITrigger(listingId: listingId, title: title, platforms: Array(apiPlatforms))
            }
            uploadManager.beginPublish(
                drafts: toPublish,
                webPlatforms: webPlatforms,
                apiTriggers: apiTriggers,
                modelContext: modelContext
            )
        }
        .presentationDetents([.large])
    }

    private func toggleSelection(_ item: Item) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    private var descriptionLineLimit: Int {
        guard !results.isEmpty, listHeight > 0 else { return 4 }
        let count = CGFloat(results.count)
        let bottomBarH: CGFloat = 72
        let processingBannerH: CGFloat = uploadManager.isProcessing ? 50 : 0
        let perRowFixedH: CGFloat = 120
        let lineH: CGFloat = 17
        let descPaddingH: CGFloat = 16
        let totalFixed = perRowFixedH * count + bottomBarH + processingBannerH
        let perItemDescH = (listHeight - totalFixed) / count
        return max(3, Int((perItemDescH - descPaddingH) / lineH))
    }

    private var focusedIndex: Int? {
        guard let fv = focusedField else { return nil }
        guard let row = results.firstIndex(where: { $0.id == fv.itemID }) else { return nil }
        let fieldOffset: Int
        switch fv.field {
        case .title: fieldOffset = 0
        case .price: fieldOffset = 1
        case .description: fieldOffset = 2
        }
        return row * 3 + fieldOffset
    }

    private func moveFocus(by delta: Int) {
        lastFocusMoveDelta = delta
        guard let current = focusedIndex else { return }
        let next = current + delta
        let maxIndex = results.count * 3 - 1
        guard next >= 0 && next <= maxIndex else { return }
        let row = next / 3
        let field: DraftFocusSubfield
        switch next % 3 {
        case 0: field = .title
        case 1: field = .price
        default: field = .description
        }
        focusedField = DraftFocusField(itemID: results[row].id, field: field)
    }
}

// MARK: - Cross-Post Status Overview

/// One published listing's cross-post info, captured at publish time so the status overview
/// survives the SwiftData draft being deleted.
struct CrossPostSessionItem: Identifiable, Equatable {
    let id: String              // Firestore listing document ID
    let title: String
    let description: String
    let price: Double
    let coverPhotoPath: String?
    let photoPaths: [String]
    let platforms: [String]     // attempted cross-post platforms, e.g. ["ebay","mercari"]
    let buyerPaysShipping: Bool
    let condition: String       // ItemCondition rawValue, so retries don't post as "good"
}

/// Post-publish overview: per listing, shows Wonni plus each attempted platform's live status
/// (read from Firestore `crossPostStatus`) with one-tap retry for any failures. This is the
/// "see status + retry" screen, shown in place of silently bouncing home after a cross-post.
struct CrossPostStatusView: View {
    let items: [CrossPostSessionItem]
    var onDone: () -> Void

    @State private var statuses: [String: [String: String]] = [:]   // listingId -> platform -> status
    @State private var listeners: [ListenerRegistration] = []
    @State private var retryJob: CrossPostJob? = nil
    @State private var retryingEbay: Set<String> = []
    @EnvironmentObject private var uploadManager: UploadManager

    private var allResolved: Bool {
        for item in items {
            for platform in item.platforms where platform != "wonni" {
                let status = statuses[item.id]?[platform] ?? "pending"
                if status == "pending" || status == "removing" { return false }
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(items) { item in
                    Section {
                        platformRow(item: item, platform: "wonni")
                        ForEach(item.platforms.filter { $0 != "wonni" }, id: \.self) { platform in
                            platformRow(item: item, platform: platform)
                        }
                    } header: {
                        HStack(spacing: 10) {
                            if let cover = item.coverPhotoPath {
                                StorageImage(path: cover)
                                    .frame(width: 30, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)

            Divider()
            // N6: still-in-flight jobs can be minimized (mirrors ProcessProgressView) —
            // the queue keeps running via UploadManager, this view just steps aside.
            // Once everything has resolved (posted or failed), it reads "Done".
            Button(action: { stopListeners(); onDone() }) {
                Text(allResolved ? "Done" : "Minimize")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .navigationTitle("Cross-Post Status")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear(perform: startListeners)
        .onDisappear(perform: stopListeners)
        .sheet(item: $retryJob) { job in
            CrossPostContainerView(
                platformName: "Facebook Marketplace",
                listingTitle: job.title,
                listingDescription: job.description,
                listingPrice: job.price
            )
        }
        // See UploadManager.crossPostError — surfaced here (not on ProcessResultsOverviewView)
        // because this is reliably the screen the user is on by the time an eBay/Etsy
        // cross-post Task resolves, regardless of how quickly the previous screen dismissed.
        // The live status badge below (via startListeners' Firestore listener) already shows
        // "Failed" + Retry per-row from the Cloud Function's own crossPostStatus write, so this
        // alert exists mainly to explain WHY it failed the moment it happens, once, per attempt.
        .alert("Cross-Post Failed", isPresented: Binding(
            get: { uploadManager.crossPostError != nil },
            set: { if !$0 { uploadManager.crossPostError = nil } }
        )) {
            Button("OK", role: .cancel) { uploadManager.crossPostError = nil }
        } message: {
            Text(uploadManager.crossPostError ?? "")
        }
        // See UploadManager.photoUploadWarning — a listing can publish (and cross-post) with
        // fewer photos than selected if one silently failed every upload retry; this is the
        // first point the user finds out, rather than noticing a thin listing later.
        .alert("Some Photos Didn't Upload", isPresented: Binding(
            get: { uploadManager.photoUploadWarning != nil },
            set: { if !$0 { uploadManager.photoUploadWarning = nil } }
        )) {
            Button("OK", role: .cancel) { uploadManager.photoUploadWarning = nil }
        } message: {
            Text(uploadManager.photoUploadWarning ?? "")
        }
    }

    @ViewBuilder
    private func platformRow(item: CrossPostSessionItem, platform: String) -> some View {
        // Wonni is always "posted" — the listing reached Firestore. Others reflect live status.
        let status = platform == "wonni" ? "posted" : (statuses[item.id]?[platform] ?? "pending")
        HStack(spacing: 12) {
            Image(systemName: platformIcon(platform))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(platformName(platform))
                .font(.subheadline)
            Spacer()
            statusBadge(status)
            if status == "failed" {
                Button("Retry") { retry(item: item, platform: platform) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(platform == "ebay" && retryingEbay.contains(item.id))
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        switch status {
        case "posted":
            Label("Posted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case "failed":
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.red).labelStyle(.titleAndIcon)
        case "pending", "removing":
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text(status == "removing" ? "Removing…" : "In progress…")
                    .font(.caption).foregroundStyle(.orange)
            }
        default:
            Text(status.capitalized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func startListeners() {
        stopListeners()
        let db = Firestore.firestore()
        for item in items {
            let reg = db.collection("listings").document(item.id).addSnapshotListener { snap, _ in
                guard let data = snap?.data() else { return }
                statuses[item.id] = data["crossPostStatus"] as? [String: String] ?? [:]
            }
            listeners.append(reg)
        }
    }

    private func stopListeners() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    private func retry(item: CrossPostSessionItem, platform: String) {
        switch platform {
        case "ebay", "etsy":
            retryingEbay.insert(item.id)
            Task {
                try? await IntegrationRepository.shared.triggerCrossPost(listingId: item.id, platforms: [platform])
                retryingEbay.remove(item.id)
            }
        case "mercari":
            let job = CrossPostJob(
                platform: platform,
                title: item.title,
                description: item.description,
                price: item.price,
                listingId: item.id,
                photoFirebasePaths: item.photoPaths,
                buyerPaysShipping: item.buyerPaysShipping,
                condition: item.condition
            )
            uploadManager.globalMercariJob = job
            uploadManager.onMercariJobComplete = nil
        case "facebook":
            // Facebook requires a visible full-screen sheet.
            retryJob = CrossPostJob(
                platform: platform,
                title: item.title,
                description: item.description,
                price: item.price,
                listingId: item.id,
                photoFirebasePaths: item.photoPaths,
                buyerPaysShipping: item.buyerPaysShipping,
                condition: item.condition
            )
        default:
            break
        }
    }

    private func platformName(_ platform: String) -> String {
        switch platform {
        case "wonni":    return "Wonni"
        case "ebay":     return "eBay"
        case "mercari":  return "Mercari"
        case "facebook": return "Facebook Marketplace"
        case "etsy":     return "Etsy"
        default:         return platform.capitalized
        }
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "wonni":    return "bag.fill"
        case "facebook": return "person.2.fill"
        default:         return "globe"
        }
    }
}

// MARK: - WordDiffView

private struct WordDiffView: View {
    let before: String
    let after: String

    enum TokenKind { case same, deleted, added }
    struct Token { let word: String; let kind: TokenKind }

    var body: some View {
        tokens.reduce(Text("")) { acc, tok in
            switch tok.kind {
            case .same:    return acc + Text(tok.word + " ").font(.caption).foregroundColor(.primary)
            case .deleted: return acc + Text(tok.word + " ").font(.caption).foregroundColor(.red).strikethrough()
            case .added:   return acc + Text(tok.word + " ").font(.caption).foregroundColor(.green).fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokens: [Token] {
        let old = before.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let new = after.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let lcs = longestCommonSubsequence(old, new)
        return buildDiff(old: old, new: new, lcs: lcs)
    }

    private func buildDiff(old: [String], new: [String], lcs: [String]) -> [Token] {
        var result: [Token] = []
        var oi = 0, ni = 0, li = 0
        while oi < old.count || ni < new.count {
            if li < lcs.count {
                while oi < old.count && old[oi] != lcs[li] {
                    result.append(Token(word: old[oi], kind: .deleted)); oi += 1
                }
                while ni < new.count && new[ni] != lcs[li] {
                    result.append(Token(word: new[ni], kind: .added)); ni += 1
                }
                if oi < old.count && ni < new.count {
                    result.append(Token(word: lcs[li], kind: .same))
                    oi += 1; ni += 1; li += 1
                }
            } else {
                while oi < old.count { result.append(Token(word: old[oi], kind: .deleted)); oi += 1 }
                while ni < new.count { result.append(Token(word: new[ni], kind: .added)); ni += 1 }
            }
        }
        return result
    }

    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        guard !a.isEmpty && !b.isEmpty else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : Swift.max(dp[i-1][j], dp[i][j-1])
            }
        }
        var res: [String] = []
        var i = a.count, j = b.count
        while i > 0 && j > 0 {
            if a[i-1] == b[j-1] { res.insert(a[i-1], at: 0); i -= 1; j -= 1 }
            else if dp[i-1][j] > dp[i][j-1] { i -= 1 }
            else { j -= 1 }
        }
        return res
    }
}

// MARK: - AIUndoToastView

private struct AIUndoToastView: View {
    let message: String
    let onRestore: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let restore = onRestore {
                Button("Restore", action: restore)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.label).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - ResultDraftRow

struct ResultDraftRow: View, Equatable {
    let item: Item
    let cache: CachedImageManager
    let isSelected: Bool
    let onToggle: () -> Void
    var focusedField: FocusState<DraftFocusField?>.Binding
    var isGeminiFailed: Bool = false
    /// Minimum lines for the description field; computed from available screen height.
    var descriptionLineLimit: Int = 4
    /// Called when the description sheet — opened via arrow-key navigation landing on this
    /// row's description slot, not a direct tap — is dismissed. Lets the keyboard toolbar's
    /// up/down arrows continue on to the next field instead of stopping dead at description,
    /// which (unlike title/price) isn't a real focusable text field.
    var onDescriptionAutoAdvance: (() -> Void)? = nil

    // ProcessResultsOverviewView.body re-evaluates on every uploadManager @Published change
    // (isUploadingPhotos, isPublishing, processingFailedIDs are all read there directly) —
    // which fires repeatedly while background photo uploads are still finishing, i.e.
    // exactly while the user is typing on this screen. That reconstructs every row with a
    // fresh `onToggle` closure, and SwiftUI's default diffing treats closures as always
    // "changed," so every row's body re-evaluates on every tick regardless of whether it has
    // anything to do with that row. Equatable + `.equatable()` at the call site lets SwiftUI
    // skip re-evaluating a row whose actual rendered inputs haven't changed. Compares every
    // `item` field this row reads — add to this list if the body starts reading a new one.
    static func == (lhs: ResultDraftRow, rhs: ResultDraftRow) -> Bool {
        lhs.isSelected == rhs.isSelected &&
        lhs.isGeminiFailed == rhs.isGeminiFailed &&
        lhs.descriptionLineLimit == rhs.descriptionLineLimit &&
        lhs.focusedField.wrappedValue == rhs.focusedField.wrappedValue &&
        lhs.item.sourceAssetIdentifiers == rhs.item.sourceAssetIdentifiers &&
        lhs.item.userEditedTitle == rhs.item.userEditedTitle &&
        lhs.item.aiSuggestedTitle == rhs.item.aiSuggestedTitle &&
        lhs.item.visionTitle == rhs.item.visionTitle &&
        lhs.item.userEditedPrice == rhs.item.userEditedPrice &&
        lhs.item.aiSuggestedPrice == rhs.item.aiSuggestedPrice &&
        lhs.item.userEditedDescription == rhs.item.userEditedDescription &&
        lhs.item.aiSuggestedDescription == rhs.item.aiSuggestedDescription &&
        lhs.item.originalUserTitleBeforeAI == rhs.item.originalUserTitleBeforeAI &&
        lhs.item.originalUserDescriptionBeforeAI == rhs.item.originalUserDescriptionBeforeAI
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var titleText: String = ""
    @State private var priceText: String = ""
    @State private var descriptionText: String = ""
    @State private var showEditSheet = false
    @State private var showDescriptionEditor = false
    @State private var descriptionEditorOpenedViaFocus = false
    @State private var undoneAITitle: String? = nil
    @State private var undoneAIDescription: String? = nil
    @State private var toastMessage: String? = nil
    @State private var toastRestoreAction: (() -> Void)? = nil
    /// While an AI-edited title shows as a word-diff, tapping it (or arrow-keying into
    /// it) swaps in the editable field. Leaving the field decides the diff's fate:
    /// text changed → the user has taken ownership, drop `originalUserTitleBeforeAI`
    /// (row becomes a normal title permanently); unchanged → the diff comes back.
    @State private var isEditingAITitle = false
    @State private var aiTitleAtEditStart: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Top row: toggle + photo + title/price + edit ───────────────
            HStack(alignment: .top, spacing: 14) {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Group {
                    if let assetId = item.sourceAssetIdentifiers.first {
                        if let img = item.thumbnail(for: assetId) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            PhotoItemView(asset: PhotoAsset(identifier: assetId), cache: cache, imageSize: CGSize(width: 160, height: 160))
                        }
                    } else {
                        Color(.systemGray5)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    // AI-edited titles show ONLY the diff (accept = leave it, reject =
                    // undo link, edit = tap the diff). The old layout stacked the diff
                    // AND a duplicate editable title, which read as two titles.
                    if let origTitle = item.originalUserTitleBeforeAI, !isEditingAITitle {
                        HStack(alignment: .top, spacing: 6) {
                            WordDiffView(before: origTitle, after: titleText)
                            Spacer(minLength: 0)
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditingAITitle() }
                        Button("Undo AI title edits") { undoAITitle() }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    } else {
                        TextField("Title", text: $titleText)
                            .font(.body.weight(.semibold))
                            .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))

                        TitleCharCountView(count: titleText.count)
                    }

                    HStack(spacing: 3) {
                        Text("$").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Price", text: $priceText)
                            .font(.subheadline)
                            .keyboardType(.decimalPad)
                            .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .price))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { showEditSheet = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            // ── Description (full width) ────────────────────────────────────
            // Same treatment as the title: an AI-edited description shows ONLY the
            // diff (tap opens the editor; saving a real change drops the diff), not
            // the diff plus a duplicate description box.
            if let origDesc = item.originalUserDescriptionBeforeAI {
                HStack(alignment: .top, spacing: 6) {
                    WordDiffView(before: origDesc, after: descriptionText)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { showDescriptionEditor = true }
                Button("Undo AI description edits") { undoAIDescription() }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
            } else {
                Button { showDescriptionEditor = true } label: {
                    Text(descriptionText.isEmpty ? "Add description…" : descriptionText)
                        .lineLimit(3)
                        .font(.caption)
                        .foregroundStyle(descriptionText.isEmpty
                            ? Color(.placeholderText)
                            : (item.userEditedDescription != nil ? .primary : .secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // ── AI badge row ────────────────────────────────────────────────
            let hasAIEdits = item.originalUserTitleBeforeAI != nil || item.originalUserDescriptionBeforeAI != nil
            HStack(spacing: 0) {
                if isGeminiFailed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        Text("Couldn't identify — enter details manually").font(.caption2).foregroundStyle(.orange.opacity(0.9))
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                        Text(hasAIEdits ? "AI edited" : "AI identified").font(.caption2).foregroundStyle(.purple.opacity(0.8))
                    }
                }
                Spacer()
            }

            // ── Undo toast (in flow) ────────────────────────────────────────
            // A real list element, not an overlay: the old floating version sat on
            // top of neighboring rows and hid them. In flow, it occupies (part of)
            // the space the undone AI text just vacated.
            if let msg = toastMessage {
                AIUndoToastView(message: msg, onRestore: toastRestoreAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastMessage != nil)
        .sheet(isPresented: $showDescriptionEditor) {
            DescriptionEditorSheet(
                initialText: descriptionText,
                onSave: { newText in
                    let changed = newText != descriptionText
                    item.userEditedDescription = newText.isEmpty ? nil : newText
                    if changed && item.originalUserDescriptionBeforeAI != nil {
                        // The user reshaped the AI's description to their liking —
                        // the diff has served its purpose; show a normal field now.
                        item.originalUserDescriptionBeforeAI = nil
                    }
                },
                hasAIPurple: item.originalUserDescriptionBeforeAI != nil
            )
        }
        .onAppear {
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            descriptionText = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
            let myTitle = DraftFocusField(itemID: item.id, field: .title)
            // Leaving the title field while editing an AI-diffed title decides the
            // diff's fate (see endEditingAITitleIfNeeded) BEFORE the general save.
            if oldFocus == myTitle && newFocus != myTitle {
                endEditingAITitleIfNeeded()
            }
            if oldFocus?.itemID == item.id && newFocus?.itemID != item.id {
                saveLocalStateToModel()
            }
            // Arrow-keying into a title that's showing as a diff: swap in the editable
            // field, same as tapping the diff.
            if newFocus == myTitle && item.originalUserTitleBeforeAI != nil && !isEditingAITitle {
                beginEditingAITitle()
            }
            // Description isn't a real focusable field (it's a button that opens a sheet),
            // so the keyboard arrows can't land real focus there. Landing "on" it via arrow
            // navigation instead opens the sheet directly, so up/down keeps working through it.
            if newFocus == DraftFocusField(itemID: item.id, field: .description) {
                descriptionEditorOpenedViaFocus = true
                showDescriptionEditor = true
            }
        }
        // Sync local state when the model is updated externally (undo AI edits, undo-toast
        // restore, bulk edit, edit sheet). Without this, the next saveLocalStateToModel()
        // (focus change / onDisappear) writes the stale local text back over the external
        // change — which made "Undo AI edits" silently revert. Same fix DraftRow got in
        // 1ad19e7 for its title/price.
        .onChange(of: item.userEditedTitle) { _, newVal in
            titleText = newVal ?? item.aiSuggestedTitle ?? ""
        }
        .onChange(of: item.userEditedDescription) { _, newVal in
            descriptionText = newVal ?? item.aiSuggestedDescription ?? ""
        }
        .onChange(of: item.userEditedPrice) { _, newVal in
            if let p = newVal ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            } else {
                priceText = ""
            }
        }
        .onChange(of: showDescriptionEditor) { _, isShowing in
            // Fires whether the sheet was saved or swiped away — either way, continue the
            // arrow-key flow onward once the user's done with the description.
            if !isShowing && descriptionEditorOpenedViaFocus {
                descriptionEditorOpenedViaFocus = false
                onDescriptionAutoAdvance?()
            }
        }
        .onDisappear {
            endEditingAITitleIfNeeded()
            saveLocalStateToModel()
        }
        .sheet(isPresented: $showEditSheet) {
            DraftEditSheet(item: item)
        }
    }

    /// Swap the AI-title diff for the editable field and focus it. The focus assignment
    /// is deferred a tick so the TextField exists in the hierarchy before it's targeted.
    private func beginEditingAITitle() {
        aiTitleAtEditStart = titleText
        isEditingAITitle = true
        DispatchQueue.main.async {
            focusedField.wrappedValue = DraftFocusField(itemID: item.id, field: .title)
        }
    }

    /// Ends an AI-title editing session. Changed text means the user reshaped the AI's
    /// title to their liking — drop `originalUserTitleBeforeAI` so the row becomes a
    /// normal title field (their requested accept/reject/edit semantics). Unchanged
    /// text (tapped in, tapped out) brings the diff back.
    private func endEditingAITitleIfNeeded() {
        guard isEditingAITitle else { return }
        isEditingAITitle = false
        if let start = aiTitleAtEditStart, titleText != start,
           !Item.deletedIDs.contains(item.id) {
            item.originalUserTitleBeforeAI = nil
        }
        aiTitleAtEditStart = nil
    }

    private func saveLocalStateToModel() {
        // Same detached-object guard as DraftRow — the sheet can be dismissed as part
        // of a flow that already deleted the draft.
        guard !Item.deletedIDs.contains(item.id) else { return }
        let v = String(titleText.prefix(140))
        if item.userEditedTitle != (v.isEmpty ? nil : v) {
            item.userEditedTitle = v.isEmpty ? nil : v
        }

        if item.userEditedDescription != (descriptionText.isEmpty ? nil : descriptionText) {
            item.userEditedDescription = descriptionText.isEmpty ? nil : descriptionText
        }

        let cleaned = priceText.filter { $0.isNumber || $0 == "." }
        let newPrice = cleaned.isEmpty ? nil : Double(cleaned)
        if item.userEditedPrice != newPrice {
            item.userEditedPrice = newPrice
        }

        try? modelContext.save()
        uploadManager.syncDraftData(item)
    }

    private func undoAITitle() {
        guard let orig = item.originalUserTitleBeforeAI else { return }
        let aiTitle = item.userEditedTitle
        // Drive the visible field on the tap frame. Without this the field only updates
        // after the model write round-trips back through .onChange(of: item.userEditedTitle),
        // which (behind a synchronous save + Firestore sync) is the lag users reported.
        titleText = orig.isEmpty ? (item.aiSuggestedTitle ?? "") : orig
        item.userEditedTitle = orig.isEmpty ? nil : orig
        item.originalUserTitleBeforeAI = nil
        item.aiUndoCount += 1
        undoneAITitle = aiTitle
        showToast(message: "AI title edits discarded") { [self] in
            titleText = self.undoneAITitle ?? item.aiSuggestedTitle ?? ""
            item.originalUserTitleBeforeAI = item.userEditedTitle
            item.userEditedTitle = self.undoneAITitle
            item.aiUndoCount = max(0, item.aiUndoCount - 1)
            self.undoneAITitle = nil
            deferredPersist()
        }
        deferredPersist()
    }

    private func undoAIDescription() {
        guard let orig = item.originalUserDescriptionBeforeAI else { return }
        let aiDesc = item.userEditedDescription
        descriptionText = orig.isEmpty ? (item.aiSuggestedDescription ?? "") : orig
        item.userEditedDescription = orig.isEmpty ? nil : orig
        item.originalUserDescriptionBeforeAI = nil
        item.aiUndoCount += 1
        undoneAIDescription = aiDesc
        showToast(message: "AI description edits discarded") { [self] in
            descriptionText = self.undoneAIDescription ?? item.aiSuggestedDescription ?? ""
            item.originalUserDescriptionBeforeAI = item.userEditedDescription
            item.userEditedDescription = self.undoneAIDescription
            item.aiUndoCount = max(0, item.aiUndoCount - 1)
            self.undoneAIDescription = nil
            deferredPersist()
        }
        deferredPersist()
    }

    /// Save + Firestore sync a beat after the current frame — keeps undo/redo taps
    /// responsive (the synchronous save was part of the visible lag). Fires on the
    /// main actor; the deleted-item guard lives in syncDraftData.
    private func deferredPersist() {
        Task { @MainActor in
            guard !Item.deletedIDs.contains(item.id) else { return }
            try? modelContext.save()
            uploadManager.syncDraftData(item)
        }
    }

    private func showToast(message: String, onRestore: @escaping () -> Void) {
        toastMessage = message
        toastRestoreAction = {
            onRestore()
            withAnimation { toastMessage = nil; toastRestoreAction = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { toastMessage = nil; toastRestoreAction = nil }
        }
    }
}

// MARK: - PublishedListingsView

struct PublishedListingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Item> { $0.isDraft == false })
    private var allItems: [Item]
    @State private var cache = CachedImageManager()

    var body: some View {
        Group {
            if allItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("No published listings yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(allItems) { item in
                    PublishedRow(item: item, cache: cache)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Published")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - PublishedRow

struct PublishedRow: View {
    let item: Item
    let cache: CachedImageManager

    @Environment(\.modelContext) private var modelContext
    @State private var titleText: String = ""
    @State private var priceText: String = ""
    @State private var descriptionText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let assetId = item.sourceAssetIdentifiers.first {
                PhotoItemView(
                    asset: PhotoAsset(identifier: assetId),
                    cache: cache,
                    imageSize: CGSize(width: 120, height: 120)
                )
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 60, height: 60)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Title…", text: $titleText)
                    .font(.headline)

                HStack(spacing: 2) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }
                .font(.subheadline)

                TextField("Description…", text: $descriptionText, axis: .vertical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2...4)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            descriptionText = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onDisappear {
            saveLocalStateToModel()
        }
    }

    private func saveLocalStateToModel() {
        if item.userEditedTitle != titleText {
            item.userEditedTitle = titleText
        }

        if item.userEditedDescription != descriptionText {
            item.userEditedDescription = descriptionText
        }

        let cleaned = priceText.filter { $0.isNumber || $0 == "." }
        let newPrice = cleaned.isEmpty ? nil : Double(cleaned)
        if item.userEditedPrice != newPrice {
            item.userEditedPrice = newPrice
        }

        try? modelContext.save()
    }
}

// MARK: - Supporting Cross-Posting Types
struct PublishConfirmationSheet: View {
    let itemsToPublish: [Item]
    let onConfirm: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var integrationRepo = IntegrationRepository.shared
    @State private var selectedPlatforms: Set<String> = []
    /// Platforms whose toggle the user has explicitly touched. The async `.task`
    /// default-selection may still seed the others, but must never overwrite an
    /// explicit user choice made while integrations were loading.
    @State private var touchedPlatforms: Set<String> = []
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    /// Gates the Publish button until integrations/settings finish loading, so a fast tap
    /// can't confirm with `selectedPlatforms` still empty from the async default-selection
    /// not having run yet (github issue #46).
    @State private var isLoadingIntegrations = true
    @State private var showEmptyPlatformsConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Publishing \(itemsToPublish.count) Listing(s) to Wonni")) {
                    ForEach(itemsToPublish) { item in
                        HStack {
                            Text(item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled")
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "$%.2f", item.userEditedPrice ?? item.aiSuggestedPrice ?? 0.0))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                
                Section(header: Text("Cross-Post Options")) {
                    if integrationRepo.integrations.isEmpty {
                        Text("No integrations available. Set them up in Profile Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(integrationRepo.integrations) { integration in
                            let isAPI = integration.platform == "ebay" || integration.platform == "etsy"
                            let isOn = Binding<Bool>(
                                get: { selectedPlatforms.contains(integration.platform) },
                                set: { isSelected in
                                    touchedPlatforms.insert(integration.platform)
                                    if isSelected {
                                        if isAPI && SellingSettingsRepository.shared.settings?.defaultLocation.postalCode.isEmpty != false {
                                            platformToEnableAfterAddressSetup = integration.platform
                                            showAddressSetupSheet = true
                                        } else {
                                            selectedPlatforms.insert(integration.platform)
                                        }
                                    } else {
                                        selectedPlatforms.remove(integration.platform)
                                    }
                                }
                            )
                            Toggle(isOn: isOn) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(platformDisplayName(integration.platform))
                                        if !isAPI {
                                            Text("Autofill")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.purple.opacity(0.12))
                                                .foregroundStyle(.purple)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    if isAPI {
                                        Text(integration.isConnected ? "Connected as: \(integration.connectedUsername ?? "Unknown")" : "Not connected (Link in settings)")
                                            .font(.caption)
                                            .foregroundStyle(integration.isConnected ? .green : .secondary)
                                    } else {
                                        Text("Launches browser autofill post-publish")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                // A Form Toggle only responds on the switch itself; the label —
                                // most of the row — was dead space, which read as "tapping does
                                // nothing." Make the label area toggle too.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { isOn.wrappedValue.toggle() }
                            }
                            .disabled(isAPI && !integration.isConnected)
                        }
                    }
                }
            }
            .navigationTitle("Publish Listings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoadingIntegrations {
                        ProgressView()
                    } else {
                        Button("Publish") {
                            if selectedPlatforms.isEmpty {
                                showEmptyPlatformsConfirm = true
                            } else {
                                onConfirm(selectedPlatforms)
                                dismiss()
                            }
                        }
                        .fontWeight(.bold)
                    }
                }
            }
            .task {
                await integrationRepo.loadIntegrations()
                await SellingSettingsRepository.shared.loadSettings()
                // Default-select connected API platforms, but only those the user hasn't
                // explicitly toggled while the async load was in flight (issue #8) — a
                // blanket reassignment here used to wipe the user's in-flight choices.
                for platform in integrationRepo.integrations.filter({ $0.isConnected }).map({ $0.platform })
                where !touchedPlatforms.contains(platform) {
                    selectedPlatforms.insert(platform)
                }
                isLoadingIntegrations = false
            }
            .sheet(isPresented: $showAddressSetupSheet) {
                AddressSetupSheet {
                    if !platformToEnableAfterAddressSetup.isEmpty {
                        selectedPlatforms.insert(platformToEnableAfterAddressSetup)
                        platformToEnableAfterAddressSetup = ""
                    }
                }
            }
            .confirmationDialog(
                "Publish to Wonni only? No cross-post platforms are selected.",
                isPresented: $showEmptyPlatformsConfirm,
                titleVisibility: .visible
            ) {
                Button("Publish to Wonni Only") {
                    onConfirm(selectedPlatforms)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    private func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }
}

