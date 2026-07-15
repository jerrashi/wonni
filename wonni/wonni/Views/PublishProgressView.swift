//
//  PublishProgressView.swift
//  wonni
//
//  Full-screen view showing per-listing publish status.
//  Mirrors ProcessProgressView's pattern: minimizable to the pill,
//  auto-retry once (handled by UploadManager), manual "Retry Failed"
//  button after exhaustion.
//

import SwiftUI
import SwiftData

struct PublishProgressView: View {
    /// Pass a closure that dismisses the fullScreenCover without navigating away.
    var onMinimize: (() -> Void)? = nil

    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [Item]
    @State private var cache = CachedImageManager()

    // ── Derived state ─────────────────────────────────────────────────────

    /// All items being tracked by the current publish session, in original order.
    private var orderedDrafts: [Item] {
        // Items are keyed by publishStatuses — use that set as the source of truth
        // for what belongs in this view (not processedItemIDs, which belongs to AI).
        let ids = uploadManager.publishStatuses.keys
        return allItems
            .filter { ids.contains($0.id) }
            .sorted { a, b in
                // Preserve stable order: done first, then uploading, then pending, then failed
                statusSortKey(a.id) < statusSortKey(b.id)
            }
    }

    private func statusSortKey(_ id: UUID) -> Int {
        switch uploadManager.publishStatuses[id] ?? .pending {
        case .done:          return 0
        case .uploading:     return 1
        case .pending:       return 2
        case .failed:        return 3
        }
    }

    private var failedDrafts: [Item] {
        allItems.filter { uploadManager.publishStatuses[$0.id] == .failed }
    }

    private var allDone: Bool {
        guard !uploadManager.publishStatuses.isEmpty else { return false }
        return uploadManager.publishStatuses.values.allSatisfy {
            switch $0 { case .done, .failed: return true; default: return false }
        }
    }

    private var anyFailed: Bool {
        uploadManager.publishStatuses.values.contains { $0 == .failed }
    }

    private var successCount: Int {
        uploadManager.publishStatuses.values.filter { $0 == .done }.count
    }

    // ── Body ──────────────────────────────────────────────────────────────

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            ZStack {
                if allDone {
                    headerDone
                } else {
                    headerInProgress
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.35), value: allDone)

            Divider()

            // ── Per-item list ─────────────────────────────────────────────
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(orderedDrafts) { item in
                        draftStatusRow(item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Spacer(minLength: 0)

            // ── Retry failed button (only shown after all done + some failed) ──
            if allDone && anyFailed {
                Divider()
                Button {
                    for draft in failedDrafts {
                        uploadManager.publishStatuses[draft.id] = .pending
                    }
                    uploadManager.retryFailedPublish(drafts: failedDrafts, modelContext: modelContext)
                } label: {
                    Label("Retry \(failedDrafts.count) Failed Listing\(failedDrafts.count == 1 ? "" : "s")", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            Divider()

            // ── Minimize / Close button ───────────────────────────────────
            Button {
                if let minimize = onMinimize {
                    minimize()
                }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 22, weight: .semibold))
                    Text(allDone && !anyFailed ? "Close" : "Minimize")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .contentShape(Rectangle())
        }
        .navigationTitle("Publishing")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ── Header subviews ───────────────────────────────────────────────────

    @ViewBuilder private var headerInProgress: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(uploadManager.publishCurrentIndex) / Double(max(1, uploadManager.publishTotalCount)))
                .tint(.blue)
                .padding(.horizontal, 24)
            HStack(spacing: 6) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Publishing \(uploadManager.publishCurrentIndex) of \(uploadManager.publishTotalCount)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var headerDone: some View {
        HStack(spacing: 10) {
            if anyFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(successCount) published, \(failedDrafts.count) failed")
                        .font(.headline)
                    Text("Tap \"Retry\" below to try again")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("All listings published!")
                    .font(.headline)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // ── Per-item row ──────────────────────────────────────────────────────

    @ViewBuilder
    private func draftStatusRow(_ item: Item) -> some View {
        let status = uploadManager.publishStatuses[item.id] ?? .pending

        HStack(spacing: 14) {
            // Thumbnail
            Group {
                if let assetId = item.sourceAssetIdentifiers.first {
                    if let img = item.thumbnail(for: assetId) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        PhotoItemView(
                            asset: PhotoAsset(identifier: assetId),
                            cache: cache,
                            imageSize: CGSize(width: 100, height: 100)
                        )
                    }
                } else {
                    Color(.systemGray5)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Title + status label
            VStack(alignment: .leading, spacing: 4) {
                Text(item.userEditedTitle ?? item.aiSuggestedTitle ?? item.visionTitle ?? "Item")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(statusLabel(for: status))
                    .font(.caption)
                    .foregroundStyle(statusColor(for: status))
                    .animation(.easeInOut(duration: 0.25), value: statusLabel(for: status))
            }

            Spacer()

            // Status icon
            statusIcon(for: status)
                .frame(width: 28, height: 28)
        }
        .padding(12)
        .background(rowBackground(for: status), in: RoundedRectangle(cornerRadius: 12))
    }

    private func rowBackground(for status: DraftUploadStatus) -> Color {
        switch status {
        case .failed:   return Color(.systemGray6).opacity(0.8)
        default:        return Color(.systemGray6)
        }
    }

    private func statusLabel(for status: DraftUploadStatus) -> String {
        switch status {
        case .pending:                           return "Waiting…"
        case .uploading(let p) where p < 0.4:   return "Uploading photos…"
        case .uploading(let p) where p < 0.8:   return "Writing listing…"
        case .uploading:                         return "Finishing up…"
        case .done:                              return "Published ✓"
        case .failed:                            return "Failed — tap Retry"
        }
    }

    private func statusColor(for status: DraftUploadStatus) -> Color {
        switch status {
        case .pending:    return .secondary
        case .uploading:  return .blue
        case .done:       return .green
        case .failed:     return .red
        }
    }

    @ViewBuilder
    private func statusIcon(for status: DraftUploadStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .uploading(let p):
            ZStack {
                Circle().stroke(Color.blue.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.08, p))
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: p)
            }
        case .done:
            ZStack {
                Circle().fill(Color.green.opacity(0.15))
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            }
        case .failed:
            ZStack {
                Circle().fill(Color.red.opacity(0.15))
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
    }
}
