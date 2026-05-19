/*
PhotoStackModalView.swift - Modal for editing photo stacks with drag and drop
*/

import SwiftUI

struct PhotoStackModalView: View {
    @ObservedObject var dataModel: DataModel
    @Binding var isPresented: Bool
    let stackIndex: Int

    @State private var draggedPhoto: (stackIndex: Int, photoIndex: Int)?
    @State private var showingAllStacks = false
    @State private var isTrashTargeted = false
    
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var currentStack: [UIImage] {
        guard stackIndex < dataModel.sessionPhotos.count else { return [] }
        return dataModel.sessionPhotos[stackIndex]
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // Stack selector
                if dataModel.sessionPhotos.count > 1 {
                    stackSelectorView()
                }

                // Photo grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<currentStack.count, id: \.self) { photoIndex in
                            photoGridView(photoIndex: photoIndex)
                        }
                    }
                    .padding()
                }

                Spacer()
            }
            .overlay(alignment: .bottom) {
                if draggedPhoto != nil {
                    stackTrashZone
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: draggedPhoto != nil)
            .navigationTitle("Edit Stack \(stackIndex + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
                
                if dataModel.sessionPhotos.count > 1 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(showingAllStacks ? "Single" : "All") {
                            showingAllStacks.toggle()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAllStacks) {
            AllStacksView(dataModel: dataModel, isPresented: $showingAllStacks)
        }
    }
    
    @ViewBuilder
    private func stackSelectorView() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<dataModel.sessionPhotos.count, id: \.self) { index in
                    Button(action: {
                        // This would need to be handled by the parent view
                        // to change the stackIndex
                    }) {
                        VStack {
                            Text("Stack \(index + 1)")
                                .font(.caption)
                                .foregroundColor(.primary)
                            
                            Text("\(dataModel.sessionPhotos[index].count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index == stackIndex ? Color.blue : Color.gray.opacity(0.2))
                        )
                    }
                    .disabled(index == stackIndex)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func photoGridView(photoIndex: Int) -> some View {
        Image(uiImage: currentStack[photoIndex])
            .resizable()
            .scaledToFill()
            .frame(width: 150, height: 150)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue, lineWidth: draggedPhoto?.stackIndex == stackIndex && draggedPhoto?.photoIndex == photoIndex ? 3 : 0)
            )
            .scaleEffect(draggedPhoto?.stackIndex == stackIndex && draggedPhoto?.photoIndex == photoIndex ? 1.1 : 1.0)
            .onDrag {
                draggedPhoto = (stackIndex: stackIndex, photoIndex: photoIndex)
                return NSItemProvider(object: "\(stackIndex)-\(photoIndex)" as NSString)
            }
            .onDrop(of: [.text], delegate: PhotoDropDelegate(
                stackIndex: stackIndex,
                photoIndex: photoIndex,
                dataModel: dataModel,
                draggedPhoto: $draggedPhoto
            ))
    }

    @ViewBuilder
    private var stackTrashZone: some View {
        HStack {
            Spacer()
            Image(systemName: isTrashTargeted ? "trash.circle.fill" : "trash.circle")
                .font(.system(size: 52))
                .foregroundStyle(isTrashTargeted ? .red : .secondary)
                .scaleEffect(isTrashTargeted ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTrashTargeted)
                .padding(.bottom, 16)
            Spacer()
        }
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .onDrop(of: [.text], isTargeted: $isTrashTargeted) { _ in
            guard let dragged = draggedPhoto else { return false }
            dataModel.removePhoto(stackIndex: dragged.stackIndex, photoIndex: dragged.photoIndex)
            draggedPhoto = nil
            return true
        }
    }
}

struct AllStacksView: View {
    @ObservedObject var dataModel: DataModel
    @Binding var isPresented: Bool

    @State private var draggedPhoto: (stackIndex: Int, photoIndex: Int)?
    @State private var isTrashTargeted = false
    
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(0..<dataModel.sessionPhotos.count, id: \.self) { stackIndex in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Stack \(stackIndex + 1)")
                                    .font(.headline)
                                Spacer()
                                Text("\(dataModel.sessionPhotos[stackIndex].count) photos")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(0..<dataModel.sessionPhotos[stackIndex].count, id: \.self) { photoIndex in
                                    allStacksPhotoView(stackIndex: stackIndex, photoIndex: photoIndex)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .overlay(alignment: .bottom) {
                if draggedPhoto != nil {
                    allStacksTrashZone
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: draggedPhoto != nil)
            .navigationTitle("All Stacks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func allStacksPhotoView(stackIndex: Int, photoIndex: Int) -> some View {
        Image(uiImage: dataModel.sessionPhotos[stackIndex][photoIndex])
            .resizable()
            .scaledToFill()
            .frame(width: 120, height: 120)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue, lineWidth: draggedPhoto?.stackIndex == stackIndex && draggedPhoto?.photoIndex == photoIndex ? 3 : 0)
            )
            .scaleEffect(draggedPhoto?.stackIndex == stackIndex && draggedPhoto?.photoIndex == photoIndex ? 1.1 : 1.0)
            .onDrag {
                draggedPhoto = (stackIndex: stackIndex, photoIndex: photoIndex)
                return NSItemProvider(object: "\(stackIndex)-\(photoIndex)" as NSString)
            }
            .onDrop(of: [.text], delegate: PhotoDropDelegate(
                stackIndex: stackIndex,
                photoIndex: photoIndex,
                dataModel: dataModel,
                draggedPhoto: $draggedPhoto
            ))
    }

    @ViewBuilder
    private var allStacksTrashZone: some View {
        HStack {
            Spacer()
            Image(systemName: isTrashTargeted ? "trash.circle.fill" : "trash.circle")
                .font(.system(size: 52))
                .foregroundStyle(isTrashTargeted ? .red : .secondary)
                .scaleEffect(isTrashTargeted ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTrashTargeted)
                .padding(.bottom, 16)
            Spacer()
        }
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .onDrop(of: [.text], isTargeted: $isTrashTargeted) { _ in
            guard let dragged = draggedPhoto else { return false }
            dataModel.removePhoto(stackIndex: dragged.stackIndex, photoIndex: dragged.photoIndex)
            draggedPhoto = nil
            return true
        }
    }
}

struct PhotoDropDelegate: DropDelegate {
    let stackIndex: Int
    let photoIndex: Int
    let dataModel: DataModel
    @Binding var draggedPhoto: (stackIndex: Int, photoIndex: Int)?
    
    func performDrop(info: DropInfo) -> Bool {
        draggedPhoto = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggedPhoto = draggedPhoto else { return }
        
        if draggedPhoto.stackIndex == stackIndex {
            // Moving within the same stack
            if draggedPhoto.photoIndex != photoIndex {
                dataModel.movePhotoWithinStack(
                    stackIndex: stackIndex,
                    from: draggedPhoto.photoIndex,
                    to: photoIndex
                )
                self.draggedPhoto?.photoIndex = photoIndex
            }
        } else {
            // Moving between different stacks
            dataModel.movePhotoBetweenStacks(
                fromStack: draggedPhoto.stackIndex,
                fromIndex: draggedPhoto.photoIndex,
                toStack: stackIndex,
                toIndex: photoIndex
            )
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}
