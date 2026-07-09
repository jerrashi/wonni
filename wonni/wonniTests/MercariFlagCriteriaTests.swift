//
//  MercariFlagCriteriaTests.swift
//  wonniTests
//

import XCTest
@testable import wonni

final class MercariFlagCriteriaTests: XCTestCase {
    private let completeName = "Taesan - BOYNEXTDOOR Home Album"
    private let completePrice = 25.0
    private let completeTakeHome = 20.0
    private let completeSoldAt = Date()

    func test_allFieldsPresent_doesNotNeedFix() {
        XCTAssertFalse(MercariSaleValidation.needsFix(
            name: completeName, price: completePrice, takeHome: completeTakeHome, soldAt: completeSoldAt
        ))
    }

    func test_missingName_needsFix() {
        XCTAssertTrue(MercariSaleValidation.needsFix(
            name: nil, price: completePrice, takeHome: completeTakeHome, soldAt: completeSoldAt
        ))
        XCTAssertTrue(MercariSaleValidation.needsFix(
            name: "   ", price: completePrice, takeHome: completeTakeHome, soldAt: completeSoldAt
        ))
    }

    func test_missingOrZeroPrice_needsFix() {
        XCTAssertTrue(MercariSaleValidation.needsFix(
            name: completeName, price: nil, takeHome: completeTakeHome, soldAt: completeSoldAt
        ))
        XCTAssertTrue(MercariSaleValidation.needsFix(
            name: completeName, price: 0, takeHome: completeTakeHome, soldAt: completeSoldAt
        ))
    }

    func test_missingTakeHome_needsFix() {
        XCTAssertTrue(MercariSaleValidation.needsFix(
            name: completeName, price: completePrice, takeHome: nil, soldAt: completeSoldAt
        ))
    }

    func test_missingSoldAt_needsFix() {
        XCTAssertTrue(MercariSaleValidation.needsFix(
            name: completeName, price: completePrice, takeHome: completeTakeHome, soldAt: nil
        ))
    }
}
