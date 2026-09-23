//
//  VariantEditingTests.swift
//  wonniTests
//
//  Shared-fixture parity tests for VariantLogic (Data/VariantEditing.swift)
//  against web's ProductDetail.jsx structural-edit functions. Each test name
//  says which web behavior it's pinning down.
//

import XCTest
@testable import wonni

final class VariantEditingTests: XCTestCase {

    // MARK: - Helpers

    private func option(_ name: String, _ values: [String]) -> Option {
        Option(id: nil, name: name, values: values)
    }

    private func makeVariant(
        id: String = VariantLogic.generateVariantId(),
        optionValues: [String: String],
        sku: String? = nil,
        price: Double? = nil,
        quantity: Int = 1,
        active: Bool = true,
        sourceVariantId: String? = nil,
        sourcePrice: Double? = nil
    ) -> Variant {
        Variant(
            active: active,
            crossPostListingIds: VariantLogic.emptyCrossPostListingIds(),
            crossPostStatus: VariantLogic.emptyCrossPostStatus(),
            id: id,
            mercariUrl: nil,
            optionValues: optionValues,
            pendingMercariDeactivation: nil,
            pendingMercariRelist: nil,
            price: price,
            quantity: quantity,
            sku: sku,
            sourcePrice: sourcePrice,
            sourceVariantId: sourceVariantId
        )
    }

    // MARK: - cartesianOptionValues

    func test_cartesian_oneDimension_returnsOneComboPerValue() {
        let combos = VariantLogic.cartesianOptionValues([option("Style", ["RM", "Jimin"])])
        XCTAssertEqual(combos.count, 2)
        XCTAssertTrue(combos.contains(["Style": "RM"]))
        XCTAssertTrue(combos.contains(["Style": "Jimin"]))
    }

    func test_cartesian_twoDimensions_returnsFullCrossProduct() {
        let combos = VariantLogic.cartesianOptionValues([
            option("Style", ["RM", "Jimin"]),
            option("Size", ["S", "M", "L"]),
        ])
        XCTAssertEqual(combos.count, 6)
        for style in ["RM", "Jimin"] {
            for size in ["S", "M", "L"] {
                XCTAssertTrue(combos.contains(["Style": style, "Size": size]), "missing combo \(style)/\(size)")
            }
        }
    }

    func test_cartesian_optionWithNoValuesYet_isIgnoredNotCollapsing() {
        // Mirrors web's comment: a freshly-added "+ Add option" dimension with
        // no values yet must not collapse the whole result to zero combos.
        let combos = VariantLogic.cartesianOptionValues([
            option("Style", ["RM"]),
            option("Size", []),
        ])
        XCTAssertEqual(combos, [["Style": "RM"]])
    }

    func test_cartesian_noOptionsAtAll_returnsSingleEmptyCombo() {
        XCTAssertEqual(VariantLogic.cartesianOptionValues([]), [[:]])
    }

    /// The degenerate "single option, single value" case — a product with
    /// exactly one variation dimension that (so far) only has one value
    /// typed. Still a real, single-row cartesian result, not the "no values
    /// yet" ignore-path above.
    func test_cartesian_singleOptionSingleValue_returnsOneCombo() {
        XCTAssertEqual(VariantLogic.cartesianOptionValues([option("Style", ["RM"])]), [["Style": "RM"]])
    }

    // MARK: - applyOptionRename

