//
//  ActiveDraftCarouselView.swift
//  wonni
//
//  Shared bottom carousel used identically in CameraView and CustomPhotoPickerView.
//  Shows the active draft's photos as a flat, drag-to-reorder row, followed by
//  committed draft fanned-card thumbnails. Tapping a committed draft opens
//  the Drafts screen (via the host's onOpenDraftHistory push). Tapping "+" commits
//  the active draft and starts upload. Each photo has an "X" that removes it with a
//  short Undo window (PhotoRemovedToast); the old drag-to-trash target is gone
//  because it was too easy to hit while reordering (user, 2026-10-10).
//

import SwiftUI
import SwiftData

struct ActiveDraftCarouselView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]

    var cache: CachedImageManager
    /// Extra action to run alongside commitActiveDraft (e.g. camera does nothing extra)
    var onCommit: (() -> Void)? = nil
    /// Navigates to draft history. Provided by the host (camera / picker) so history is
    /// PUSHED on their shared NavigationStack — the old local sheet here stacked a modal
    /// on top of the live camera, the root cause of the reported flow lag (spec N1).
    let onOpenDraftHistory: () -> Void

    @State private var draggedAssetId: String? = nil
    @State private var stackBouncing = false

    /// 72pt thumbnails + 8pt vertical padding on each side.
    private static let rowHeight: CGFloat = 88

    // Active draft — the Item currently being built
    private var activeDraft: Item? {
        guard let id = uploadManager.activeDraftID, !uploadManager.deletedDraftIDs.contains(id) else { return nil }
        return allItems.first { $0.id == id }
    }

    // Committed drafts — exclude the active draft, sorted newest first
    private var committedDrafts: [Item] {
        let activeID = uploadManager.activeDraftID
        // Exclude drafts mid-deletion — see UploadManager.deleteDraftLocallyAndCloud /
        // Item.deletedIDs. This carousel is always visible on the camera screen and is
        // driven by its own independent @Query, so it needs the same exclusion the other
        // draft-list views apply.
        return allItems
            .filter {
                $0.isDraft && !$0.pendingPublish && !$0.sourceAssetIdentifiers.isEmpty && $0.id != activeID
                    && !uploadManager.deletedDraftIDs.contains($0.id)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var hasContent: Bool {
        activeDraft?.sourceAssetIdentifiers.isEmpty == false || !committedDrafts.isEmpty
    }

    var body: some View {
        if hasContent {
            HStack(spacing: 0) {
                // ── Scrollable photo row ────────────────────────────────
                ScrollView(.horizontal, showsIndicators: false) {
                    // LazyHStack, not HStack (2026-09-28 draft-drawer freeze/crash
                    // investigation — see DraftThumbnailView.swift's header comment):
                    // this carousel is visible across camera + picker, so a plain HStack
                    // eagerly decoding every active-draft photo on every re-render was a
                    // major contributor to "the photo picker flow in general is slow".
                    LazyHStack(spacing: 8) {
                        // Committed drafts stack — single fanned card stack
                        if !committedDrafts.isEmpty {
                            DraftsStackIconView(drafts: committedDrafts, cache: cache)
                                .scaleEffect(stackBouncing ? 1.08 : 1.0)
                                .animation(.spring(response: 0.35, dampingFraction: 0.45), value: stackBouncing)
                                .onTapGesture { onOpenDraftHistory() }
                                .accessibilityIdentifier("draftsStackIcon")
                        }

                        // Divider between active and committed (if both exist)
                        if activeDraft?.sourceAssetIdentifiers.isEmpty == false && !committedDrafts.isEmpty {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 1, height: 54)
                                .padding(.horizontal, 4)
                        }

                        // Active draft photos — flat, draggable
                        if let draft = activeDraft, !draft.sourceAssetIdentifiers.isEmpty {
                            ForEach(draft.sourceAssetIdentifiers, id: \.self) { assetId in
                                activePhotoCell(draft: draft, assetId: assetId)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                // Explicit height is REQUIRED with the LazyHStack above: unlike HStack
                // (which hugs its children), a LazyHStack in a horizontal ScrollView is
                // greedy on the cross axis and takes whatever height it's offered. The
                // HStack→LazyHStack swap (#143) is what made this carousel balloon to
                // half the picker / float mid-screen on the camera — #146 and #147
                // chased that as a transition/safeAreaInset bug.
                .frame(height: Self.rowHeight)

                // ── "+" commit button ──
                let hasActive = activeDraft?.sourceAssetIdentifiers.isEmpty == false
                do {
                    Button {
                        guard hasActive else { return }
                        withAnimation(.easeIn(duration: 0.18)) {
                            uploadManager.commitActiveDraft(modelContext: modelContext)
                            onCommit?()
                            stackBouncing = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                stackBouncing = false
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(hasActive ? Color.blue : Color.gray.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!hasActive)
                    .padding(.trailing, 12)
                    .animation(.easeInOut(duration: 0.15), value: hasActive)
                    .accessibilityIdentifier("commitDraftButton")
                }
            }
            .accessibilityIdentifier("draftsCarousel")
        }
    }

    // MARK: - Active photo cell

    @ViewBuilder
    private func activePhotoCell(draft: Item, assetId: String) -> some View {
        let isDragged = draggedAssetId == assetId

        DraftThumbnailView(item: draft, assetId: assetId)
        .frame(width: 72, height: 72)
        .cornerRadius(10)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        .opacity(isDragged ? 0.4 : 1.0)
        .scaleEffect(isDragged ? 0.9 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragged)
        .onDrag {
            draggedAssetId = assetId
            return NSItemProvider(object: assetId as NSString)
        }
        .onDrop(of: [.text], delegate: ActiveDraftPhotoDropDelegate(
            targetAssetId: assetId,
            draft: draft,
            draggedAssetId: $draggedAssetId,
            modelContext: modelContext
        ))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    uploadManager.removePhotoFromActiveDraftWithUndo(assetId: assetId, modelContext: modelContext)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    // 44pt hit area on a 72pt cell, without growing the visible mark.
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 8, y: -8)
            .accessibilityLabel("Remove photo")
            .accessibilityIdentifier("carouselRemovePhotoButton")
        }
    }
}

// MARK: - "Photo removed · Undo" toast

/// Floats over the host (camera / picker) while `UploadManager.removedPhoto` is set.
/// Swipe down or sideways to dismiss early; otherwise it goes away on its own.
struct PhotoRemovedToast: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        if uploadManager.removedPhoto != nil {
            HStack(spacing: 14) {
                Text("Photo removed")
                    .font(.subheadline.weight(.medium))
                Button("Undo") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        uploadManager.undoRemovePhoto(modelContext: modelContext)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("undoRemovePhotoButton")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .offset(dragOffset)
            // High priority so the swipe is ours even though a scrolling grid sits
            // underneath the toast.
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        // Only follow the finger away from the content (down / sideways).
                        dragOffset = CGSize(width: value.translation.width, height: max(0, value.translation.height))
                    }
                    .onEnded { value in
                        if value.translation.height > 30 || abs(value.translation.width) > 60 {
                            withAnimation(.easeIn(duration: 0.15)) { uploadManager.finalizeRemovedPhoto() }
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = .zero }
                        }
                    }
            )
            .onDisappear { dragOffset = .zero }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // No identifier on the container: SwiftUI would push it down onto the Undo
            // button and hide "undoRemovePhotoButton" from the UI tests.
        }
    }
}

