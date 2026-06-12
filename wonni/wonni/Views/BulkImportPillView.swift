//
//  BulkImportPillView.swift
//  wonni
//

import SwiftUI

struct BulkImportPillView: View {
    @EnvironmentObject var importManager: BulkImportManager
    
    var progress: Double {
        guard importManager.totalCount > 0 else { return 0 }
        return Double(importManager.currentIndex) / Double(importManager.totalCount)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: progress)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("Importing items...")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(importManager.currentIndex) of \(importManager.totalCount)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            Button {
                importManager.showProgressSheet = true
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(red: 0.0, green: 0.3, blue: 0.1).opacity(0.85)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .sheet(isPresented: $importManager.showProgressSheet) {
            NavigationStack {
                BulkImportProgressView()
            }
            .environmentObject(importManager)
        }
    }
}

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
                    Text("$\(String(format: "%.2f", job.preview.price))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
