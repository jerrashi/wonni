//
//  MercariFormJSTests.swift
//  wonniTests
//
//  Runs the exact production script (MercariFormJS.disableSmartPricing) against the
//  Smart Pricing markup captured from mercari.com/sell on 2026-10-12, in a real
//  WKWebView. When Mercari changes the markup, capture the new shape as another
//  fixture here before touching the script.
//

import XCTest
import WebKit
@testable import wonni

@MainActor
final class MercariFormJSTests: XCTestCase {
    private var window: UIWindow!
    private var webView: WKWebView!

    override func setUp() async throws {
        // Detached webviews throttle callAsyncJavaScript — keep it in a key window.
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        webView = WKWebView(frame: window.bounds)
        window.rootViewController!.view.addSubview(webView)
    }

    override func tearDown() async throws {
        webView.removeFromSuperview()
        window.isHidden = true
        webView = nil
        window = nil
    }

    // MARK: - Fixture

    /// The real Smart Pricing block (styled-components hashes included, since the script
    /// must not depend on them). `expanded` / `on` set the initial state; `confirmDialog`
    /// makes the first click open a "Turn off Smart Pricing?" dialog, as Mercari does on
    /// some accounts. A small script stands in for React: it flips `aria-pressed` + the
    /// label on click, and toggles the accordion's `aria-expanded`.
    private func fixture(expanded: Bool = true, on: Bool = true, confirmDialog: Bool = false, present: Bool = true) -> String {
        let block = present ? """
        <div class="Flex-sc-3da62de4-0 Space-sc-42894f7-0 Container-sc-cedcd252-0 Accordion__BorderedContainer-sc-85979cd2-4 dqTTWg dOTGOM gtOjBT eQHxuX">
          <button data-testid="SmartPricingAccordion" aria-expanded="\(expanded)" class="Button-sc-3e5b0e03-0 Accordion__ButtonWrapper-sc-85979cd2-2 ldNowU kYWHrS">
            <div class="Flex-sc-3da62de4-0"><div display="flex" width="100%" class="Container-sc-beaovl hwycDA"><div display="flex" class="Container-sc-beaovl fOiDVA">
              <h3 color="gray-dark" class="H3-sc-ctcfao cXBVeo">Smart pricing</h3>
              <p class="T2-sc-1um8956 components__DescText-sc-75d85332-3 eSPIXM hbsGpF">Increase your chances of a sale by gradually lowering your price.</p>
            </div></div></div>
          </button>
          <div id="body" class="Accordion__FadeInDiv-sc-85979cd2-1 ixpzCn" \(expanded ? "" : "hidden")>
            <div class="Flex-sc-3da62de4-0 Space-sc-42894f7-0 Container-sc-cedcd252-0 ijmEFU dOTGOM gtOjBT">
              <div class="Flex-sc-3da62de4-0"><h5 class="H5-sc-dphgz5">Adjusts price automatically&nbsp;</h5>
                <p class="T2-sc-1um8956 iamnBA">It lowers your price over time, boosts search visibility with each price change.</p></div>
              <button data-testid="SmartPricingButton" role="button" aria-pressed="\(on)" class="BaseButton-sc-1y14cqd eUcznm">\(on ? "ON" : "OFF")</button>
            </div>
            <div display="flex" class="Container-sc-beaovl bIZUci"><p color="gray-dark" class="T2-sc-1um8956 jtxPMF">Minimum price</p></div>
            <div width="120px" class="Container-sc-beaovl jazylz"><div class="FieldWrapper-sc-1t72wbn gzvNDO">
              <input inputmode="decimal" placeholder="0.00" data-testid="SmartPricingFloorPrice" id="sellMinPriceForAutoPriceDrop" class="TextInput-sc-14etqcw edtCTM" type="text" value="9.00" name="sellMinPriceForAutoPriceDrop">
            </div></div>
            <p data-testid="SmartPricingRecommendedPrice" class="T3-sc-7hzl3c">Recommended: $9</p>
          </div>
        </div>
        """ : ""
        return """
        <html><body>
        <input data-testid="Price" value="5">
        \(block)
        <div id="dialogHost"></div>
        <script>
        window.__clicks = 0;
        var acc = document.querySelector('[data-testid="SmartPricingAccordion"]');
        if (acc) acc.addEventListener('click', function() {
            var open = acc.getAttribute('aria-expanded') === 'true';
            acc.setAttribute('aria-expanded', open ? 'false' : 'true');
            document.getElementById('body').hidden = open;
        });
        function flip(btn) {
            var on = btn.getAttribute('aria-pressed') === 'true';
            btn.setAttribute('aria-pressed', on ? 'false' : 'true');
            btn.textContent = on ? 'OFF' : 'ON';
        }
        var btn = document.querySelector('[data-testid="SmartPricingButton"]');
        if (btn) btn.addEventListener('click', function() {
            window.__clicks++;
            if (\(confirmDialog) && btn.getAttribute('aria-pressed') === 'true') {
                var d = document.createElement('div');
                d.setAttribute('role', 'dialog');
                d.innerHTML = '<p>Turn off Smart Pricing?</p><button id="cancel">Cancel</button><button id="ok">Turn off</button>';
                document.getElementById('dialogHost').appendChild(d);
                d.querySelector('#ok').addEventListener('click', function() { flip(btn); d.remove(); });
                d.querySelector('#cancel').addEventListener('click', function() { d.remove(); });
                return;
            }
            flip(btn);
        });
        </script>
        </body></html>
        """
    }

