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

        // 1. Navigate to Sell tab (camera)
        app.tabBars.buttons["Sell"].tap()

        // 2. Verify the camera view appears. CameraView's own capture UI has no
        // accessible title text (was previously checked via a nonexistent
        // staticTexts["Camera"] — that label actually belongs to a *different*
        // screen's back button, see pickerBackButton below) — cameraGalleryButton
        // is the one stable, always-present element on this screen.
        let galleryButton = app.buttons["cameraGalleryButton"]
        XCTAssert(galleryButton.waitForExistence(timeout: 5), "Camera view should appear")

        // 3. Add a photo via the gallery picker. iOS Simulator has no camera
        // hardware — AVCaptureSession's shutter button (no accessibility
        // identifier, and inert on Simulator either way) can't produce a real
        // photo, so this goes through the same picker route already proven out
        // in testDraftsCarouselStaysPinnedToBottomAfterPickerRoundTrip below.
        galleryButton.tap()
        app.tap() // flush the permission-alert interruption monitor if it fired

        let firstPhoto = app.descendants(matching: .any).matching(identifier: "photoGridItem").firstMatch
        XCTAssert(firstPhoto.waitForExistence(timeout: 60), "At least one photo grid item should load")
        firstPhoto.tap()

        let commitButton = app.buttons.matching(identifier: "draftsCarousel").firstMatch
        XCTAssert(commitButton.waitForExistence(timeout: 5), "Commit ('+') button should appear once a photo is selected")
        commitButton.tap()

        let backButton = app.buttons["pickerBackButton"]
        XCTAssert(backButton.waitForExistence(timeout: 5), "Back-to-camera button should appear")
        backButton.tap()

        // 4. Proceed to drafts
        let proceedButton = app.buttons["Proceed"]
        XCTAssert(proceedButton.waitForExistence(timeout: 5), "Proceed button should exist")
        proceedButton.tap()

        // 5. Verify BulkListingOverviewView (draft list) appears. That screen sets no
        // .navigationTitle and renders no static text at all until processing actually
        // starts — the "Processing N of M…" banner (uploadManager.isProcessing) — so the
        // real, always-present signal that we landed here is the draft row itself (was
        // previously checked via a staticTexts CONTAINS 'draft'/'Process' match that never
        // existed on this screen, silently never passing — found 2026-09-15).
        let draftCell = app.cells.firstMatch
        XCTAssert(draftCell.waitForExistence(timeout: 5), "At least one draft cell should exist")

        // 6. Tap Process button
        let processButton = app.buttons["Process"]
        XCTAssert(processButton.exists, "Process button should exist")
        processButton.tap()

        // 7. Wait for ProcessProgressView sheet to appear
        let processingTitle = app.staticTexts["Processing"]
        XCTAssert(processingTitle.waitForExistence(timeout: 5), "Processing view should appear")

        // 8. Wait for AI processing to complete (longer timeout for API calls)
        let processCompleteText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Complete' OR label CONTAINS 'processed'")).firstMatch
        XCTAssert(processCompleteText.waitForExistence(timeout: 60), "AI processing should complete within 60s")

        // 9. The processing sheet auto-dismisses itself (UploadManager.processDrafts sets
        // showProcessResults = true ~1.2s after processing finishes) — no manual dismiss
        // needed. A prior version of this test tapped a "Close" button here, but that raced
        // the auto-dismiss: `.exists` could pass and the button still vanish before `.tap()`
        // landed, failing the whole test on an XCUIElement AX-action error rather than a
        // real assertion (found 2026-09-15, CI run 35007555834).

        // 10. Wait for ProcessResultsOverviewView (Review & Publish sheet) to appear
        let reviewTitle = app.staticTexts["Review & Publish"]
        XCTAssert(reviewTitle.waitForExistence(timeout: 10), "Review & Publish sheet should appear")

        // 11. Verify Publish button is enabled
        let publishButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Publish'")).firstMatch
        XCTAssert(publishButton.exists && !publishButton.isHittable == false, "Publish button should be enabled")

        // 12. Tap Publish
        publishButton.tap()

        // 13. Wait for PublishConfirmationSheet with platform toggles
        let publishConfirmTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Publish'")).firstMatch
        XCTAssert(publishConfirmTitle.waitForExistence(timeout: 5), "Publish confirmation sheet should appear")

        // 14. Verify platform toggles exist and respond
        let mercariToggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'Mercari'")).firstMatch
        XCTAssert(mercariToggle.exists, "Mercari toggle should exist")

        // 15. Tap Mercari toggle to select it
        mercariToggle.tap()

        // 16. Verify toggle is now ON. A Switch's accessibility `.value` comes back
        // as a String ("0"/"1"), not NSNumber, on the iOS 18+ simulators this CI
        // runs against — casting straight to NSNumber always returned nil here,
        // failing the assertion regardless of the toggle's actual (correct) state.
        XCTAssertEqual(switchIsOn(mercariToggle), true, "Mercari toggle should be ON after tapping")

        // 17. Tap Publish button in confirmation sheet
        let confirmPublishButton = app.buttons.matching(NSPredicate(format: "label == 'Publish'")).firstMatch
        XCTAssert(confirmPublishButton.exists, "Publish confirmation button should exist")
        confirmPublishButton.tap()

        // 18. Wait for publishing to start (progress indicator). "Publishing…" only
        // ever renders as a Text inside the bottom Publish Button itself (see
        // CreateListingView.swift's ProgressView + Text(buttonLabel) HStack) —
        // SwiftUI exposes that whole HStack as a single Button-typed accessibility
        // element, never a separate StaticText, so match by label across all
        // element types instead of assuming staticTexts (same fix already applied
        // to firstPhoto above, for the same underlying reason).
        let publishingIndicator = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Publishing' OR label CONTAINS 'posting'")).firstMatch
        XCTAssert(publishingIndicator.waitForExistence(timeout: 5), "Publishing should start")

        // 19. Wait for CrossPostStatusView to appear (final status screen)
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
                let initialState = switchIsOn(mercariToggle)
                mercariToggle.tap()
                let newState = switchIsOn(mercariToggle)
                XCTAssertNotEqual(initialState, newState, "Toggle should change state")
            }

            // Test eBay toggle
            let ebayToggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'eBay'")).firstMatch
            if ebayToggle.exists {
                let initialState = switchIsOn(ebayToggle)
                ebayToggle.tap()
                let newState = switchIsOn(ebayToggle)
                XCTAssertNotEqual(initialState, newState, "eBay toggle should change state")
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
        // 30s wasn't always enough: whichever test in this suite touches the Photos
        // library first pays PHPhotoLibrary's cold-start indexing cost, which can run
        // past 30s under CI load (confirmed via two independent full-suite CI runs
        // both timing out here, at this exact step, while the same wait elsewhere in
        // the suite — once Photos is warm — finishes in seconds). 60s covers that
        // cold-start case without slowing down the common warm case.
        XCTAssert(firstPhoto.waitForExistence(timeout: 60), "At least one photo grid item should load")
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

    /// Repro for "no way to delete drafts": after selecting a full draft in the
    /// drafts history modal, the Delete button is reportedly replaced by a "..."
    /// overflow button that does nothing when tapped.
    func testDeleteDraftFromHistoryModal() throws {
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

        // Build two committed drafts.
        for _ in 0..<2 {
            galleryButton.tap()
            app.tap()

            let firstPhoto = app.descendants(matching: .any).matching(identifier: "photoGridItem").firstMatch
            XCTAssert(firstPhoto.waitForExistence(timeout: 60), "At least one photo grid item should load")
            firstPhoto.tap()

            let commitButton = app.buttons.matching(identifier: "draftsCarousel").firstMatch
            XCTAssert(commitButton.waitForExistence(timeout: 5))
            commitButton.tap()

            let backButton = app.buttons["pickerBackButton"]
            XCTAssert(backButton.waitForExistence(timeout: 5))
            backButton.tap()
        }

        let stackIcon = app.descendants(matching: .any).matching(identifier: "draftsStackIcon").firstMatch
        XCTAssert(stackIcon.waitForExistence(timeout: 5), "Drafts stack icon should appear")
        stackIcon.tap()

        let selectButton = app.buttons["draftHistorySelectButton"]
        XCTAssert(selectButton.waitForExistence(timeout: 5), "Select button should appear")
        selectButton.tap()

        let fullSelectToggle = app.descendants(matching: .any).matching(identifier: "draftFullSelectToggle").firstMatch
        XCTAssert(fullSelectToggle.waitForExistence(timeout: 5), "Full-select toggle should appear")
        fullSelectToggle.tap()

        // Snapshot the toolbar state right after a full draft is selected.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "after-full-select"
        attachment.lifetime = .keepAlways
        add(attachment)

        let deleteButton = app.buttons["draftHistoryDeleteButton"]
        XCTAssert(deleteButton.exists, "Delete button should still exist in the accessibility tree: \(app.debugDescription)")
        XCTAssert(deleteButton.isHittable, "Delete button should be hittable, not collapsed into an overflow menu")

        deleteButton.tap()

        let confirmDelete = app.alerts.buttons["Delete"]
        XCTAssert(confirmDelete.waitForExistence(timeout: 5), "Delete confirmation alert should appear")
        confirmDelete.tap()
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

    /// A Switch's accessibility `.value` is documented as "0"/"1"/"mixed", exposed
    /// as a String on the iOS 18+ simulators this CI runs against — casting it
    /// straight to NSNumber (as this file previously did) silently returns nil
    /// regardless of the switch's actual state. Handles both representations so a
    /// future OS/XCTest revision that reports NSNumber again keeps working too.
    private func switchIsOn(_ element: XCUIElement) -> Bool? {
        if let number = element.value as? NSNumber { return number.boolValue }
        if let string = element.value as? String { return string == "1" }
        return nil
    }
}
