//
//  MercariDateParsingTests.swift
//  wonniTests
//

import XCTest
@testable import wonni

final class MercariDateParsingTests: XCTestCase {
    func test_parseSoldDate_twoDigitYear() {
        let date = MercariDateParsing.parseSoldDate("06/25/26")
        XCTAssertNotNil(date)
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 25)
    }

    func test_parseSoldDate_fourDigitYear() {
        let date = MercariDateParsing.parseSoldDate("06/25/2026")
        XCTAssertNotNil(date)
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 25)
    }

    func test_parseSoldDate_invalidString_returnsNil() {
        XCTAssertNil(MercariDateParsing.parseSoldDate("not a date"))
        XCTAssertNil(MercariDateParsing.parseSoldDate(""))
        XCTAssertNil(MercariDateParsing.parseSoldDate("13/40/26"))
    }
}
