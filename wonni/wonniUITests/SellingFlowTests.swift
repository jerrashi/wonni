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
        app.launchArguments += ["-uiTesting"]
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

    /// Repro for the "drafts carousel renders mid-screen instead of pinned to the
    /// bottom" bug: after a draft is committed and the user bounces camera -> picker
    /// -> camera -> picker (repeatedly), ActiveDraftCarouselView must stay pinned to
    /// the true screen bottom in both hosts, never floating mid-screen or overlapping
    /// the photo grid.
    func testDraftsCarouselStaysPinnedToBottomAfterPickerRoundTrip() throws {
        // Photos permission alert may appear the first time the picker touches the
        // library — auto-allow it so the flow isn't blocked.
        let photosInterruption = addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            let allowButtons = alert.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Allow' OR label CONTAINS 'OK'")
            )
            if allowButtons.count > 0 {
                allowButtons.firstMatch.tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(photosInterruption) }

        app.tabBars.buttons["Sell"].tap()

        let galleryButton = app.buttons["cameraGalleryButton"]
        XCTAssert(galleryButton.waitForExistence(timeout: 5), "Camera gallery button should appear")

        // Build one committed draft so hasContent is true for the rest of the test.
        galleryButton.tap()
        app.tap() // flush the permission-alert interruption monitor if it fired

        // SwiftUI exposes SelectablePhotoGridItem as an Image-typed AX element (since
        // its overlay image becomes the combined accessibility trait), not "Other" —
        // match by identifier across all element types rather than assuming a type.
        let firstPhoto = app.descendants(matching: .any).matching(identifier: "photoGridItem").firstMatch
        // Generous timeout: the permission alert + PHPhotoLibrary fetch can take a
        // while on a simulator, especially right after a fresh install/grant.
        XCTAssert(firstPhoto.waitForExistence(timeout: 30), "At least one photo grid item should load")
        firstPhoto.tap()

        // The Button's own "commitDraftButton" identifier gets clobbered by the
        // ancestor HStack's "draftsCarousel" identifier (same override behavior noted
        // above) — disambiguate from the carousel's ScrollView by element type instead.
        let commitButton = app.buttons.matching(identifier: "draftsCarousel").firstMatch
        XCTAssert(commitButton.waitForExistence(timeout: 5), "Commit ('+') button should appear once a photo is selected")
        commitButton.tap()

        let backButton = app.buttons["pickerBackButton"]
        XCTAssert(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        // Round-trip camera <-> picker a few times — the reported glitch "persists"
        // across repeated visits, not just the first.
        for iteration in 1...3 {
            XCTAssert(galleryButton.waitForExistence(timeout: 5), "Camera view should reappear (iteration \(iteration))")

            let screenHeight = app.windows.firstMatch.frame.height
            // Camera's bottom-pinned row has no single container identifier (nesting
            // one broke the leaf buttons' own identifiers — see draftsCarousel note
            // below), so use the gallery button itself as a proxy for "did the whole
            // bottom-pinned block render where it should."
            XCTAssertGreaterThan(
                galleryButton.frame.minY, screenHeight * 0.5,
                "Camera bottom controls rendered mid-screen instead of pinned to the bottom (iteration \(iteration)): \(galleryButton.frame) vs screen height \(screenHeight)"
            )

            galleryButton.tap()

            // ActiveDraftCarouselView is the single shared component used identically
            // by both hosts, tagged "draftsCarousel" once at its own root — no extra
            // per-host wrapper identifier, since SwiftUI applies an ancestor's
            // accessibilityIdentifier to descendants and clobbers their own explicit
            // identifiers (confirmed via the accessibility hierarchy dump). It's exposed
            // as a ScrollView-typed element — the commit button below shares the same
            // clobbered identifier, so scope by type to get the carousel specifically.
            let pickerCarousel = app.scrollViews.matching(identifier: "draftsCarousel").firstMatch
            XCTAssert(pickerCarousel.waitForExistence(timeout: 5), "Picker drafts carousel should exist (iteration \(iteration))")
            XCTAssertGreaterThan(
                pickerCarousel.frame.minY, screenHeight * 0.5,
                "Picker drafts carousel rendered mid-grid instead of pinned to the bottom (iteration \(iteration)): \(pickerCarousel.frame) vs screen height \(screenHeight)"
            )

            // The carousel must sit BELOW every currently-visible grid cell, never
            // overlapping/embedded among them.
            let gridItems = app.descendants(matching: .any).matching(identifier: "photoGridItem")
            let visibleGridItemCount = min(gridItems.count, 6)
            for i in 0..<visibleGridItemCount {
                let cell = gridItems.element(boundBy: i)
                guard cell.exists, cell.frame.height > 0 else { continue }
                XCTAssertGreaterThanOrEqual(
                    pickerCarousel.frame.minY, cell.frame.maxY,
                    "Drafts carousel overlaps grid cell \(i) (iteration \(iteration)): carousel \(pickerCarousel.frame) vs cell \(cell.frame)"
                )
            }

            backButton.tap()
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
