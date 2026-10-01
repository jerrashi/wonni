//
//  LayoutRegressionTests.swift
//  wonniTests
//
//  Fast (sub-second) guards against views silently growing to fill whatever space
//  they're offered — the class of bug behind #143, where the draft carousel ballooned
//  to half the picker after an HStack→LazyHStack swap. The simulator UI tests catch
//  this too, but they take ~15 min and were opt-in; these run with every unit test.
//
//  Pattern: host the view in a UIHostingController, offer it a full phone-sized
//  canvas, and assert the size it *asks for*. A view that hugs its content reports
//  its natural size; a greedy one reports the whole canvas.
//

import XCTest
import SwiftUI
import SwiftData
@testable import wonni

@MainActor
final class LayoutRegressionTests: XCTestCase {
    /// iPhone-class canvas. Any view that reports close to the full height is greedy.
    private static let canvas = CGSize(width: 390, height: 844)

    /// Hosts `view` in an on-screen window (so @Query / @Environment resolve) and
    /// returns the size it requests when offered the full canvas.
    private func fittingSize<V: View>(of view: V) -> CGSize {
        let host = UIHostingController(rootView: view)
        // Measure the view alone — otherwise the window's safe-area insets (54pt on
        // current iPhones) are folded into the reported height.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.canvas))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        // Let SwiftUI run one pass so @Query has delivered its results.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return host.sizeThatFits(in: Self.canvas)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    // MARK: - Draft carousel (#143)

    func testDraftCarouselHugsOneRowWithActiveDraft() throws {
        let container = try makeContainer()
        let draft = Item(sourceAssetIdentifiers: ["a", "b", "c"])
        container.mainContext.insert(draft)
        try container.mainContext.save()

        let manager = UploadManager.shared
        let previousActive = manager.activeDraftID
        manager.activeDraftID = draft.id
        defer { manager.activeDraftID = previousActive }

        let view = ActiveDraftCarouselView(cache: CachedImageManager(), onOpenDraftHistory: {})
            .environmentObject(manager)
            .modelContainer(container)

        let size = fittingSize(of: view)
        XCTAssertGreaterThan(size.height, 0, "Carousel should render when the active draft has photos")
        XCTAssertLessThan(size.height, 120,
                          "Draft carousel is greedy on height (\(size.height)pt of \(Self.canvas.height)pt offered) — see the rowHeight frame in ActiveDraftCarouselView")
    }

    func testDraftCarouselHugsOneRowWithCommittedDraftsOnly() throws {
        let container = try makeContainer()
        for index in 0..<3 {
            container.mainContext.insert(Item(sourceAssetIdentifiers: ["committed-\(index)"]))
        }
        try container.mainContext.save()

        let manager = UploadManager.shared
        let previousActive = manager.activeDraftID
        manager.activeDraftID = nil
        defer { manager.activeDraftID = previousActive }

        let view = ActiveDraftCarouselView(cache: CachedImageManager(), onOpenDraftHistory: {})
            .environmentObject(manager)
            .modelContainer(container)

        let size = fittingSize(of: view)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(size.height, 120,
                          "Draft carousel is greedy on height (\(size.height)pt) with only committed drafts")
    }
}
