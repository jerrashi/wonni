//
//  VariantsEditorView.swift
//  wonni
//
//  Phase 2 of iOS variant parity — the "Manage variations" entry point and
//  its structural-edit sheet. The per-row price/SKU/quantity table lives in
//  VariantsTableView.swift; this file owns loading/persisting the product's
//  options+variants and the destructive-delete confirmation, mirroring web's
//  ManageVariationsModal / handleOptionsChange (web/src/pages/ProductDetail.jsx).
//
//  All structural logic (cartesian generation, rename/remove/add, the
//  single-SKU -> first-dimension transition) lives in VariantLogic
//  (Data/VariantEditing.swift) and is unit-tested there — this file is pure
//  SwiftUI wiring on top of it.
//

import SwiftUI

/// Entry point for editing a product's variation dimensions and per-variant
/// price/SKU/quantity — presented as a sheet from wherever an existing
/// product is being edited (see `DraftEditSheet`'s "Manage Variations" button
/// for the current, and only, hook: this feature only makes sense for a
/// product that already has a real `products/{id}` doc, i.e.
/// `item.firestoreListingId`, since everything here reads/writes through
/// `ProductRepository`).
struct VariantsEditorView: View {
    let productId: String
    /// The listing's shared price — used only to decide whether a variant's
    /// `price` counts as "populated" (see `VariantLogic.isPopulatedVariant`);
    /// a variant price that's just following the shared price isn't worth a
    /// destructive-delete confirm.
    let listingPrice: Double?

    @Environment(\.dismiss) private var dismiss

    @State private var options: [Option] = []
    @State private var variants: [Variant] = []
    @State private var hasVariants: Bool = false
    @State private var quantityVariesByVariant: Bool = false
    @State private var masterQuantity: Int = 0
    @State private var imageAssets: [ProductImageAsset] = []

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var showManageVariations = false
    @State private var pendingRemoval: PendingRemoval?

    /// Bridges a pending destructive-delete confirm (computed by
    /// `VariantLogic.rowsToBeRemoved`) back to whoever asked for the
    /// structural change — `ManageVariationsSheet`'s `saveDraft`/`deleteOption`
    /// `await` this exactly like web's `onChange(...)` awaits Firestore, so
    /// the sheet only leaves its edit view once the change is real.
    private struct PendingRemoval {
        let change: VariantStructuralChange
        let nextOptions: [Option]
        let populatedCount: Int
        let resume: ContinuationBox
    }