// MARK: - Drop delegate for active draft reorder

struct ActiveDraftPhotoDropDelegate: DropDelegate {
    let targetAssetId: String
    let draft: Item
    @Binding var draggedAssetId: String?
    let modelContext: ModelContext

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedAssetId, dragged != targetAssetId else { return }
        guard let from = draft.sourceAssetIdentifiers.firstIndex(of: dragged),
              let to   = draft.sourceAssetIdentifiers.firstIndex(of: targetAssetId) else { return }
        withAnimation { draft.movePhoto(from: from, to: to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        try? modelContext.save()
        draggedAssetId = nil
        return true
    }
}

// MARK: - Drafts Stack Icon View (Fanned deck representing committed drafts)

struct DraftsStackIconView: View {
    let drafts: [Item] // sorted newest first
    let cache: CachedImageManager

    var body: some View {
        // Always render a fixed 3-card fan. Slots are ordered back-to-front, so the
        // newest draft sits on top (front). When there are fewer than 3 committed
        // drafts the back slots are `nil` and render as placeholder squares.
        let slotCount = 3
        let recent = Array(drafts.prefix(slotCount))          // newest first
        let padCount = slotCount - recent.count
        let slots: [Item?] = Array(repeating: nil, count: padCount) + recent.reversed().map { Optional($0) }

        ZStack {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, draft in
                let step = 20.0 / Double(slotCount - 1)
                let rotation = -10.0 + (Double(index) * step)
                let xOffset = CGFloat(-5.0 + (Double(index) * (10.0 / Double(slotCount - 1))))
                let yOffset = CGFloat(-2.0 + (Double(index) * (4.0 / Double(slotCount - 1))))

                Group {
                    if let draft, let assetId = draft.sourceAssetIdentifiers.first {
                        DraftThumbnailView(item: draft, assetId: assetId)
                    } else {
                        // Placeholder square for an empty slot
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.35))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white.opacity(0.6))
                            )
                    }
                }
                .frame(width: 72, height: 72)
                .cornerRadius(10)
                .clipped()
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2)
                .rotationEffect(.degrees(rotation), anchor: .bottom)
                .offset(x: xOffset, y: yOffset)
                .zIndex(Double(index))
            }
        }
        .frame(width: 82, height: 72)
        .overlay(alignment: .topTrailing) {
            if drafts.count > 0 {
                Text("\(drafts.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.blue)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .offset(x: 4, y: -4)
            }
        }
    }
}
