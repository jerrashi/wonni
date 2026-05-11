//
//  CreateListingView.swift
//  wonni
//

import SwiftUI
import Photos
import UniformTypeIdentifiers
import FirebaseFirestore
import FirebaseAuth



struct DraftsStackIcon: View {
    var drafts: [UserListing]
    var cache: CachedImageManager
    /// Drives the spring bounce when a new draft is received.
    var bouncing: Bool = false

    private var coverAsset: PhotoAsset? {
        drafts.last
            .flatMap { $0.sourceAssetIdentifiers.first }
            .map { PhotoAsset(identifier: $0) }
    }

    var body: some View {
        ZStack {
            // Back card 2 (furthest)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray4))
                .frame(width: 35, height: 45)
                .rotationEffect(.degrees(-12), anchor: .bottom)
                .offset(x: -4, y: 0)

            // Back card 1
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray3))
                .frame(width: 35, height: 45)
                .rotationEffect(.degrees(-5), anchor: .bottom)
                .offset(x: -2, y: 0)

            // Top card — most recent draft's cover photo
            Group {
                if let asset = coverAsset {
                    PhotoItemView(asset: asset, cache: cache, imageSize: CGSize(width: 70, height: 90))
                        .scaledToFill()
                        .frame(width: 35, height: 45)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray2))
                        .frame(width: 35, height: 45)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
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
        @State private var sessionDraftIDs: [String] = []
        @State private var showingExitAlert = false
        @Environment(\.dismiss) private var dismiss
        
        @StateObject private var repository = ListingRepository.shared
        @State private var firestoreDrafts: [UserListing] = []
        @State private var listener: ListenerRegistration?
        
