import XCTest
@testable import wonni

/// Pure decision helpers behind FacebookAutoPosterView — the parts of the Facebook flow
/// that can regress without a device: login-page detection and the per-listing /
/// account-default toggle resolution.
final class FacebookAutofillPolicyTests: XCTestCase {

    func testLoginURLsAreDetected() {
        let loginURLs = [
            "https://m.facebook.com/login/?next=https%3A%2F%2Fwww.facebook.com%2Fmarketplace",
            "https://www.facebook.com/login.php?next=/marketplace/create/item",
            "https://www.facebook.com/checkpoint/1501092823525282/",
            "https://m.facebook.com/two_step_verification/authentication/",
            "https://www.facebook.com/recover/initiate/",
        ]
        for raw in loginURLs {
            XCTAssertTrue(FacebookAutoPosterView.isFacebookLoginURL(URL(string: raw)), raw)
        }
    }

    func testFormAndMarketplaceURLsAreNotLogin() {
        let formURLs = [
            "https://www.facebook.com/marketplace/create/item",
            "https://www.facebook.com/marketplace/selling/item/?listing_id",
            "https://www.facebook.com/marketplace/item/123456789/",
            "https://www.facebook.com/",
        ]
        for raw in formURLs {
            XCTAssertFalse(FacebookAutoPosterView.isFacebookLoginURL(URL(string: raw)), raw)
        }
        XCTAssertFalse(FacebookAutoPosterView.isFacebookLoginURL(nil))
    }

    func testListingOverrideBeatsAccountDefault() {
        XCTAssertTrue(FacebookAutoPosterView.effectiveToggle(override: true, accountDefault: false))
        XCTAssertFalse(FacebookAutoPosterView.effectiveToggle(override: false, accountDefault: true))
    }

    func testNilOverrideFallsBackToAccountDefault() {
        XCTAssertTrue(FacebookAutoPosterView.effectiveToggle(override: nil, accountDefault: true))
        XCTAssertFalse(FacebookAutoPosterView.effectiveToggle(override: nil, accountDefault: false))
    }

    func testConditionMapsOntoFacebooksFourBuckets() {
        XCTAssertEqual(FacebookAutoPosterView.facebookConditionLabel(ItemCondition.new.rawValue), "New")
        XCTAssertEqual(FacebookAutoPosterView.facebookConditionLabel(ItemCondition.newWithoutTags.rawValue), "New")
        XCTAssertEqual(FacebookAutoPosterView.facebookConditionLabel(ItemCondition.likeNew.rawValue), "Used - Like New")
        XCTAssertEqual(FacebookAutoPosterView.facebookConditionLabel(ItemCondition.good.rawValue), "Used - Good")
        XCTAssertEqual(FacebookAutoPosterView.facebookConditionLabel(ItemCondition.forParts.rawValue), "Used - Fair")
        XCTAssertEqual(FacebookAutoPosterView.facebookConditionLabel("garbage"), "Used - Good")
    }
}
