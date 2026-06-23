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
        var addingToExistingDraft: Bool = false
        /// Called when the user taps the green checkmark (non-addingToExistingDraft mode).
        /// The parent navigation controller should handle pushing the drafts overview.
        var onProceed: (() -> Void)? = nil

        @StateObject var photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
        @State private var navigateToOverview = false
        @State private var showingDraftHistory = false
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

        /// All used asset IDs (active + committed) — for the "Hide previously selected" toggle
        private var allUsedAssetIDs: Set<String> {
            let committed = committedDrafts.flatMap { $0.sourceAssetIdentifiers }
            return activeDraftAssetIDs.union(committed)
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
                        ActiveDraftCarouselView(cache: photoCollection.cache)
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
                        if addingToExistingDraft {
                            if uploadManager.activeDraftID != nil {
                                uploadManager.commitActiveDraft(modelContext: modelContext)
                            }
                        }
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
                    if addingToExistingDraft {
                        Button("Done") {
                            if hasActiveDraft {
                                uploadManager.commitActiveDraft(modelContext: modelContext)
                            }
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(!canProceed)
                    } else {
                        Button {
                            if hasActiveDraft {
                                uploadManager.commitActiveDraft(modelContext: modelContext)
                            }
                            if let proceed = onProceed {
                                proceed()
                            } else {
                                navigateToOverview = true
                            }
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(canProceed ? .green : .secondary)
                        }
                        .disabled(!canProceed)
                    }
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
            .sheet(isPresented: $showingDraftHistory) {
                DraftHistoryModal(photoCollection: photoCollection)
            }
            .navigationDestination(isPresented: $navigateToOverview) {
                BulkListingOverviewView(sessionDraftIDs: uploadManager.sessionDraftIDs)
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
                        let data = sourceDraft.removePhoto(assetId: assetId)
                        draft.insertPhoto(assetId: assetId, data: data, at: toIdx)
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
                        let data = sourceDraft.removePhoto(assetId: assetId)
                        draft.insertPhoto(assetId: assetId, data: data, at: draft.sourceAssetIdentifiers.count)
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
                            let data = currentDraft.removePhoto(assetId: assetId)
                            if let origDraft = drafts.first(where: { $0.id == origID }) {
                                origDraft.insertPhoto(assetId: origAsset, data: data ?? originalPhotoData, at: origIdx)
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

    // MARK: - DraftHistoryModal
    struct DraftHistoryModal: View {
        @Environment(\.dismiss) private var dismiss
        @Query(filter: #Predicate<Item> { $0.isDraft == true })
        private var allItems: [Item]
        @ObservedObject var photoCollection: PhotoCollection
        @Environment(\.modelContext) private var modelContext
        @EnvironmentObject private var uploadManager: UploadManager

        @State private var isSelectionMode = false
        @State private var selectedPhotos = Set<String>()
        @State private var showingDeleteConfirm = false
        @State private var draggedCompositeId: String?
        @State private var isTrashTargeted = false
        @State private var showingPickerForDraft = false
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
            allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty }
        }

        var body: some View {
            NavigationStack {
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
                                                let title = draft.userEditedTitle ?? draft.visionTitle ?? draft.aiSuggestedTitle
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
                                                            if let uiImage = draft.image(for: assetId) {
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
                                                        uploadManager.activeDraftID = draft.id
                                                        showingPickerForDraft = true
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
                .sheet(isPresented: $showingPickerForDraft, onDismiss: {
                    // Collapse the draft-history modal too once the add-photos picker closes, so the
                    // user returns straight to the listing flow instead of unwinding nested modals.
                    dismiss()
                }) {
                    CustomPhotoPickerView(addingToExistingDraft: true)
                        .environmentObject(uploadManager)
                }
                .sheet(isPresented: $showingDraftBulkEdit) {
                    DraftBulkEditSheet(items: fullySelectedDrafts) {
                        isSelectionMode = false
                        selectedPhotos.removeAll()
                    }
                    .environmentObject(uploadManager)
                }
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
                            _ = draft.removePhoto(assetId: assetId)
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
                _ = sourceDraft.removePhoto(assetId: assetId)
                if sourceDraft.sourceAssetIdentifiers.isEmpty {
                    uploadManager.deleteDraftLocallyAndCloud(draft: sourceDraft, modelContext: modelContext)
                }
                try? modelContext.save()
            }
            draggedCompositeId = nil
            return true
        }
    }

struct DraftHistoryTitleField: View {
    let draft: Item
    var focusedDraftID: FocusState<UUID?>.Binding
    @State private var localTitle: String = ""

    var body: some View {
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
            .onAppear {
                localTitle = draft.userEditedTitle ?? draft.visionTitle ?? draft.aiSuggestedTitle ?? ""
            }
            .onChange(of: focusedDraftID.wrappedValue) { oldFocus, newFocus in
                if oldFocus == draft.id && newFocus != draft.id {
                    let v = localTitle
                    if draft.userEditedTitle != (v.isEmpty ? nil : v) {
                        draft.userEditedTitle = v.isEmpty ? nil : v
                    }
                }
            }
            .onDisappear {
                let v = localTitle
                if draft.userEditedTitle != (v.isEmpty ? nil : v) {
                    draft.userEditedTitle = v.isEmpty ? nil : v
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

// MARK: - DraftRow (redesigned)
struct DraftRow: View {
    let item: Item
    var focusedField: FocusState<DraftFocusField?>.Binding
    let cache: CachedImageManager
    var isSelectable: Bool = false
    var isSelected: Bool = false
    var onToggle: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var priceText: String = ""
    @State private var titleText: String = ""
    @State private var showDescriptionEditor = false


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
                            if let uiImage = item.image(for: assetId) {
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
                    TextField("Add title…", text: $titleText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(item.userEditedTitle != nil ? .primary : .secondary)
                        .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))
                        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                            guard let tf = notification.object as? UITextField else { return }
                            DispatchQueue.main.async { tf.selectAll(nil) }
                        }

                    TitleCharCountView(count: titleText.count)

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
                                    item.userEditedTitle = origTitle
                                    item.originalUserTitleBeforeAI = nil
                                }
                                if let origDesc = item.originalUserDescriptionBeforeAI {
                                    item.userEditedDescription = origDesc
                                    item.originalUserDescriptionBeforeAI = nil
                                }
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
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? item.visionTitle ?? ""
            if let p = item.userEditedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
            // When focus changes from this item's title/price to somewhere else or nil, save
            if oldFocus?.itemID == item.id && newFocus?.itemID != item.id {
                saveLocalStateToModel()
            }
        }
        .onDisappear {
            saveLocalStateToModel()
        }
    }

    private func saveLocalStateToModel() {
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
                                            if let uiImage = item.image(for: assetId) {
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
    var sessionDraftIDs: [UUID] = []

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

    private var drafts: [Item] {
        let sessionIDs = Set(uploadManager.sessionDraftIDs)
        if !sessionIDs.isEmpty {
            return allItems.filter { sessionIDs.contains($0.id) && !$0.sourceAssetIdentifiers.isEmpty }
        }
        return allItems.filter { !$0.sourceAssetIdentifiers.isEmpty }
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
                            }
                        )
                        .id(item.id)
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            uploadManager.deleteDraftLocallyAndCloud(draft: drafts[i], modelContext: modelContext)
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: focusedField) { _, newValue in
                    try? modelContext.save()
                    if let fv = newValue {
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

    @State private var showPublishConfirmation = false
    @State private var webAutofillQueue: [CrossPostJob] = []
    @State private var activeAutofillJob: CrossPostJob? = nil
    @State private var crossPostError: String? = nil
    /// eBay/Etsy cross-posts deferred until `isPublishing` becomes false, ensuring the
    /// Firestore listing document exists before the Cloud Function tries to read it.
    /// Stores title for error messages since the SwiftData Item may be deleted by then.
    @State private var pendingAPITriggers: [(listingId: String, title: String, platforms: [String])] = []

    // Only show the items that went through AI processing
    private var results: [Item] {
        let processedSet = Set(uploadManager.processedItemIDs)
        return allItems.filter { processedSet.contains($0.id) }
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
                        descriptionLineLimit: descriptionLineLimit
                    )
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
        // Only surface the eBay/API error once no web-autofill sheet is up. The Mercari sheet is
        // presented from this same view, and you can't show an alert underneath an active sheet —
        // that's why the error used to flash and vanish the instant Mercari opened. Gating on
        // `activeAutofillJob == nil` holds the error until the web queue drains, then shows it.
        .alert("Cross-Post Failed", isPresented: Binding(
            get: { crossPostError != nil && activeAutofillJob == nil && uploadManager.globalMercariJob == nil },
            set: { if !$0 { crossPostError = nil } }
        )) {
            Button("OK", role: .cancel) { crossPostError = nil }
        } message: {
            Text(crossPostError ?? "")
        }
        .sheet(isPresented: $showPublishConfirmation) {
            publishConfirmationSheetContent
        }
        .sheet(item: $activeAutofillJob, onDismiss: {
            checkAndStartNextWebJob()
        }) { job in
            CrossPostContainerView(
                platformName: "Facebook Marketplace",
                listingTitle: job.title,
                listingDescription: job.description,
                listingPrice: job.price
            )
        }
        .onChange(of: uploadManager.isPublishing) { _, isPublishing in
            guard !isPublishing else { return }
            // Fire deferred API cross-posts now that the Firestore write has completed.
            if !pendingAPITriggers.isEmpty {
                let triggers = pendingAPITriggers
                pendingAPITriggers = []
                Task {
                    var errorMessages: [String] = []
                    for trigger in triggers {
                        do {
                            try await IntegrationRepository.shared.triggerCrossPost(
                                listingId: trigger.listingId,
                                platforms: trigger.platforms
                            )
                        } catch {
                            errorMessages.append(formatCrossPostError(error, title: trigger.title, platforms: trigger.platforms))
                        }
                    }
                    if !errorMessages.isEmpty {
                        crossPostError = errorMessages.joined(separator: "\n\n")
                    }
                }
            }
            // Start web autofill jobs (Mercari, Facebook) after publish completes. If there are
            // none (e.g. eBay-only), transition to the global CrossPostStatusView sheet.
            if !webAutofillQueue.isEmpty {
                checkAndStartNextWebJob()
            } else {
                uploadManager.showResultsOverview = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    uploadManager.showCrossPostStatus = true
                }
            }
        }
        .interactiveDismissDisabled(uploadManager.isPublishing || activeAutofillJob != nil)
    }
    
    @ViewBuilder private var publishConfirmationSheetContent: some View {
        PublishConfirmationSheet(itemsToPublish: toPublish) { selectedPlatforms in
            var jobs: [CrossPostJob] = []
            for item in toPublish {
                for platform in selectedPlatforms {
                    if platform == "mercari" || platform == "facebook" {
                        jobs.append(CrossPostJob(
                            platform: platform,
                            title: item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled",
                            description: item.userEditedDescription ?? item.aiSuggestedDescription ?? "",
                            price: item.userEditedPrice ?? item.aiSuggestedPrice ?? 0.0,
                            listingId: item.firestoreListingId,
                            item: item,
                            buyerPaysShipping: item.buyerPaysShipping
                        ))
                    }
                }
            }
            self.webAutofillQueue = jobs
            uploadManager.pendingAutofillJobsCount = jobs.count
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
                    coverPhotoPath: item.firebasePhotoPaths?.first,
                    photoPaths: item.firebasePhotoPaths ?? [],
                    platforms: attemptedPlatforms,
                    buyerPaysShipping: item.buyerPaysShipping
                )
            }
            if !attemptedPlatforms.isEmpty {
                uploadManager.crossPostStatusPending = true
            }
            // Defer API cross-posts to onChange(of: isPublishing) so the Firestore write
            // completes before the Cloud Function tries to read the listing document.
            let apiPlatforms = selectedPlatforms.filter { $0 == "ebay" || $0 == "etsy" }
            if !apiPlatforms.isEmpty {
                pendingAPITriggers = toPublish.compactMap { item in
                    guard let listingId = item.firestoreListingId else { return nil }
                    let title = item.userEditedTitle ?? item.aiSuggestedTitle ?? "Untitled"
                    return (listingId: listingId, title: title, platforms: Array(apiPlatforms))
                }
            }
            uploadManager.publishDrafts(drafts: toPublish, modelContext: modelContext)
        }
        .presentationDetents([.large])
    }

    private func checkAndStartNextWebJob() {
        guard activeAutofillJob == nil, uploadManager.globalMercariJob == nil else { return }
        if !webAutofillQueue.isEmpty {
            let nextJob = webAutofillQueue.removeFirst()
            uploadManager.pendingAutofillJobsCount = webAutofillQueue.count + 1
            if nextJob.platform == "mercari" {
                // Mercari runs headlessly — show as a pill above the tab bar via MainView.
                uploadManager.globalMercariJob = nextJob
                uploadManager.onMercariJobComplete = { checkAndStartNextWebJob() }
            } else {
                // Facebook and other web platforms require a visible sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    activeAutofillJob = nextJob
                }
            }
        } else {
            uploadManager.pendingAutofillJobsCount = 0
            // All web cross-posting jobs finished — now safe to delete SwiftData items
            // that were held alive so startPosting() could read their photos.
            let pendingIDs = uploadManager.publishedPendingDeletionIDs
            if !pendingIDs.isEmpty {
                for item in allItems where pendingIDs.contains(item.id) {
                    modelContext.delete(item)
                }
                try? modelContext.save()
                uploadManager.publishedPendingDeletionIDs.removeAll()
            }
            // Close the results sheet and open CrossPostStatusView globally from MainView.
            uploadManager.showResultsOverview = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                uploadManager.showCrossPostStatus = true
            }
        }
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

    private func formatCrossPostError(_ error: Error, title: String, platforms: [String]) -> String {
        let nsError = error as NSError
        let serverMsg = nsError.userInfo["NSLocalizedDescription"] as? String ?? ""

        // Title-too-long: eBay max is 80 chars
        if serverMsg.lowercased().contains("title") && (serverMsg.lowercased().contains("long") || serverMsg.lowercased().contains("80") || serverMsg.lowercased().contains("character")) {
            let count = title.count
            return "eBay cross-post failed for \"\(title.prefix(40))…\"\n\nYour title is \(count) characters. eBay requires 80 or fewer. Edit the title and try again."
        }
        // Business policy / setup issue
        if serverMsg.contains("bizpolicy") || serverMsg.contains("Business Policies") || serverMsg.contains("bp/manage") {
            return "eBay cross-post failed: Your eBay Business Policies aren't configured yet. Visit your eBay Seller Hub → Business Policies to set up Payment, Return, and Shipping policies."
        }
        // Missing permissions / reconnect
        if serverMsg.contains("missing required permissions") || serverMsg.contains("invalid_scope") {
            return "eBay cross-post failed: Missing eBay permissions. Please disconnect and reconnect your eBay account in Settings."
        }
        // Generic fallback with raw message
        if !serverMsg.isEmpty && serverMsg != "INTERNAL" {
            return "Cross-post failed for \"\(title.prefix(40))\": \(serverMsg)"
        }
        return "Cross-post failed for \"\(title.prefix(40))\". Check your connection and integration settings, then try again."
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
            Button(action: { stopListeners(); onDone() }) {
                Text("Done")
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
                buyerPaysShipping: item.buyerPaysShipping
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
                buyerPaysShipping: item.buyerPaysShipping
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

struct ResultDraftRow: View {
    let item: Item
    let cache: CachedImageManager
    let isSelected: Bool
    let onToggle: () -> Void
    var focusedField: FocusState<DraftFocusField?>.Binding
    var isGeminiFailed: Bool = false
    /// Minimum lines for the description field; computed from available screen height.
    var descriptionLineLimit: Int = 4

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var titleText: String = ""
    @State private var priceText: String = ""
    @State private var descriptionText: String = ""
    @State private var showEditSheet = false
    @State private var showDescriptionEditor = false
    @State private var undoneAITitle: String? = nil
    @State private var undoneAIDescription: String? = nil
    @State private var toastMessage: String? = nil
    @State private var toastRestoreAction: (() -> Void)? = nil

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
                        if let img = item.image(for: assetId) {
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
                    if let origTitle = item.originalUserTitleBeforeAI {
                        WordDiffView(before: origTitle, after: titleText)
                        Button("Undo AI title edits") { undoAITitle() }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    }

                    TextField("Title", text: $titleText)
                        .font(.body.weight(.semibold))
                        .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))

                    TitleCharCountView(count: titleText.count)

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
            if let origDesc = item.originalUserDescriptionBeforeAI {
                WordDiffView(before: origDesc, after: descriptionText)
                    .padding(.horizontal, 4)
                Button("Undo AI description edits") { undoAIDescription() }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
            }

            Button { showDescriptionEditor = true } label: {
                Text(descriptionText.isEmpty ? "Add description…" : descriptionText)
                    .lineLimit(3)
                    .font(.caption)
                    .foregroundStyle(descriptionText.isEmpty
                        ? Color(.placeholderText)
                        : (item.userEditedDescription != nil ? .primary : .secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(item.originalUserDescriptionBeforeAI != nil
                        ? Color.purple.opacity(0.08) : Color(.systemGray6))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(item.originalUserDescriptionBeforeAI != nil
                                ? Color.purple.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDescriptionEditor) {
                DescriptionEditorSheet(
                    initialText: descriptionText,
                    onSave: { newText in
                        item.userEditedDescription = newText.isEmpty ? nil : newText
                    },
                    hasAIPurple: item.originalUserDescriptionBeforeAI != nil
                )
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
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                AIUndoToastView(message: msg, onRestore: toastRestoreAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastMessage != nil)
        .onAppear {
            titleText = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            descriptionText = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
            if oldFocus?.itemID == item.id && newFocus?.itemID != item.id {
                saveLocalStateToModel()
            }
        }
        .onDisappear {
            saveLocalStateToModel()
        }
        .sheet(isPresented: $showEditSheet) {
            DraftEditSheet(item: item)
        }
    }

    private func saveLocalStateToModel() {
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
        item.userEditedTitle = orig.isEmpty ? nil : orig
        item.originalUserTitleBeforeAI = nil
        try? modelContext.save()
        uploadManager.syncDraftData(item)
        undoneAITitle = aiTitle
        showToast(message: "AI title edits discarded") { [self] in
            item.originalUserTitleBeforeAI = item.userEditedTitle
            item.userEditedTitle = self.undoneAITitle
            self.undoneAITitle = nil
            try? modelContext.save()
            uploadManager.syncDraftData(item)
        }
    }

    private func undoAIDescription() {
        guard let orig = item.originalUserDescriptionBeforeAI else { return }
        let aiDesc = item.userEditedDescription
        item.userEditedDescription = orig.isEmpty ? nil : orig
        item.originalUserDescriptionBeforeAI = nil
        try? modelContext.save()
        uploadManager.syncDraftData(item)
        undoneAIDescription = aiDesc
        showToast(message: "AI description edits discarded") { [self] in
            item.originalUserDescriptionBeforeAI = item.userEditedDescription
            item.userEditedDescription = self.undoneAIDescription
            self.undoneAIDescription = nil
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
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    
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
                            Toggle(isOn: Binding(
                                get: { selectedPlatforms.contains(integration.platform) },
                                set: { isSelected in
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
                            )) {
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
                    Button("Publish") {
                        onConfirm(selectedPlatforms)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .task {
                await integrationRepo.loadIntegrations()
                await SellingSettingsRepository.shared.loadSettings()
                // Only set the default selection on first load; don't overwrite changes the
                // user has already made before the async load completed.
                if selectedPlatforms.isEmpty {
                    selectedPlatforms = Set(integrationRepo.integrations.filter { $0.isConnected }.map { $0.platform })
                }
            }
            .sheet(isPresented: $showAddressSetupSheet) {
                AddressSetupSheet {
                    if !platformToEnableAfterAddressSetup.isEmpty {
                        selectedPlatforms.insert(platformToEnableAfterAddressSetup)
                        platformToEnableAfterAddressSetup = ""
                    }
                }
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

