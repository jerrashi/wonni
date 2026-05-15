import SwiftUI

struct BulkEditSheet: View {
    let selectedListingIds: Set<String>
    let onComplete: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var priceAdjustmentMode: PriceAdjustmentDirection = .none
    @State private var priceAdjustmentType: PriceAdjustmentType = .absolute
    @State private var priceAdjustmentValue: Double?
    @State private var priceLimitValue: Double?
    
    @State private var titlePrepend: String = ""
    @State private var titleAppend: String = ""
    
    @State private var descriptionPrepend: String = ""
    @State private var descriptionAppend: String = ""
    
    @State private var selectedCondition: ItemCondition? = nil
    @State private var selectedShipping: ShippingPolicyMode = .unchanged
    
    @State private var isApplying = false
    
    @FocusState private var focusedField: FocusField?
    
    enum FocusField: Hashable {
        case titlePrepend, titleAppend, descPrepend, descAppend, priceAmount, priceLimit
    }
    
    enum PriceAdjustmentDirection {
        case none, increase, decrease, set
    }
    
    enum PriceAdjustmentType {
        case percentage, absolute
    }
    
    enum ShippingPolicyMode: String, CaseIterable {
        case unchanged = "Unchanged"
        case buyerPays = "Buyer Pays"
        case freeShipping = "Free Shipping"
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // TITLE ROW
                    dynamicTextRow(
                        prepend: $titlePrepend,
                        label: "Title",
                        append: $titleAppend,
                        focus1: .titlePrepend,
                        focus2: .titleAppend
                    )
                    
                    // DESCRIPTION ROW
                    dynamicTextRow(
                        prepend: $descriptionPrepend,
                        label: "Desc.",
                        append: $descriptionAppend,
                        focus1: .descPrepend,
                        focus2: .descAppend
                    )
                } header: {
                    Text("Text Modifications")
                }
                