    /// A `CheckedContinuation` can only be resumed once; SwiftUI's alert
    /// `isPresented` binding setter and the explicit Cancel/Delete button
    /// actions can both end up trying to resolve the same pending confirm
    /// (button tap sets state directly; SwiftUI then also drives the binding
    /// to `false`) — this box makes a second resume a harmless no-op instead
    /// of the runtime trap `CheckedContinuation` gives for a real double-resume.
    private final class ContinuationBox {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError).foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if options.isEmpty {
                    emptyState
                } else {
                    editorBody
                }
            }
            .navigationTitle("Manage Variations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !options.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showManageVariations = true
                        } label: {
                            Image(systemName: "square.grid.2x2")
                        }
                    }
                }
            }
            .sheet(isPresented: $showManageVariations) {
                ManageVariationsSheet(options: options) { nextOptions, change in
                    await handleOptionsChange(nextOptions: nextOptions, change: change)
                }
            }
            .alert(
                "Delete variant data?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { presented in
                        if !presented { pendingRemoval?.resume.resume(false); pendingRemoval = nil }
                    }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingRemoval?.resume.resume(false)
                    pendingRemoval = nil
                }
                Button("Delete", role: .destructive) {
                    guard let pending = pendingRemoval else { return }
                    pendingRemoval = nil
                    Task {
                        let applied = await applyChange(nextOptions: pending.nextOptions, change: pending.change)
                        pending.resume.resume(applied)
                    }
                }
            } message: {
                let count = pendingRemoval?.populatedCount ?? 0
                Text("This will permanently delete \(count) variant\(count == 1 ? "" : "s") and its price/SKU/quantity data. This can't be undone.")
            }
            .alert(
                "Couldn't Save",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .task { await load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Variations Yet")
                .font(.title3.weight(.semibold))
            Text("Add a dimension like Style or Size to sell this product in multiple variations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showManageVariations = true
            } label: {
                Label("Add Variation", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            Toggle("Quantity varies by variant", isOn: $quantityVariesByVariant)
                .padding()
                .onChange(of: quantityVariesByVariant) { _, newValue in
                    Task { await persistQuantityMode(newValue) }
                }
            Divider()
            VariantsTableView(
                options: options,
                variants: $variants,
                quantityVariesByVariant: quantityVariesByVariant,
                masterQuantity: $masterQuantity,
                listingPrice: listingPrice,
                imageAssets: $imageAssets,
                onCommitVariants: { await persistVariants() },
                onCommitImageAssets: { await persistImageAssets() }
            )
        }
    }

    // MARK: - Load / persist

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            async let productDoc = ProductRepository.shared.fetchProductVariants(productId: productId)
            async let assets = ProductRepository.shared.fetchProductImageAssets(productId: productId)
            async let rawProduct = ProductRepository.shared.fetchProduct(productId: productId)
            let doc = try await productDoc
            imageAssets = try await assets
            let raw = try await rawProduct

            options = VariantLogic.options(from: doc)
            variants = VariantLogic.variants(from: doc)
            hasVariants = doc?.hasVariants ?? !options.isEmpty
            quantityVariesByVariant = doc?.quantityVariesByVariant ?? false
            masterQuantity = (raw?["quantity"] as? Int) ?? variants.first?.quantity ?? 0
        } catch {
            loadError = "Could not load this product's variations."
        }
        isLoading = false
    }

    /// Async bridge from `ManageVariationsSheet`'s save/delete actions
    /// (`onChange`) into the destructive-confirm gate + persistence, mirroring
    /// web's `handleOptionsChange`: compute what would be removed, confirm
    /// only if it's real data, then apply + persist.
    private func handleOptionsChange(nextOptions: [Option], change: VariantStructuralChange) async -> Bool {
        let removed = VariantLogic.rowsToBeRemoved(change: change, currentVariants: variants)
        let populatedCount = removed.filter { VariantLogic.isPopulatedVariant($0, listingPrice: listingPrice) }.count
        guard populatedCount > 0 else {
            return await applyChange(nextOptions: nextOptions, change: change)
        }
        return await withCheckedContinuation { continuation in
            pendingRemoval = PendingRemoval(
                change: change,
                nextOptions: nextOptions,
                populatedCount: populatedCount,
                resume: ContinuationBox(continuation)
            )
        }
    }

    @discardableResult
    private func applyChange(nextOptions: [Option], change: VariantStructuralChange) async -> Bool {
        let nextVariants = VariantLogic.applyStructuralChange(
            nextOptions: nextOptions,
            change: change,
            currentVariants: variants,
            productId: productId
        )
        options = nextOptions
        variants = nextVariants
        hasVariants = !nextOptions.isEmpty
        await persistVariants()
        return true
    }

    private func persistVariants() async {
        do {
            try await ProductRepository.shared.syncVariants(
                productId: productId,
                options: options,
                variants: variants,
                hasVariants: hasVariants,
                quantityVariesByVariant: quantityVariesByVariant
            )
        } catch {
            saveError = "Could not save your changes. Check your connection and try again."
        }
    }

    private func persistQuantityMode(_ newValue: Bool) async {
        // Turning shared quantity ON mirrors it onto every variant so the
        // table's "shared quantity" figure and each row start in sync,
        // matching web's own on-toggle behavior.
        if !newValue {
            variants = variants.map { $0.with(quantity: masterQuantity) }
        }
        await persistVariants()
    }

    private func persistImageAssets() async {
        do {
            try await ProductRepository.shared.syncProductImageAssets(productId: productId, imageAssets: imageAssets)
        } catch {
            saveError = "Could not save photo assignment. Check your connection and try again."
        }
    }
}

// MARK: - ManageVariationsSheet

/// Add/rename/delete a variation dimension and its values — mirrors web's
/// `ManageVariationsModal`. Every structural change here calls back into
/// `onChange` immediately (no separate "Save options" step, matching web:
/// only the price/SKU/qty table batches), which owns the destructive-delete
/// confirm and Firestore persistence; this sheet only leaves its edit view
/// once `onChange` reports the change was actually applied.
struct ManageVariationsSheet: View {
    let options: [Option]
    let onChange: ([Option], VariantStructuralChange) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var sheetView: SheetView = .list
    @State private var editingOptionName: String?
    @State private var draftName: String = ""
    @State private var draftValues: [DraftValue] = []
    @State private var originalValues: [String] = []
    @State private var newValueText: String = ""
    @State private var isSaving = false

