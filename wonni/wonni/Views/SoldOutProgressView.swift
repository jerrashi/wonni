//
//  SoldOutProgressView.swift
//  wonni
//
//  The list behind the "Marking sold out · 1 of 4" pill (mock approved 2026-10-29):
//  one row per listing, one chip per platform; a running Mercari row has Open, which
//  shows the live Mercari page the automation is driving (minimized by default, never
//  fully hidden — same as Mercari posting). When every listing confirmed, the runner
//  closes this sheet and the pill itself; when some failed, the sheet stays as the
//  "not marked sold out" list with Retry / Dismiss.
//

import SwiftUI

struct SoldOutProgressView: View {
    @ObservedObject private var runner = SoldOutRunner.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showWebView = false

    private var doneCount: Int { runner.jobs.filter(\.succeeded).count }
    private var failedCount: Int { runner.jobs.filter { $0.failure != nil }.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(runner.jobs) { job in
                        row(job)
                    }
                } header: {
                    Text(headerText)
                } footer: {
                    if case .finished = runner.phase {
                        Text("Listings that failed are still in stock. Retry runs the same steps again.")
                    } else {
                        Text("Mercari steps run one at a time in a web view. Open shows the page; everything keeps running if you leave the app.")
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .finished = runner.phase {
                        Button("Dismiss") {
                            runner.dismissFinished()
                            dismiss()
                        }
                    } else {
                        Button("Minimize") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if case .finished(let failed) = runner.phase, !failed.isEmpty {
                        Button("Retry \(failed.count)") { runner.retryAllFailed() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showWebView) {
                SoldOutMercariWebView()
            }
            .onChange(of: runner.currentAutomator == nil) { _, gone in
                // The step ended while the page was open: drop back to the list.
                if gone { showWebView = false }
            }
        }
    }

    private var navigationTitle: String {
        if case .finished = runner.phase { return "Not Marked Sold Out" }
        return "Marking Sold Out"
    }

    private var headerText: String {
        let total = runner.jobs.count
        var parts = ["\(doneCount) of \(total) done"]
        if failedCount > 0 { parts.append("\(failedCount) need\(failedCount == 1 ? "s" : "") attention") }
        return parts.joined(separator: " · ")
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ job: SoldOutJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(job)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                chips(job)
                if let failure = job.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            trailingButton(job)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnail(_ job: SoldOutJob) -> some View {
        if let path = job.coverPhotoPath {
            StorageImage(path: path)
                .frame(width: 44, height: 44)
                .cornerRadius(6)
                .clipped()
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray5))
                .frame(width: 44, height: 44)
        }
    }

    /// One chip per platform. The server step covers Wonni and the API platforms at
    /// once, so they share its state; Mercari has its own.
    @ViewBuilder
    private func chips(_ job: SoldOutJob) -> some View {
        FlowChips {
            ForEach(job.serverPlatforms, id: \.self) { platform in
                chip(SoldOutPlan.displayName(platform), state: job.serverStep)
            }
            if job.hasMercariStep {
                chip("Mercari", state: job.mercariStep, verb: job.mercariAction == .delete ? "deleted" : "deactivated")
            }
        }
    }

    @ViewBuilder
    private func chip(_ name: String, state: SoldOutJob.StepState, verb: String? = nil) -> some View {
        switch state {
        case .waiting:
            chipLabel(name, color: .secondary, icon: nil)
        case .running(let step):
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6).frame(width: 10, height: 10)
                Text(name == "Mercari" ? "\(name) · \(step)" : name)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        case .done:
            chipLabel(verb.map { "\(name) \($0)" } ?? name, color: .green, icon: "checkmark")
        case .failed:
            chipLabel(name, color: .red, icon: "xmark")
        }
    }

    private func chipLabel(_ text: String, color: Color, icon: String?) -> some View {
        HStack(spacing: 3) {
            Text(text)
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
        }
        .font(.caption2)
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(color == .secondary ? 0.08 : 0.12)))
    }

    @ViewBuilder
    private func trailingButton(_ job: SoldOutJob) -> some View {
        if job.failure != nil {
            Button("Retry") { runner.retry(job.id) }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.red)
        } else if case .running = job.mercariStep, runner.currentMercariJobId == job.id {
            Button("Open") { showWebView = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
        } else if !job.ended, job.serverStep == .waiting {
            Button("Remove") { runner.remove(job.id) }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.secondary)
        }
    }
}

/// Chips that wrap onto a second line when a listing is on many platforms.
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        // iOS 16+: a lazy grid with adaptive columns is the simplest wrapping row.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 5, alignment: .leading)], alignment: .leading, spacing: 5) {
            content
        }
    }
}

/// The live Mercari page behind a running Mercari step. Minimize keeps the step
/// running; Stop fails this listing (its stock is restored) and the queue moves on.
struct SoldOutMercariWebView: View {
    @ObservedObject private var runner = SoldOutRunner.shared
    @Environment(\.dismiss) private var dismiss

    private var job: SoldOutJob? {
        runner.jobs.first { $0.id == runner.currentMercariJobId }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let automator = runner.currentAutomator {
                    AutomatorHeader(automator: automator, action: job?.mercariAction ?? .deactivate)
                    MercariSheetWebView(webView: automator.webView)
                } else {
                    Spacer()
                    Text("This step has finished.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .navigationTitle(job?.title ?? "Mercari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Minimize") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Stop", role: .destructive) {
                        runner.stopCurrentMercariStep()
                        dismiss()
                    }
                    .disabled(runner.currentAutomator == nil)
                }
            }
        }
    }

    private struct AutomatorHeader: View {
        @ObservedObject var automator: MercariListingStateAutomator
        let action: MercariSoldOutAction

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(action == .delete ? "Deleting on Mercari" : "Deactivating on Mercari")
                        .font(.subheadline.weight(.semibold))
                }
                Text(automator.stepText.isEmpty ? "Connecting to Mercari…" : automator.stepText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("If Mercari asks you to sign in, do it here; the step continues on its own.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
    }
}