    func test_rename_dimensionNameOnly_preservesPriceAndSku() {
        let v = makeVariant(optionValues: ["Style": "RM"], sku: "sku-1", price: 12.5)
        let renamed = VariantLogic.applyOptionRename(
            [v], optionName: "Style", newOptionName: "Member", valueRenames: [:]
        )
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed[0].optionValues, ["Member": "RM"])
        XCTAssertEqual(renamed[0].sku, "sku-1")
        XCTAssertEqual(renamed[0].price, 12.5)
        XCTAssertEqual(renamed[0].id, v.id)
    }

    func test_rename_valueTextOnly_preservesPriceAndSku() {
        let v = makeVariant(optionValues: ["Style": "RM"], sku: "sku-1", price: 12.5)
        let renamed = VariantLogic.applyOptionRename(
            [v], optionName: "Style", newOptionName: "Style", valueRenames: ["RM": "Kim Namjoon"]
        )
        XCTAssertEqual(renamed[0].optionValues, ["Style": "Kim Namjoon"])
        XCTAssertEqual(renamed[0].sku, "sku-1")
        XCTAssertEqual(renamed[0].price, 12.5)
    }

    func test_rename_leavesVariantsWithoutThatOptionUntouched() {
        let v = makeVariant(optionValues: ["Size": "M"])
        let renamed = VariantLogic.applyOptionRename(
            [v], optionName: "Style", newOptionName: "Member", valueRenames: [:]
        )
        XCTAssertEqual(renamed, [v])
    }

    /// Web's `applyOptionRename` (ProductDetail.jsx) applies its `renameMap`
    /// with a single `Map.get` per variant — no re-lookup of the *renamed*
    /// value. So a rename dict describing a chain (A -> B, B -> C) does NOT
    /// transitively chase A all the way to C: a variant that was "A" lands on
    /// "B" (not "C"), and a variant that was already "B" independently lands
    /// on "C". Swift's `valueRenames[oldValue] ?? oldValue` is the same
    /// single dictionary lookup, so it must match exactly.
    func test_rename_chainedValueRenames_isSinglePassNotTransitive() {
        let wasA = makeVariant(optionValues: ["Style": "A"])
        let wasB = makeVariant(optionValues: ["Style": "B"])
        let renamed = VariantLogic.applyOptionRename(
            [wasA, wasB], optionName: "Style", newOptionName: "Style",
            valueRenames: ["A": "B", "B": "C"]
        )
        XCTAssertEqual(renamed.first { $0.id == wasA.id }?.optionValues, ["Style": "B"])
        XCTAssertEqual(renamed.first { $0.id == wasB.id }?.optionValues, ["Style": "C"])
    }

    /// Neither web's `applyOptionRename` nor this port guards against two
    /// *different* source values being renamed to the same new text — that
    /// collision is only prevented one layer up, by the "Manage variations"
    /// UI's save guard (web: `new Set(values).size !== values.length` in
    /// `saveDraft`; iOS: the equivalent check in `VariantsEditorView`'s
    /// `saveDraft`, both of which block the save entirely before calling into
    /// this function). Calling the pure function directly with a colliding
    /// rename map — as could happen if a caller ever bypassed that UI guard —
    /// silently produces two variant rows sharing the identical
    /// `optionValues` combo. This test pins down that real (if UI-guarded)
    /// behavior rather than assuming the pure layer defends against it.
    func test_rename_twoValuesRenamedToSameText_collidesIntoDuplicateOptionValues() {
        let wasRM = makeVariant(optionValues: ["Style": "RM"])
        let wasJimin = makeVariant(optionValues: ["Style": "Jimin"])
        let renamed = VariantLogic.applyOptionRename(
            [wasRM, wasJimin], optionName: "Style", newOptionName: "Style",
            valueRenames: ["RM": "Member", "Jimin": "Member"]
        )
        XCTAssertEqual(renamed.map { $0.optionValues }, [["Style": "Member"], ["Style": "Member"]])
    }

    // MARK: - removeOptionValues (hard delete)

    func test_removeOptionValues_hardDeletesMatchingRows() {
        let keep = makeVariant(optionValues: ["Style": "Jimin"])
        let drop = makeVariant(optionValues: ["Style": "RM"], price: 20, sourceVariantId: "w123")
        let result = VariantLogic.removeOptionValues([keep, drop], optionName: "Style", removedValues: ["RM"])
        XCTAssertEqual(result.map(\.id), [keep.id])
    }

    func test_removeOptionValues_emptyRemovedList_isNoOp() {
        let v = makeVariant(optionValues: ["Style": "RM"])
        XCTAssertEqual(VariantLogic.removeOptionValues([v], optionName: "Style", removedValues: []), [v])
    }

    /// Removing the *only* remaining value of a dimension is blocked one
    /// layer up — both web's `saveDraft` (`if (!name || !values.length ||
    /// values.some((v) => !v)) return;`, ProductDetail.jsx) and iOS's
    /// `VariantsEditorView.saveDraft` (the equivalent
    /// `guard !name.isEmpty, !values.isEmpty, ... else { return false }`)
    /// refuse to submit an edit that would leave an option with zero values;
    /// the only way to actually drop a dimension to nothing is the trash-icon
    /// "delete option entirely" path (`removeOptionEntirely`), which also
    /// drops the option out of `nextOptions` so `hasVariants` (`nextOptions.
    /// length > 0` / iOS's `!nextOptions.isEmpty`) correctly collapses to
    /// false. This function itself has no such guard — it just does what
    /// it's told — so this test documents that the *pure* `removeOptionValues`
    /// will happily hard-delete every row for a dimension if asked (leaving
    /// the option's `values` array, if the caller still supplies one, as the
    /// caller's problem, not this function's).
    func test_removeOptionValues_removingEveryValue_dropsEveryRowForThatDimension() {
        let a = makeVariant(optionValues: ["Style": "OnlyValue"], sourceVariantId: "w1")
        let b = makeVariant(optionValues: ["Style": "OnlyValue"], sku: "p-2")
        let result = VariantLogic.removeOptionValues([a, b], optionName: "Style", removedValues: ["OnlyValue"])
        XCTAssertEqual(result, [])
    }

    // MARK: - removeOptionEntirely (hard delete)

    func test_removeOptionEntirely_dropsEveryRowCarryingThatDimension() {
        let a = makeVariant(optionValues: ["Style": "RM", "Size": "M"])
        let b = makeVariant(optionValues: ["Style": "Jimin", "Size": "L"])
        let unrelated = makeVariant(optionValues: ["Size": "S"]) // no Style key at all
        let result = VariantLogic.removeOptionEntirely([a, b, unrelated], optionName: "Style")
        XCTAssertEqual(result.map(\.id), [unrelated.id])
    }

    // MARK: - addOptionValues

    func test_addOptionValues_addsOneBlankRowPerOtherDimensionCombo() {
        let existing = [makeVariant(optionValues: ["Style": "RM", "Size": "S"], sku: "p-1")]
        let next = VariantLogic.addOptionValues(
            existing,
            otherOptions: [option("Size", ["S", "M", "L"])],
            optionName: "Style",
            addedValues: ["Jimin"],
            productId: "p"
        )
        XCTAssertEqual(next.count, existing.count + 3)
        let added = next.dropFirst()
        XCTAssertEqual(Set(added.map { $0.optionValues["Size"] }), Set(["S", "M", "L"]))
        for row in added {
            XCTAssertEqual(row.optionValues["Style"], "Jimin")
            XCTAssertEqual(row.price, nil)
            XCTAssertEqual(row.quantity, 1)
            XCTAssertTrue(row.active)
        }
        // Existing row untouched.
        XCTAssertEqual(next[0].sku, "p-1")
    }

    // MARK: - addNewOptionDimension: the single-SKU -> first-dimension transition

    func test_addNewOptionDimension_noExistingRows_everyValueBlank() {
        let next = VariantLogic.addNewOptionDimension([], optionName: "Style", values: ["RM", "Jimin"], productId: "p")
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next[0].optionValues, ["Style": "RM"])
        XCTAssertEqual(next[1].optionValues, ["Style": "Jimin"])
        XCTAssertEqual(next[0].sku, "p-1")
        XCTAssertEqual(next[1].sku, "p-2")
    }

    /// The one transition the task explicitly calls out as easy to get subtly
    /// wrong: a single existing (active) row *becomes* the first new value —
    /// keeping its id/sku/price — while the rest of the new dimension's
    /// values generate fresh blank rows alongside it.
    func test_addNewOptionDimension_singleExistingRow_becomesFirstValue() {
        let existing = makeVariant(optionValues: [:], sku: "listing-sku", price: 42, sourceVariantId: "src-1")
        let next = VariantLogic.addNewOptionDimension(
            [existing], optionName: "Size", values: ["M-L", "XL-XXL"], productId: "p"
        )
        XCTAssertEqual(next.count, 2)

        // The original row becomes "M-L" — same id, sku, price, sourceVariantId.
        let becameFirst = next.first { $0.id == existing.id }
        XCTAssertNotNil(becameFirst)
        XCTAssertEqual(becameFirst?.optionValues, ["Size": "M-L"])
        XCTAssertEqual(becameFirst?.sku, "listing-sku")
        XCTAssertEqual(becameFirst?.price, 42)
        XCTAssertEqual(becameFirst?.sourceVariantId, "src-1")

        // The remaining value is a brand-new blank row.
        let blank = next.first { $0.id != existing.id }
        XCTAssertNotNil(blank)
        XCTAssertEqual(blank?.optionValues, ["Size": "XL-XXL"])
        XCTAssertEqual(blank?.price, nil)
        XCTAssertEqual(blank?.sourceVariantId, nil)
    }

    func test_addNewOptionDimension_multipleExistingRows_eachBecomesFirstValueIndependently() {
        let a = makeVariant(optionValues: ["Style": "RM"], sku: "a")
        let b = makeVariant(optionValues: ["Style": "Jimin"], sku: "b")
        let next = VariantLogic.addNewOptionDimension([a, b], optionName: "Size", values: ["S", "M"], productId: "p")

        XCTAssertEqual(next.count, 4)
        let aFirst = next.first { $0.id == a.id }
        XCTAssertEqual(aFirst?.optionValues, ["Style": "RM", "Size": "S"])
        let bFirst = next.first { $0.id == b.id }
        XCTAssertEqual(bFirst?.optionValues, ["Style": "Jimin", "Size": "S"])

        let newRows = next.filter { $0.id != a.id && $0.id != b.id }
        XCTAssertEqual(newRows.count, 2)
        XCTAssertTrue(newRows.contains { $0.optionValues == ["Style": "RM", "Size": "M"] })
        XCTAssertTrue(newRows.contains { $0.optionValues == ["Style": "Jimin", "Size": "M"] })
    }

    /// A single-value new dimension (e.g. the very first value typed, or a
    /// dimension that will only ever have one value) must not fabricate any
    /// extra blank rows — `restValues` is empty, so every active existing row
    /// just becomes that one value in place, one-for-one, exactly like web's
    /// `[firstValue, ...restValues] = values` destructure with an
    /// empty `restValues`.
    func test_addNewOptionDimension_singleValueOnly_everyActiveRowBecomesItInPlace_noExtraRows() {
        let a = makeVariant(optionValues: ["Style": "RM"], sku: "a")
        let b = makeVariant(optionValues: ["Style": "Jimin"], sku: "b")
        let next = VariantLogic.addNewOptionDimension([a, b], optionName: "Size", values: ["OneSize"], productId: "p")
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.first { $0.id == a.id }?.optionValues, ["Style": "RM", "Size": "OneSize"])
        XCTAssertEqual(next.first { $0.id == b.id }?.optionValues, ["Style": "Jimin", "Size": "OneSize"])
    }

    func test_addNewOptionDimension_inactiveRowsAreLeftAsIs() {
        let inactive = makeVariant(optionValues: [:], sku: "gone", active: false)
        let next = VariantLogic.addNewOptionDimension([inactive], optionName: "Size", values: ["S"], productId: "p")
        // No active rows to carry data over from, so every value is blank —
        // the inactive row passes through untouched (it's excluded from
        // `activeExisting`, so the "no prior rows" branch fires), same as web.
        XCTAssertTrue(next.contains { $0.id == inactive.id && $0.optionValues.isEmpty })
        XCTAssertTrue(next.contains { $0.optionValues == ["Size": "S"] && $0.id != inactive.id })
    }

    // MARK: - isPopulatedVariant

    func test_isPopulatedVariant_sourceVariantIdCounts() {
        let v = makeVariant(optionValues: [:], sourceVariantId: "src-1")
        XCTAssertTrue(VariantLogic.isPopulatedVariant(v, listingPrice: nil))
    }

    func test_isPopulatedVariant_priceMatchingListingPriceDoesNotCount() {
        let v = makeVariant(optionValues: [:], price: 10)
        XCTAssertFalse(VariantLogic.isPopulatedVariant(v, listingPrice: 10))
    }

    func test_isPopulatedVariant_priceDivergingFromListingPriceCounts() {
        let v = makeVariant(optionValues: [:], price: 15)
        XCTAssertTrue(VariantLogic.isPopulatedVariant(v, listingPrice: 10))
    }

    func test_isPopulatedVariant_blankRowDoesNotCount() {
        let v = makeVariant(optionValues: ["Style": "RM"])
        XCTAssertFalse(VariantLogic.isPopulatedVariant(v, listingPrice: nil))
    }

    // MARK: - applyStructuralChange / rowsToBeRemoved end-to-end

    func test_applyStructuralChange_editOption_removedValuesAreHardDeleted() {
        let keep = makeVariant(optionValues: ["Style": "Jimin"])
        let drop = makeVariant(optionValues: ["Style": "RM"], sourceVariantId: "w1")
        let change = VariantStructuralChange.editOptionDimension(
            name: "Style", newName: "Style", valueRenames: [:], removedValues: ["RM"], addedValues: []
        )
        let removed = VariantLogic.rowsToBeRemoved(change: change, currentVariants: [keep, drop])
        XCTAssertEqual(removed.map(\.id), [drop.id])

        let next = VariantLogic.applyStructuralChange(
            nextOptions: [option("Style", ["Jimin"])],
            change: change,
            currentVariants: [keep, drop],
            productId: "p"
        )
        XCTAssertEqual(next.map(\.id), [keep.id])
    }

    func test_rowsToBeRemoved_addingADimension_neverRemovesAnything() {
        let existing = [makeVariant(optionValues: [:], sourceVariantId: "src")]
        let change = VariantStructuralChange.addOptionDimension(name: "Style", values: ["RM"])
        XCTAssertEqual(VariantLogic.rowsToBeRemoved(change: change, currentVariants: existing), [])
    }

    // MARK: - Photo matching (sharedPhotos / variantPhotos / photosTagged)

    func test_sharedPhotos_onlyUntaggedPhotos() {
        let shared = ProductImageAsset(id: "1", url: "u1", variantTags: nil)
        let sharedEmpty = ProductImageAsset(id: "2", url: "u2", variantTags: [])
        let tagged = ProductImageAsset(id: "3", url: "u3", variantTags: [VariantPhotoTag(optionName: "Style", value: "RM")])
        let result = VariantLogic.sharedPhotos([shared, sharedEmpty, tagged])
        XCTAssertEqual(Set(result.map(\.id)), Set(["1", "2"]))
    }

    /// The exact case called out in the task: a photo tagged with only the
    /// Style dimension (no Size tag) must match EVERY Size under that Style —
    /// a partial tag set is intentionally broader, not an error.
    func test_variantPhotos_partialTagMatchesEverySubValue() {
        let photo = ProductImageAsset(id: "1", url: "u", variantTags: [VariantPhotoTag(optionName: "Style", value: "RM")])
        let variantSmall = makeVariant(optionValues: ["Style": "RM", "Size": "S"])
        let variantLarge = makeVariant(optionValues: ["Style": "RM", "Size": "L"])
        let variantOtherStyle = makeVariant(optionValues: ["Style": "Jimin", "Size": "S"])

        XCTAssertEqual(VariantLogic.variantPhotos(variantSmall, imageAssets: [photo]).map(\.id), ["1"])
        XCTAssertEqual(VariantLogic.variantPhotos(variantLarge, imageAssets: [photo]).map(\.id), ["1"])
        XCTAssertEqual(VariantLogic.variantPhotos(variantOtherStyle, imageAssets: [photo]), [])
    }

    func test_variantPhotos_fullyTaggedPhotoMatchesOnlyExactCombo() {
        let photo = ProductImageAsset(
            id: "1", url: "u",
            variantTags: [VariantPhotoTag(optionName: "Style", value: "RM"), VariantPhotoTag(optionName: "Size", value: "S")]
        )
        let exact = makeVariant(optionValues: ["Style": "RM", "Size": "S"])
        let sameStyleDifferentSize = makeVariant(optionValues: ["Style": "RM", "Size": "L"])

        XCTAssertEqual(VariantLogic.variantPhotos(exact, imageAssets: [photo]).map(\.id), ["1"])
        XCTAssertEqual(VariantLogic.variantPhotos(sameStyleDifferentSize, imageAssets: [photo]), [])
    }

    func test_variantPhotos_untaggedPhotoMatchesNoVariant() {
        let photo = ProductImageAsset(id: "1", url: "u", variantTags: nil)
        let variant = makeVariant(optionValues: ["Style": "RM"])
        XCTAssertEqual(VariantLogic.variantPhotos(variant, imageAssets: [photo]), [])
    }

    /// A photo tagged with an option NAME that no longer exists on the
    /// product — e.g. it was tagged "Color: Red" before "Color" was renamed
    /// to "Style" via the Manage Variations rename flow, and the photo's tag
    /// was never re-applied (nothing in `applyOptionRename` touches
    /// `imageAssets[].variantTags`; renaming a dimension only relabels
    /// `variants[].optionValues`, on both web and iOS). `variant.
    /// optionValues[tag.optionName]` is then nil for every variant (no
    /// variant carries a "Color" key any more), which never equals the tag's
    /// non-nil `value`, so `variantPhotos` matches nothing for ANY variant —
    /// not just the ones that used to be "Red". This is real, observable
    /// parity behavior on both platforms (not a bug in this port), and worth
    /// pinning down since a stale tag silently orphans a photo rather than
    /// erroring or falling back to "shared".
    func test_variantPhotos_staleTagOptionNameNoLongerOnProduct_matchesNoVariant() {
        let stalePhoto = ProductImageAsset(
            id: "1", url: "u",
            variantTags: [VariantPhotoTag(optionName: "Color", value: "Red")]
        )
        let variant = makeVariant(optionValues: ["Style": "Red"]) // renamed dimension; no "Color" key survives
        XCTAssertEqual(VariantLogic.variantPhotos(variant, imageAssets: [stalePhoto]), [])
    }

    /// The same stale-tagged photo is also excluded from `sharedPhotos`
    /// (its `variantTags` is non-empty, so it fails the "no tags at all"
    /// shared-photo test) — so after a dimension rename with no photo
    /// re-tagging, a previously-assigned photo becomes invisible to every
    /// variant AND is not folded back into the shared pool. It doesn't
    /// silently disappear from `imageAssets` itself (still present, still
    /// shown in the product's general photo grid) — just unreachable through
    /// either per-variant path until someone re-tags it.
    func test_sharedPhotos_photoWithStaleTags_isExcludedNotFoldedIntoShared() {
        let stalePhoto = ProductImageAsset(
            id: "1", url: "u",
            variantTags: [VariantPhotoTag(optionName: "Color", value: "Red")]
        )
        XCTAssertEqual(VariantLogic.sharedPhotos([stalePhoto]), [])
    }

    func test_resolvedMercariPhotoURLs_emptyImageAssets_returnsEmpty() {
        let variant = makeVariant(optionValues: ["Style": "RM"])
        XCTAssertEqual(VariantLogic.resolvedMercariPhotoURLs(variant: variant, imageAssets: []), [])
    }

    func test_photosTagged_directValueMatch() {
        let photo = ProductImageAsset(id: "1", url: "u", variantTags: [VariantPhotoTag(optionName: "Style", value: "RM")])
        XCTAssertEqual(VariantLogic.photosTagged(optionName: "Style", value: "RM", in: [photo]).map(\.id), ["1"])
        XCTAssertEqual(VariantLogic.photosTagged(optionName: "Style", value: "Jimin", in: [photo]), [])
    }

    // MARK: - Mercari per-variant listing resolution (Phase 3)

    func test_defaultMercariTitle_appendsSortedOptionValues() {
        let variant = makeVariant(optionValues: ["Size": "L", "Style": "RM"])
        XCTAssertEqual(VariantLogic.defaultMercariTitle(baseTitle: "Cool Hoodie", variant: variant), "Cool Hoodie - RM L")
    }

    func test_defaultMercariTitle_noOptionValues_fallsBackToBaseTitle() {
        let variant = makeVariant(optionValues: [:])
        XCTAssertEqual(VariantLogic.defaultMercariTitle(baseTitle: "Cool Hoodie", variant: variant), "Cool Hoodie")
    }

    func test_resolvedMercariTitle_usesOverrideWhenSet() {
        let variant = makeVariant(optionValues: ["Style": "RM"])
        let resolved = VariantLogic.resolvedMercariTitle(
            baseTitle: "Cool Hoodie",
            variant: variant,
            overrides: [variant.id: "Custom Title"]
        )
        XCTAssertEqual(resolved, "Custom Title")
    }

    func test_resolvedMercariTitle_blankOverrideFallsBackToDefault() {
        let variant = makeVariant(optionValues: ["Style": "RM"])
        let resolved = VariantLogic.resolvedMercariTitle(
            baseTitle: "Cool Hoodie",
            variant: variant,
            overrides: [variant.id: "   "]
        )
        XCTAssertEqual(resolved, "Cool Hoodie - RM")
    }

    func test_resolvedMercariTitle_truncatesTo80Characters() {
        let variant = makeVariant(optionValues: [:])
        let longTitle = String(repeating: "x", count: 100)
        let resolved = VariantLogic.resolvedMercariTitle(baseTitle: longTitle, variant: variant, overrides: [:])
        XCTAssertEqual(resolved.count, 80)
    }

    func test_resolvedMercariPhotoURLs_combinesSharedAndOwnTaggedPhotos_deduplicated() {
        let shared = ProductImageAsset(id: "shared", url: "shared-url", variantTags: nil)
        let owned = ProductImageAsset(id: "owned", url: "owned-url", variantTags: [VariantPhotoTag(optionName: "Style", value: "RM")])
        let otherStyle = ProductImageAsset(id: "other", url: "other-url", variantTags: [VariantPhotoTag(optionName: "Style", value: "Jimin")])
        let duplicateSharedUrl = ProductImageAsset(id: "dup", url: "shared-url", variantTags: nil)
        let variant = makeVariant(optionValues: ["Style": "RM"])

        let urls = VariantLogic.resolvedMercariPhotoURLs(
            variant: variant,
            imageAssets: [shared, owned, otherStyle, duplicateSharedUrl]
        )

        XCTAssertEqual(urls, ["shared-url", "owned-url"])
    }
}
