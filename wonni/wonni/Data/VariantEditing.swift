//
//  VariantEditing.swift
//  wonni
//
//  Pure, testable Swift port of web's variant structural-edit logic
//  (web/src/pages/ProductDetail.jsx — normalizeOptions/normalizeVariants,
//  cartesianOptionValues, blankVariant, applyOptionRename, removeOptionValues,
//  removeOptionEntirely, addOptionValues, addNewOptionDimension, sharedPhotos,
//  variantPhotos). No SwiftUI/Firestore dependency — operates purely on the
//  generated `Option`/`Variant` structs (Generated/BackendContracts.swift) and
//  a lightweight `ProductImageAsset` type, so this file (and only this file)
//  is what VariantEditingTests exercises for parity with web's behavior.
//
//  Persistence for anything built on top of these functions always goes
//  through `ProductRepository.syncVariants` — the whole-array merge write.
//  NEVER write a dotted Firestore path like "variants.2.price" (see that
//  method's doc comment for why).
//

import Foundation

// MARK: - Per-variant photo tagging (`products/{id}.imageAssets[]`)

/// One tag on a photo, matching a single option dimension's value — mirrors
/// web's `{ optionName, value }` shape on `imageAssets[].variantTags`. A photo
/// can carry zero, one, or several of these; see `variantPhotos` below for how
/// a partial tag set (fewer dimensions than the product has) matches broadly
/// rather than narrowly.
struct VariantPhotoTag: Codable, Equatable, Hashable {
    var optionName: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case optionName
        case value
    }
}

/// `products/{id}.imageAssets[]` — not part of the typed `ProductDoc` contract
/// (see `functions/contracts/products.js`'s file header: that contract only
/// covers the variant subset, not the whole doc), so this is iOS's own local
/// shape for reading/writing that field via `ProductRepository`'s raw-dict
/// `fetchProduct`/`syncProduct` methods.
struct ProductImageAsset: Codable, Identifiable, Equatable {
    var id: String
    var url: String
    var variantTags: [VariantPhotoTag]?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case variantTags
    }
}

// MARK: - Structural change description

/// One structural edit made in the "Manage variations" sheet, applied to the
/// existing `variants` array. Mirrors the shapes of web's `changeInfo` object
/// passed to `handleOptionsChange` — a discriminated union here instead of an
/// ad hoc dictionary. The final `options` array itself is computed by the
/// caller (the "Manage variations" UI), exactly as web's modal computes
/// `nextOptions` itself and hands it to `handleOptionsChange` alongside this
/// delta — this type only carries what's needed to derive the next `variants`.
enum VariantStructuralChange {
    /// The product had no option dimensions yet, or is gaining a new one
    /// alongside existing dimensions. `values` is every value of the new
    /// dimension, in order.
    case addOptionDimension(name: String, values: [String])
    /// The whole dimension (and every variant row under it) is being deleted.
    case removeOptionDimension(name: String)
    /// An edit to an *existing* dimension: rename the dimension and/or some of
    /// its values, remove some values (hard delete), and/or add new values —
    /// all from one trip through "Manage variations". Order matters and is
    /// applied exactly like web: rename first, then remove, then add, so
    /// `removedValues`/`addedValues` are keyed by the post-rename value text.
    case editOptionDimension(
        name: String,
        newName: String,
        valueRenames: [String: String],
        removedValues: [String],
        addedValues: [String]
    )
}

// MARK: - Pure variant-editing logic

enum VariantLogic {

    // MARK: ID / blank-row generation

    /// Mirrors web's `generateVariantId()` — a timestamp plus a short random
    /// suffix, unique enough for a client-generated Firestore array element id.
    static func generateVariantId() -> String {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = UUID().uuidString.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(6)
        return "v\(millis)\(suffix)"
    }

    static func emptyCrossPostStatus() -> VariantCrossPostStatus {
        VariantCrossPostStatus(ebay: nil, etsy: nil, mercari: nil, tiktok: nil)
    }

    static func emptyCrossPostListingIds() -> VariantCrossPostListingIds {
        VariantCrossPostListingIds(ebay: nil, etsy: nil, mercari: nil, tiktok: nil)
    }

