import SwiftUI
import SwiftData
import FirebaseFunctions

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
    @State private var markOutOfStock = false
    @State private var outOfStockSummary: String?
    @State private var weightWholeLbs: Int = 0
    @State private var weightOz: Double = 0
    @State private var lengthIn: Double? = nil
    @State private var widthIn: Double? = nil
    @State private var heightIn: Double? = nil

    @State private var isApplying = false

    @FocusState private var focusedField: FocusField?

    enum FocusField: Hashable {
        case titlePrepend, titleAppend, descPrepend, descAppend, priceAmount, priceLimit
        case weightLbs, weightOz, lengthIn, widthIn, heightIn
    }

    private var combinedWeightLbs: Double? {
        let total = Double(weightWholeLbs) + weightOz / 16.0
        return total > 0 ? total : nil
    }
    private var hasDimensions: Bool {
        lengthIn != nil && widthIn != nil && heightIn != nil
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

                Section {
                    HStack(spacing: 8) {
                        Text("Weight")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", value: $weightWholeLbs, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .focused($focusedField, equals: .weightLbs)
                        Text("lbs").font(.subheadline).foregroundStyle(.secondary)
                        TextField("0", value: $weightOz, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .focused($focusedField, equals: .weightOz)
                        Text("oz").font(.subheadline).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        Text("L×W×H")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        TextField("L", value: $lengthIn, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder).frame(width: 50)
                            .focused($focusedField, equals: .lengthIn)
                        Text("×").foregroundStyle(.secondary)
                        TextField("W", value: $widthIn, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder).frame(width: 50)
                            .focused($focusedField, equals: .widthIn)
                        Text("×").foregroundStyle(.secondary)
                        TextField("H", value: $heightIn, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder).frame(width: 50)
                            .focused($focusedField, equals: .heightIn)
                        Text("in").font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Shipping Dimensions")
                } footer: {
                    Text("Leave at 0 / blank to keep existing values.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Mark as Out of Stock", isOn: $markOutOfStock)
                        .tint(.red)
                } header: {
                    Text("Availability")
                } footer: {
                    Text("Sets quantity to 0 and marks each listing sold. Hides the listing on eBay and Etsy and deactivates it on Mercari.")
                        .font(.caption).foregroundStyle(.secondary)
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
            .alert(
                "Out of Stock",
                isPresented: Binding(
                    get: { outOfStockSummary != nil },
                    set: { if !$0 { outOfStockSummary = nil } }
                )
            ) {
                Button("OK") {
                    onComplete()
                    dismiss()
                }
            } message: {
                Text(outOfStockSummary ?? "")
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
        case .titlePrepend:
            focusedField = nil
        case .titleAppend:
            focusedField = .titlePrepend
        case .descPrepend:
            focusedField = .titleAppend
        case .descAppend:
            focusedField = .descPrepend
        case .priceAmount:
            focusedField = .descAppend
        case .priceLimit:
            focusedField = .priceAmount
        case .weightLbs:
            focusedField = .priceLimit
        case .weightOz:
            focusedField = .weightLbs
        case .lengthIn:
            focusedField = .weightOz
        case .widthIn:
            focusedField = .lengthIn
        case .heightIn:
            focusedField = .widthIn
        case nil:
            focusedField = .heightIn
        }
    }
    
    private func focusNext() {
        switch focusedField {
        case .titlePrepend:
            focusedField = .titleAppend
        case .titleAppend:
            focusedField = .descPrepend
        case .descPrepend:
            focusedField = .descAppend
        case .descAppend:
            focusedField = .priceAmount
        case .priceAmount:
            focusedField = .priceLimit
        case .priceLimit:
            focusedField = .weightLbs
        case .weightLbs:
            focusedField = .weightOz
        case .weightOz:
            focusedField = .lengthIn
        case .lengthIn:
            focusedField = .widthIn
        case .widthIn:
            focusedField = .heightIn
        case .heightIn:
            focusedField = nil
        case nil:
            focusedField = .titlePrepend
        }
    }
    
    private var hasFieldChanges: Bool {
        (priceAdjustmentMode != .none && priceAdjustmentValue != nil) ||
        !titlePrepend.isEmpty || !titleAppend.isEmpty ||
        !descriptionPrepend.isEmpty || !descriptionAppend.isEmpty ||
        selectedCondition != nil || selectedShipping != .unchanged ||
        combinedWeightLbs != nil || hasDimensions
    }

    private var hasChanges: Bool {
        hasFieldChanges || markOutOfStock
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
                if hasFieldChanges {
                    let dims: (Double, Double, Double)? = hasDimensions ? (lengthIn!, widthIn!, heightIn!) : nil
                    let ebayIds = try await ListingRepository.shared.bulkUpdate(
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
                        buyerPaysShipping: buyerPaysShipping,
                        setWeightLbs: combinedWeightLbs,
                        setPackageDimensions: dims
                    )

                    // markSoldOutAndCascade hides the eBay listing with qty=0 anyway,
                    // so pushing field edits to eBay is skipped when going out of stock.
                    if !markOutOfStock {
                        for id in ebayIds {
                            Task {
                                _ = try? await callCloudFunction("ebayUpdateListing", ["listingId": id])
                            }
                        }
                    }
                }

                if markOutOfStock {
                    let result = await markSelectedOutOfStock(Array(selectedListingIds))
                    if result.failed > 0 {
                        // Stay open and show the summary; onComplete/dismiss run
                        // when the user acknowledges the alert.
                        await MainActor.run {
                            isApplying = false
                            outOfStockSummary = "\(result.succeeded)/\(result.succeeded + result.failed) listings marked out of stock. \(result.failed) failed after 3 attempts — see Xcode console and Firebase function logs for details."
                        }
                        return
                    }
                }

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

    /// Marks every listing in `ids` out of stock via the `markSoldOutAndCascade`
    /// cloud function (qty=0, status=sold, hides on eBay/Etsy, flags Mercari for
    /// webview deactivation). Best-effort with auto-retry: each listing gets up to
    /// 3 attempts with backoff, and failures don't stop the remaining listings.
    /// Calls stay sequential — each invocation fans out to eBay/Etsy APIs, and
    /// firing dozens concurrently invites rate limiting.
    private func markSelectedOutOfStock(_ ids: [String]) async -> (succeeded: Int, failed: Int) {
        var failedCount = 0
        for id in ids {
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    _ = try await callCloudFunction("markSoldOutAndCascade", ["listingId": id])
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    }
                }
            }
            if let error = lastError {
                failedCount += 1
                print("[BulkEdit] markSoldOutAndCascade failed for \(id) after 3 attempts: \(error)")
            }
        }
        return (ids.count - failedCount, failedCount)
    }
}

