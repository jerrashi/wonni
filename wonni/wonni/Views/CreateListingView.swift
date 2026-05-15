//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
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

    var body: some View {
        let assets: [PhotoAsset] = drafts.compactMap {
            $0.sourceAssetIdentifiers.first.map(PhotoAsset.init(identifier:))
        }
        let topAssets = Array(assets.prefix(3))

        ZStack {
            if topAssets.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray2))
                    .frame(width: 35, height: 45)
            } else {
                ForEach(topAssets.indices, id: \.self) { index in
                    let asset = topAssets[index]
                    let rotation = index == 0 ? -15.0 : (index == 1 ? 0.0 : 15.0)
                    let xOffset  = index == 0 ? -1.0  : (index == 1 ? 0.0  : 1.0)
                    PhotoItemView(asset: asset, cache: cache, imageSize: CGSize(width: 70, height: 90))
                        .scaledToFill()
                        .frame(width: 35, height: 45)
                        .cornerRadius(4)
                        .rotationEffect(.degrees(topAssets.count > 1 ? rotation : 0), anchor: .bottom)
                        .shadow(color: .black.opacity(0.2), radius: 2, x: xOffset, y: 1)
                }
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(bouncing ? 1.25 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.45), value: bouncing)
    }
}

struct SelectablePhotoGridItem: View {
    let asset: PhotoAsset
    let selectedAssets: [PhotoAsset]
    let usedAssetIDs: Set<String>
    let cache: CachedImageManager
    let imageSize: CGSize
    let toggleAction: () -> Void
    
