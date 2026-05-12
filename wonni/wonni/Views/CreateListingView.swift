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

        @StateObject private var repository = ListingRepository.shared

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
            
            // Invisible navigation link to fix navigation stack pushing issues
            NavigationLink(destination: BulkListingOverviewView(selectedAssets: selectedAssets), isActive: $navigateToOverview) {
                EmptyView()
            }
            .hidden()
            
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
                                .onChange(of: selectedAssets.count) { _ in
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
            let userId = Auth.auth().currentUser?.uid ?? "anonymous"

            // Save to SwiftData immediately — picker UI updates are instant.
            let newItem = Item(
                blurb: "Draft from \(assetsToUpload.count) selected photos",
                sourceAssetIdentifiers: assetsToUpload.map { $0.id }
            )
            modelContext.insert(newItem)
            try? modelContext.save()
            sessionDraftIDs.append(newItem.id)

            // Upload to Firebase Storage + Firestore in background for AI/publish flow.
            Task {
                var photoPaths: [String] = []
                var imagesToProcess: [UIImage] = []

                for asset in assetsToUpload {
                    if let image = await asset.fullResolutionImage() {
                        imagesToProcess.append(image)
                        if let path = try? await StorageService.shared.uploadTempImage(image: image) {
                            photoPaths.append(path)
                        }
                    }
                }

                var listing = UserListing.newDraft(userId: userId, sourceAssetIdentifiers: assetsToUpload.map { $0.id })
                listing.photoPaths = photoPaths
                listing.coverPhotoPath = photoPaths.first

                do {
                    let docId = try await repository.saveDraft(listing)
                    await MainActor.run {
                        self.lastCreatedListingId = docId
                        self.lastCreatedImages = imagesToProcess
                        self.showingIdentification = true
                    }
                } catch {
                    print("Error saving draft to Firestore: \(error.localizedDescription)")
                }
            }
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

        @FocusState private var focusedID: UUID?
        @State private var cache = CachedImageManager()

        private var drafts: [Item] { allItems.filter { $0.isDraft } }

        var body: some View {
            List {
                ForEach(drafts) { item in
                    DraftRow(item: item, focusedID: $focusedID, cache: cache)
                }
                .onDelete { offsets in
                    for i in offsets { modelContext.delete(drafts[i]) }
                    try? modelContext.save()
                }
            }
            .listStyle(.plain)
            .navigationTitle("Drafts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Upload All") {
                        uploadManager.startUpload(drafts: drafts, modelContext: modelContext)
                        uploadManager.shouldReturnToRoot = true
                    }
                    .disabled(drafts.isEmpty || uploadManager.isPillVisible)
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { moveFocus(by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(focusedIndex.map { $0 == 0 } ?? true)

                    Button { moveFocus(by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(focusedIndex.map { $0 == drafts.count - 1 } ?? true)

                    Spacer()

                    Button("Done") { focusedID = nil }
                }
            }
            .task {
                for item in drafts where item.aiSuggestedTitle == nil {
                    item.aiSuggestedTitle = await classifyFirstImage(for: item) ?? "Item"
                    try? modelContext.save()
                }
            }
            .onChange(of: focusedID) { oldID, _ in
                if oldID != nil { try? modelContext.save() }
            }
            .onAppear {
                if drafts.isEmpty && !selectedAssets.isEmpty {
                    let newItem = Item(
                        blurb: "Draft from selected photos",
                        sourceAssetIdentifiers: selectedAssets.map { $0.id }
                    )
                    modelContext.insert(newItem)
                    try? modelContext.save()
                }
            }
        }

        private var focusedIndex: Int? {
            guard let id = focusedID else { return nil }
            return drafts.firstIndex { $0.id == id }
        }

        private func moveFocus(by delta: Int) {
            guard let idx = focusedIndex else { return }
            let next = idx + delta
            guard next >= 0 && next < drafts.count else { return }
            focusedID = drafts[next].id
        }

        private func classifyFirstImage(for item: Item) async -> String? {
            guard let assetId = item.sourceAssetIdentifiers.first else { return nil }
            guard let image = await PhotoAsset(identifier: assetId).fullResolutionImage(),
                  let cgImage = image.cgImage else { return nil }

            return await Task.detached(priority: .userInitiated) {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                // OCR first — brand names / text on the object are most specific
                let ocrRequest = VNRecognizeTextRequest()
                ocrRequest.recognitionLevel = .accurate
                ocrRequest.usesLanguageCorrection = false
                let classifyRequest = VNClassifyImageRequest()
                try? handler.perform([ocrRequest, classifyRequest])

                let ocrText = (ocrRequest.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { $0.count > 2 && $0.count < 50 }
                    .prefix(2)
                    .joined(separator: " · ")
                if !ocrText.isEmpty { return ocrText }

                // Classifier fallback — lower threshold catches specific labels before generic ones
                let skipLabels: Set<String> = [
                    "people", "person", "adult", "man", "woman", "child", "indoor", "outdoor",
                    "nature", "object", "item", "thing", "animal", "food", "vehicle", "plant",
                    "building", "interior", "exterior", "surface", "text", "number", "furniture"
                ]
                let top = (classifyRequest.results as? [VNClassificationObservation] ?? [])
                    .filter { $0.confidence > 0.08 }
                    .compactMap { obs -> String? in
                        let raw = (obs.identifier.components(separatedBy: ",").first ?? obs.identifier)
                            .replacingOccurrences(of: "_", with: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let label = raw.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
                        return skipLabels.contains(label.lowercased()) ? nil : label
                    }
                    .prefix(3)
                return top.isEmpty ? nil : top.joined(separator: " · ")
            }.value
        }
    }

    // MARK: - DraftRow
    struct DraftRow: View {
        let item: Item
        var focusedID: FocusState<UUID?>.Binding
        let cache: CachedImageManager

        @Environment(\.modelContext) private var modelContext
        @State private var priceText: String = ""
        @State private var showingPriceField = false

        private var isUserEdited: Bool { item.userEditedTitle != nil }

        private var titleBinding: Binding<String> {
            Binding(
                get: { item.userEditedTitle ?? item.aiSuggestedTitle ?? "" },
                set: { item.userEditedTitle = $0 }
            )
        }

        var body: some View {
            HStack(spacing: 12) {
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
                    // Title row — pencil signals editability
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        TextField("Add title…", text: titleBinding)
                            .font(.headline)
                            .foregroundStyle(isUserEdited ? Color.primary : Color.secondary)
                            .focused(focusedID, equals: item.id)
                            // Select all text when this field becomes active so typing
                            // immediately replaces the AI suggestion
                            .onReceive(NotificationCenter.default.publisher(
                                for: UITextField.textDidBeginEditingNotification
                            )) { notification in
                                guard let tf = notification.object as? UITextField else { return }
                                DispatchQueue.main.async { tf.selectAll(nil) }
                            }
                    }

                    // Price: tap $ to reveal field; auto-hides when cleared
                    if showingPriceField || item.userEditedPrice != nil {
                        HStack(spacing: 4) {
                            Text("$")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("0.00", text: $priceText)
                                .font(.subheadline)
                                .keyboardType(.decimalPad)
                        }
                    } else {
                        Button {
                            showingPriceField = true
                        } label: {
                            Image(systemName: "dollarsign.circle")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
            .onAppear {
                if let p = item.userEditedPrice {
                    priceText = String(format: "%.2f", p)
                    showingPriceField = true
                }
            }
            .onChange(of: priceText) { _, newValue in
                let cleaned = newValue.filter { $0.isNumber || $0 == "." }
                if cleaned.isEmpty {
                    item.userEditedPrice = nil
                    showingPriceField = false
                } else {
                    item.userEditedPrice = Double(cleaned)
                }
                try? modelContext.save()
            }
        }
    }

// MARK: - UploadingView

struct UploadingView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.dismiss) private var dismiss

    private var allDone: Bool {
        !uploadManager.statuses.isEmpty &&
        uploadManager.statuses.values.allSatisfy {
            switch $0 { case .done, .failed: return true; default: return false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Overall progress header
            VStack(spacing: 8) {
                ProgressView(value: uploadManager.overallProgress)
                    .tint(allDone ? .green : .blue)
                    .padding(.horizontal, 20)

                if allDone {
                    Label("Upload complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                } else {
                    HStack(spacing: 4) {
                        Text("Uploading \(uploadManager.currentIndex) of \(uploadManager.totalCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let eta = uploadManager.etaString {
                            Text("· \(eta)")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !uploadManager.currentDraftName.isEmpty {
                        Text(uploadManager.currentDraftName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 20)

            Divider()

            // Per-draft status list
            List {
                ForEach(uploadManager.orderedDraftIDs, id: \.self) { id in
                    let name = uploadManager.draftNames[id] ?? "Draft"
                    let status = uploadManager.statuses[id] ?? .pending
                    let errorMsg = uploadManager.uploadErrors[id]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 14) {
                            StatusIconView(status: status)
                                .frame(width: 28, height: 28)
                            Text(name)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            if case .uploading(let p) = status {
                                Text("\(Int(p * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let err = errorMsg {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.leading, 42)
                        }
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Action buttons
            VStack(spacing: 12) {
                if allDone {
                    NavigationLink {
                        PublishedListingsView()
                    } label: {
                        Label("View Published Listings", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button {
                    dismiss()
                } label: {
                    Label(
                        allDone ? "Done" : "Minimize to pill",
                        systemImage: allDone ? "checkmark" : "minus.circle.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(allDone ? Color(.systemGray5) : Color.accentColor)
                    .foregroundStyle(allDone ? Color.primary : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .navigationTitle("Uploading")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !allDone {
                    Button("Cancel") {
                        uploadManager.cancel()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
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
