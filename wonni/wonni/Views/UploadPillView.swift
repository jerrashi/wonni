//
//  UploadPillView.swift
//  wonni
//

import SwiftUI

struct UploadPillView: View {
    @EnvironmentObject var uploadManager: UploadManager

    var body: some View {
        Group {
            switch uploadManager.pillState {
            case .pill:
                pillContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            case .minimized:
                minimizedBar
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 83)
        .animation(.spring(response: 0.3), value: uploadManager.pillState)
        .sheet(isPresented: $uploadManager.showExpandedModal) {
            UploadExpandedModal()
                .environmentObject(uploadManager)
        }
    }

    // MARK: - Full pill

    private var pillContent: some View {
        HStack(spacing: 12) {
            // Circular progress ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: uploadManager.overallProgress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: uploadManager.overallProgress)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(uploadManager.etaString.map { "\($0) remaining" } ?? "Uploading…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Uploading \(uploadManager.currentIndex) of \(uploadManager.totalCount)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            Button {
                uploadManager.showExpandedModal = true
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }

            Button {
                withAnimation(.spring(response: 0.3)) {
                    uploadManager.pillState = .minimized
                }
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.65)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Minimized progress bar

    private var minimizedBar: some View {
        ProgressView(value: uploadManager.overallProgress)
            .tint(.blue)
            .frame(maxWidth: .infinity)
            .scaleEffect(y: 1.5, anchor: .bottom)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) {
                    uploadManager.pillState = .pill
                }
            }
    }
}

// MARK: - Expanded modal

struct UploadExpandedModal: View {
    @EnvironmentObject var uploadManager: UploadManager
    @Environment(\.dismiss) private var dismiss

    private var sortedIDs: [UUID] {
        uploadManager.statuses.keys.sorted {
            let a = uploadManager.draftNames[$0] ?? ""
            let b = uploadManager.draftNames[$1] ?? ""
            return a < b
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    ProgressView(value: uploadManager.overallProgress)
                        .tint(.blue)
                        .padding(.horizontal, 20)

                    Text("Uploading draft \(uploadManager.currentIndex) of \(uploadManager.totalCount)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)

                Divider()

                List {
                    ForEach(sortedIDs, id: \.self) { id in
                        let status = uploadManager.statuses[id] ?? .pending
                        let name = uploadManager.draftNames[id] ?? "Draft"

                        HStack(spacing: 14) {
                            StatusIconView(status: status)
                                .frame(width: 28, height: 28)

                            Text(name)
                                .font(.body)
                                .lineLimit(1)

                            Spacer()

                            if case .uploading(let p) = status {
                                Text("\(Int(p * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Upload Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        uploadManager.cancel()
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - Status icon

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
