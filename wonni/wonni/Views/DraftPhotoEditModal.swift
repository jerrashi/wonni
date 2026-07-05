import SwiftUI
import PhotosUI
import FirebaseAuth

struct DraftPhotoEditModal: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var localAssetIds: [String] = []
    @State private var isSelectionMode = false
    @State private var selectedPhotos = Set<String>()
    @State private var draggedAssetId: String? = nil
    
    @State private var cache = CachedImageManager()

    var hasChanges: Bool {
        localAssetIds != item.sourceAssetIdentifiers
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(localAssetIds, id: \.self) { assetId in
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
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 160, maxHeight: 160)
                            .cornerRadius(8)
                            .clipped()
                            .opacity(selectedPhotos.contains(assetId) ? 0.6 : 1.0)
                            .onDrag({
                                draggedAssetId = assetId
                                return NSItemProvider(object: assetId as NSString)
                            }, preview: {
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
                                .frame(width: 160, height: 160)
                                .cornerRadius(8)
                                .clipped()
                            })
                            .onDrop(of: [.text], delegate: DraftPhotoEditDropDelegate(
                                assetId: assetId,
                                localAssetIds: $localAssetIds,
                                draggedAssetId: $draggedAssetId,
                                selectedPhotos: selectedPhotos
                            ))
                            
                            if isSelectionMode {
                                Image(systemName: selectedPhotos.contains(assetId) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedPhotos.contains(assetId) ? .blue : .white)
                                    .background(Circle().fill(Color.black.opacity(0.4)))
                                    .padding(8)
                            }
                        }
                        .onTapGesture {
                            if isSelectionMode {
                                if selectedPhotos.contains(assetId) {
                                    selectedPhotos.remove(assetId)
                                } else {
                                    selectedPhotos.insert(assetId)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Edit Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                    Button("Save") {
                        if hasChanges {
                            syncChangesToItem()
                        }
                        dismiss()
                    }
                    .disabled(!hasChanges && !isSelectionMode)
                }
                ToolbarItem(placement: .bottomBar) {
                    if isSelectionMode {
                        HStack {
                            Button(role: .destructive) {
                                localAssetIds.removeAll { selectedPhotos.contains($0) }
                                selectedPhotos.removeAll()
                                isSelectionMode = false
                            } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(selectedPhotos.isEmpty)
                        }
                    }
                }
            }
            .onAppear {
                localAssetIds = item.sourceAssetIdentifiers
            }
        }
        .presentationDetents([.large])
    }

    private func syncChangesToItem() {
        let removedAssetIds = Set(item.sourceAssetIdentifiers).subtracting(localAssetIds)
        let pathsToDelete = removedAssetIds.compactMap { item.firebasePhotoPathsByAsset?[$0] }

        var newPhotosData: [Data] = []
        for assetId in localAssetIds {
            if let idx = item.sourceAssetIdentifiers.firstIndex(of: assetId) {
                if idx < item.photosData.count {
                    newPhotosData.append(item.photosData[idx])
                }
            }
        }

        item.sourceAssetIdentifiers = localAssetIds
        if item.isLocalPhotoOnly || !item.photosData.isEmpty {
            item.photosData = newPhotosData
        }
        for assetId in removedAssetIds {
            item.firebasePhotoPathsByAsset?.removeValue(forKey: assetId)
        }

        try? modelContext.save()

        guard !pathsToDelete.isEmpty, let userId = Auth.auth().currentUser?.uid else { return }
        Task {
            for path in pathsToDelete {
                do {
                    try await StorageService.shared.deletePhoto(path: path, userId: userId)
                } catch {
                    print("[DraftPhotoEditModal] Failed to delete photo at \(path): \(error)")
                    await MainActor.run {
                        UploadManager.shared.cleanupError = "Couldn't fully delete a removed photo. It may still be using storage."
                    }
                }
            }
        }
    }
}

struct DraftPhotoEditDropDelegate: DropDelegate {
    let assetId: String
    @Binding var localAssetIds: [String]
    @Binding var draggedAssetId: String?
    let selectedPhotos: Set<String>

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedAssetId, dragged != assetId else { return }
        
        let isGroupDrag = selectedPhotos.contains(dragged)
        let itemsToMove = isGroupDrag ? localAssetIds.filter { selectedPhotos.contains($0) } : [dragged]
        
        guard !itemsToMove.contains(assetId) else { return }
        guard let targetIndex = localAssetIds.firstIndex(of: assetId) else { return }
        
        withAnimation {
            for itemToMove in itemsToMove {
                if let idx = localAssetIds.firstIndex(of: itemToMove) {
                    localAssetIds.remove(at: idx)
                }
            }
            
            let adjustedTargetIndex = localAssetIds.firstIndex(of: assetId) ?? targetIndex
            localAssetIds.insert(contentsOf: itemsToMove, at: adjustedTargetIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedAssetId = nil
        return true
    }
}