    var isSelected: Bool { selectedAssets.contains(asset) }
    var isDrafted: Bool { usedAssetIDs.contains(asset.id) }
    var selectionIndex: Int? { selectedAssets.firstIndex(of: asset) }
    
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
        @StateObject var photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)
        @State private var selectedAssets: [PhotoAsset] = []
        @State private var navigateToOverview = false
        @State private var showingDraftHistory = false
        @State private var hidePreviouslySelected = false
        @State private var sessionDraftIDs: [UUID] = []
        @State private var showingExitAlert = false
        @Environment(\.dismiss) private var dismiss

        @Environment(\.modelContext) private var modelContext
        @Query private var allItems: [Item]

        @EnvironmentObject private var uploadManager: UploadManager

        @State private var draggedAsset: PhotoAsset?
        @State private var carouselCollapsing = false
        @State private var stackBouncing = false

        @State private var showingIdentification = false
        @State private var lastCreatedListingId: String?
        @State private var lastCreatedImages: [UIImage] = []
        
        @Environment(\.displayScale) private var displayScale
        private static let itemSpacing = 2.0
        private var imageSize: CGSize {
            return CGSize(width: 100 * min(displayScale, 2), height: 100 * min(displayScale, 2))
        }
        
        let columns = [
            GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 2)
        ]
        
        var body: some View {
            let currentDrafts = allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty }
            let currentUsedAssetIDs = Set(currentDrafts.flatMap { $0.sourceAssetIdentifiers })
            
            // (Navigation logic is handled by .navigationDestination modifier below)
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.itemSpacing) {
                    if hidePreviouslySelected {
                        ForEach(photoCollection.photoAssets.filter { !currentUsedAssetIDs.contains($0.id) }) { asset in
                            SelectablePhotoGridItem(
                                asset: asset,
                                selectedAssets: selectedAssets,
                                usedAssetIDs: currentUsedAssetIDs,
                                cache: photoCollection.cache,
                                imageSize: imageSize,
                                toggleAction: { toggleSelection(asset) }
                            )
                        }
                    } else {
                        ForEach(photoCollection.photoAssets) { asset in
                            SelectablePhotoGridItem(
                                asset: asset,
                                selectedAssets: selectedAssets,
                                usedAssetIDs: currentUsedAssetIDs,
                                cache: photoCollection.cache,
                                imageSize: imageSize,
                                toggleAction: { toggleSelection(asset) }
                            )
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    // Thin upload progress bar – always visible while uploading
                    if uploadManager.isUploadingPhotos {
                        VStack(spacing: 4) {
                            ProgressView(value: uploadManager.uploadProgress)
                                .tint(.blue)
                                .padding(.horizontal, 16)
                            Text("Uploading photos…" + (uploadManager.uploadEtaString.map { " \($0)" } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
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
                if !selectedAssets.isEmpty || !currentDrafts.isEmpty {
                    VStack(spacing: 0) {
                        Divider()
                        
                        if !selectedAssets.isEmpty {
                            ScrollViewReader { scrollView in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(Array(selectedAssets.enumerated()), id: \.element.id) { index, asset in
                                            let totalCount = selectedAssets.count
                                            let centerIndex = Double(totalCount - 1) / 2.0
                                            let direction = Double(index) - centerIndex
                                            PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: imageSize)
                                                .frame(width: 60, height: 60)
                                                .cornerRadius(8)
                                                .id(asset.id)
                                                .overlay(alignment: .topTrailing) {
                                                    if !carouselCollapsing {
                                                        Button {
                                                            toggleSelection(asset)
                                                        } label: {
                                                            Image(systemName: "xmark.circle.fill")
                                                                .foregroundColor(.red)
                                                                .background(Circle().fill(Color.white))
                                                        }
                                                        .offset(x: 5, y: -5)
                                                    }
                                                }
                                                .scaleEffect(carouselCollapsing ? 0.05 : 1.0)
                                                .offset(x: carouselCollapsing ? -direction * 28 : 0)
                                                .opacity(carouselCollapsing ? 0 : 1)
                                                .onDrag {
                                                    self.draggedAsset = asset
                                                    return NSItemProvider(object: asset.id as NSString)
                                                }
                                                .onDrop(of: [.text], delegate: PhotoAssetDropDelegate(item: asset, items: $selectedAssets, draggedItem: $draggedAsset))
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                }
                                .frame(height: 84)
                                .onChange(of: selectedAssets.count) {
                                    if let last = selectedAssets.last {
                                        withAnimation {
                                            scrollView.scrollTo(last.id, anchor: .trailing)
                                        }
                                    }
                                }
                            }
                        }
                        
                        HStack {
                            if !currentDrafts.isEmpty {
                                Button {
                                    showingDraftHistory = true
                                } label: {
                                    DraftsStackIcon(
                                        drafts: currentDrafts,
                                        cache: photoCollection.cache,
                                        bouncing: stackBouncing
                                    )
                                }
                            } else {
                                Spacer().frame(width: 60)
                            }
                            
                            Spacer()
                            
                            if !selectedAssets.isEmpty {
                                Button {
                                    // Phase 1: collapse the carousel thumbnails inward
                                    withAnimation(.easeIn(duration: 0.28)) {
                                        carouselCollapsing = true
                                    }
                                    // Phase 2: save draft + bounce the stack icon
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                        saveSelectionToDraft()
                                        selectedAssets.removeAll()
                                        stackBouncing = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            stackBouncing = false
                                            carouselCollapsing = false
                                        }
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 40))
                                }
                                .disabled(carouselCollapsing)
                            } else {
                                Spacer().frame(width: 40)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
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
                        if sessionDraftIDs.isEmpty {
                            dismiss()
                        } else {
                            showingExitAlert = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    let canProceed = !selectedAssets.isEmpty || !currentDrafts.isEmpty
                    Button {
                        if !selectedAssets.isEmpty {
                            saveSelectionToDraft()
                        }
                        navigateToOverview = true
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(canProceed ? .green : .secondary)
                    }
                    .disabled(!canProceed)
                }
            }
            .task {
                do {
                    try await photoCollection.load()
                } catch {
                    print("Failed to load photos: \(error)")
                }
            }
            .sheet(isPresented: $showingIdentification) {
                if let id = lastCreatedListingId {
                    IdentificationConfirmationView(listingId: id, images: lastCreatedImages)
                }
            }
            .sheet(isPresented: $showingDraftHistory) {
                DraftHistoryModal(photoCollection: photoCollection)
            }
            .alert("Save Drafts?", isPresented: $showingExitAlert) {
                Button("Discard", role: .destructive) {
                    for draft in allItems where sessionDraftIDs.contains(draft.id) {
                        modelContext.delete(draft)
                    }
                    try? modelContext.save()
                    dismiss()
                }
                Button("Save") {
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You have created drafts in this session. Would you like to save or discard them?")
            }
            .navigationDestination(isPresented: $navigateToOverview) {
                BulkListingOverviewView(selectedAssets: selectedAssets)
            }
        }
        
        private func toggleSelection(_ asset: PhotoAsset) {
            withAnimation {
                if let index = selectedAssets.firstIndex(of: asset) {
                    selectedAssets.remove(at: index)
                } else {
                    selectedAssets.append(asset)
                }
            }
        }
        
        private func saveSelectionToDraft() {
            guard !selectedAssets.isEmpty else { return }

            let assetsToUpload = selectedAssets

            // 1. Save to SwiftData immediately — picker UI updates are instant.
            let newItem = Item(
                blurb: "Draft from \(assetsToUpload.count) selected photos",
                sourceAssetIdentifiers: assetsToUpload.map { $0.id }
            )
            modelContext.insert(newItem)
            try? modelContext.save()
            sessionDraftIDs.append(newItem.id)

            // 2. Kick off background upload via UploadManager (tracks progress, shows pill).
            uploadManager.startBackgroundUpload(draft: newItem, modelContext: modelContext)
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
                            var ids = draft.sourceAssetIdentifiers
                            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                            draft.sourceAssetIdentifiers = ids
                        }
                    }
                }
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            guard let dragged = draggedCompositeId else { return false }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return false }
            let sourceDraftId = parts[0]
            let assetId = parts[1]

            if sourceDraftId != draft.id.uuidString {
                if let sourceDraft = drafts.first(where: { $0.id.uuidString == sourceDraftId }) {
                    var sourceIds = sourceDraft.sourceAssetIdentifiers
                    sourceIds.removeAll(where: { $0 == assetId })
                    sourceDraft.sourceAssetIdentifiers = sourceIds

                    var destIds = draft.sourceAssetIdentifiers
                    if let to = draft.sourceAssetIdentifiers.firstIndex(of: targetAssetId) {
                        destIds.insert(assetId, at: to)
                    } else {
                        destIds.append(assetId)
                    }
                    draft.sourceAssetIdentifiers = destIds
                    try? modelContext.save()
                }
            } else {
                try? modelContext.save()
            }

            draggedCompositeId = nil
            return true
        }
    }
    
    // MARK: - DraftHistoryModal
    struct DraftHistoryModal: View {
        @Environment(\.dismiss) private var dismiss
        @Query private var allItems: [Item]
        @ObservedObject var photoCollection: PhotoCollection
        @Environment(\.modelContext) private var modelContext

        @State private var isSelectionMode = false
        @State private var selectedPhotos = Set<String>()
        @State private var showingDeleteConfirm = false
        @State private var draggedCompositeId: String?

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

                                        HStack {
                                            if isSelectionMode {
                                                Image(systemName: isFullySelected ? "checkmark.circle.fill" : (isPartiallySelected ? "minus.circle.fill" : "circle"))
                                                    .foregroundColor(selectedCount > 0 ? .blue : .gray)
                                                    .font(.title2)
                                                    .onTapGesture {
                                                        if isFullySelected {
                                                            for id in draftCompositeIDs { selectedPhotos.remove(id) }
                                                        } else {
                                                            for id in draftCompositeIDs { selectedPhotos.insert(id) }
                                                        }
                                                    }
                                            }
                                            Text("\(draft.sourceAssetIdentifiers.count) Photos")
                                                .font(.headline)
                                            Spacer()
                                        }
                                        .padding(.horizontal)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 12) {
                                                ForEach(draft.sourceAssetIdentifiers, id: \.self) { assetId in
                                                    let compositeId = "\(draft.id.uuidString)|\(assetId)"
                                                    let asset = PhotoAsset(identifier: assetId)

                                                    ZStack(alignment: .topTrailing) {
                                                        PhotoItemView(asset: asset, cache: photoCollection.cache, imageSize: CGSize(width: 80, height: 80))
                                                            .frame(width: 80, height: 80)
                                                            .cornerRadius(8)
                                                            .onDrag {
                                                                if !isSelectionMode {
                                                                    draggedCompositeId = compositeId
                                                                    return NSItemProvider(object: compositeId as NSString)
                                                                }
                                                                return NSItemProvider()
                                                            }
                                                            .onDrop(of: [.text], delegate: DraftPhotoDropDelegate(
                                                                targetAssetId: assetId,
                                                                draft: draft,
                                                                draggedCompositeId: $draggedCompositeId,
                                                                modelContext: modelContext,
                                                                drafts: drafts
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
                                            }
                                            .padding(.horizontal)
                                        }

                                        Divider()
                                            .padding(.horizontal)
                                    }
                                }
                            }
                            .padding(.top)
                        }
                    }
                }
                .navigationTitle("Drafts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if isSelectionMode {
                            Button("Cancel") {
                                isSelectionMode = false
                                selectedPhotos.removeAll()
                            }
                        } else {
                            Button("Done") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSelectionMode {
                            Button("Delete") {
                                showingDeleteConfirm = true
                            }
                            .foregroundColor(.red)
                            .disabled(selectedPhotos.isEmpty)
                        } else {
                            Button("Select") {
                                isSelectionMode = true
                            }
                        }
                    }
                }
                .alert("Delete Selected?", isPresented: $showingDeleteConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        deleteSelectedItems()
                    }
                } message: {
                    Text("Are you sure you want to delete the selected items?")
                }
            }
        }

        private func deleteSelectedItems() {
            for draft in allItems {
                let draftCompositeIDs = draft.sourceAssetIdentifiers.map { "\(draft.id.uuidString)|\($0)" }
                let selectedCount = draftCompositeIDs.filter { selectedPhotos.contains($0) }.count

                if selectedCount > 0 {
                    if selectedCount == draftCompositeIDs.count {
                        modelContext.delete(draft)
                    } else {
                        var updatedPhotos = draft.sourceAssetIdentifiers
                        updatedPhotos.removeAll { assetId in
                            selectedPhotos.contains("\(draft.id.uuidString)|\(assetId)")
                        }
                        draft.sourceAssetIdentifiers = updatedPhotos
                    }
                }
            }

            try? modelContext.save()
            isSelectionMode = false
            selectedPhotos.removeAll()
        }
    }
    
    // MARK: - BulkListingOverviewView (Drafts)
    struct BulkListingOverviewView: View {
        var selectedAssets: [PhotoAsset]

        @Environment(\.modelContext) private var modelContext
        @Query private var allItems: [Item]
        @EnvironmentObject private var uploadManager: UploadManager

        @FocusState private var focusedField: DraftFocusField?
        @State private var cache = CachedImageManager()
        @State private var showUploadWarning = false
        @State private var navigateToResults = false

        private var drafts: [Item] { allItems.filter { $0.isDraft } }

        var body: some View {
            VStack(spacing: 0) {
                // ── Thin upload progress bar at top ────────────────────────
                if uploadManager.isUploadingPhotos {
                    VStack(spacing: 4) {
                        ProgressView(value: uploadManager.uploadProgress)
                            .tint(.blue)
                            .padding(.horizontal)
                        Text("Uploading photos… \(uploadManager.uploadEtaString.map { $0 } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                                cache: cache
                            )
                            .id(item.id)
                        }
                        .onDelete { offsets in
                            for i in offsets { modelContext.delete(drafts[i]) }
                            try? modelContext.save()
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
            }
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    processButton
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { moveFocus(by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(focusedIndex == nil || focusedIndex == 0)

                    Button { moveFocus(by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(focusedIndex == nil || focusedIndex == (drafts.count * 2 - 1))

                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .navigationDestination(isPresented: $navigateToResults) {
                ProcessResultsOverviewView()
            }
            .onChange(of: uploadManager.showProcessResults) { _, show in
                if show { navigateToResults = true }
            }
            .overlay(alignment: .bottom) {
                if showUploadWarning {
                    Text("Photos need to finish uploading first before processing")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: showUploadWarning)
        }

        // MARK: Process Button
        @ViewBuilder
        private var processButton: some View {
            let uploading = uploadManager.isUploadingPhotos
            let processing = uploadManager.isProcessing
            Button {
                if uploading {
                    withAnimation { showUploadWarning = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation { showUploadWarning = false }
                    }
                } else if !processing && !drafts.isEmpty {
                    uploadManager.processDrafts(drafts: drafts, modelContext: modelContext)
                }
            } label: {
                Text("Process")
                    .fontWeight(.semibold)
                    .foregroundStyle(uploading || processing || drafts.isEmpty ? .secondary : Color.accentColor)
            }
            .disabled(processing || drafts.isEmpty)
        }

        // MARK: Keyboard navigation helpers
        /// Flattened index: row*2 = title field, row*2+1 = price field
        private var focusedIndex: Int? {
            guard let fv = focusedField else { return nil }
            guard let row = drafts.firstIndex(where: { $0.id == fv.itemID }) else { return nil }
            return row * 2 + (fv.field == .title ? 0 : 1)
        }

        private func moveFocus(by delta: Int) {
            guard let current = focusedIndex else { return }
            let next = current + delta
            let maxIndex = drafts.count * 2 - 1
            guard next >= 0 && next <= maxIndex else { return }
            let row = next / 2
            let field: DraftFocusSubfield = (next % 2 == 0) ? .title : .price
            focusedField = DraftFocusField(itemID: drafts[row].id, field: field)
        }
    }

// MARK: - DraftRow (redesigned)
struct DraftRow: View {

        let item: Item
        var focusedField: FocusState<DraftFocusField?>.Binding
        let cache: CachedImageManager

        @Environment(\.modelContext) private var modelContext
        @State private var priceText: String = ""
        @State private var showEditSheet = false

        private var titleBinding: Binding<String> {
            Binding(
                get: { item.userEditedTitle ?? item.aiSuggestedTitle ?? "" },
                set: { item.userEditedTitle = $0.isEmpty ? nil : $0 }
            )
        }

        var body: some View {
            HStack(spacing: 14) {
                // Photo thumbnail
                Group {
                    if let assetId = item.sourceAssetIdentifiers.first {
                        PhotoItemView(
                            asset: PhotoAsset(identifier: assetId),
                            cache: cache,
                            imageSize: CGSize(width: 160, height: 160)
                        )
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.systemGray5))
                            .frame(width: 76, height: 76)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }

                // Title & price fields
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Add title…", text: titleBinding)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(item.userEditedTitle != nil ? .primary : .secondary)
                        .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))
                        .onReceive(NotificationCenter.default.publisher(
                            for: UITextField.textDidBeginEditingNotification
                        )) { notification in
                            guard let tf = notification.object as? UITextField else { return }
                            DispatchQueue.main.async { tf.selectAll(nil) }
                        }
                        .onChange(of: titleBinding.wrappedValue) { _, _ in
                            try? modelContext.save()
                        }

                    HStack(spacing: 3) {
                        Text("$")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Price", text: $priceText)
                            .font(.subheadline)
                            .keyboardType(.decimalPad)
                            .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .price))
                            .onChange(of: priceText) { _, newValue in
                                let cleaned = newValue.filter { $0.isNumber || $0 == "." }
                                item.userEditedPrice = cleaned.isEmpty ? nil : Double(cleaned)
                                try? modelContext.save()
                            }
                    }
                    
                    // Photo count badge
                    if item.sourceAssetIdentifiers.count > 1 {
                        Label("\(item.sourceAssetIdentifiers.count) photos", systemImage: "photo.on.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Edit button → full detail sheet
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .onAppear {
                if let p = item.userEditedPrice {
                    priceText = String(format: "%.2f", p)
                }
            }
            .sheet(isPresented: $showEditSheet) {
                DraftEditSheet(item: item)
            }
        }
    }

    // MARK: - DraftEditSheet (full listing editor)
    struct DraftEditSheet: View {
        let item: Item
        @Environment(\.dismiss) private var dismiss
        @Environment(\.modelContext) private var modelContext

        @State private var title: String = ""
        @State private var priceText: String = ""
        @State private var description: String = ""
        @State private var personalNote: String = ""
        @State private var buyerPaysShipping: Bool = true
        @State private var handlingFee: String = ""
        @State private var estimatedDays: String = ""
        @State private var selectedCondition: ItemCondition = .good
        @State private var tagsText: String = ""

        var body: some View {
            NavigationStack {
                Form {
                    Section("Title & Price") {
                        TextField("Title", text: $title)
                            .font(.body.weight(.medium))
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

                    Section("Shipping") {
                        Toggle("Buyer pays shipping", isOn: $buyerPaysShipping)
                        if !buyerPaysShipping {
                            HStack {
                                Text("Handling fee $")
                                TextField("0.00", text: $handlingFee)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
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
                    }

                    Section("Tags (comma-separated)") {
                        TextField("e.g. photocard, kpop, sealed", text: $tagsText)
                    }

                    Section("Personal Note") {
                        TextField("e.g. stored in basement", text: $personalNote)
                    }
                }
                .navigationTitle("Edit Draft")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            saveToDraft()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
                .onAppear { loadFromDraft() }
            }
        }

        private func loadFromDraft() {
            title = item.userEditedTitle ?? item.aiSuggestedTitle ?? ""
            if let p = item.userEditedPrice {
                priceText = String(format: "%.2f", p)
            }
            description = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
            personalNote = item.personalNote ?? ""
            buyerPaysShipping = item.buyerPaysShipping
            handlingFee = item.handlingFee > 0 ? String(format: "%.2f", item.handlingFee) : ""
            estimatedDays = "\(item.estimatedShippingDays)"
            tagsText = item.tags.joined(separator: ", ")
        }

        private func saveToDraft() {
            item.userEditedTitle = title.isEmpty ? nil : title
            item.userEditedPrice = Double(priceText.filter { $0.isNumber || $0 == "." })
            item.userEditedDescription = description.isEmpty ? nil : description
            item.personalNote = personalNote.isEmpty ? nil : personalNote
            item.buyerPaysShipping = buyerPaysShipping
            item.handlingFee = Double(handlingFee.filter { $0.isNumber || $0 == "." }) ?? 0
            item.estimatedShippingDays = Int(estimatedDays) ?? 3
            item.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try? modelContext.save()
        }
    }

// MARK: - Draft Focus Types (shared between BulkListingOverviewView & ProcessResultsOverviewView)

struct DraftFocusField: Hashable {
    let itemID: UUID
    let field: DraftFocusSubfield
}
enum DraftFocusSubfield: Hashable { case title, price }

// MARK: - ProcessResultsOverviewView


struct ProcessResultsOverviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]
    @EnvironmentObject private var uploadManager: UploadManager

    @State private var cache = CachedImageManager()
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingEditSheet: Item? = nil
    @FocusState private var focusedField: DraftFocusField?

    // Only show the items that went through AI processing
    private var results: [Item] {
        let processedSet = Set(uploadManager.processedItemIDs)
        return allItems.filter { $0.isDraft && processedSet.contains($0.id) }
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
                        focusedField: $focusedField
                    )
                }
                .onDelete { offsets in
                    for i in offsets { modelContext.delete(results[i]) }
                    try? modelContext.save()
                }
            }
            .listStyle(.plain)

            // ── Bottom action bar ────────────────────────────────────────
            Divider()
            HStack(spacing: 16) {
                // Select all / deselect all
                Button(selectedIDs.count == results.count ? "Deselect All" : "Select All") {
                    if selectedIDs.count == results.count {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(results.map { $0.id })
                    }
                }
                .font(.subheadline)

                Spacer()

                // Publish selected
                Button {
                    let toPublish = results.filter { selectedIDs.contains($0.id) }
                    uploadManager.publishDrafts(drafts: toPublish, modelContext: modelContext)
                } label: {
                    Text("Publish \(selectedIDs.isEmpty ? "All" : "\(selectedIDs.count)")")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(results.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("Review & Publish")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { moveFocus(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(focusedIndex == nil || focusedIndex == 0)
                Button { moveFocus(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(focusedIndex == nil || focusedIndex == (results.count * 2 - 1))
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    private func toggleSelection(_ item: Item) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    private var focusedIndex: Int? {
        guard let fv = focusedField else { return nil }
        guard let row = results.firstIndex(where: { $0.id == fv.itemID }) else { return nil }
        return row * 2 + (fv.field == .title ? 0 : 1)
    }

    private func moveFocus(by delta: Int) {
        guard let current = focusedIndex else { return }
        let next = current + delta
        let maxIndex = results.count * 2 - 1
        guard next >= 0 && next <= maxIndex else { return }
        let row = next / 2
        let field: DraftFocusSubfield = (next % 2 == 0) ? .title : .price
        focusedField = DraftFocusField(itemID: results[row].id, field: field)
    }
}

// MARK: - ResultDraftRow

struct ResultDraftRow: View {
    let item: Item
    let cache: CachedImageManager
    let isSelected: Bool
    let onToggle: () -> Void
    var focusedField: FocusState<DraftFocusField?>.Binding

    @Environment(\.modelContext) private var modelContext
    @State private var priceText: String = ""
    @State private var showEditSheet = false

    private var titleBinding: Binding<String> {
        Binding(
            get: { item.userEditedTitle ?? item.aiSuggestedTitle ?? "" },
            set: { item.userEditedTitle = $0.isEmpty ? nil : $0; try? modelContext.save() }
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            // Selection circle
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            // Photo thumbnail
            Group {
                if let assetId = item.sourceAssetIdentifiers.first {
                    PhotoItemView(
                        asset: PhotoAsset(identifier: assetId),
                        cache: cache,
                        imageSize: CGSize(width: 160, height: 160)
                    )
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                        .frame(width: 76, height: 76)
                }
            }

            // AI-populated fields (editable)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: titleBinding)
                    .font(.body.weight(.semibold))
                    .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .title))

                HStack(spacing: 3) {
                    Text("$").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Price", text: $priceText)
                        .font(.subheadline)
                        .keyboardType(.decimalPad)
                        .focused(focusedField, equals: DraftFocusField(itemID: item.id, field: .price))
                        .onChange(of: priceText) { _, v in
                            let cleaned = v.filter { $0.isNumber || $0 == "." }
                            item.userEditedPrice = cleaned.isEmpty ? nil : Double(cleaned)
                            try? modelContext.save()
                        }
                }

                // AI confidence label
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text("AI-identified")
                        .font(.caption2)
                        .foregroundStyle(.purple.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Edit button
            Button { showEditSheet = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .onAppear {
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            DraftEditSheet(item: item)
        }
    }
}

// MARK: - PublishedListingsView

struct PublishedListingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]
    @State private var cache = CachedImageManager()

    private var publishedItems: [Item] { allItems.filter { !$0.isDraft } }

    var body: some View {
        Group {
            if publishedItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("No published listings yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(publishedItems) { item in
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
    @State private var priceText: String = ""

    private var titleBinding: Binding<String> {
        Binding(
            get: { item.userEditedTitle ?? item.aiSuggestedTitle ?? "" },
            set: { item.userEditedTitle = $0; try? modelContext.save() }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { item.userEditedDescription ?? item.aiSuggestedDescription ?? "" },
            set: { item.userEditedDescription = $0; try? modelContext.save() }
        )
    }

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
                TextField("Title…", text: titleBinding)
                    .font(.headline)

                HStack(spacing: 2) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }
                .font(.subheadline)

                TextField("Description…", text: descriptionBinding, axis: .vertical)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2...4)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if let p = item.userEditedPrice ?? item.aiSuggestedPrice {
                priceText = String(format: "%.2f", p)
            }
        }
        .onChange(of: priceText) { _, newValue in
            let cleaned = newValue.filter { $0.isNumber || $0 == "." }
            item.userEditedPrice = cleaned.isEmpty ? nil : Double(cleaned)
            try? modelContext.save()
        }
    }
}