                Section {
                    // PRICE ROW
                    VStack(spacing: 12) {
                        HStack(spacing: 0) {
                            Button {
                                withAnimation { priceAdjustmentMode = (priceAdjustmentMode == .decrease) ? .none : .decrease }
                            } label: {
                                Text("- Decrease")
                                    .font(.subheadline).fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(priceAdjustmentMode == .decrease ? Color.red.opacity(0.15) : Color.clear)
                                    .foregroundStyle(priceAdjustmentMode == .decrease ? .red : .primary)
                            }
                            
                            Divider().frame(height: 24)
                            
                            Button {
                                withAnimation { priceAdjustmentMode = (priceAdjustmentMode == .set) ? .none : .set }
                            } label: {
                                Text("Set Price")
                                    .font(.subheadline).fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(priceAdjustmentMode == .set ? Color.blue : Color.clear)
                                    .foregroundStyle(priceAdjustmentMode == .set ? .white : .primary)
                                    .shadow(color: priceAdjustmentMode == .set ? Color.blue.opacity(0.4) : .clear, radius: 4, y: 2)
                            }
                            
                            Divider().frame(height: 24)
                            
                            Button {
                                withAnimation { priceAdjustmentMode = (priceAdjustmentMode == .increase) ? .none : .increase }
                            } label: {
                                Text("+ Increase")
                                    .font(.subheadline).fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(priceAdjustmentMode == .increase ? Color.green.opacity(0.15) : Color.clear)
                                    .foregroundStyle(priceAdjustmentMode == .increase ? .green : .primary)
                            }
                        }
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .buttonStyle(.plain)
                        
                        if priceAdjustmentMode != .none {
                            Divider()
                            
                            if priceAdjustmentMode == .set {
                                HStack {
                                    Text("New Price:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    TextField("Amount", value: $priceAdjustmentValue, format: .number)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .priceAmount)
                                }
                            } else {
                                HStack {
                                    Picker("Type", selection: $priceAdjustmentType) {
                                        Text("$").tag(PriceAdjustmentType.absolute)
                                        Text("%").tag(PriceAdjustmentType.percentage)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 100)
                                    
                                    TextField("Amount", value: $priceAdjustmentValue, format: .number)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .priceAmount)
                                }
                                
                                if priceAdjustmentValue != nil {
                                    HStack {
                                        Text(priceAdjustmentMode == .decrease ? "Minimum Price:" : "Maximum Price:")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        TextField("Amount", value: $priceLimitValue, format: .number)
                                            .keyboardType(.decimalPad)
                                            .textFieldStyle(.roundedBorder)
                                            .focused($focusedField, equals: .priceLimit)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Price Adjustment")
                }
                
                Section {
                    Picker("Condition", selection: $selectedCondition) {
                        Text("Unchanged").tag(ItemCondition?.none)
                        ForEach(ItemCondition.allCases, id: \.self) { condition in
                            Text(condition.displayName).tag(ItemCondition?.some(condition))
                        }
                    }
                    
                    Picker("Shipping", selection: $selectedShipping) {
                        ForEach(ShippingPolicyMode.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                } header: {
                    Text("Details")
                }
            }
            .navigationTitle("Bulk Edit (\(selectedListingIds.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyBulkEdit() }
                        .disabled(isApplying || !hasChanges)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: focusPrevious) { Image(systemName: "chevron.up") }
                    Button(action: focusNext) { Image(systemName: "chevron.down") }
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .overlay {
                if isApplying {
                    ProgressView("Applying changes...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    @ViewBuilder
    private func dynamicTextRow(
        prepend: Binding<String>,
        label: String,
        append: Binding<String>,
        focus1: FocusField,
        focus2: FocusField
    ) -> some View {
        let pLarge = prepend.wrappedValue.contains("\n") || prepend.wrappedValue.count > 15
        let aLarge = append.wrappedValue.contains("\n") || append.wrappedValue.count > 15
        
        VStack(alignment: .leading, spacing: 8) {
            if pLarge && aLarge {
                textField(prepend, "Prepend", focus1)
                textLabel(label)
                textField(append, "Append", focus2)
            } else if pLarge {
                textField(prepend, "Prepend", focus1)
                HStack(alignment: .center, spacing: 8) {
                    textLabel(label)
                    textField(append, "Append", focus2)
                }
            } else if aLarge {
                HStack(alignment: .center, spacing: 8) {
                    textField(prepend, "Prepend", focus1)
                    textLabel(label)
                }
                textField(append, "Append", focus2)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    textField(prepend, "Prepend", focus1)
                    textLabel(label)
                    textField(append, "Append", focus2)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.default, value: prepend.wrappedValue)
        .animation(.default, value: append.wrappedValue)
    }
    
    private func textLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .fixedSize()
    }
    
    private func textField(_ binding: Binding<String>, _ placeholder: String, _ field: FocusField) -> some View {
        TextField(placeholder, text: binding, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: field)
    }
    
    private func focusPrevious() {
        switch focusedField {
        case .titlePrepend: focusedField = nil
        case .titleAppend: focusedField = .titlePrepend
        case .descPrepend: focusedField = .titleAppend
        case .descAppend: focusedField = .descPrepend
        case .priceAmount: focusedField = .descAppend
        case .priceLimit: focusedField = .priceAmount
        case nil: focusedField = .priceLimit
        }
    }
    
    private func focusNext() {
        switch focusedField {
        case .titlePrepend: focusedField = .titleAppend
        case .titleAppend: focusedField = .descPrepend
        case .descPrepend: focusedField = .descAppend
        case .descAppend: focusedField = .priceAmount
        case .priceAmount: focusedField = .priceLimit
        case .priceLimit: focusedField = nil
        case nil: focusedField = .titlePrepend
        }
    }
    
    private var hasChanges: Bool {
        (priceAdjustmentMode != .none && priceAdjustmentValue != nil) ||
        !titlePrepend.isEmpty || !titleAppend.isEmpty ||
        !descriptionPrepend.isEmpty || !descriptionAppend.isEmpty ||
        selectedCondition != nil || selectedShipping != .unchanged
    }
    
    private func applyBulkEdit() {
        isApplying = true
        
        Task {
            var adjustment: Double?
            var isPercentage = false
            var isPriceSet = false
            
            if let val = priceAdjustmentValue, priceAdjustmentMode != .none {
                if priceAdjustmentMode == .set {
                    adjustment = val
                    isPriceSet = true
                } else {
                    adjustment = priceAdjustmentMode == .decrease ? -val : val
                    isPercentage = (priceAdjustmentType == .percentage)
                }
            }
            
            let minP: Double = (priceAdjustmentMode == .decrease && priceLimitValue != nil) ? priceLimitValue! : 0.01
            let maxP: Double? = (priceAdjustmentMode == .increase) ? priceLimitValue : nil
            
            let buyerPaysShipping: Bool?
            switch selectedShipping {
            case .unchanged: buyerPaysShipping = nil
            case .buyerPays: buyerPaysShipping = true
            case .freeShipping: buyerPaysShipping = false
            }
            
            do {
                try await ListingRepository.shared.bulkUpdate(
                    listingIds: Array(selectedListingIds),
                    priceAdjustment: adjustment,
                    isPercentage: isPercentage,
                    isPriceSet: isPriceSet,
                    minimumPrice: minP,
                    maximumPrice: maxP,
                    titlePrepend: titlePrepend.isEmpty ? nil : titlePrepend,
                    titleAppend: titleAppend.isEmpty ? nil : titleAppend,
                    descriptionPrepend: descriptionPrepend.isEmpty ? nil : descriptionPrepend,
                    descriptionAppend: descriptionAppend.isEmpty ? nil : descriptionAppend,
                    condition: selectedCondition,
                    buyerPaysShipping: buyerPaysShipping
                )
                
                await MainActor.run {
                    isApplying = false
                    onComplete()
                    dismiss()
                }
            } catch {
                print("Bulk edit failed: \(error)")
                await MainActor.run {
                    isApplying = false
                }
            }
        }
    }
}
