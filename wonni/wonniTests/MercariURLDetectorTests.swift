//
//  MercariURLDetectorTests.swift
//  wonniTests
//

import XCTest
@testable import wonni

final class MercariURLDetectorTests: XCTestCase {
    func test_bareItemId_detectedAsItemId() {
        XCTAssertEqual(MercariURLDetector.detect("m12345678"), .itemId("m12345678"))
    }

    func test_orderStatusURL_extractsItemId() {
        let url = "https://www.mercari.com/transaction/order_status/m54146977204/"
        XCTAssertEqual(MercariURLDetector.detect(url), .orderStatusURL(itemId: "m54146977204"))
    }

    func test_itemListingURL_extractsItemId() {
        let url = "https://www.mercari.com/us/item/m80000976017/"
        XCTAssertEqual(MercariURLDetector.detect(url), .itemURL(itemId: "m80000976017"))
    }

    func test_garbageInput_isUnrecognized() {
        XCTAssertEqual(MercariURLDetector.detect("not a url or id"), .unrecognized)
        XCTAssertEqual(MercariURLDetector.detect(""), .unrecognized)
        XCTAssertEqual(MercariURLDetector.detect("https://www.ebay.com/itm/12345"), .unrecognized)
    }

    func test_urlWithTrailingSlashOrQueryString_stillExtracts() {
        let url = "https://www.mercari.com/us/item/m17026384286/?ref=share"
        XCTAssertEqual(MercariURLDetector.detect(url), .itemURL(itemId: "m17026384286"))
    }

    func test_input_isTrimmedOfWhitespace() {
        XCTAssertEqual(MercariURLDetector.detect("  m12345678  \n"), .itemId("m12345678"))
    }
}
