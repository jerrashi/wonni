//
//  VariantsTableView.swift
//  wonni
//
//  The per-variant price/SKU/quantity table inside VariantsEditorView.
//  Mirrors web's two-level Style x Size table (ProductDetail.jsx,
//  renderPrimaryRow/renderRow/commitPrimaryFieldEdit/confirmBulkEdit): for a
//  single dimension it's a flat list; for two dimensions it defaults to a
//  "primary" (first dimension) view where editing price cascades to every
//  row sharing that primary value, gated by the same confirm-with-"don't ask
//  again" dialog as web, and a "secondary" view for per-SKU editing.
//
//  Auto-save vs. explicit save: web has no Save button — every field commits
//  on blur. SwiftUI has no exact blur equivalent for a plain TextField, so
//  this commits on Return (`.onSubmit`) and once more as a safety net when
//  the field's container disappears — not identical to web's keystroke-level
//  autosave, but close enough that nothing typed is ever lost, without wiring
//  a FocusState per row just to fake `onBlur`. This is a deliberate,
//  documented divergence — the structural data operations above are what
//  actually needed to match web bit for bit.
//

import SwiftUI

struct VariantsTableView: View {
    let options: [Option]
    @Binding var variants: [Variant]
    let quantityVariesByVariant: Bool
    @Binding var masterQuantity: Int
    let listingPrice: Double?
    @Binding var imageAssets: [ProductImageAsset]
    let onCommitVariants: () async -> Void
    let onCommitImageAssets: () async -> Void

    @State private var tableMode: TableMode = .primary
    @State private var pendingBulkEdit: PendingBulkEdit?
    @AppStorage("wonni_skip_primary_bulk_edit_warning") private var skipBulkEditWarning = false
    @State private var photoPickerTarget: PhotoPickerTarget?
    @State private var deletingVariant: Variant?

    private enum TableMode { case primary, secondary }

    private struct PendingBulkEdit {
        let primaryValue: String
        let price: Double?
    }

    private struct PhotoPickerTarget: Identifiable {
        let id = UUID()
        let optionName: String
        let value: String
    }

    private var hasSubVariation: Bool { options.count >= 2 }
    private var primaryName: String? { options.first?.name }
    private var secondaryName: String? { options.count > 1 ? options[1].name : nil }
    private var activeVariants: [Variant] { variants.filter { $0.active } }