    /// Mirrors web's `blankVariant(productId, skuIndex, optionValues)` — a
    /// brand-new, never-populated row: `sku: "\(productId)-\(skuIndex)"`,
    /// `price: nil`, `quantity: 1`, `active: true`, every cross-post/Mercari
    /// field empty.
    static func blankVariant(productId: String, skuIndex: Int, optionValues: [String: String]) -> Variant {
        Variant(
            active: true,
            crossPostListingIds: emptyCrossPostListingIds(),
            crossPostStatus: emptyCrossPostStatus(),
            id: generateVariantId(),
            mercariUrl: nil,
            optionValues: optionValues,
            pendingMercariDeactivation: nil,
            pendingMercariRelist: nil,
            price: nil,
            quantity: 1,
            sku: "\(productId)-\(skuIndex)",
            sourcePrice: nil,
            sourceVariantId: nil
        )
    }

    // MARK: Cartesian combos

    /// Mirrors web's `cartesianOptionValues(options)`: every combination of
    /// every option's values, as `{ optionName: value }` dictionaries. Options
    /// with no values yet are ignored (not collapsed to zero combos) — see
    /// web's comment on the same function for why: otherwise the instant a
    /// blank "+ Add option" dimension exists, every existing variant would
    /// look orphaned until its values are filled in.
    static func cartesianOptionValues(_ options: [Option]) -> [[String: String]] {
        let withValues = options.filter { !$0.values.isEmpty }
        guard !withValues.isEmpty else { return [[:]] }
        return withValues.reduce([[:]]) { combos, opt in
            combos.flatMap { combo -> [[String: String]] in
                opt.values.map { value in
                    var next = combo
                    next[opt.name] = value
                    return next
                }
            }
        }
    }

    // MARK: Populated-row detection (for the destructive-delete confirm)

    /// Mirrors web's `isPopulatedVariant` — a variant carries real (imported
    /// or user-entered) data worth protecting, as opposed to a blank
    /// placeholder row. A price that's just following the shared listing
    /// price (never explicitly overridden) doesn't count.
    static func isPopulatedVariant(_ variant: Variant, listingPrice: Double?) -> Bool {
        variant.sourceVariantId != nil
            || variant.sourcePrice != nil
            || (variant.price != nil && variant.price != listingPrice)
    }

    // MARK: Rename / remove / add primitives
    // (mirror web's applyOptionRename / removeOptionValues / removeOptionEntirely
    // / addOptionValues / addNewOptionDimension exactly, including their doc
    // comments on *why* each behaves the way it does.)

    /// Relabels existing variants' `optionValues` to reflect a pure rename
    /// (dimension name and/or individual value text edited in place) — a typo
    /// fix shouldn't touch price/SKU data the way deleting-and-re-adding a
    /// value would.
    static func applyOptionRename(
        _ existingVariants: [Variant],
        optionName: String,
        newOptionName: String,
        valueRenames: [String: String]
    ) -> [Variant] {
        guard !optionName.isEmpty else { return existingVariants }
        if optionName == newOptionName && valueRenames.isEmpty { return existingVariants }
        return existingVariants.map { v in
            guard let oldValue = v.optionValues[optionName] else { return v }
            var rest = v.optionValues
            rest.removeValue(forKey: optionName)
            rest[newOptionName] = valueRenames[oldValue] ?? oldValue
            return v.with(optionValues: rest)
        }
    }

    /// Hard-deletes every variant row for one or more removed values of
    /// `optionName`. Explicit deletions are irreversible by design — there's
    /// no "unmatched, needs review" quarantine here, because there's nothing
    /// to guess at: the user picked exactly which value(s) to remove.
    static func removeOptionValues(
        _ existingVariants: [Variant],
        optionName: String,
        removedValues: [String]
    ) -> [Variant] {
        guard !removedValues.isEmpty else { return existingVariants }
        let removedSet = Set(removedValues)
        return existingVariants.filter { v in
            guard let value = v.optionValues[optionName] else { return true }
            return !removedSet.contains(value)
        }
    }

