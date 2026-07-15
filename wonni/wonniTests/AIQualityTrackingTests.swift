//
//  AIQualityTrackingTests.swift
//  wonniTests
//

import XCTest
@testable import wonni

final class AIQualityTrackingTests: XCTestCase {
    /// Builds a snapshot with neutral defaults so each test states only what it cares about.
    private func snapshot(
        aiTitle: String? = nil,
        aiDescription: String? = nil,
        aiPrice: Double? = nil,
        userTitle: String? = nil,
        userDescription: String? = nil,
        userPrice: Double? = nil,
        visionTitle: String? = nil,
        visionAccepted: Bool = false,
        model: String? = nil,
        prompt: String? = nil,
        undoCount: Int = 0
    ) -> AIQualityTracking {
        AIQualityTracking.from(
            aiSuggestedTitle: aiTitle,
            aiSuggestedDescription: aiDescription,
            aiSuggestedPrice: aiPrice,
            userEditedTitle: userTitle,
            userEditedDescription: userDescription,
            userEditedPrice: userPrice,
            visionTitle: visionTitle,
            visionTitleAccepted: visionAccepted,
            aiModel: model,
            promptVersion: prompt,
            undoCount: undoCount
        )
    }

    func test_untouchedAIOutput_noEditedFlags() {
        // The published value comes from the AI fallback (userEdited* all nil).
        let t = snapshot(aiTitle: "Aespa Lemonade Album", aiDescription: "Like-new…", aiPrice: 35)
        XCTAssertFalse(t.titleEdited)
        XCTAssertFalse(t.descriptionEdited)
        XCTAssertFalse(t.priceEdited)
    }

    func test_userChangedEachField_flagsSet() {
        let t = snapshot(
            aiTitle: "Aespa Lemonade Album", aiDescription: "Like-new…", aiPrice: 35,
            userTitle: "Aespa Lemonade ACID Ver.", userDescription: "My own text", userPrice: 40
        )
        XCTAssertTrue(t.titleEdited)
        XCTAssertTrue(t.descriptionEdited)
        XCTAssertTrue(t.priceEdited)
    }

    func test_userValueEqualToAI_notCountedAsEdited() {
        // The AI title path writes the AI output INTO userEditedTitle when the user
        // had a title hint — identical text must not count as a user edit.
        let t = snapshot(aiTitle: "Same Title", userTitle: "Same Title")
        XCTAssertFalse(t.titleEdited)
    }

    func test_aiNeverProducedField_editedStaysFalse() {
        // Gemini failed / returned nothing: a user-typed value isn't an "edit" of AI
        // output, and must not pollute the quality metric.
        let t = snapshot(userTitle: "Manually typed", userPrice: 12)
        XCTAssertFalse(t.titleEdited)
        XCTAssertFalse(t.priceEdited)
        XCTAssertNil(t.aiSuggestedTitle)
    }

    func test_rawSignalsPassThrough() {
        let t = snapshot(
            visionTitle: "Compact Disc", visionAccepted: true,
            model: "gemini-3.1-flash-lite", prompt: "2026-07-14.1", undoCount: 2
        )
        XCTAssertEqual(t.visionTitle, "Compact Disc")
        XCTAssertTrue(t.visionTitleAccepted)
        XCTAssertEqual(t.aiModel, "gemini-3.1-flash-lite")
        XCTAssertEqual(t.promptVersion, "2026-07-14.1")
        XCTAssertEqual(t.undoCount, 2)
    }
}
