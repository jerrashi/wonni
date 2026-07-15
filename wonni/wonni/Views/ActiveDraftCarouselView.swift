//
//  ActiveDraftCarouselView.swift
//  wonni
//
//  Shared bottom carousel used identically in CameraView and CustomPhotoPickerView.
//  Shows the active draft's photos as a flat, drag-to-reorder row, followed by
//  committed draft fanned-card thumbnails. Tapping a committed draft opens
//  draft history (via the host's onOpenDraftHistory push). Tapping "+" commits the
//  active draft and starts upload.
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
    @State private var isTrashTargeted = false

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
                    HStack(spacing: 8) {
                        // Committed drafts stack — single fanned card stack
                        if !committedDrafts.isEmpty {
                            DraftsStackIconView(drafts: committedDrafts, cache: cache)
                                .scaleEffect(stackBouncing ? 1.08 : 1.0)
                                .animation(.spring(response: 0.35, dampingFraction: 0.45), value: stackBouncing)
                                .onTapGesture { onOpenDraftHistory() }
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

                // ── "+" commit button, replaced by a trash drop target while dragging ──
                let hasActive = activeDraft?.sourceAssetIdentifiers.isEmpty == false
                if draggedAssetId != nil {
                    Image(systemName: isTrashTargeted ? "trash.circle.fill" : "trash.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                        .scaleEffect(isTrashTargeted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTrashTargeted)
                        .frame(width: 44, height: 44)
                        .padding(.trailing, 12)
                        .onDrop(of: [.text], isTargeted: $isTrashTargeted) { _ in
                            deleteDraggedPhoto()
                        }
                } else {
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
                }
            }
        }
    }

    // MARK: - Active photo cell

    @ViewBuilder
    private func activePhotoCell(draft: Item, assetId: String) -> some View {
        let isDragged = draggedAssetId == assetId

        Group {
            if let uiImage = draft.thumbnail(for: assetId) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                PhotoItemView(
                    asset: PhotoAsset(identifier: assetId),
                    cache: cache,
                    imageSize: CGSize(width: 144, height: 144)
                )
            }
        }
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
    }

    @discardableResult
    private func deleteDraggedPhoto() -> Bool {
        guard let assetId = draggedAssetId else { return false }
        uploadManager.removePhotoFromActiveDraft(assetId: assetId, modelContext: modelContext)
        draggedAssetId = nil
        return true
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
                        if let uiImage = draft.thumbnail(for: assetId) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            PhotoItemView(
                                asset: PhotoAsset(identifier: assetId),
                                cache: cache,
                                imageSize: CGSize(width: 144, height: 144)
                            )
                        }
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
