/*
CameraView.swift
*/

import SwiftUI
import SwiftData

/// Every screen the Sell tab can push, as a value. The tab's NavigationStack is driven
/// by an array of these (`CameraView.path`), so every move is an append or a pop and
/// "back" is always the previous element. Until 2026-10-10 the tab had one optional
/// destination slot plus a second nested slot inside the picker; the drafts drawer's
/// "+" either popped the drawer or swapped it for a new picker in place, so "<" from
/// that picker went to the camera instead of the drawer, and the in-place swap
/// crashed on the user's phone.
enum CameraRoute: Hashable {
    /// The photo picker editing one draft. A new listing gets an empty draft created
    /// just before the push; it is deleted again if the picker is popped with no photos.
    case picker(UUID)
    /// The drafts drawer (every committed draft with its photo strip and "+").
    case drafts
    /// The post-Proceed drafts overview (titles, prices, Process).
    case overview
}

struct CameraView: View {
    @StateObject private var model = DataModel()
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]

    @State private var isFlashing = false
    /// Owned by CameraViewController's NavigationStack. See `CameraRoute`.
    @Binding var path: [CameraRoute]
    @AppStorage("showCameraGrid") private var showGrid: Bool = false
    /// "Paste a list" — drafts without photos (BulkTextDraftsSheet). Lives here, next
    /// to the shutter, because this is where every listing starts.
    @State private var showBulkTextDrafts = false

    private var hasActiveDraft: Bool {
        guard let id = uploadManager.activeDraftID else { return false }
        return allItems.first(where: { $0.id == id })?.sourceAssetIdentifiers.isEmpty == false
    }

    private var hasAnyContent: Bool {
        let activeID = uploadManager.activeDraftID
        // Exclude pendingPublish items — they are already committed to publish and should
        // not appear in the camera carousel or drive the Proceed button. They are still
        // saved drafts, just hidden until the user visits the publish overview.
        let anyCommitted = allItems.contains {
            $0.isDraft && !$0.pendingPublish && !$0.sourceAssetIdentifiers.isEmpty && $0.id != activeID
        }
        return hasActiveDraft || anyCommitted
    }

    var body: some View {
        GeometryReader { geo in
            let screenW     = geo.size.width
            let safeTop     = geo.safeAreaInsets.top
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
                    .offset(y: topBarH)

                // 3. Top bar — safe-area-aware
                topBarView(safeTop: safeTop)
                    .frame(height: topBarH)
                    .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea()
        }
        // Bottom controls reserved via safeAreaInset — same primitive the photo picker
        // uses for its bottom bar. The previous GeometryReader + frame(maxHeight:
        // .infinity, alignment: .bottom) approach could latch onto a stale size/safe-area
        // reading across the nav-bar show/hide transition triggered by pushing/popping
        // CustomPhotoPickerView (which, unlike this view, shows a nav bar), rendering the
        // carousel and camera buttons mid-screen instead of pinned to the bottom.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                // Shared carousel (identical to picker bottom bar)
                if hasAnyContent {
                    // No entrance transition here on purpose: the FIRST photo of a
                    // fresh draft flips hasAnyContent false→true at the exact instant
                    // takePhoto() fires, and AVCapturePhotoOutput briefly stalls the
                    // live preview while it processes the shot (expected — that's the
                    // camera-app black flash). If that stall lands mid slide-up
                    // animation, the carousel visually freezes partway up the screen
                    // instead of finishing. Appearing instantly avoids the window.
                    ActiveDraftCarouselView(
                        cache: model.photoCollection.cache,
                        onOpenDraftHistory: { path.append(.drafts) }
                    )
                }
                cameraButtonsView()
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
        // #34: was scoped to ViewfinderView's own overlay, so the flash only
        // covered the viewfinder rect — not the top bar or bottom controls.
        // Applied here (top-level, after safeAreaInset) it covers the whole
        // screen instead. allowsHitTesting(false) so it can't eat a fast
        // double-tap on the shutter/gallery/switch buttons during the flash.
        .overlay {
            if isFlashing {
                Color.white.opacity(0.8)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeOut(duration: 0.15)) { isFlashing = false }
                        }
                    }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            // Wire camera photo callback BEFORE starting the camera
            model.onPhotoAdded = { [weak uploadManager] assetId, imageData in
                guard let um = uploadManager else { return }
                um.addPhotoToActiveDraft(assetId: assetId, imageData: imageData, modelContext: modelContext)
            }
            // .task re-runs on every appear (incl. returning from another tab) — only
            // start the session when the camera itself is what's on screen.
            if path.isEmpty {
                await model.camera.start()
            }
            await model.loadPhotos()
            await model.loadThumbnail()
        }
        // The capture session runs ONLY while the camera itself is on screen. Driving
        // this off the route (instead of onAppear/onDisappear pairs on each destination)
        // also covers pushes the destinations make themselves — e.g. picker → drafts
        // overview used to fire the picker's onDisappear and resume the preview UNDER
        // the drafts screen. isPreviewPaused stops viewfinder frames instantly; stop()
        // tears the AVCaptureSession down (spec N1: no rendering or capture while hidden).
        .onChange(of: path) { oldPath, newPath in
            pathDidChange(from: oldPath, to: newPath)
            if newPath.isEmpty {
                model.camera.isPreviewPaused = false
                Task { await model.camera.start() }
            } else {
                model.camera.isPreviewPaused = true
                model.camera.stop()
            }
        }
        // Tab switched away (camera can't be visible): stop capturing. The .task above
        // restarts it on return.
        .onDisappear {
            model.camera.stop()
        }
        .sheet(isPresented: $showBulkTextDrafts) {
            // "Open drafts" sets uploadManager.openDraftsOverview, which the onChange
            // below turns into a push of the overview once the sheet is gone.
            BulkTextDraftsSheet(offersOpenDrafts: true)
                .environmentObject(uploadManager)
        }
        .navigationDestination(for: CameraRoute.self) { destination in
            switch destination {
            case .picker(let draftID):
                // One PhotoCollection for the whole tab (the camera's). The picker used
                // to create its own, so every picker on screen was another photo-library
                // observer and another full fetch.
                CustomPhotoPickerView(
                    draftID: draftID,
                    photoCollection: model.photoCollection,
                    onProceed: { path.append(.overview) },
                    onOpenDrafts: { path.append(.drafts) }
                )
            case .drafts:
                // "+" on a draft pushes a picker for THAT draft on top of the drawer, so
                // "<" from it lands back on the drawer. The drawer itself stays in the
                // path underneath, untouched.
                DraftHistoryView(photoCollection: model.photoCollection, onAddPhotos: { draftID in
                    path.append(.picker(draftID))
                })
            case .overview:
                BulkListingOverviewView()
            }
        }
        .onChange(of: uploadManager.shouldReturnToRoot) { _, should in
            if should {
                path.removeAll()
                uploadManager.shouldReturnToRoot = false
                uploadManager.selectedTab = 4
            }
        }
        // "Open drafts" from BulkTextDraftsSheet when it was opened outside this stack
        // (Profile › Import). Checked on appear too: the flag is set before the tab
        // switch, so if this view wasn't alive yet the onChange never fires.
        .onChange(of: uploadManager.openDraftsOverview) { _, should in
            if should { openDraftsOverviewIfRequested() }
        }
        .onAppear { openDraftsOverviewIfRequested() }
        // Review & Publish's Back button (spec N4): dismisses the full-screen results
        // view and pops this stack back to the camera, drafts intact.
        .onChange(of: uploadManager.returnToCameraRoot) { _, should in
            if should {
                path.removeAll()
                uploadManager.returnToCameraRoot = false
            }
        }
    }

    /// Pushes the picker for the draft the camera is building, creating an empty one
    /// when there is none. The picker is keyed by that id, so the same screen serves a
    /// new listing and a reopened draft.
    private func openPicker() {
        let draftID = uploadManager.ensureActiveDraft(modelContext: modelContext)
        path.append(.picker(draftID))
    }

    /// Runs on every path change (Back chevron, swipe-back, `dismiss()` and our own
    /// pops all end up here). Pickers that left the path get their draft closed out
    /// (empty → deleted, reopened-and-changed → re-uploaded), and the topmost picker
    /// still on the path becomes the active draft again. With no picker left, the last
    /// closed picker's draft stays active when it has photos, so the camera keeps adding
    /// to it; `pickerDidClose` clears it when it was empty and deleted.
    private func pathDidChange(from oldPath: [CameraRoute], to newPath: [CameraRoute]) {
        let remaining = Set(newPath)
        for route in oldPath where !remaining.contains(route) {
            if case .picker(let draftID) = route {
                uploadManager.pickerDidClose(draftID: draftID, modelContext: modelContext)
            }
        }
        for route in newPath.reversed() {
            if case .picker(let draftID) = route {
                uploadManager.activeDraftID = draftID
                break
            }
        }
    }

    private func openDraftsOverviewIfRequested() {
        guard uploadManager.openDraftsOverview else { return }
        uploadManager.openDraftsOverview = false
        // The flag is set from inside a sheet (BulkTextDraftsSheet) that is dismissing
        // at this exact moment — defer the push past its dismiss animation so SwiftUI
        // doesn't get a sheet dismissal and a navigation push in the same frame (same
        // pattern as ProcessProgressView's onMinimize).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            path.append(.overview)
        }
    }

    // MARK: - Top bar

    private func topBarView(safeTop: CGFloat) -> some View {
        HStack(alignment: .center) {
            Button {
                // Commit active draft if it has photos (no dialog — drafts save silently).
                // An empty active draft (no photos taken yet) is left as-is; it will be
                // cleaned up automatically at session end if never committed.
                if hasActiveDraft {
                    uploadManager.commitActiveDraft(modelContext: modelContext)
                }
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

            Button {
                showBulkTextDrafts = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("List")
                        .font(.body.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
            }
            .padding(.leading, 10)
            .accessibilityIdentifier("cameraDraftsFromListButton")

            Spacer()

            if hasAnyContent {
                Button {
                    // Commit active draft first if non-empty, then navigate
                    if hasActiveDraft {
                        uploadManager.commitActiveDraft(modelContext: modelContext)
                    }
                    path.append(.overview)
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
                openPicker()
            } label: {
                ThumbnailView(image: model.thumbnailImage)
                    .frame(width: 46, height: 46)
                    .cornerRadius(8)
            }
            .accessibilityIdentifier("cameraGalleryButton")

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