        @State private var draggedAsset: PhotoAsset?
        /// Phase 1: carousel thumbnails collapse inward
        @State private var carouselCollapsing = false
        /// Phase 2: DraftsStackIcon spring-bounces to confirm receipt
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
            let currentDrafts = firestoreDrafts
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
                if !currentUsedAssetIDs.isEmpty {
                    Toggle(isOn: $hidePreviouslySelected) {
                        HStack {
                            Image(systemName: hidePreviouslySelected ? "eye.slash" : "eye")
                            Text("Hide previously selected")
                        }
                        .font(.subheadline)
                    }
                    .disabled(photoCollection.photoAssets.count > 50000)
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
            .onAppear {
                startListening()
            }
            .onDisappear {
                listener?.remove()
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
                    if !selectedAssets.isEmpty || !currentDrafts.isEmpty {
                        Button {
                            if !selectedAssets.isEmpty {
                                saveSelectionToDraft()
                            }
                            navigateToOverview = true
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                        }
                    }
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
                    Task {
                        for id in sessionDraftIDs {
                            try? await repository.deleteListing(id: id)
                        }
                        await MainActor.run {
                            dismiss()
                        }
                    }
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
            
            // 1. Clear selection and trigger animation immediately
            selectedAssets.removeAll()
            
            Task {
                var photoPaths: [String] = []
                var imagesToProcess: [UIImage] = []
                
                // 2. Fetch and upload each image
                for asset in assetsToUpload {
                    if let image = await asset.fullResolutionImage() {
                        imagesToProcess.append(image)
                        if let path = try? await StorageService.shared.uploadTempImage(image: image) {
                            photoPaths.append(path)
                        }
                    }
                }
                
                // 3. Create the draft with the uploaded paths
                let newListing = UserListing.newDraft(
                    userId: userId,
                    sourceAssetIdentifiers: assetsToUpload.map { $0.id }
                )
                var listingWithPhotos = newListing
                listingWithPhotos.photoPaths = photoPaths
                listingWithPhotos.coverPhotoPath = photoPaths.first
                
                do {
                    let docId = try await repository.saveDraft(listingWithPhotos)
                    await MainActor.run {
                        self.lastCreatedListingId = docId
                        self.lastCreatedImages = imagesToProcess
                        self.sessionDraftIDs.append(docId)
                        self.showingIdentification = true
                    }
                } catch {
                    print("Error saving draft with photos: \(error.localizedDescription)")
                }
            }
        }
        
        private func startListening() {
            listener = repository.draftsPublisher { result in
                switch result {
                case .success(let drafts):
                    self.firestoreDrafts = drafts
                case .failure(let error):
                    print("Error listening for drafts: \(error.localizedDescription)")
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
        let draft: UserListing
        @Binding var draggedCompositeId: String?
        let drafts: [UserListing]
        
        func dropEntered(info: DropInfo) {
            guard let dragged = draggedCompositeId else { return }
            let parts = dragged.components(separatedBy: "|")
            guard parts.count == 2 else { return }
            let sourceDraftId = parts[0]
            let assetId = parts[1]
            
            if sourceDraftId == draft.id {
                if assetId != targetAssetId {
                    if let from = draft.sourceAssetIdentifiers.firstIndex(of: assetId),
                       let to = draft.sourceAssetIdentifiers.firstIndex(of: targetAssetId) {
                        withAnimation {
                            var updatedDraft = draft
                            var ids = draft.sourceAssetIdentifiers
                            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                            updatedDraft.sourceAssetIdentifiers = ids
                            
                            // Optimistic UI or wait for Task
                            Task {
                                try? await ListingRepository.shared.saveDraft(updatedDraft)
                            }
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
            
            if sourceDraftId != draft.id {
                if let sourceDraft = drafts.first(where: { $0.id == sourceDraftId }) {
                    var updatedSource = sourceDraft
                    updatedSource.sourceAssetIdentifiers.removeAll(where: { $0 == assetId })
                    
                    var updatedDest = draft
                    if let to = draft.sourceAssetIdentifiers.firstIndex(of: targetAssetId) {
                        updatedDest.sourceAssetIdentifiers.insert(assetId, at: to)
                    } else {
                        updatedDest.sourceAssetIdentifiers.append(assetId)
                    }
                    
                    Task {
                        try? await ListingRepository.shared.saveDraft(updatedSource)
                        try? await ListingRepository.shared.saveDraft(updatedDest)
                    }
                }
            }
            
            draggedCompositeId = nil
            return true
        }
    }
    
    // MARK: - DraftHistoryModal
    struct DraftHistoryModal: View {
        @Environment(\.dismiss) private var dismiss
        @ObservedObject var photoCollection: PhotoCollection
        @StateObject private var repository = ListingRepository.shared
        
        @State private var drafts: [UserListing] = []
        @State private var listener: ListenerRegistration?
        @State private var isSelectionMode = false
        @State private var selectedPhotos = Set<String>()
        @State private var showingDeleteConfirm = false
        @State private var draggedCompositeId: String?
        
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
                                        let draftId = draft.id ?? ""
                                        let draftCompositeIDs = draft.sourceAssetIdentifiers.map { "\(draftId)|\($0)" }
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
                                                    let compositeId = "\(draftId)|\(assetId)"
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
                .onAppear {
                    listener = repository.draftsPublisher { result in
                        if case .success(let drafts) = result {
                            self.drafts = drafts
                        }
                    }
                }
                .onDisappear {
                    listener?.remove()
                }
                .alert("Delete Photos?", isPresented: $showingDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        deleteSelectedItems()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Are you sure you want to delete the selected items?")
                }
            }
        }
        
        private func deleteSelectedItems() {
            Task {
                for draft in drafts {
                    let draftId = draft.id ?? ""
                    let draftCompositeIDs = draft.sourceAssetIdentifiers.map { "\(draftId)|\($0)" }
                    let selectedForThisDraft = draftCompositeIDs.filter { selectedPhotos.contains($0) }
                    
                    if !selectedForThisDraft.isEmpty {
                        if selectedForThisDraft.count == draftCompositeIDs.count {
                            try? await repository.deleteListing(id: draftId)
                        } else {
                            var updatedDraft = draft
                            updatedDraft.sourceAssetIdentifiers.removeAll { assetId in
                                selectedPhotos.contains("\(draftId)|\(assetId)")
                            }
                            try? await repository.saveDraft(updatedDraft)
                        }
                    }
                }
                
                await MainActor.run {
                    isSelectionMode = false
                    selectedPhotos.removeAll()
                }
            }
        }
    }
    
    // MARK: - BulkListingOverviewView
    struct BulkListingOverviewView: View {
        var selectedAssets: [PhotoAsset]
        @State private var selection = Set<String>()
        @State private var showingBulkEdit = false
        @StateObject private var repository = ListingRepository.shared
        
        @State private var drafts: [UserListing] = []
        @State private var listener: ListenerRegistration?
        
        var body: some View {
            List(selection: $selection) {
                ForEach(drafts) { item in
                    HStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                            .overlay(Text("\(item.sourceAssetIdentifiers.count) img").font(.caption2))
                        
                        VStack(alignment: .leading) {
                            Text(item.customTitle ?? "New Draft Item")
                                .font(.headline)
                            Text(item.customDescription ?? "No description")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    .tag(item.id ?? "")
                }
            }
            .navigationTitle("Bulk Overview")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button("Delete") {
                            deleteSelected()
                        }
                        .disabled(selection.isEmpty)
                        .foregroundColor(.red)
                        
                        Spacer()
                        
                        Button("Bulk Edit") {
                            showingBulkEdit = true
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingBulkEdit) {
                BulkEditModal(selection: $selection, drafts: drafts)
            }
            .onAppear {
                startListening()
                
                // If we came from the picker with new photos but no drafts exist yet
                if drafts.isEmpty && !selectedAssets.isEmpty {
                    let userId = Auth.auth().currentUser?.uid ?? "anonymous"
                    let newListing = UserListing.newDraft(
                        userId: userId,
                        sourceAssetIdentifiers: selectedAssets.map { $0.id }
                    )
                    Task {
                        try? await repository.saveDraft(newListing)
                    }
                }
            }
            .onDisappear {
                listener?.remove()
            }
        }
        
        private func startListening() {
            listener = repository.draftsPublisher { result in
                if case .success(let drafts) = result {
                    self.drafts = drafts
                }
            }
        }
        
        private func deleteSelected() {
            Task {
                for id in selection {
                    try? await repository.deleteListing(id: id)
                }
                await MainActor.run {
                    selection.removeAll()
                }
            }
        }
    }
    
    // MARK: - BulkEditModal
    struct BulkEditModal: View {
        @Binding var selection: Set<String>
        let drafts: [UserListing]
        @Environment(\.dismiss) private var dismiss
        @StateObject private var repository = ListingRepository.shared
        
        @State private var appendDescription = ""
        @State private var buyerPaysShipping = true
        @State private var handlingFee: Double = 0.0
        
        var body: some View {
            NavigationStack {
                Form {
                    Section(header: Text("Description")) {
                        TextField("Append to description...", text: $appendDescription, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    
                    Section(header: Text("Shipping Rules")) {
                        Toggle("Buyer Pays Shipping", isOn: $buyerPaysShipping)
                        HStack {
                            Text("Handling Fee")
                            Spacer()
                            TextField("$0.00", value: $handlingFee, format: .currency(code: "USD"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    
                    Section {
                        Button("Apply Changes") {
                            applyChanges()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .navigationTitle("Bulk Edit (\(selection.count))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        
        private func applyChanges() {
            Task {
                for id in selection {
                    if var draft = drafts.first(where: { $0.id == id }) {
                        if !appendDescription.isEmpty {
                            let current = draft.customDescription ?? ""
                            draft.customDescription = current.isEmpty ? appendDescription : (current + "\n" + appendDescription)
                        }
                        
                        var shipping = draft.shippingInfo ?? ShippingInfo(buyerPaysShipping: buyerPaysShipping, handlingFee: handlingFee, estimatedShippingDays: 3)
                        shipping.buyerPaysShipping = buyerPaysShipping
                        shipping.handlingFee = handlingFee
                        draft.shippingInfo = shipping
                        
                        try? await repository.saveDraft(draft)
                    }
                }
                await MainActor.run {
                    selection.removeAll()
                }
            }
        }
    }
