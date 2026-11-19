//
//  SoldOutProgressView.swift
//  wonni
//
//  The list behind the "Marking sold out · 1 of 4" task bar (mock approved 2026-10-29,
//  redrawn 2026-11-19): one card per listing, one row per step; a running Mercari row has Open, which
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

    var body: some View {
        NavigationStack {
            // Board 2 of the 2026-11-19 mock: one card per listing, one row per step
            // ("Wonni + eBay", then Mercari) with Open / Retry / Skip. Text kept short.
            List {
                ForEach(runner.jobs) { job in
                    Section {
                        Text(job.title)
                            .font(.headline)
                            .lineLimit(1)
                        serverRow(job)
                        if job.hasMercariStep { mercariRow(job) }
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
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .finished(let failed) = runner.phase, !failed.isEmpty {
                        Button("Retry \(failed.count)") { runner.retryAllFailed() }
                    } else {
                        Button("Minimize") { dismiss() }
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

    // MARK: Rows

    private func serverRow(_ job: SoldOutJob) -> some View {
        HStack(spacing: 10) {
            stepIcon(job.serverStep)
            VStack(alignment: .leading, spacing: 1) {
                Text(SoldOutPlan.serverRowTitle(job))
                if case .failed(let reason) = job.serverStep {
                    Text(reason).font(.footnote).foregroundStyle(.red).lineLimit(3)
                }
            }
            Spacer(minLength: 4)
            if case .failed = job.serverStep, job.ended {
                Button("Retry") { runner.retry(job.id) }.buttonStyle(.bordered)
                if job.platformErrors?.isEmpty == false {
                    Button("Skip") { runner.skip(job.id, mercari: false) }.buttonStyle(.bordered)
                }
            } else if !job.ended, job.serverStep == .waiting {
                Button("Remove") { runner.remove(job.id) }.buttonStyle(.bordered).tint(.secondary)
            }
        }
        .font(.subheadline)
    }

    private func mercariRow(_ job: SoldOutJob) -> some View {
        HStack(spacing: 10) {
            stepIcon(job.mercariStep)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mercari")
                switch job.mercariStep {
                case .running(let step):
                    Text(step).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                case .failed(let reason):
                    Text(reason).font(.footnote).foregroundStyle(.red).lineLimit(3)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 4)
            switch job.mercariStep {
            case .running where runner.currentMercariJobId == job.id:
                Button("Open") { showWebView = true }.buttonStyle(.bordered)
                Button("Skip") { runner.skip(job.id, mercari: true) }.buttonStyle(.bordered)
            case .waiting:
                Button("Skip") { runner.skip(job.id, mercari: true) }.buttonStyle(.bordered)
            case .failed:
                Button("Retry") { runner.retry(job.id) }.buttonStyle(.bordered)
                Button("Skip") { runner.skip(job.id, mercari: true) }.buttonStyle(.bordered)
            default:
                EmptyView()
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func stepIcon(_ state: SoldOutJob.StepState) -> some View {
        Group {
            switch state {
            case .waiting:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .skipped:
                Image(systemName: "minus.circle.fill").foregroundStyle(.gray)
            }
        }
        .font(.title3)
        .frame(width: 22)
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