// MARK: - DraftBulkEditSheet
// Operates on SwiftData Item objects (pre-publish drafts) — no Firestore round-trip.

struct DraftBulkEditSheet: View {
    let items: [Item]
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var uploadManager: UploadManager

    @State private var priceAdjustmentMode: BulkEditSheet.PriceAdjustmentDirection = .none
    @State private var priceAdjustmentType: BulkEditSheet.PriceAdjustmentType = .absolute
    @State private var priceAdjustmentValue: Double?
    @State private var priceLimitValue: Double?

    @State private var titlePrepend: String = ""
    @State private var titleAppend: String = ""
    @State private var descriptionPrepend: String = ""
    @State private var descriptionAppend: String = ""

    // Used when every selected draft is empty: set the title/description directly on all of them
    // (prepend/append is meaningless with no existing text).
    @State private var titleSet: String = ""
    @State private var descriptionSet: String = ""

    @State private var selectedCondition: ItemCondition? = nil
    @State private var selectedShipping: BulkEditSheet.ShippingPolicyMode = .unchanged

    @FocusState private var focusedField: BulkEditSheet.FocusField?

    /// A draft counts as "empty" when it has no user-entered or AI title. The offline vision
    /// identifier output (`visionTitle`) is intentionally treated as empty — it's a placeholder,
    /// not a real title — so drafts that only have a vision guess still use the set-directly mode.
    private func hasMeaningfulTitle(_ item: Item) -> Bool {
        let t = (item.userEditedTitle ?? item.aiSuggestedTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty
    }
    private var allDraftsEmpty: Bool {
        !items.isEmpty && items.allSatisfy { !hasMeaningfulTitle($0) }
    }
    /// True when the selection is mixed: at least one draft has a meaningful title and at least
    /// one does not. In this case, both set-fields and prepend/append fields are shown.
    private var hasMixedEmptiness: Bool {
        let hasEmpty = items.contains { !hasMeaningfulTitle($0) }
        let hasFilled = items.contains { hasMeaningfulTitle($0) }
        return hasEmpty && hasFilled
    }

    var body: some View {
        NavigationStack {
            Form {
                if allDraftsEmpty {
                    // All drafts are empty: show direct-set fields only.
                    Section {
                        setTextRow(label: "Title", placeholder: "Title for all", text: $titleSet, focus: .titlePrepend)
                        setTextRow(label: "Desc.", placeholder: "Description for all", text: $descriptionSet, focus: .descPrepend)
                    } header: { Text("Title & Description") }
                } else if hasMixedEmptiness {
                    // Mixed selection: show both sections — set-fields apply to empty drafts,
                    // prepend/append fields apply to drafts that already have content.
                    Section {
                        setTextRow(label: "Title", placeholder: "Title (for untitled)", text: $titleSet, focus: .titlePrepend)
                        setTextRow(label: "Desc.", placeholder: "Desc. (for empty)", text: $descriptionSet, focus: .descPrepend)
                    } header: { Text("Set (applies to untitled drafts)") }
                    Section {
                        dynamicTextRow(prepend: $titlePrepend, label: "Title", append: $titleAppend,
                                       focus1: .titlePrepend, focus2: .titleAppend)
                        dynamicTextRow(prepend: $descriptionPrepend, label: "Desc.", append: $descriptionAppend,
                                       focus1: .descPrepend, focus2: .descAppend)
                    } header: { Text("Modify (applies to titled drafts)") }
                } else {
                    // All drafts have titles: show prepend/append fields only.
                    Section {
                        dynamicTextRow(prepend: $titlePrepend, label: "Title", append: $titleAppend,
                                       focus1: .titlePrepend, focus2: .titleAppend)
                        dynamicTextRow(prepend: $descriptionPrepend, label: "Desc.", append: $descriptionAppend,
                                       focus1: .descPrepend, focus2: .descAppend)
                    } header: { Text("Text Modifications") }
                }

                Section {
                    VStack(spacing: 12) {
                        HStack(spacing: 0) {
                            priceButton("- Decrease", mode: .decrease, color: .red)
                            Divider().frame(height: 24)
                            priceButton("Set Price", mode: .set, color: .blue)
                            Divider().frame(height: 24)
                            priceButton("+ Increase", mode: .increase, color: .green)
                        }
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .buttonStyle(.plain)

                        if priceAdjustmentMode != .none {
                            Divider()
                            if priceAdjustmentMode == .set {
                                HStack {
                                    Text("New Price:").font(.subheadline).foregroundStyle(.secondary)
                                    TextField("Amount", value: $priceAdjustmentValue, format: .number)
                                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .priceAmount)
                                }
                            } else {
                                HStack {
                                    Picker("Type", selection: $priceAdjustmentType) {
                                        Text("$").tag(BulkEditSheet.PriceAdjustmentType.absolute)
                                        Text("%").tag(BulkEditSheet.PriceAdjustmentType.percentage)
                                    }
                                    .pickerStyle(.segmented).frame(width: 100)
                                    TextField("Amount", value: $priceAdjustmentValue, format: .number)
                                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .priceAmount)
                                }
                                if priceAdjustmentValue != nil {
                                    HStack {
                                        Text(priceAdjustmentMode == .decrease ? "Minimum:" : "Maximum:")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        TextField("Amount", value: $priceLimitValue, format: .number)
                                            .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                            .focused($focusedField, equals: .priceLimit)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: { Text("Price Adjustment") }

                Section {
                    Picker("Condition", selection: $selectedCondition) {
                        Text("Unchanged").tag(ItemCondition?.none)
                        ForEach(ItemCondition.allCases, id: \.self) { c in
                            Text(c.displayName).tag(ItemCondition?.some(c))
                        }
                    }
                    Picker("Shipping", selection: $selectedShipping) {
                        ForEach(BulkEditSheet.ShippingPolicyMode.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                } header: { Text("Details") }
            }
            .navigationTitle("Bulk Edit (\(items.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyBulkEdit() }
                        .disabled(!hasChanges)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func priceButton(_ label: String, mode: BulkEditSheet.PriceAdjustmentDirection, color: Color) -> some View {
        Button {
            withAnimation { priceAdjustmentMode = (priceAdjustmentMode == mode) ? .none : mode }
        } label: {
            Text(label)
                .font(.subheadline).fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(priceAdjustmentMode == mode
                    ? (mode == .set ? color : color.opacity(0.15))
                    : Color.clear)
                .foregroundStyle(priceAdjustmentMode == mode
                    ? (mode == .set ? Color.white : color)
                    : Color.primary)
        }
    }

    private func setTextRow(
        label: String, placeholder: String, text: Binding<String>, focus: BulkEditSheet.FocusField
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary).fixedSize()
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: focus)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func dynamicTextRow(
        prepend: Binding<String>, label: String, append: Binding<String>,
        focus1: BulkEditSheet.FocusField, focus2: BulkEditSheet.FocusField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                TextField("Prepend", text: prepend, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: focus1)
                Text(label).font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary).fixedSize()
                TextField("Append", text: append, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: focus2)
            }
        }
        .padding(.vertical, 4)
    }

    private var hasChanges: Bool {
        // In mixed mode (some drafts have titles, some don't) either the set-fields or the
        // prepend/append fields may be used depending on each item, so check all of them.
        let textChanged = !titleSet.isEmpty || !descriptionSet.isEmpty ||
            !titlePrepend.isEmpty || !titleAppend.isEmpty ||
            !descriptionPrepend.isEmpty || !descriptionAppend.isEmpty
        return (priceAdjustmentMode != .none && priceAdjustmentValue != nil) ||
            textChanged ||
            selectedCondition != nil || selectedShipping != .unchanged
    }

    private func applyBulkEdit() {
        for item in items {
            // Per-item mode decision: use set-directly for drafts that have no meaningful
            // title/description, and prepend/append for drafts that already have content.
            // This correctly handles mixed selections (some empty, some not).
            let itemHasTitle = hasMeaningfulTitle(item)
            if !itemHasTitle {
                // Draft has no real title yet — apply the "set" values directly.
                let t = titleSet.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { item.userEditedTitle = String(t.prefix(140)) }
                let d = descriptionSet.trimmingCharacters(in: .whitespacesAndNewlines)
                if !d.isEmpty { item.userEditedDescription = d }
            } else {
                let currentTitle = item.userEditedTitle ?? item.aiSuggestedTitle ?? item.visionTitle ?? ""
                var newTitle = currentTitle
                if !titlePrepend.isEmpty { newTitle = titlePrepend + newTitle }
                if !titleAppend.isEmpty { newTitle = newTitle + titleAppend }
                if newTitle != currentTitle {
                    item.userEditedTitle = newTitle.isEmpty ? nil : String(newTitle.prefix(140))
                }

                let currentDesc = item.userEditedDescription ?? item.aiSuggestedDescription ?? ""
                var newDesc = currentDesc
                if !descriptionPrepend.isEmpty { newDesc = descriptionPrepend + newDesc }
                if !descriptionAppend.isEmpty { newDesc = newDesc + descriptionAppend }
                if newDesc != currentDesc {
                    item.userEditedDescription = newDesc.isEmpty ? nil : newDesc
                }
            }

            if let val = priceAdjustmentValue, priceAdjustmentMode != .none {
                let base = item.userEditedPrice ?? item.aiSuggestedPrice ?? 0
                var newPrice: Double
                switch priceAdjustmentMode {
                case .set: newPrice = val
                case .increase:
                    newPrice = priceAdjustmentType == .percentage ? base * (1 + val / 100) : base + val
                    if let maxP = priceLimitValue { newPrice = Swift.min(newPrice, maxP) }
                case .decrease:
                    newPrice = priceAdjustmentType == .percentage ? base * (1 - val / 100) : base - val
                    newPrice = Swift.max(newPrice, priceLimitValue ?? 0.01)
                case .none: newPrice = base
                }
                item.userEditedPrice = Swift.max(0.01, newPrice)
            }

            if let condition = selectedCondition { item.condition = condition.rawValue }
            switch selectedShipping {
            case .buyerPays: item.buyerPaysShipping = true
            case .freeShipping: item.buyerPaysShipping = false
            case .unchanged: break
            }

            uploadManager.syncDraftData(item)
        }
        try? modelContext.save()
        onComplete()
        dismiss()
    }
}