    /// Hard-deletes every variant row that carries `optionName` at all — used
    /// when the whole option dimension is deleted.
    static func removeOptionEntirely(_ existingVariants: [Variant], optionName: String) -> [Variant] {
        existingVariants.filter { $0.optionValues[optionName] == nil }
    }

    /// Adds new blank rows for one or more brand-new values of an *already
    /// existing* option dimension — one new row per combination of the other
    /// dimensions' current values. Existing rows are untouched, so a pure
    /// addition can never orphan anything.
    static func addOptionValues(
        _ existingVariants: [Variant],
        otherOptions: [Option],
        optionName: String,
        addedValues: [String],
        productId: String
    ) -> [Variant] {
        let otherCombos = cartesianOptionValues(otherOptions)
        var nextSkuIndex = existingVariants.count + 1
        var added: [Variant] = []
        for addedValue in addedValues {
            for combo in otherCombos {
                var optionValues = combo
                optionValues[optionName] = addedValue
                added.append(blankVariant(productId: productId, skuIndex: nextSkuIndex, optionValues: optionValues))
                nextSkuIndex += 1
            }
        }
        return existingVariants + added
    }

    /// Adds a brand-new option dimension (the product had none yet, or had
    /// one and is gaining a second). Existing active rows don't gain a blank
    /// sibling for every new value — they *become* the first value (keeping
    /// their id/price/SKU), and only the remaining values generate fresh
    /// blank rows. e.g. "V Jersey" becomes "V Jersey, M-L", and "V Jersey,
    /// XL-XXL" is added alongside it, rather than both starting blank and
    /// orphaning the old row. This is the one transition that's easy to get
    /// subtly wrong — see `VariantEditingTests` for the exact-parity cases.
    static func addNewOptionDimension(
        _ existingVariants: [Variant],
        optionName: String,
        values: [String],
        productId: String
    ) -> [Variant] {
        guard let firstValue = values.first else { return existingVariants }
        let restValues = Array(values.dropFirst())
        var nextSkuIndex = existingVariants.count + 1
        let activeExisting = existingVariants.filter { $0.active }

        // No prior per-variant rows to carry data over from (e.g. going
        // straight from a single-SKU listing to having variations) — every
        // value is blank.
        guard !activeExisting.isEmpty else {
            var blanks: [Variant] = []
            for value in values {
                blanks.append(blankVariant(productId: productId, skuIndex: nextSkuIndex, optionValues: [optionName: value]))
                nextSkuIndex += 1
            }
            return existingVariants + blanks
        }

        var result: [Variant] = []
        for v in existingVariants {
            guard v.active else { result.append(v); continue }
            var becomesFirst = v.optionValues
            becomesFirst[optionName] = firstValue
            result.append(v.with(optionValues: becomesFirst))
            for value in restValues {
                var optionValues = v.optionValues
                optionValues[optionName] = value
                result.append(blankVariant(productId: productId, skuIndex: nextSkuIndex, optionValues: optionValues))
                nextSkuIndex += 1
            }
        }
        return result
    }

    // MARK: Top-level structural-change pipeline

    /// Full structural-edit pipeline — mirrors web's `handleOptionsChange`
    /// variant-side logic exactly (the `options` array itself, including
    /// renames/adds/removes of the dimensions themselves, is owned by the
    /// "Manage variations" UI and passed in as `nextOptions` for the
    /// `addOptionValues` "other dimensions" cartesian, same as web). Does
    /// **not** gate on confirmation — call `rowsToBeRemoved` first and only
    /// call this once any resulting destructive-delete confirm has been
    /// accepted (see `isPopulatedVariant`).
    static func applyStructuralChange(
        nextOptions: [Option],
        change: VariantStructuralChange,
        currentVariants: [Variant],
        productId: String
    ) -> [Variant] {
        switch change {
        case .addOptionDimension(let name, let values):
            return addNewOptionDimension(currentVariants, optionName: name, values: values, productId: productId)

        case .removeOptionDimension(let name):
            return removeOptionEntirely(currentVariants, optionName: name)

        case .editOptionDimension(let name, let newName, let valueRenames, let removedValues, let addedValues):
            // Relabel first so removedValues/addedValues below are keyed by
            // the option's current (possibly just-renamed) name/value text.
            var next = applyOptionRename(currentVariants, optionName: name, newOptionName: newName, valueRenames: valueRenames)
            if !removedValues.isEmpty {
                next = removeOptionValues(next, optionName: newName, removedValues: removedValues)
            }
            if !addedValues.isEmpty {
                let otherOptions = nextOptions.filter { $0.name != newName }
                next = addOptionValues(next, otherOptions: otherOptions, optionName: newName, addedValues: addedValues, productId: productId)
            }
            return next
        }
    }

