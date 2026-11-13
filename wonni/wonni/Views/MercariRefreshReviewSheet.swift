//
//  MercariRefreshReviewSheet.swift
//
//  The review screen after a Mercari Refresh scan (mock
//  https://claude.ai/artifact/9kVDXBohrFYbQQCzfHCaWp, approved 2026-11-12):
//  every new sale is listed and checked, the user unchecks what they don't want,
//  links unmatched rows to a product, or swipes a row to "Never import". Nothing is
//  recorded until Import. The screen shows its own title only; the mock's step
//  numbers were an internal label.
//

import SwiftUI

struct MercariRefreshReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var plan: MercariRefreshPlan
    /// Called after a successful import so the dashboard can reload.
    let onImported: (Int) -> Void

    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var linkingRow: MercariRefreshRow?
    @State private var importedCount: Int?

    init(plan: MercariRefreshPlan, onImported: @escaping (Int) -> Void) {
        _plan = State(initialValue: plan)
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            Group {
                if let importedCount {
                    doneView(importedCount)
                } else {
                    reviewList
                }
            }
            .navigationTitle(importedCount != nil ? "Imported" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if importedCount == nil {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("mercariReviewCancelButton")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if importedCount != nil {
                        Button("Done") { dismiss() }.accessibilityIdentifier("mercariReviewDoneButton")
                    }
                }
            }
        }
        .sheet(item: $linkingRow) { row in
            MercariLinkPickerSheet(row: row) { link in
                plan.link(row.id, to: link)
            }
        }
    }

    private var title: String {
        let n = plan.importable.count
        return n == 1 ? "1 new Mercari sale" : "\(n) new Mercari sales"
    }

    // MARK: Review list

    private var reviewList: some View {
        VStack(spacing: 0) {
            List {
                if plan.importable.isEmpty {
                    Text("No new Mercari sales.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(plan.importable) { row in
                            rowView(row)
                                .swipeActions(edge: .trailing) {
                                    Button("Never import", role: .destructive) { Task { await neverImport(row) } }
                                }
                        }
                    } footer: {
                        Text("Uncheck any you do not want. Swipe a row left for Never import.")
                    }
                }
                if !plan.hidden.isEmpty {
                    Section {
                        ForEach(plan.hidden) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title.isEmpty ? row.id : row.title).lineLimit(1)
                                    Text(row.price, format: .currency(code: "USD"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") { Task { await restore(row) } }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("mercariReviewRestore-\(row.id)")
                            }
                        }
                    } header: {
                        Text("Never import")
                    } footer: {
                        Text("You hid these earlier. Restore one to put it back on the list above.")
                    }
                }
                let invalid = plan.rows.filter { $0.kind == .invalid }
                if !invalid.isEmpty {
                    Section("Could not be read") {
                        ForEach(invalid) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title.isEmpty ? row.id : row.title).lineLimit(1)
                                Text(row.warning ?? "Missing a price. Open the sale on Mercari to import it by hand.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote).foregroundStyle(.red)
                    .padding(.horizontal).padding(.top, 8)
            }
            footer
        }
    }

    private func rowView(_ row: MercariRefreshRow) -> some View {
        HStack(spacing: 12) {
            Button {
                plan.toggle(row.id)
            } label: {
                Image(systemName: plan.isChecked(row.id) ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(plan.isChecked(row.id) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import \(row.title)")
            .accessibilityValue(plan.isChecked(row.id) ? "checked" : "unchecked")
            .accessibilityIdentifier("mercariReviewCheck-\(row.id)")

            thumbnail(row)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title.isEmpty ? row.id : row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                matchLine(row)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.price, format: .currency(code: "USD")).font(.subheadline.weight(.semibold))
                if let takeHome = row.takeHome {
                    Text("take-home \(takeHome.formatted(.currency(code: "USD")))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(plan.isChecked(row.id) ? 1 : 0.55)
    }

    @ViewBuilder private func matchLine(_ row: MercariRefreshRow) -> some View {
        if let link = plan.links[row.id] {
            HStack(spacing: 6) {
                Text("Linked").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.18), in: Capsule())
                Text(link.variantLabel.map { "\(link.productTitle), \($0)" } ?? link.productTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Change") { linkingRow = row }.font(.caption)
            }
        } else if let title = row.productTitle {
            HStack(spacing: 6) {
                Text("Matched").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.18), in: Capsule())
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Button("Link to product…") { linkingRow = row }
                .font(.caption)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
                .accessibilityIdentifier("mercariReviewLink-\(row.id)")
        }
    }

    private func thumbnail(_ row: MercariRefreshRow) -> some View {
        Group {
            if let s = row.thumbnailUrl, let url = URL(string: s) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color(.systemGray5) }
            } else {
                Color(.systemGray5)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text("\(plan.selectedCount) of \(plan.importable.count) selected")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await importSelected() }
            } label: {
                if isImporting { ProgressView() } else { Text("Import \(plan.selectedCount)").fontWeight(.semibold) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(plan.selectedCount == 0 || isImporting)
            .accessibilityIdentifier("mercariReviewImportButton")
        }
        .padding()
        .background(.bar)
    }

    // MARK: Done

    private func doneView(_ count: Int) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Text("\(count)").font(.system(size: 44, weight: .bold)).monospacedDigit()
            Text(count == 1 ? "sale recorded" : "sales recorded").foregroundStyle(.secondary)
            Text("Stock was lowered and your other platforms were updated.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func importSelected() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let response = try await MercariRefreshService.record(plan)
            importedCount = response.recorded
            onImported(response.recorded)
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func restore(_ row: MercariRefreshRow) async {
        errorMessage = nil
        do {
            try await MercariRefreshService.setDiscarded(plan, ids: [row.id], discarded: false)
            withAnimation { plan.restore(row.id) }
        } catch {
            errorMessage = "Could not restore that sale: \(error.localizedDescription)"
        }
    }

    private func neverImport(_ row: MercariRefreshRow) async {
        errorMessage = nil
        do {
            try await MercariRefreshService.setDiscarded(plan, ids: [row.id], discarded: true)
            withAnimation { plan.remove([row.id]) }
        } catch {
            errorMessage = "Could not hide that sale: \(error.localizedDescription)"
        }
    }
}

// MARK: - Link picker

/// "Link sale to product": pick a product, then (when it has variants) the version that sold.
struct MercariLinkPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let row: MercariRefreshRow
    let onLink: (MercariLink) -> Void

    @State private var candidates: [MercariRefreshService.LinkCandidate] = []
    @State private var query = ""
    @State private var chosen: MercariRefreshService.LinkCandidate?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title.isEmpty ? row.id : row.title).font(.subheadline.weight(.semibold))
                        Text(row.price.formatted(.currency(code: "USD"))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let chosen, !chosen.variants.isEmpty {
                    Section("Which version sold?") {
                        ForEach(chosen.variants) { v in
                            Button(v.label) {
                                onLink(.init(productId: chosen.id, variantSku: v.sku, productTitle: chosen.title, variantLabel: v.label))
                                dismiss()
                            }
                        }
                    }
                } else {
                    Section("Your products") {
                        if isLoading {
                            ProgressView()
                        } else {
                            ForEach(MercariRefreshService.filter(candidates, query: query)) { c in
                                Button {
                                    if c.variants.isEmpty {
                                        onLink(.init(productId: c.id, variantSku: nil, productTitle: c.title, variantLabel: nil))
                                        dismiss()
                                    } else {
                                        chosen = c
                                    }
                                } label: {
                                    HStack {
                                        Text(c.title).lineLimit(2)
                                        Spacer()
                                        if !c.variants.isEmpty {
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("The Mercari id is saved on this product, so the next scan matches it without asking.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Search your products")
            .navigationTitle("Link sale to product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(chosen != nil ? "Back" : "Cancel") {
                        if chosen != nil { chosen = nil } else { dismiss() }
                    }
                }
            }
            .task {
                candidates = await MercariRefreshService.linkCandidates()
                isLoading = false
                if query.isEmpty { query = firstWords(of: row.title) }
            }
        }
    }

    /// Pre-fills the search with the first two words of the sale's title.
    private func firstWords(of title: String) -> String {
        title.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
