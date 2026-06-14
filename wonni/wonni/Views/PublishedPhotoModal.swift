import SwiftUI
import PhotosUI

struct PublishedPhotoModal: View {
    @Binding var photos: [EditPhotoItem]
    @Environment(\.dismiss) private var dismiss

    @State private var isSelectionMode = false
    @State private var selectedPhotos = Set<String>()
    @State private var draggedPhotoId: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(photos) { item in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                switch item {
                                case .existing(let path):
                                    StorageImage(path: path)
                                case .new(_, let image):
                                    Image(uiImage: image).resizable().scaledToFill()
                                }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 160, maxHeight: 160)
                            .cornerRadius(8)
                            .clipped()
                            .opacity(selectedPhotos.contains(item.id) ? 0.6 : 1.0)
                            .onDrag({
                                draggedPhotoId = item.id
                                return NSItemProvider(object: item.id as NSString)
                            }, preview: {
                                Group {
                                    switch item {
                                    case .existing(let path):
                                        StorageImage(path: path)
                                    case .new(_, let image):
                                        Image(uiImage: image).resizable().scaledToFill()
                                    }
                                }
                                .frame(width: 160, height: 160)
                                .cornerRadius(8)
                                .clipped()
                            })
                            .onDrop(of: [.text], delegate: PublishedPhotoDropDelegate(
                                item: item,
                                photos: $photos,
                                draggedPhotoId: $draggedPhotoId,
                                selectedPhotos: selectedPhotos
                            ))
                            
                            if isSelectionMode {
                                Image(systemName: selectedPhotos.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedPhotos.contains(item.id) ? .blue : .white)
                                    .background(Circle().fill(Color.black.opacity(0.4)))
                                    .padding(8)
                            }
                        }
                        .onTapGesture {
                            if isSelectionMode {
                                if selectedPhotos.contains(item.id) {
                                    selectedPhotos.remove(item.id)
                                } else {
                                    selectedPhotos.insert(item.id)
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
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if isSelectionMode {
                        HStack {
                            Button(role: .destructive) {
                                photos.removeAll { selectedPhotos.contains($0.id) }
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
        }
        .presentationDetents([.large])
    }
}

struct PublishedPhotoDropDelegate: DropDelegate {
    let item: EditPhotoItem
    @Binding var photos: [EditPhotoItem]
    @Binding var draggedPhotoId: String?
    let selectedPhotos: Set<String>

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedPhotoId, dragged != item.id else { return }
        
        let isGroupDrag = selectedPhotos.contains(dragged)
        let itemsToMove = isGroupDrag ? photos.filter { selectedPhotos.contains($0.id) } : photos.filter { $0.id == dragged }
        
        guard !itemsToMove.contains(item) else { return }
        guard let targetIndex = photos.firstIndex(of: item) else { return }
        
        withAnimation {
            for itemToMove in itemsToMove {
                if let idx = photos.firstIndex(of: itemToMove) {
                    photos.remove(at: idx)
                }
            }
            
            let adjustedTargetIndex = photos.firstIndex(of: item) ?? targetIndex
            photos.insert(contentsOf: itemsToMove, at: adjustedTargetIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPhotoId = nil
        return true
    }
}