    /// Rows `applyStructuralChange` would hard-delete for `change`, computed
    /// against the pre-change `variants` — used to decide whether a
    /// destructive confirm is needed before actually applying the change
    /// (mirrors web's `confirmHardDelete` call sites in `handleOptionsChange`).
    static func rowsToBeRemoved(change: VariantStructuralChange, currentVariants: [Variant]) -> [Variant] {
        switch change {
        case .addOptionDimension:
            return []

        case .removeOptionDimension(let name):
            return currentVariants.filter { $0.optionValues[name] != nil }

        case .editOptionDimension(let name, let newName, let valueRenames, let removedValues, _):
            guard !removedValues.isEmpty else { return [] }
            let renamed = applyOptionRename(currentVariants, optionName: name, newOptionName: newName, valueRenames: valueRenames)
            let removedSet = Set(removedValues)
            return renamed.filter { v in
                guard let value = v.optionValues[newName] else { return false }
                return removedSet.contains(value)
            }
        }
    }

    // MARK: Per-variant photo assignment

    /// Photos with no `variantTags` at all — shared across every variant.
    static func sharedPhotos(_ imageAssets: [ProductImageAsset]) -> [ProductImageAsset] {
        imageAssets.filter { ($0.variantTags?.isEmpty ?? true) }
    }

    /// A photo belongs to a variant when every one of its tags matches that
    /// variant's `optionValues` — a single tag like
    /// `{ optionName: "Style", value: "RM" }` matches every combo where
    /// Style == "RM", regardless of other dimensions (a photo tagged with
    /// fewer dimensions than the product has is intentionally broader, not
    /// an error case). Mirrors web's `variantPhotos` exactly.
    static func variantPhotos(_ variant: Variant, imageAssets: [ProductImageAsset]) -> [ProductImageAsset] {
        imageAssets.filter { asset in
            guard let tags = asset.variantTags, !tags.isEmpty else { return false }
            return tags.allSatisfy { tag in variant.optionValues[tag.optionName] == tag.value }
        }
    }

    /// Photos carrying a tag matching `optionName`/`value` exactly — a
    /// simpler, direct check than `variantPhotos` (which requires *every* tag
    /// on the photo to match a full variant's `optionValues`). This is what
    /// web's primary/secondary table rows use for their "N photos attached"
    /// counts and the "already has photos, overwrite?" picker guard — a
    /// broader question ("is this photo tagged for this value at all") than
    /// "does this exact variant own this photo".
    static func photosTagged(optionName: String, value: String, in imageAssets: [ProductImageAsset]) -> [ProductImageAsset] {
        imageAssets.filter { asset in
            (asset.variantTags ?? []).contains { $0.optionName == optionName && $0.value == value }
        }
    }

    // MARK: ProductDoc <-> pure-logic type bridging

    /// `ProductDoc.options` decodes as `[OptionElement]` (quicktype generated
    /// two structurally-identical types for the same JSON Schema shape, one
    /// per place it's referenced) — this bridges to the `[Option]` every
    /// function above and `ProductRepository.syncVariants` actually take.
    static func options(from productDoc: ProductDoc?) -> [Option] {
        (productDoc?.options ?? []).map { Option(id: $0.id, name: $0.name, values: $0.values) }
    }

    static func variants(from productDoc: ProductDoc?) -> [Variant] {
        productDoc?.variants ?? []
    }
}
