//
//  MercariRefreshReviewSheet.swift
//
//  Review for Mercari sales a refresh could not record on its own (mock
//  https://claude.ai/artifact/3N5S6mWWBA36jptkxDtygP v4, approved 2026-11-14). Opened
//  from the dashboard banner, never on its own. Sections: "Needs info" (no title /
//  price / date: can't be checked until edited), "Ready", "Never import". Every row
//  opens MercariSaleEditSheet. Cancel just closes: the rows stay in the server-side
//  inbox and the banner keeps counting them.
//

import SwiftUI

struct MercariRefreshReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var plan: MercariRefreshPlan
    /// Called after an import with the toast text, so the dashboard can reload and show it.
    let onImported: (String) -> Void
    /// Called after Never import / Restore so the dashboard's banner count follows.
    let onInboxChanged: () -> Void

    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var editingRow: MercariRefreshRow?

    init(plan: MercariRefreshPlan, onImported: @escaping (String) -> Void, onInboxChanged: @escaping () -> Void = {}) {
        _plan = State(initialValue: plan)
        self.onImported = onImported
        self.onInboxChanged = onInboxChanged
    }

    var body: some View {
        NavigationStack {
            reviewList
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("mercariReviewCancelButton")
                    }
                }
        }
        .sheet(item: $editingRow) { row in
            MercariSaleEditSheet(
                row: row,
                product: plan.product(for: row),
                onDone: { edited, link, declined in
                    plan.update(edited)
                    if let link { plan.link(edited.id, to: link) }
                    if declined { plan.unlink(edited.id) }
                },
                onNeverImport: { Task { await neverImport(row) } }
            )
        }
    }

    private var title: String {
        let n = plan.importable.count
        return n == 1 ? "1 Mercari sale" : "\(n) Mercari sales"
    }

    // MARK: Review list

    private var reviewList: some View {
        VStack(spacing: 0) {
            List {
                if plan.importable.isEmpty {
                    Text("Nothing left to review.").foregroundStyle(.secondary)
                }
                if !plan.needsInfo.isEmpty {
                    Section {
                        ForEach(plan.needsInfo) { rowView($0) }
                    } header: {
                        Text("Needs info (\(plan.needsInfo.count))")
                    } footer: {
                        Text("Mercari didn't give these a price or date. Tap one to fill it in.")
                    }
                }
                if !plan.ready.isEmpty {
                    Section {
                        ForEach(plan.ready) { rowView($0) }
                    } header: {
                        Text("Ready (\(plan.ready.count))")
                    } footer: {
                        Text("Tap a row to edit it. Uncheck any you don't want yet; they stay here for later.")
                    }
                }
                if !plan.hidden.isEmpty {
                    Section {
                        ForEach(plan.hidden) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title.isEmpty ? row.id : row.title).lineLimit(1)
                                    Text("Won't be imported or shown again")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") { Task { await restore(row) } }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("mercariReviewRestore-\(row.id)")
                            }
                        }
                    } header: {
                        Text("Never import (\(plan.hidden.count))")
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
        let incomplete = !row.missing.isEmpty
        let checked = plan.isChecked(row.id)
        return HStack(spacing: 12) {
            Button {
                plan.toggle(row.id)
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(incomplete)
            .accessibilityLabel("Import \(row.title.isEmpty ? row.id : row.title)")
            .accessibilityValue(checked ? "checked" : "unchecked")
            .accessibilityIdentifier("mercariReviewCheck-\(row.id)")

            Button { editingRow = row } label: {
                HStack(spacing: 12) {
                    thumbnail(row)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title.isEmpty ? row.id : row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        statusLine(row)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.price.map { $0.formatted(.currency(code: "USD")) } ?? "—").font(.subheadline.weight(.semibold))
                        if let takeHome = row.takeHome ?? MercariRefreshRow.estimatedTakeHome(row.price) {
                            Text(takeHome.formatted(.currency(code: "USD")))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mercariReviewRow-\(row.id)")
        }
        .opacity(checked || incomplete ? 1 : 0.55)
        .swipeActions(edge: .trailing) {
            Button("Never import", role: .destructive) { Task { await neverImport(row) } }
        }
    }

    @ViewBuilder private func statusLine(_ row: MercariRefreshRow) -> some View {
        HStack(spacing: 6) {
            if !row.missing.isEmpty {
                chip("Needs \(row.missing.joined(separator: " + "))", .red)
            } else {
                switch plan.product(for: row) {
                case .matched(let title):
                    chip("Matched", .green)
                    Text(title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .linked(let link):
                    chip("Linked", .green)
                    Text(link.variantLabel.map { "\(link.productTitle), \($0)" } ?? link.productTitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .suggested(_, let title):
                    chip("Suggested", .orange)
                    Text(title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .none:
                    chip("Not linked", .orange)
                    Text("stock won't change").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
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
            Text("\(plan.selectedCount) selected")
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

    // MARK: Actions

    private func importSelected() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        do {
            let response = try await MercariRefreshService.record(plan)
            let done = response.results.filter { $0.outcome == .recorded || $0.outcome == .duplicate }
            let failed = response.results.filter { $0.outcome == .parseFailed || $0.outcome == .noMatch }
            let lowered = response.results.filter { $0.outcome == .recorded && $0.productId != nil }.count
            plan.remove(Set(done.map(\.mercariItemId)))
            var message = "\(done.count) Mercari sale\(done.count == 1 ? "" : "s") recorded"
            if lowered > 0 { message += " · stock lowered on \(lowered)" }
            let left = plan.importable.count
            if left > 0 { message += " · \(left) still waiting" }
            onImported(message)
            if failed.isEmpty {
                dismiss()
            } else {
                errorMessage = failed.map { "\($0.mercariItemId): \($0.warning ?? "could not record")" }.joined(separator: "\n")
            }
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func restore(_ row: MercariRefreshRow) async {
        errorMessage = nil
        do {
            try await MercariRefreshService.setDiscarded(plan, ids: [row.id], discarded: false)
            withAnimation { plan.restore(row.id) }
            onInboxChanged()
        } catch {
            errorMessage = "Could not restore that sale: \(error.localizedDescription)"
        }
    }

    private func neverImport(_ row: MercariRefreshRow) async {
        errorMessage = nil
        do {
            try await MercariRefreshService.setDiscarded(plan, ids: [row.id], discarded: true)
            withAnimation { plan.hide(row.id) }
            onInboxChanged()
        } catch {
            errorMessage = "Could not hide that sale: \(error.localizedDescription)"
        }
    }
}

// MARK: - Edit form

/// One sale's fields before import: title, price, take-home (estimated until edited), sold
/// date, quantity, product link, Never import. Done is disabled until title, price and date
/// are filled in.
struct MercariSaleEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var row: MercariRefreshRow
    let product: MercariRefreshPlan.Product
    /// (edited row, new link if the user picked one, true if they unlinked)
    let onDone: (MercariRefreshRow, MercariLink?, Bool) -> Void
    let onNeverImport: () -> Void

    @State private var priceText: String
    @State private var takeHomeText: String
    @State private var takeHomeTouched: Bool
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var newLink: MercariLink?
    @State private var unlinked = false
    @State private var showPicker = false

    init(row: MercariRefreshRow, product: MercariRefreshPlan.Product,
         onDone: @escaping (MercariRefreshRow, MercariLink?, Bool) -> Void, onNeverImport: @escaping () -> Void) {
        _row = State(initialValue: row)
        self.product = product
        self.onDone = onDone
        self.onNeverImport = onNeverImport
        _priceText = State(initialValue: row.price.map { String(format: "%.2f", $0) } ?? "")
        let estimate = MercariRefreshRow.estimatedTakeHome(row.price)
        _takeHomeText = State(initialValue: (row.takeHome ?? estimate).map { String(format: "%.2f", $0) } ?? "")
        _takeHomeTouched = State(initialValue: row.takeHome != nil && !row.takeHomeEstimated)
        _hasDate = State(initialValue: row.soldAt != nil)
        _date = State(initialValue: row.soldAt ?? Date())
    }

    private var edited: MercariRefreshRow {
        var r = row
        r.price = Double(priceText.replacingOccurrences(of: "$", with: ""))
        r.takeHome = Double(takeHomeText.replacingOccurrences(of: "$", with: ""))
        r.takeHomeEstimated = !takeHomeTouched
        r.soldAt = hasDate ? date : nil
        return r
    }

    private var productLine: (text: String, canChange: Bool) {
        if let newLink { return (newLink.variantLabel.map { "\(newLink.productTitle), \($0)" } ?? newLink.productTitle, true) }
        if unlinked { return ("Not linked. The sale still counts in your totals, but no stock changes.", true) }
        switch product {
        case .matched(let title): return ("\(title ?? "Product") · matched by Mercari id", false)
        case .linked(let link): return (link.variantLabel.map { "\(link.productTitle), \($0)" } ?? link.productTitle, true)
        case .suggested(_, let title): return ("Suggested: \(title ?? "")", true)
        case .none: return ("Not linked. The sale still counts in your totals, but no stock changes.", true)
        }
    }

    private var isLinked: Bool {
        if newLink != nil { return true }
        if unlinked { return false }
        if case .none = product { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Link("Open on Mercari", destination: URL(string: "https://www.mercari.com/us/item/\(row.id)/")!)
                        .font(.footnote)
                } footer: {
                    Text("Mercari item \(row.id)")
                }
                Section("Sale") {
                    TextField("Title (required)", text: $row.title)
                        .accessibilityIdentifier("mercariEditTitle")
                    HStack {
                        Text("Sale price")
                        Spacer()
                        TextField("Required", text: $priceText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("mercariEditPrice")
                            .onChange(of: priceText) { _, new in
                                guard !takeHomeTouched else { return }
                                takeHomeText = MercariRefreshRow.estimatedTakeHome(Double(new)).map { String(format: "%.2f", $0) } ?? ""
                            }
                    }
                    HStack {
                        Text(takeHomeTouched ? "Take-home" : "Take-home (estimated)")
                        Spacer()
                        TextField("After fees", text: $takeHomeText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .onChange(of: takeHomeText) { old, new in
                                if new != (MercariRefreshRow.estimatedTakeHome(Double(priceText)).map { String(format: "%.2f", $0) } ?? "") {
                                    takeHomeTouched = true
                                }
                                _ = old
                            }
                    }
                    if hasDate {
                        DatePicker("Sold on", selection: $date, displayedComponents: .date)
                    } else {
                        Button("Add sold date (required)") { hasDate = true }
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("mercariEditAddDate")
                    }
                    Stepper("Quantity \(row.quantity)", value: $row.quantity, in: 1...99)
                }
                Section {
                    Text(productLine.text).font(.subheadline)
                        .foregroundStyle(isLinked ? .primary : .secondary)
                    if productLine.canChange {
                        Button(isLinked ? "Change product" : "Link to product…") { showPicker = true }
                        if isLinked {
                            Button("Unlink", role: .destructive) { newLink = nil; unlinked = true }
                        }
                    }
                } header: {
                    Text("Product")
                }
                Section {
                    Button("Never import this sale", role: .destructive) {
                        onNeverImport()
                        dismiss()
                    }
                }
                if !edited.missing.isEmpty {
                    Section {
                        Text("Fill in \(edited.missing.joined(separator: ", ")) to import this sale.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(edited, newLink, unlinked && newLink == nil)
                        dismiss()
                    }
                    .disabled(!edited.missing.isEmpty)
                    .accessibilityIdentifier("mercariEditDone")
                }
            }
            .sheet(isPresented: $showPicker) {
                MercariLinkPickerSheet(row: edited) { link in
                    newLink = link
                    unlinked = false
                }
            }
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
                        Text(row.price.map { $0.formatted(.currency(code: "USD")) } ?? "No price yet").font(.caption).foregroundStyle(.secondary)
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
                    Text("The Mercari id is saved on this product, so the next refresh records its sales on its own.")
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
