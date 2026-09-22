//
//  VariantMercariBatchPostView.swift
//  wonni
//
//  Phase 3 — status UI for VariantMercariPostQueue: a compact summary line
//  ("3/5 posted. 1 failed. 1 pending.") that expands on tap into grouped
//  sections (Posted / Failed / In Progress / Pending), each with the action
//  that section supports (retry a failure, cancel a still-queued variant).
//  The actual posting runs headlessly in the background via
//  VariantMercariPostRunner — this view only reflects the queue's published
//  state and lets the user drive it (start, pause, retry, cancel, dismiss).
//

import SwiftUI

/// Entry point + status UI for "Post All Variants to Mercari" — presented as
/// a sheet from `VariantsEditorView`. Starts the queue as soon as it appears
/// (the user already reviewed/confirmed variant info in the table behind
/// it); the sheet can be dismissed and the batch keeps running as long as
/// this view stays mounted (owns the `@StateObject` queue), matching the
/// "runs in the background, check results when done" flow from the design.
struct VariantMercariBatchPostView: View {
    let items: [VariantMercariPostQueue.Item]

    @StateObject private var queue = VariantMercariPostQueue()
    @State private var isExpanded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summaryBar
                if isExpanded {
                    Divider()
                    groupedList
                } else {
                    Spacer()
                }
            }
            .navigationTitle("Post to Mercari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if queue.isRunning {
                    ToolbarItem(placement: .primaryAction) {
                        Button(queue.isPaused ? "Resume" : "Pause") {
                            queue.isPaused ? queue.resume() : queue.pause()
                        }
                    }
                }
            }
            .background(VariantMercariPostRunner(queue: queue))
            .onAppear {
                guard queue.items.isEmpty else { return }
                queue.configure(items)
                queue.start()
            }
        }
    }

    // MARK: - Summary bar (always visible, tap to expand/collapse)

    private var summaryBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(queue.summaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(queue.postedCount + queue.failedCount), total: Double(max(queue.total, 1)))
                    .tint(queue.failedCount > 0 ? .orange : .accentColor)
                if queue.isPaused {
                    Text("Paused — will finish the current listing, then stop starting new ones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if queue.isFinished {
                    Text(queue.failedCount > 0 ? "Done — some variants need a manual retry below." : "All variants posted.")
                        .font(.caption)
                        .foregroundStyle(queue.failedCount > 0 ? .orange : .secondary)
                }
            }
            .padding()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grouped list

    private var postedItems: [VariantMercariPostQueue.Item] {
        queue.items.filter { if case .posted = $0.state { return true }; return false }
    }
    private var failedItems: [VariantMercariPostQueue.Item] {
        queue.items.filter { if case .failed = $0.state { return true }; return false }
    }
    private var inProgressItems: [VariantMercariPostQueue.Item] {
        queue.items.filter {
            switch $0.state {
            case .posting, .retrying: return true
            default: return false
            }
        }
    }
    private var pendingItems: [VariantMercariPostQueue.Item] {
        queue.items.filter { if case .pending = $0.state { return true }; return false }
    }

    private var groupedList: some View {
        List {
            if !inProgressItems.isEmpty {
                Section("Posting now") {
                    ForEach(inProgressItems) { item in row(item) }
                }
            }
            if !failedItems.isEmpty {
                Section("Failed") {
                    ForEach(failedItems) { item in row(item) }
                }
            }
            if !postedItems.isEmpty {
                Section("Posted") {
                    ForEach(postedItems) { item in row(item) }
                }
            }
            if !pendingItems.isEmpty {
                Section("Pending") {
                    ForEach(pendingItems) { item in row(item) }
                        .onDelete { offsets in
                            for idx in offsets { queue.cancelPending(variantId: pendingItems[idx].id) }
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(_ item: VariantMercariPostQueue.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stateIcon(item.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayLabel).font(.subheadline.weight(.medium))
                Text(detailText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if case .failed = item.state {
                Button("Retry") { queue.retry(variantId: item.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if case .pending = item.state {
                Button(role: .destructive) {
                    queue.cancelPending(variantId: item.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateIcon(_ state: VariantMercariPostQueue.Item.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .posting, .retrying:
            ProgressView().scaleEffect(0.8)
        case .posted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func detailText(_ item: VariantMercariPostQueue.Item) -> String {
        switch item.state {
        case .pending: return "Queued"
        case .posting: return "Posting to Mercari…"
        case .retrying(let attempt): return "Retrying (attempt \(attempt) of \(VariantMercariPostQueue.maxAttemptsPerVariant))…"
        case .posted(let mercariItemId): return "Listed — Mercari ID \(mercariItemId)"
        case .failed(let reason): return reason
        }
    }
}
