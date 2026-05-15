//
//  ProcessProgressView.swift
//  wonni
//

import SwiftUI

/// Full-screen view that shows Gemini processing progress for each draft.
/// The user can tap "∨" to minimize it to the ProcessPillView.
struct ProcessProgressView: View {
    @EnvironmentObject private var uploadManager: UploadManager
    @Environment(\.dismiss) private var dismiss
    @State private var cache = CachedImageManager()

    private var allDone: Bool {
        guard !uploadManager.processStatuses.isEmpty else { return false }
        return uploadManager.processStatuses.values.allSatisfy {
            switch $0 { case .done, .failed: return true; default: return false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            Group {
                if allDone {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All items processed!")
                                .font(.subheadline.weight(.semibold))
                            Text("Review the results below and tap Publish.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 8) {
                        ProgressView(value: uploadManager.processProgress)
                            .tint(.purple)
                            .padding(.horizontal, 20)
                        HStack(spacing: 4) {
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
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.35), value: allDone)

            Divider()

            // ── Per-item list ───────────────────────────────────────────────
            List(uploadManager.processedItemIDs.reversed(), id: \.self) { id in
                let status = uploadManager.processStatuses[id] ?? .pending
                HStack(spacing: 14) {
                    StatusIconView(status: status)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Item \(id.uuidString.prefix(8))")
                            .font(.body)
                            .lineLimit(1)
                        if case .done = status {
                            Text("AI analysis complete")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else if case .uploading = status {
                            Text("Analyzing with Gemini…")
                                .font(.caption2)
                                .foregroundStyle(.purple.opacity(0.8))
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
        .navigationTitle("AI Processing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Minimize to pill
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                }
            }
        }
    }
}