    /// Groups active variants by the first option dimension's value,
    /// preserving first-seen order — the "primary" view's rows.
    private var primaryGroups: [(key: String, rows: [Variant])] {
        guard let primaryName else { return [] }
        var order: [String] = []
        var buckets: [String: [Variant]] = [:]
        for v in activeVariants {
            let key = v.optionValues[primaryName] ?? "—"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(v)
        }
        return order.map { (key: $0, rows: buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasSubVariation {
                Picker("View", selection: $tableMode) {
                    Text("By \(primaryName ?? "")").tag(TableMode.primary)
                    Text("By \(secondaryName ?? "")").tag(TableMode.secondary)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            if !quantityVariesByVariant {
                sharedQuantityRow
            }

            List {
                if hasSubVariation && tableMode == .primary {
                    Section {
                        ForEach(primaryGroups, id: \.key) { group in
                            primaryRow(group)
                        }
                    } header: {
                        Text("Edit SKUs in the \(secondaryName ?? "sub-variation") view")
                    }
                } else {
                    ForEach(activeVariants, id: \.id) { variant in
                        secondaryRow(variant)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    deletingVariant = variant
                                }
                            }
                    }
                }
            }
            .listStyle(.plain)
        }
        .alert(
            "Apply to all sub-variations?",
            isPresented: Binding(get: { pendingBulkEdit != nil }, set: { if !$0 { pendingBulkEdit = nil } })
        ) {
            Button("Undo Edit", role: .cancel) { pendingBulkEdit = nil }
            Button("Ignore") { confirmBulkEdit(remember: false) }
            Button("Never show again") { confirmBulkEdit(remember: true) }
        } message: {
            Text("Edits to \(primaryName ?? "primary") variation details will apply to every \(secondaryName ?? "sub-variation") under it. Edit in the \(secondaryName ?? "sub-variation") view instead to change a single SKU.")
        }
        .alert(
            "Delete this variant?",
            isPresented: Binding(get: { deletingVariant != nil }, set: { if !$0 { deletingVariant = nil } })
        ) {
            Button("Cancel", role: .cancel) { deletingVariant = nil }
            Button("Delete", role: .destructive) {
                if let v = deletingVariant {
                    variants.removeAll { $0.id == v.id }
                    Task { await onCommitVariants() }
                }
                deletingVariant = nil
            }
        } message: {
            Text("This permanently deletes this variant row and its price/SKU/quantity data. This can't be undone.")
        }
        .sheet(item: $photoPickerTarget) { target in
            VariantPhotoPickerSheet(
                optionName: target.optionName,
                value: target.value,
                imageAssets: $imageAssets,
                onSave: { Task { await onCommitImageAssets() } }
            )
        }
    }

    private var sharedQuantityRow: some View {
        HStack {
            Text("Shared quantity")
                .font(.subheadline)
            Spacer()
            TextField("0", value: $masterQuantity, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    variants = variants.map { $0.with(quantity: masterQuantity) }
                    Task { await onCommitVariants() }
                }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Primary (Style-level) row

    private func primaryRow(_ group: (key: String, rows: [Variant])) -> some View {
        let totalQty = group.rows.reduce(0) { $0 + $1.quantity }
        let displayPrice = group.rows.first?.price
        let photoCount = primaryName.map { VariantLogic.photosTagged(optionName: $0, value: group.key, in: imageAssets).count } ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.key).font(.body.weight(.semibold))
                Spacer()
                Button {
                    guard let primaryName else { return }
                    photoPickerTarget = PhotoPickerTarget(optionName: primaryName, value: group.key)
                } label: {
                    Label(photoCount > 0 ? "\(photoCount) photo\(photoCount == 1 ? "" : "s")" : "Select photo", systemImage: "photo")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 16) {
                HStack {
                    Text("Price")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "listing price",
                        value: Binding(
                            get: { displayPrice == listingPrice ? nil : displayPrice },
                            set: { newValue in commitPrimaryFieldEdit(primaryValue: group.key, price: newValue) }
                        ),
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Qty").font(.caption).foregroundStyle(.secondary)
                    Text("\(totalQty)").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func commitPrimaryFieldEdit(primaryValue: String, price: Double?) {
        guard let primaryName else { return }
        // Only fires when the value actually changed — TextField's Binding
        // setter can otherwise re-fire on unrelated view updates.
        let current = variants.first(where: { $0.optionValues[primaryName] == primaryValue })?.price
        guard current != price else { return }
        if skipBulkEditWarning {
            applyBulkPriceEdit(primaryValue: primaryValue, price: price)
        } else {
            pendingBulkEdit = PendingBulkEdit(primaryValue: primaryValue, price: price)
        }
    }

    private func confirmBulkEdit(remember: Bool) {
        guard let pending = pendingBulkEdit else { return }
        if remember { skipBulkEditWarning = true }
        applyBulkPriceEdit(primaryValue: pending.primaryValue, price: pending.price)
        pendingBulkEdit = nil
    }

    private func applyBulkPriceEdit(primaryValue: String, price: Double?) {
        guard let primaryName else { return }
        variants = variants.map { v in
            guard v.optionValues[primaryName] == primaryValue else { return v }
            return v.with(price: price)
        }
        Task { await onCommitVariants() }
    }

    // MARK: - Secondary (per-SKU) row

    private func secondaryRow(_ variant: Variant) -> some View {
        let label: String = variant.optionValues.isEmpty
            ? "Default"
            : variant.optionValues.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " \u{00B7} ")
        let photoCount: Int = {
            guard let secondaryName, let value = variant.optionValues[secondaryName] else {
                // Single-dimension product — the row IS the whole variant, so
                // count against its one option value directly.
                guard let primaryName, let value = variant.optionValues[primaryName] else { return 0 }
                return VariantLogic.photosTagged(optionName: primaryName, value: value, in: imageAssets).count
            }
            return VariantLogic.photosTagged(optionName: secondaryName, value: value, in: imageAssets).count
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.body.weight(.medium))
                Spacer()
                Button {
                    let target: PhotoPickerTarget?
                    if let secondaryName, let value = variant.optionValues[secondaryName] {
                        target = PhotoPickerTarget(optionName: secondaryName, value: value)
                    } else if let primaryName, let value = variant.optionValues[primaryName] {
                        target = PhotoPickerTarget(optionName: primaryName, value: value)
                    } else {
                        target = nil
                    }
                    photoPickerTarget = target
                } label: {
                    Label(photoCount > 0 ? "\(photoCount)" : "Photo", systemImage: "photo")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 12) {
                skuField(variant)
                priceField(variant)
                quantityField(variant)
            }
        }
        .padding(.vertical, 4)
    }

    private func skuField(_ variant: Variant) -> some View {
        TextField(
            "SKU",
            text: Binding(
                get: { variant.sku ?? "" },
                set: { newValue in setVariantField(variant.id) { $0.withSKU(newValue) } }
            )
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit { Task { await onCommitVariants() } }
    }

    private func priceField(_ variant: Variant) -> some View {
        TextField(
            "listing price",
            value: Binding(
                get: { variant.price == listingPrice ? nil : variant.price },
                set: { newValue in setVariantField(variant.id) { $0.with(price: newValue) } }
            ),
            format: .number
        )
        .keyboardType(.decimalPad)
        .textFieldStyle(.roundedBorder)
        .onSubmit { Task { await onCommitVariants() } }
    }

    private func quantityField(_ variant: Variant) -> some View {
        TextField(
            "qty",
            value: Binding(
                get: { quantityVariesByVariant ? variant.quantity : masterQuantity },
                set: { newValue in
                    if quantityVariesByVariant {
                        setVariantField(variant.id) { $0.with(quantity: newValue) }
                    }
                }
            ),
            format: .number
        )
        .keyboardType(.numberPad)
        .textFieldStyle(.roundedBorder)
        .disabled(!quantityVariesByVariant)
        .onSubmit { Task { await onCommitVariants() } }
    }

    private func setVariantField(_ id: String, _ transform: (Variant) -> Variant) {
        variants = variants.map { $0.id == id ? transform($0) : $0 }
    }
}

// MARK: - SKU editing helper

private extension Variant {
    /// `Variant.with(sku:)` takes `String??` (present-and-nil vs. absent) —
    /// this small wrapper lets a plain `TextField(text:)` binding write a SKU
    /// without fighting that double-optional directly.
    func withSKU(_ text: String) -> Variant {
        with(sku: text.isEmpty ? nil : text)
    }
}

// MARK: - VariantPhotoPickerSheet

/// Assigns existing `products/{id}.imageAssets[]` photos to one option value
/// (a primary Style or a secondary Size) — tags/untags them, mirroring web's
/// `linkPhotosToValue`. There's no equivalent iOS surface to reuse (a
/// dropship product's photos are already-uploaded remote URLs pulled from the
/// web import, not the PhotosPicker/CustomPhotoPickerView flow
/// `CreateListingView.swift` uses for picking NEW photos from the library),
/// so this is a small dedicated grid over the existing image URLs rather than
/// a photo *picker* in the PhotosPicker sense.
struct VariantPhotoPickerSheet: View {
    let optionName: String
    let value: String
    @Binding var imageAssets: [ProductImageAsset]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 8)]

    var body: some View {
        NavigationStack {
            Group {
                if imageAssets.isEmpty {
                    Text("No photos on this product yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(imageAssets) { asset in
                                photoCell(asset)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Photos for \"\(value)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        linkSelectedPhotos()
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                selectedIds = Set(VariantLogic.photosTagged(optionName: optionName, value: value, in: imageAssets).map(\.id))
            }
        }
    }

    private func photoCell(_ asset: ProductImageAsset) -> some View {
        let isSelected = selectedIds.contains(asset.id)
        return ZStack(alignment: .topTrailing) {
            AsyncImage(url: URL(string: asset.url)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.systemGray5)
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .white)
                .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.3)))
                .padding(4)
        }
        .onTapGesture {
            if isSelected { selectedIds.remove(asset.id) } else { selectedIds.insert(asset.id) }
        }
    }

    /// Selected images get a tag replacing any prior tag for this option
    /// name (so moving a photo from one value to another just re-tags it);
    /// images that had exactly this tag but were unchecked lose it — any
    /// other tags they carry are left alone. Mirrors web's
    /// `linkPhotosToValue` exactly.
    private func linkSelectedPhotos() {
        imageAssets = imageAssets.map { asset in
            var tags = asset.variantTags ?? []
            let hasThisTag = tags.contains { $0.optionName == optionName && $0.value == value }
            if selectedIds.contains(asset.id) {
                tags.removeAll { $0.optionName == optionName }
                tags.append(VariantPhotoTag(optionName: optionName, value: value))
                return ProductImageAsset(id: asset.id, url: asset.url, variantTags: tags)
            }
            if hasThisTag {
                tags.removeAll { $0.optionName == optionName && $0.value == value }
                return ProductImageAsset(id: asset.id, url: asset.url, variantTags: tags)
            }
            return asset
        }
    }
}