    private enum SheetView { case list, edit }

    /// One value row in the edit form. `original` is the value's text when
    /// editing began (`nil` for a freshly-added value) — diffed at save time
    /// to tell "renamed this value" apart from "removed one, added another"
    /// (see `VariantStructuralChange.editOptionDimension`).
    private struct DraftValue: Identifiable {
        let id = UUID()
        var text: String
        var original: String?
    }

    var body: some View {
        NavigationStack {
            Group {
                switch sheetView {
                case .list: listView
                case .edit: editView
                }
            }
            .navigationTitle(sheetView == .edit ? (editingOptionName == nil ? "Add Variation" : "Edit Variation") : "Manage Variations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if sheetView == .edit {
                        Button("Back") { sheetView = .list }
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    private var listView: some View {
        List {
            Section {
                ForEach(options, id: \.name) { option in
                    Button {
                        openEdit(option)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name).font(.body.weight(.medium))
                            Text(option.values.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await deleteOption(option) }
                        }
                    }
                }
            }
            Button {
                openAdd()
            } label: {
                Label("Add Variation Dimension", systemImage: "plus")
            }
        }
    }

    private var editView: some View {
        Form {
            Section("Dimension name") {
                TextField("e.g. Style", text: $draftName)
            }
            Section("Values") {
                ForEach($draftValues) { $value in
                    TextField("Value", text: $value.text)
                }
                .onDelete { draftValues.remove(atOffsets: $0) }
                HStack {
                    TextField("Add a value", text: $newValueText)
                        .onSubmit { addDraftValue() }
                    Button("Add") { addDraftValue() }
                        .disabled(newValueText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if editingOptionName != nil {
                Section {
                    Text("Removing a value permanently deletes its variant row(s) and their price/SKU/quantity data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await saveDraft() }
            } label: {
                if isSaving {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Save").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .disabled(isSaving || !isDraftValid)
            .background(.regularMaterial)
        }
    }

    private var isDraftValid: Bool {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let values = draftValues.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else { return false }
        return Set(values).count == values.count
    }

    private func openEdit(_ option: Option) {
        editingOptionName = option.name
        draftName = option.name
        originalValues = option.values
        draftValues = option.values.map { DraftValue(text: $0, original: $0) }
        newValueText = ""
        sheetView = .edit
    }

    private func openAdd() {
        editingOptionName = nil
        draftName = ""
        originalValues = []
        draftValues = []
        newValueText = ""
        sheetView = .edit
    }

    private func addDraftValue() {
        let v = newValueText.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !draftValues.contains(where: { $0.text == v }) else { return }
        draftValues.append(DraftValue(text: v, original: nil))
        newValueText = ""
    }

    private func saveDraft() async {
        guard isDraftValid else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let values = draftValues.map { $0.text.trimmingCharacters(in: .whitespaces) }

        var nextOptions = options
        if let editingOptionName {
            nextOptions = options.map { $0.name == editingOptionName ? $0.with(name: name, values: values) : $0 }
        } else {
            nextOptions.append(Option(id: VariantLogic.generateVariantId(), name: name, values: values))
        }

        let change: VariantStructuralChange
        if let editingOptionName {
            var valueRenames: [String: String] = [:]
            for d in draftValues {
                guard let original = d.original, original != d.text.trimmingCharacters(in: .whitespaces) else { continue }
                valueRenames[original] = d.text.trimmingCharacters(in: .whitespaces)
            }
            let addedValues = draftValues.filter { $0.original == nil }.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let removedValues = originalValues.filter { ov in !draftValues.contains { $0.original == ov } }
            change = .editOptionDimension(
                name: editingOptionName,
                newName: name,
                valueRenames: valueRenames,
                removedValues: removedValues,
                addedValues: addedValues
            )
        } else {
            change = .addOptionDimension(name: name, values: values)
        }

        isSaving = true
        let applied = await onChange(nextOptions, change)
        isSaving = false
        // Only leave the edit view once the change actually persisted — if the
        // destructive-delete confirm was declined, or the write failed,
        // flipping to the list view would show stale/unchanged data and look
        // like the edit was silently reverted (same reasoning as web's
        // saveDraft).
        if applied {
            sheetView = .list
        }
    }

    private func deleteOption(_ option: Option) async {
        let nextOptions = options.filter { $0.name != option.name }
        _ = await onChange(nextOptions, .removeOptionDimension(name: option.name))
    }
}
