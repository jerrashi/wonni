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

    // MARK: - removeOptionValues (hard delete)

    func test_removeOptionValues_hardDeletesMatchingRows() {
        let keep = makeVariant(optionValues: ["Style": "Jimin"])
        let drop = makeVariant(optionValues: ["Style": "RM"], sourceVariantId: "w123", price: 20)
        let result = VariantLogic.removeOptionValues([keep, drop], optionName: "Style", removedValues: ["RM"])
        XCTAssertEqual(result.map(\.id), [keep.id])
    }

    func test_removeOptionValues_emptyRemovedList_isNoOp() {
        let v = makeVariant(optionValues: ["Style": "RM"])
        XCTAssertEqual(VariantLogic.removeOptionValues([v], optionName: "Style", removedValues: []), [v])
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

    func test_addNewOptionDimension_inactiveRowsAreLeftAsIs() {
        let inactive = makeVariant(optionValues: [:], active: false, sku: "gone")
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

    func test_photosTagged_directValueMatch() {
        let photo = ProductImageAsset(id: "1", url: "u", variantTags: [VariantPhotoTag(optionName: "Style", value: "RM")])
        XCTAssertEqual(VariantLogic.photosTagged(optionName: "Style", value: "RM", in: [photo]).map(\.id), ["1"])
        XCTAssertEqual(VariantLogic.photosTagged(optionName: "Style", value: "Jimin", in: [photo]), [])
    }
}
