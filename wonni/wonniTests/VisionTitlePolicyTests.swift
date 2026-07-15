//
//  VisionTitlePolicyTests.swift
//  wonniTests
//

import XCTest
@testable import wonni

final class VisionTitlePolicyTests: XCTestCase {
    private func candidate(
        _ identifier: String,
        confidence: Float,
        passes: Bool = true
    ) -> VisionTitlePolicy.Candidate {
        VisionTitlePolicy.Candidate(
            identifier: identifier, confidence: confidence, passesPrecisionFilter: passes
        )
    }

    // MARK: Classification selection

    func test_specificLabelBeatsGenericAncestor() {
        // The reported failure mode: "structure" (generic ancestor, highest confidence)
        // used to win over the actually useful label.
        let result = VisionTitlePolicy.suggestion(
            classifications: [
                candidate("structure", confidence: 0.95),
                candidate("compact_disc", confidence: 0.72),
            ],
            ocrText: nil
        )
        XCTAssertEqual(result, "Compact Disc")
    }

    func test_compoundIdentifierOutranksSingleWordEvenAtLowerConfidence() {
        let result = VisionTitlePolicy.suggestion(
            classifications: [
                candidate("toy", confidence: 0.9),
                candidate("action_figure", confidence: 0.65),
            ],
            ocrText: nil
        )
        XCTAssertEqual(result, "Action Figure")
    }

    func test_confidenceBreaksTiesWithinSameSpecificity() {
        let result = VisionTitlePolicy.suggestion(
            classifications: [
                candidate("hot_air_balloon", confidence: 0.7),
                candidate("compact_disc", confidence: 0.8),
            ],
            ocrText: nil
        )
        XCTAssertEqual(result, "Compact Disc")
    }

    func test_denylistedLabelNeverSuggested() {
        for generic in ["structure", "material", "object", "indoor", "texture"] {
            let result = VisionTitlePolicy.suggestion(
                classifications: [candidate(generic, confidence: 0.99)],
                ocrText: nil
            )
            XCTAssertNil(result, "\"\(generic)\" should never be suggested")
        }
    }

    func test_denylistIsCaseInsensitiveOnIdentifier() {
        XCTAssertNil(VisionTitlePolicy.suggestion(
            classifications: [candidate("Structure", confidence: 0.99)],
            ocrText: nil
        ))
    }

    func test_allGenericTokenCompound_rejectedDespiteCompoundPreference() {
        // Device regression 2026-07-14: "wood_processed" (the photo's wooden
        // BACKGROUND) won because compound identifiers are preferred. Material-only
        // compounds must lose to OCR / blank.
        XCTAssertNil(VisionTitlePolicy.suggestion(
            classifications: [candidate("wood_processed", confidence: 0.95)],
            ocrText: nil
        ))
        // With OCR present, the material label must not shadow it.
        XCTAssertEqual(
            VisionTitlePolicy.suggestion(
                classifications: [candidate("wood_processed", confidence: 0.95)],
                ocrText: "aespa lemonade"
            ),
            "Aespa Lemonade"
        )
    }

    func test_partiallyGenericCompound_stillAccepted() {
        // "compact_disc" has no material tokens; a mixed id like "glass_bottle"
        // (generic material + real subject noun) must also survive.
        XCTAssertEqual(
            VisionTitlePolicy.suggestion(
                classifications: [candidate("glass_bottle", confidence: 0.8)],
                ocrText: nil
            ),
            "Glass Bottle"
        )
    }

    func test_belowConfidenceFloor_noClassificationSuggestion() {
        let result = VisionTitlePolicy.suggestion(
            classifications: [candidate(
                "compact_disc",
                confidence: VisionTitlePolicy.minClassificationConfidence - 0.01
            )],
            ocrText: nil
        )
        XCTAssertNil(result)
    }

    func test_failingPrecisionFilter_excluded() {
        let result = VisionTitlePolicy.suggestion(
            classifications: [candidate("compact_disc", confidence: 0.9, passes: false)],
            ocrText: nil
        )
        XCTAssertNil(result)
    }

    // MARK: OCR fallback

    func test_ocrFallbackWhenNoEligibleClassification() {
        let result = VisionTitlePolicy.suggestion(
            classifications: [candidate("structure", confidence: 0.99)],
            ocrText: "sony walkman"
        )
        XCTAssertEqual(result, "Sony Walkman")
    }

    func test_classificationWinsOverOCR() {
        // Order agreed 2026-07-14: confident specific classification first, OCR second.
        let result = VisionTitlePolicy.suggestion(
            classifications: [candidate("compact_disc", confidence: 0.85)],
            ocrText: "some printed text"
        )
        XCTAssertEqual(result, "Compact Disc")
    }

    func test_whitespaceOnlyOCR_treatedAsAbsent() {
        XCTAssertNil(VisionTitlePolicy.suggestion(
            classifications: [],
            ocrText: "   \n"
        ))
    }

    // MARK: Blank fallback

    func test_nothingUseful_returnsNil() {
        XCTAssertNil(VisionTitlePolicy.suggestion(classifications: [], ocrText: nil))
        XCTAssertNil(VisionTitlePolicy.suggestion(
            classifications: [candidate("object", confidence: 0.99)],
            ocrText: nil
        ))
    }

    // MARK: Label formatting

    func test_humanReadableLabel() {
        XCTAssertEqual(VisionTitlePolicy.humanReadableLabel("hot_air_balloon"), "Hot Air Balloon")
        XCTAssertEqual(VisionTitlePolicy.humanReadableLabel("butterfly"), "Butterfly")
    }
}
