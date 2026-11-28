import XCTest
@testable import wonni

/// AI tags are suggestions kept apart from the seller's tags (2026-11-28).
final class SuggestedTagsTests: XCTestCase {
    func testKeepMovesASuggestionIntoTheTags() {
        var f = DraftEditFields()
        f.tagsText = "ARIRANG Tour Merch"
        f.suggestedTags = ["bts", "muffler"]
        f.keepSuggestedTag("bts")
        XCTAssertEqual(f.tagsText, "ARIRANG Tour Merch, bts")
        XCTAssertEqual(f.suggestedTags, ["muffler"])
    }

    func testDropOnlyDismissesTheSuggestion() {
        var f = DraftEditFields()
        f.suggestedTags = ["bts", "muffler"]
        f.dropSuggestedTag("muffler")
        XCTAssertEqual(f.tagsText, "")
        XCTAssertEqual(f.suggestedTags, ["bts"])
    }

    func testASuggestionAlreadyTypedIsHidden() {
        var f = DraftEditFields()
        f.tagsText = "BTS"
        f.suggestedTags = ["bts", "kpop"]
        XCTAssertEqual(f.visibleSuggestedTags, ["kpop"])
    }

    func testOldPendingEditWithoutSuggestionsStillDecodes() throws {
        var f = DraftEditFields()
        f.title = "x"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as! [String: Any]
        json.removeValue(forKey: "suggestedTags")
        let decoded = try JSONDecoder().decode(DraftEditFields.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.suggestedTags)
    }

    func testLegacyAITagsAreTheAllLowercaseOnes() {
        XCTAssertEqual(Item.tagsWithoutLegacyAI(["ARIRANG Tour Merch", "spider-man", "marvel comics", "N64"]),
                       ["ARIRANG Tour Merch", "N64"])
    }
}
