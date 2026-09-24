//
//  WeverseSubSheets.swift
//  wonni
//
//  Sub-screens for BulkImportSheet's Weverse shipping-estimate pipeline —
//  see runShippingEstimatePipeline there. Mirrors the two modal sub-screens
//  in web/src/components/WeverseShopImportModal.jsx.
//

import SwiftUI

/// Shown when classifyWeverseItemTypes couldn't confidently classify one or
/// more selected items — lets the user manually pick (or type) a type per
/// item, grouping similar items so shipping only needs to be checked once
/// per type.
struct WeverseTypeConfirmSheet: View {
    let items: [ListingPreview]
    let knownTypes: [String]
    @Binding var typeChoices: [String: String]
    @Binding var newTypeDrafts: [String: String]
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var allTypesChosen: Bool {
        items.allSatisfy { item in
            guard let choice = typeChoices[item.url], !choice.isEmpty else { return false }
            if choice == "__new__" {
                return !(newTypeDrafts[item.url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("We couldn't automatically classify \(items.count) item\(items.count == 1 ? "" : "s") — this groups similar items so we only need to check shipping cost once per type.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ForEach(items) { item in
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            AsyncImage(url: URL(string: item.thumbnailUrl)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(.systemGray5)
                            }
                            .frame(width: 36, height: 36)
                            .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.footnote)
                                    .lineLimit(2)

                                Picker("Confirm item type", selection: Binding(
                                    get: { typeChoices[item.url] ?? "" },
                                    set: { typeChoices[item.url] = $0 }
                                )) {
                                    Text("Confirm item type…").tag("")
                                    ForEach(knownTypes, id: \.self) { type in
                                        Text(type).tag(type)
                                    }
                                    Text("+ Add new…").tag("__new__")
                                }
                                .pickerStyle(.menu)

                                if typeChoices[item.url] == "__new__" {
                                    TextField("New type name", text: Binding(
                                        get: { newTypeDrafts[item.url] ?? "" },
                                        set: { newTypeDrafts[item.url] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.footnote)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Confirm Item Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onContinue()
                        dismiss()
                    }
                    .disabled(!allTypesChosen)
                }
            }
        }
    }
}

/// Shown when a shipping probe fails with errorCode MISSING_ADDRESS — the
/// Weverse account has no saved delivery address, so it can't quote a fee.
struct WeverseMissingAddressSheet: View {
    let onSkip: () -> Void
    let onOpenWeverse: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Weverse needs a saved shipping address on your account before it can quote a delivery fee. Add one on Weverse, then come back and continue.")
                    .font(.subheadline)

                Spacer()

                Button("Open Weverse") { onOpenWeverse() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                Button("I've Added It — Retry") { onRetry() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Button("Skip Estimate") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Add a Shipping Address")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
