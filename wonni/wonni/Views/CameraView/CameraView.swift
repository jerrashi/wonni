/*
CameraView.swift
*/

import SwiftUI
import SwiftData

struct CameraView: View {
    @StateObject private var model = DataModel()
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]

    @State private var isFlashing = false
    @State private var showingDraftHistory = false   // replaces PhotoStackModalView
    @State private var showingPicker = false
    @State private var navigatingToDrafts = false
    @State private var stackBouncing = false
    @State private var draggedSessionPhoto: SessionPhotoID? = nil  // for carousel D&D
    @AppStorage("showCameraGrid") private var showGrid: Bool = false

    // All SwiftData drafts — shared with picker, no session filter
    private var allDrafts: [Item] {
        allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty }
    }

    // True when the session has at least one captured photo
    private var hasSessionPhotos: Bool {
        model.sessionPhotos.contains { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let screenW = geo.size.width
                let safeTop = geo.safeAreaInsets.top
                let safeBottom = geo.safeAreaInsets.bottom

                // Viewfinder fills the full width at a 4:3 aspect ratio
                let viewfinderH = screenW * (4.0 / 3.0)
                // Top bar height: real safe area inset + button row height
                let topBarH: CGFloat = safeTop + 56

                ZStack(alignment: .top) {
                    // 1. Full black background
                    Color.black.ignoresSafeArea()

                    // 2. Viewfinder placed directly below the top bar
                    ViewfinderView(image: $model.viewfinderImage)
                        .frame(width: screenW, height: viewfinderH)
                        .clipped()
                        .overlay {
                            if showGrid { CameraGridOverlay() }
                        }
                        .overlay {
                            if isFlashing {
                                Color.white.opacity(0.8)
                                    .onAppear {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                            withAnimation(.easeOut(duration: 0.15)) { isFlashing = false }
                                        }
                                    }
                            }
                        }
                        .offset(y: topBarH)

                    // 3. Top bar — safe-area-aware
                    topBarView(safeTop: safeTop)
                        .frame(height: topBarH)
                        .frame(maxWidth: .infinity)

                    // 4. Bottom controls pinned to the screen bottom.
                    //    Space above this (between viewfinder bottom and controls)
                    //    is reserved for the future drafts scroll view.
                    VStack(spacing: 8) {
                        // Session carousel OR draft thumbnails row
                        bottomPanelContent()
                        // Shutter bar
                        cameraButtonsView()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, safeBottom + 12)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await model.camera.start()
                await model.loadPhotos()
                await model.loadThumbnail()
            }
            // DraftHistoryModal — same sheet used by photo picker view
            .sheet(isPresented: $showingDraftHistory) {
                CustomPhotoPickerView.DraftHistoryModal(photoCollection: model.photoCollection)
            }
            .navigationDestination(isPresented: $showingPicker) {
                CustomPhotoPickerView()
                    .onAppear { model.camera.isPreviewPaused = true }
                    .onDisappear { model.camera.isPreviewPaused = false }
            }
            .navigationDestination(isPresented: $navigatingToDrafts) {
                BulkListingOverviewView(sessionDraftIDs: uploadManager.sessionDraftIDs)
                    .onAppear { model.camera.isPreviewPaused = true }
                    .onDisappear { model.camera.isPreviewPaused = false }
            }
            .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
                if should {
                    navigatingToDrafts = false
                    uploadManager.shouldReturnToRoot = false
                    uploadManager.selectedTab = 4
                }
            }
        }
    }

    // MARK: - Top bar

    private func topBarView(safeTop: CGFloat) -> some View {
        HStack(alignment: .center) {
            Button {
                uploadManager.selectedTab = 0
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Back")
                        .font(.body.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
            }

            Spacer()

            let hasPhotos = hasSessionPhotos || !allDrafts.isEmpty
            if hasPhotos {
                Button {
                    Task {
                        if hasSessionPhotos {
                            _ = await model.commitStacksAsDrafts(modelContext: modelContext, uploadManager: uploadManager)
                        }
                        navigatingToDrafts = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Proceed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, safeTop + 8)
    }

    // MARK: - Bottom panel content

    @ViewBuilder
    private func bottomPanelContent() -> some View {
        if hasSessionPhotos {
            // Active session: flat drag-to-reorder carousel (same as photo picker)
            sessionPhotoCarousel()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !allDrafts.isEmpty {
            // No active session: show committed draft thumbnails
            draftThumbnailsRow()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Session photo carousel (flat, all stacks, draggable)

    @ViewBuilder
    private func sessionPhotoCarousel() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.sessionPhotos.indices, id: \.self) { stackIdx in
                    let photos = model.sessionPhotos[stackIdx]
                    if !photos.isEmpty {
                        // Stack divider (not before first stack)
                        if stackIdx > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 1, height: 64)
                                .padding(.horizontal, 6)
                        }

                        HStack(spacing: 8) {
                            ForEach(photos.indices, id: \.self) { photoIdx in
                                let pid = SessionPhotoID(stackIdx: stackIdx, photoIdx: photoIdx)
                                sessionPhotoCell(image: photos[photoIdx], id: pid)
                            }
                        }
                    }
                }

                // Committed draft thumbnails shown at the end of the carousel
                if !allDrafts.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: 64)
                        .padding(.horizontal, 8)

                    ForEach(allDrafts) { draft in
                        DraftStackThumbnailView(draft: draft, cache: model.photoCollection.cache)
                            .scaleEffect(stackBouncing ? 1.08 : 1.0)
                            .animation(.spring(response: 0.35, dampingFraction: 0.45), value: stackBouncing)
                            .onTapGesture { showingDraftHistory = true }
                            .padding(.leading, 4)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .frame(height: 94)
    }

    @ViewBuilder
    private func sessionPhotoCell(image: UIImage, id: SessionPhotoID) -> some View {
        let isDragged = draggedSessionPhoto == id

        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .cornerRadius(10)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.8), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 2)
            .opacity(isDragged ? 0.4 : 1.0)
            .scaleEffect(isDragged ? 0.92 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragged)
            .onDrag {
                draggedSessionPhoto = id
                return NSItemProvider(object: "\(id.stackIdx)|\(id.photoIdx)" as NSString)
            }
            .onDrop(of: [.text], delegate: SessionPhotoDropDelegate(
                target: id,
                model: model,
                draggedPhoto: $draggedSessionPhoto
            ))
    }

    // MARK: - Draft-only thumbnails row (no active session)

    @ViewBuilder
    private func draftThumbnailsRow() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(allDrafts) { draft in
                    DraftStackThumbnailView(draft: draft, cache: model.photoCollection.cache)
                        .onTapGesture { showingDraftHistory = true }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 88)
    }

    // MARK: - Bottom camera buttons

    private func cameraButtonsView() -> some View {
        HStack(spacing: 0) {
            // Gallery / picker button
            Button {
                Task {
                    if hasSessionPhotos {
                        _ = await model.commitStacksAsDrafts(modelContext: modelContext, uploadManager: uploadManager)
                    }
                    showingPicker = true
                }
            } label: {
                ThumbnailView(image: model.thumbnailImage)
                    .frame(width: 46, height: 46)
                    .cornerRadius(8)
            }
            .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
                if should {
                    showingPicker = false
                    uploadManager.shouldReturnToRoot = false
                    uploadManager.selectedTab = 4
                }
            }

            Spacer()

            // Shutter button
            Button {
                model.camera.takePhoto()
                isFlashing = true
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: 66, height: 66)
                    Circle()
                        .fill(.white)
                        .frame(width: 54, height: 54)
                }
            }

            Spacer()

            // "+" — commit current session stacks immediately → starts upload
            Button {
                guard hasSessionPhotos else { return }
                withAnimation(.easeIn(duration: 0.22)) {
                    Task {
                        _ = await model.commitStacksAsDrafts(modelContext: modelContext, uploadManager: uploadManager)
                        stackBouncing = true
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        stackBouncing = false
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(hasSessionPhotos ? Color.blue : Color.gray.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!hasSessionPhotos)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Photo Identity (for drag & drop)

struct SessionPhotoID: Equatable {
    let stackIdx: Int
    let photoIdx: Int
}

// MARK: - Session Photo Drop Delegate

struct SessionPhotoDropDelegate: DropDelegate {
    let target: SessionPhotoID
    let model: DataModel
    @Binding var draggedPhoto: SessionPhotoID?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedPhoto, dragged != target else { return }

        if dragged.stackIdx == target.stackIdx {
            // Reorder within same stack
            model.movePhotoWithinStack(
                stackIndex: dragged.stackIdx,
                from: dragged.photoIdx,
                to: target.photoIdx
            )
            draggedPhoto = SessionPhotoID(stackIdx: target.stackIdx, photoIdx: target.photoIdx)
        } else {
            // Move between stacks
            model.movePhotoBetweenStacks(
                fromStack: dragged.stackIdx,
                fromIndex: dragged.photoIdx,
                toStack: target.stackIdx,
                toIndex: target.photoIdx
            )
            draggedPhoto = SessionPhotoID(stackIdx: target.stackIdx, photoIdx: target.photoIdx)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedPhoto = nil
        return true
    }
}

// MARK: - Camera Grid Overlay

struct CameraGridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w/3, y: 0)); p.addLine(to: CGPoint(x: w/3, y: h))
                    p.move(to: CGPoint(x: 2*w/3, y: 0)); p.addLine(to: CGPoint(x: 2*w/3, y: h))
                }.stroke(Color.white.opacity(0.3), lineWidth: 0.8)

                Path { p in
                    p.move(to: CGPoint(x: 0, y: h/3)); p.addLine(to: CGPoint(x: w, y: h/3))
                    p.move(to: CGPoint(x: 0, y: 2*h/3)); p.addLine(to: CGPoint(x: w, y: 2*h/3))
                }.stroke(Color.white.opacity(0.3), lineWidth: 0.8)
            }
        }
    }
}
