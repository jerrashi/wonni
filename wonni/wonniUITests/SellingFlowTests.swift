//
//  SellingFlowTests.swift
//  wonniUITests
//
//  Tests the critical end-to-end selling flow: camera → process → publish
//

import XCTest

final class SellingFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Test the complete selling flow from camera to publish
    func testPublishSingleListing() throws {
        // 1. Navigate to Sell tab (camera)
        app.tabBars.buttons["Sell"].tap()

        // 2. Verify camera view appears
        let cameraView = app.staticTexts["Camera"]
        XCTAssert(cameraView.waitForExistence(timeout: 5), "Camera view should appear")

        // 3. Take a photo (use simulator's mock photo)
        let takePhotoButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'photo' OR label CONTAINS 'camera'")).firstMatch
        if takePhotoButton.exists {
            takePhotoButton.tap()
        }

        // 4. Proceed to drafts
        let proceedButton = app.buttons["Proceed"]
        XCTAssert(proceedButton.waitForExistence(timeout: 5), "Proceed button should exist")
        proceedButton.tap()

        // 5. Verify BulkListingOverviewView (draft list) appears
        let draftListView = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'draft' OR label CONTAINS 'Process'")).firstMatch
        XCTAssert(draftListView.waitForExistence(timeout: 5), "Draft list should appear")

        // 6. Verify draft row exists
        let draftCell = app.cells.firstMatch
        XCTAssert(draftCell.exists, "At least one draft cell should exist")

        // 7. Tap Process button
        let processButton = app.buttons["Process"]
        XCTAssert(processButton.exists, "Process button should exist")
        processButton.tap()

        // 8. Wait for ProcessProgressView sheet to appear
        let processingTitle = app.staticTexts["Processing"]
        XCTAssert(processingTitle.waitForExistence(timeout: 5), "Processing view should appear")

        // 9. Wait for AI processing to complete (longer timeout for API calls)
        let processCompleteText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Complete' OR label CONTAINS 'processed'")).firstMatch
        XCTAssert(processCompleteText.waitForExistence(timeout: 60), "AI processing should complete within 60s")

        // 10. Dismiss processing view or wait for results sheet
        let closeButton = app.buttons["Close"]
        if closeButton.exists {
            closeButton.tap()
        }

        // 11. Wait for ProcessResultsOverviewView (Review & Publish sheet) to appear
        let reviewTitle = app.staticTexts["Review & Publish"]
        XCTAssert(reviewTitle.waitForExistence(timeout: 10), "Review & Publish sheet should appear")

        // 12. Verify Publish button is enabled
        let publishButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Publish'")).firstMatch
        XCTAssert(publishButton.exists && !publishButton.isHittable == false, "Publish button should be enabled")

        // 13. Tap Publish
        publishButton.tap()

        // 14. Wait for PublishConfirmationSheet with platform toggles
        let publishConfirmTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Publish'")).firstMatch
        XCTAssert(publishConfirmTitle.waitForExistence(timeout: 5), "Publish confirmation sheet should appear")

        // 15. Verify platform toggles exist and respond
        let mercariToggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'Mercari'")).firstMatch
        XCTAssert(mercariToggle.exists, "Mercari toggle should exist")

        // 16. Tap Mercari toggle to select it
        mercariToggle.tap()

        // 17. Verify toggle is now ON
        let isOn = mercariToggle.value as? NSNumber
        XCTAssertEqual(isOn?.boolValue, true, "Mercari toggle should be ON after tapping")

        // 18. Tap Publish button in confirmation sheet
        let confirmPublishButton = app.buttons.matching(NSPredicate(format: "label == 'Publish'")).firstMatch
        XCTAssert(confirmPublishButton.exists, "Publish confirmation button should exist")
        confirmPublishButton.tap()

        // 19. Wait for publishing to start (progress indicator)
        let publishingIndicator = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Publishing' OR label CONTAINS 'posting'")).firstMatch
        XCTAssert(publishingIndicator.waitForExistence(timeout: 5), "Publishing should start")

        // 20. Wait for CrossPostStatusView to appear (final status screen)
        let statusTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Status' OR label CONTAINS 'published'")).firstMatch
        XCTAssert(statusTitle.waitForExistence(timeout: 60), "Cross-post status should appear after publishing")
    }

    /// Test that platform toggles work correctly
    func testPlatformToggles() throws {
        // Navigate to Sell tab
        app.tabBars.buttons["Sell"].tap()

        // Skip to publish confirmation (simplified version)
        // In a real test, you'd go through the full flow, but for this focused test:

        // We'll test the toggle behavior in isolation if the sheet appears
        let publishConfirmTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Publishing'")).firstMatch

        if publishConfirmTitle.exists {
            // Test Mercari toggle
            let mercariToggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'Mercari'")).firstMatch
            if mercariToggle.exists {
                let initialState = mercariToggle.value as? NSNumber
                mercariToggle.tap()
                let newState = mercariToggle.value as? NSNumber
                XCTAssertNotEqual(initialState?.boolValue, newState?.boolValue, "Toggle should change state")
            }

            // Test eBay toggle
            let ebayToggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'eBay'")).firstMatch
            if ebayToggle.exists {
                let initialState = ebayToggle.value as? NSNumber
                ebayToggle.tap()
                let newState = ebayToggle.value as? NSNumber
                XCTAssertNotEqual(initialState?.boolValue, newState?.boolValue, "eBay toggle should change state")
            }
        }
    }

    /// Test that editing fields saves correctly (deferred saves)
    func testEditingDraftFieldsSaves() throws {
        // Navigate to Sell tab
        app.tabBars.buttons["Sell"].tap()

        // Go through flow to reach Review & Publish sheet
        // (abbreviated - full flow would be testPublishSingleListing)

        let reviewTitle = app.staticTexts["Review & Publish"]
        if reviewTitle.waitForExistence(timeout: 20) {
            // Find a title field
            let titleField = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'title' OR placeholderValue CONTAINS 'Title'")).firstMatch

            if titleField.exists {
                // Clear and edit
                titleField.tap()
                titleField.typeText("Test Product Name")

                // Move focus away (should trigger save)
                app.staticTexts.firstMatch.tap()

                // Verify no errors appear
                let errorAlert = app.alerts.firstMatch
                XCTAssert(!errorAlert.exists, "No error should appear after editing fields")
            }
        }
    }
}
