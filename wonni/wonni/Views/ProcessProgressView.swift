//
//  ProcessProgressView.swift
//  wonni
//

import SwiftUI
import SwiftData

/// Full-screen view that shows Gemini processing progress for each draft.
/// Present as a fullScreenCover from BulkListingOverviewView.
/// Pass onMinimize to navigate home; the view auto-dismisses when results are ready.
struct ProcessProgressView: View {
    var onMinimize: (() -> Void)? = nil

    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [Item]
    @State private var cache = CachedImageManager()

    private var orderedDrafts: [Item] {
        uploadManager.processQueuedIDs.compactMap { id in
            allItems.first { $0.id == id }
        }
    }

    private var allDone: Bool {
        guard !uploadManager.processStatuses.isEmpty else { return false }
        return uploadManager.processStatuses.values.allSatisfy {
            switch $0 { case .done, .failed: return true; default: return false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            ZStack {
                if allDone {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.purple)
                        Text("All items processed!")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 10) {
                        ProgressView(value: uploadManager.processProgress)
                            .tint(.purple)
                            .padding(.horizontal, 24)
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.purple)
                            Text("Processing \(uploadManager.processCurrentIndex) of \(uploadManager.processTotalCount)…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.35), value: allDone)

            Divider()

            // ── Per-item list ─────────────────────────────────────────────────
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

            Divider()

            // ── Minimize button ───────────────────────────────────────────────
            Button {
                if let minimizeAction = onMinimize {
                    minimizeAction()
                } else {
                    dismiss()
                }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 22, weight: .semibold))
                    Text(allDone ? "Close" : "Minimize")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .contentShape(Rectangle())
        }
        .navigationTitle("Processing")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: uploadManager.showProcessResults) { _, show in
            if show { dismiss() }
        }
    }

    @ViewBuilder
    private func draftStatusRow(_ item: Item) -> some View {
        let status = uploadManager.processStatuses[item.id] ?? .pending

        HStack(spacing: 14) {
            // Thumbnail
            Group {
                if let assetId = item.sourceAssetIdentifiers.first {
                    if let img = item.image(for: assetId) {
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

            // Title + status text
            VStack(alignment: .leading, spacing: 4) {
                Text(item.userEditedTitle ?? item.visionTitle ?? "Item")
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
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusLabel(for status: DraftUploadStatus) -> String {
        switch status {
        case .pending:                           return "Waiting…"
        case .uploading(let p) where p < 0.34:  return "Identifying…"
        case .uploading(let p) where p < 0.68:  return "Analyzing with AI…"
        case .uploading:                         return "Generating description…"
        case .done:                              return "Complete"
        case .failed:                            return "Couldn't identify"
        }
    }

    private func statusColor(for status: DraftUploadStatus) -> Color {
        switch status {
        case .pending:    return .secondary
        case .uploading:  return .purple
        case .done:       return .green
        case .failed:     return .orange
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
                Circle().stroke(Color.purple.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.08, p))
                    .stroke(Color.purple, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
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
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "exclamationmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
    }
}