    private func loadFixture(_ html: String) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.mercari.com/sell/")!)
        for _ in 0..<300 {
            if let probe = try? await webView.callJS("return window.location.href + '|' + document.readyState;") as? String,
               probe.contains("mercari.com"), probe.hasSuffix("complete") { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Fixture never finished loading")
    }

    private func run() async throws -> String {
        let raw = try await webView.callJS(MercariFormJS.disableSmartPricing)
        return try XCTUnwrap(raw as? String)
    }

    private func toggleState() async throws -> String {
        let raw = try await webView.callJS("""
            var b = document.querySelector('[data-testid="SmartPricingButton"]');
            return b ? (b.getAttribute('aria-pressed') + '|' + b.textContent.trim()) : 'none';
        """)
        return try XCTUnwrap(raw as? String)
    }

    // MARK: - Script

    func test_onToggle_isTurnedOffAndVerified() async throws {
        try await loadFixture(fixture(on: true))
        let result = try await run()
        XCTAssertEqual(result, "disabled")
        let state = try await toggleState()
        XCTAssertEqual(state, "false|OFF")
    }

    func test_offToggle_isLeftAlone() async throws {
        try await loadFixture(fixture(on: false))
        let result = try await run()
        XCTAssertEqual(result, "was-off")
        let state = try await toggleState()
        XCTAssertEqual(state, "false|OFF")
        let clicks = try await webView.callJS("return window.__clicks;") as? Int
        XCTAssertEqual(clicks, 0, "must not click an OFF toggle (that would turn it ON)")
    }

    func test_collapsedAccordion_isExpandedFirst() async throws {
        try await loadFixture(fixture(expanded: false, on: true))
        let result = try await run()
        XCTAssertEqual(result, "disabled")
        let state = try await toggleState()
        XCTAssertEqual(state, "false|OFF")
    }

    func test_confirmDialog_isAccepted() async throws {
        try await loadFixture(fixture(on: true, confirmDialog: true))
        let result = try await run()
        XCTAssertEqual(result, "disabled")
        let state = try await toggleState()
        XCTAssertEqual(state, "false|OFF")
    }

    func test_sectionAbsent_reportsHidden() async throws {
        // Desktop Mercari removes the whole block for prices ≤ $9 — nothing to do.
        try await loadFixture(fixture(present: false))
        let result = try await run()
        XCTAssertEqual(result, "hidden")
    }

    func test_accordionHeaderIsNotMistakenForTheToggle() async throws {
        // The old script matched [data-testid*="SmartPricing"], whose first hit is the
        // accordion header (no pressed state) → it reported "was-off" and never clicked.
        try await loadFixture(fixture(on: true))
        let result = try await run()
        XCTAssertNotEqual(result, "was-off")
        XCTAssertEqual(result, "disabled")
    }

    // MARK: - Policy

    func test_policy_under10_alwaysRequiresOff() {
        XCTAssertTrue(MercariFormJS.mustDisableSmartPricing(price: 5, keepSmartPricing: true))
        XCTAssertTrue(MercariFormJS.mustDisableSmartPricing(price: 9.99, keepSmartPricing: true))
        XCTAssertTrue(MercariFormJS.mustDisableSmartPricing(price: 5, keepSmartPricing: false))
    }

    func test_policy_10AndUp_followsPreference() {
        XCTAssertFalse(MercariFormJS.mustDisableSmartPricing(price: 10, keepSmartPricing: true))
        XCTAssertTrue(MercariFormJS.mustDisableSmartPricing(price: 10, keepSmartPricing: false))
        XCTAssertFalse(MercariFormJS.mustDisableSmartPricing(price: 250, keepSmartPricing: true))
    }

    func test_resultClassification() {
        for ok in ["hidden", "was-off", "disabled"] { XCTAssertTrue(MercariFormJS.smartPricingIsOff(ok), ok) }
        for bad in ["still-on", "no-toggle", "error"] { XCTAssertFalse(MercariFormJS.smartPricingIsOff(bad), bad) }
    }
}
