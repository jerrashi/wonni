/*
See the License.txt file for this sample's licensing information.
*/

import SwiftUI
import SwiftData

struct CameraView: View {
    @StateObject private var model = DataModel()
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]

    @State private var isFlashing = false
    @State private var showingModal = false
    @State private var selectedStackIndex = 0
    @State private var showingPicker = false
    @State private var navigatingToDrafts = false
    @AppStorage("showCameraGrid") private var showGrid: Bool = false


    // All SwiftData drafts — shared with picker, no session filter
    private var allDrafts: [Item] {
        allItems.filter { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty }
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

                    // 3. Top bar — safe-area-aware so it clears Dynamic Island /
                    //    notch / iOS 26 status bar on every screen size
                    topBarView(safeTop: safeTop)
                        .frame(height: topBarH)
                        .frame(maxWidth: .infinity)

                    // 4. Bottom controls pinned to the screen bottom.
                    //    The blank space between the viewfinder bottom and these
                    //    controls is intentional — the draft scroll view will
                    //    eventually live there.
                    VStack(spacing: 8) {
                        // Draft stacks row (all drafts: camera + picker, shared)
                        if !model.sessionPhotos.flatMap({ $0 }).isEmpty || !allDrafts.isEmpty {
                            pickerAndCameraStacksRow()
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
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
            .sheet(isPresented: $showingModal) {
                PhotoStackModalView(
                    dataModel: model,
                    isPresented: $showingModal,
                    stackIndex: selectedStackIndex
                )
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

            let hasPhotos = !model.sessionPhotos.flatMap({ $0 }).isEmpty || !allDrafts.isEmpty
            if hasPhotos {
                Button {
                    Task {
                        _ = await model.commitStacksAsDrafts(modelContext: modelContext, uploadManager: uploadManager)
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

    // MARK: - Unified draft + camera stacks row

    @ViewBuilder
    private func pickerAndCameraStacksRow() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Camera-session stacks (in-memory UIImage stacks)
                ForEach(0..<model.sessionPhotos.count, id: \.self) { stackIndex in
                    let photos = model.sessionPhotos[stackIndex]
                    if !photos.isEmpty {
                        CameraSessionStackView(photos: photos)
                            .onTapGesture {
                                selectedStackIndex = stackIndex
                                showingModal = true
                            }
                    }
                }

                // All SwiftData drafts (camera-committed + picker)
                ForEach(allDrafts) { draft in
                    DraftStackThumbnailView(draft: draft, cache: model.photoCollection.cache)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 82)
    }

    // MARK: - Bottom camera buttons

    private func cameraButtonsView() -> some View {
        HStack(spacing: 0) {
            // Gallery / picker button — commit any in-progress camera stacks first
            Button {
                Task {
                    if !model.sessionPhotos.flatMap({ $0 }).isEmpty {
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

            // Add new stack button  (same as + in picker)
            Button {
                model.addNewStack()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .opacity(model.sessionPhotos.flatMap({ $0 }).isEmpty ? 0 : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Nested subviews

    private struct CameraSessionStackView: View {
        let photos: [UIImage]
        var body: some View {
            let count = photos.count
            ZStack {
                ForEach(0..<min(3, count), id: \.self) { index in
                    let offset = CGFloat(index) * 5
                    Image(uiImage: photos[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .cornerRadius(10)
                        .clipped()
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 2)
                        .offset(x: offset, y: -offset)
                        .zIndex(Double(3 - index))
                }
            }
            .frame(width: 76, height: 76)
        }
    }
}

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
