//
//  BulkImportProgressView.swift
//  wonni
//

import SwiftUI

struct BulkImportProgressView: View {
    @EnvironmentObject var importManager: BulkImportManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List(importManager.jobs) { job in
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: job.preview.thumbnailUrl)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.systemGray5)
                }
                .frame(width: 44, height: 44)
                .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.preview.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let desc = job.preview.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Text("$\(String(format: "%.2f", job.preview.price))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                statusIcon(for: job.status)
            }
        }
        .navigationTitle("Bulk Import Progress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
    
    @ViewBuilder
    private func statusIcon(for status: BulkImportStatus) -> some View {
        ZStack {
            switch status {
            case .pending:
                Circle().fill(Color(.systemGray5))
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .extracting:
                ProgressView()
                    .scaleEffect(0.8)
            case .done:
                Circle().fill(Color.green.opacity(0.15))
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            case .failed:
                Circle().fill(Color.red.opacity(0.15))
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 24, height: 24)
    }
}
