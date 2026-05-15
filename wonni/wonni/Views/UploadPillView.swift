//
//  UploadPillView.swift
//  wonni
//

import SwiftUI

// MARK: - Upload Pill (photo upload phase)

struct UploadPillView: View {
    @EnvironmentObject var uploadManager: UploadManager

    var body: some View {
        HStack(spacing: 12) {
            // Circular progress ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: uploadManager.uploadProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: uploadManager.uploadProgress)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("Uploading photos…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if let eta = uploadManager.uploadEtaString {
                    Text("\(eta) remaining")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Spacer()

            Image(systemName: "icloud.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(red: 0.05, green: 0.05, blue: 0.3).opacity(0.85)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

// MARK: - Process Pill (Gemini processing phase)

struct ProcessPillView: View {
    @EnvironmentObject var uploadManager: UploadManager
    @State private var showingProcessView = false

    var body: some View {
        HStack(spacing: 12) {
            // Circular progress ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: uploadManager.processProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: uploadManager.processProgress)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("Processing with AI…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(uploadManager.processCurrentIndex) of \(uploadManager.processTotalCount)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            Button {
                showingProcessView = true
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
                .overlay(Capsule().fill(Color(red: 0.1, green: 0.0, blue: 0.35).opacity(0.85)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .sheet(isPresented: $showingProcessView) {
            NavigationStack {
                ProcessProgressView()
            }
            .environmentObject(uploadManager)
        }
    }
}

// MARK: - Status icon (upload/process rows)

struct StatusIconView: View {
    let status: DraftUploadStatus

    var body: some View {
        ZStack {
            switch status {
            case .pending:
                Circle().fill(Color(.systemGray5))
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .uploading(let p):
                Circle().stroke(Color.blue.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: p)
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
    }
}
