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
    /// Single source of truth for camera-tab navigation. Two separate
    /// `navigationDestination(isPresented:)` modifiers on the same NavigationStack
    /// collide and wedge the UI, so we drive one destination off this enum instead.
    private enum CameraRoute: Hashable {
        case picker
        case drafts
    }
    @State private var route: CameraRoute?
    @State private var showingExitAlert = false
    @AppStorage("showCameraGrid") private var showGrid: Bool = false

    private var hasActiveDraft: Bool {
        guard let id = uploadManager.activeDraftID else { return false }
        return allItems.first(where: { $0.id == id })?.sourceAssetIdentifiers.isEmpty == false
    }

    private var hasAnyContent: Bool {
        let activeID = uploadManager.activeDraftID
        let anyCommitted = allItems.contains { $0.isDraft && !$0.sourceAssetIdentifiers.isEmpty && $0.id != activeID }
        return hasActiveDraft || anyCommitted
    }

    var body: some View {
        GeometryReader { geo in
            let screenW     = geo.size.width
            let safeTop     = geo.safeAreaInsets.top
            let safeBottom  = geo.safeAreaInsets.bottom
            let viewfinderH = screenW * (4.0 / 3.0)
            let topBarH: CGFloat = safeTop + 56

            ZStack(alignment: .top) {
                // 1. Full black background
                Color.black.ignoresSafeArea()

                // 2. Viewfinder directly below the top bar
                ViewfinderView(image: $model.viewfinderImage)
                    .frame(width: screenW, height: viewfinderH)
                    .clipped()
                    .overlay { if showGrid { CameraGridOverlay() } }
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

                // 4. Bottom controls pinned to screen bottom
                VStack(spacing: 8) {
                    // Shared carousel (identical to picker bottom bar)
                    if hasAnyContent {
                        ActiveDraftCarouselView(cache: model.photoCollection.cache)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    cameraButtonsView()
                }
                .padding(.bottom, safeBottom + 12)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Save Drafts?", isPresented: $showingExitAlert) {
            Button("Discard", role: .destructive) {
                if let activeID = uploadManager.activeDraftID,
                   let draft = allItems.first(where: { $0.id == activeID }) {
                    uploadManager.deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
                    uploadManager.activeDraftID = nil
                }
                for draft in allItems where uploadManager.sessionDraftIDs.contains(draft.id) {
                    uploadManager.deleteDraftLocallyAndCloud(draft: draft, modelContext: modelContext)
                }
                uploadManager.sessionDraftIDs.removeAll()
                uploadManager.selectedTab = 0
            }
            Button("Save") { uploadManager.selectedTab = 0 }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have created drafts in this session. Would you like to save or discard them?")
        }
        .task {
            // Wire camera photo callback BEFORE starting the camera
            model.onPhotoAdded = { [weak uploadManager] assetId, imageData in
                guard let um = uploadManager else { return }
                um.addPhotoToActiveDraft(assetId: assetId, imageData: imageData, modelContext: modelContext)
            }
            await model.camera.start()
            await model.loadPhotos()
            await model.loadThumbnail()
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .picker:
                CustomPhotoPickerView()
                    .onAppear  { model.camera.isPreviewPaused = true }
                    .onDisappear { model.camera.isPreviewPaused = false }
            case .drafts:
                BulkListingOverviewView(sessionDraftIDs: uploadManager.sessionDraftIDs)
                    .onAppear  { model.camera.isPreviewPaused = true }
                    .onDisappear { model.camera.isPreviewPaused = false }
            }
        }
        .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
            if should {
                route = nil
                uploadManager.shouldReturnToRoot = false
                uploadManager.selectedTab = 4
            }
        }
    }

    // MARK: - Top bar

    private func topBarView(safeTop: CGFloat) -> some View {
        HStack(alignment: .center) {
            Button {
                let hasActiveDraftNow = uploadManager.activeDraftID != nil
                let hasSessionDrafts = !uploadManager.sessionDraftIDs.isEmpty
                if hasActiveDraftNow || hasSessionDrafts {
                    showingExitAlert = true
                } else {
                    uploadManager.selectedTab = 0
                }
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

            if hasAnyContent {
                Button {
                    // Commit active draft first if non-empty, then navigate
                    if hasActiveDraft {
                        uploadManager.commitActiveDraft(modelContext: modelContext)
                    }
                    route = .drafts
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

    // MARK: - Bottom camera buttons

    private func cameraButtonsView() -> some View {
        HStack(spacing: 0) {
            // Gallery button
            Button {
                route = .picker
            } label: {
                ThumbnailView(image: model.thumbnailImage)
                    .frame(width: 46, height: 46)
                    .cornerRadius(8)
            }
            .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
                if should {
                    route = nil
                    uploadManager.shouldReturnToRoot = false
                    uploadManager.selectedTab = 4
                }
            }

            Spacer()

            // Shutter
            Button {
                model.camera.takePhoto()
                isFlashing = true
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 3).frame(width: 66, height: 66)
                    Circle().fill(.white).frame(width: 54, height: 54)
                }
            }

            Spacer()

            // Switch camera button
            Button {
                model.camera.switchCaptureDevice()
            } label: {
                Image(systemName: "camera.rotate")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .buttonStyle(.plain)
    }
}

// MARK: - Camera Grid Overlay

struct CameraGridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w/3, y: 0));   p.addLine(to: CGPoint(x: w/3, y: h))
                    p.move(to: CGPoint(x: 2*w/3, y: 0)); p.addLine(to: CGPoint(x: 2*w/3, y: h))
                }.stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h/3));   p.addLine(to: CGPoint(x: w, y: h/3))
                    p.move(to: CGPoint(x: 0, y: 2*h/3)); p.addLine(to: CGPoint(x: w, y: 2*h/3))
                }.stroke(Color.white.opacity(0.3), lineWidth: 0.8)
            }
        }
    }
}
