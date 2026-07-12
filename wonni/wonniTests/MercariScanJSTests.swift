//
//  MercariScanJSTests.swift
//  wonniTests
//
//  Runs the exact production extraction script (MercariScanJS.extractInProgressItems)
//  against fixture HTML in a real WKWebView. These fixtures replicate the page shapes
//  Mercari's in_progress listings page has been observed to use; when Mercari changes
//  markup, capture the new shape as another fixture here before touching the script.
//

import XCTest
import WebKit
@testable import wonni

@MainActor
final class MercariScanJSTests: XCTestCase {
    private var window: UIWindow!
    private var webView: WKWebView!

    override func setUp() async throws {
        // The webview must be in a key window — detached webviews throttle
        // callAsyncJavaScript, which is itself one of the bugs this suite guards against.
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

    private func loadFixture(_ html: String) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.mercari.com/mypage/listings/in_progress/")!)
        // Can't poll readyState alone: the initial about:blank document is already
        // "complete", so the check must also confirm the fixture's baseURL committed.
        for _ in 0..<100 {
            if let probe = try? await webView.callJS("return window.location.href + '|' + document.readyState;") as? String,
               probe.contains("mercari.com"), probe.hasSuffix("complete") { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Fixture never finished loading")
    }

    private func runExtract() async throws -> (items: [[String: Any]], diag: [String: Any]) {
        let raw = try await webView.callJS(MercariScanJS.extractInProgressItems)
        let json = try XCTUnwrap(raw as? String)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        let diag = try XCTUnwrap(root["diag"] as? [String: Any])
        return (items, diag)
    }

    // MARK: - Phase 1: __NEXT_DATA__

    func test_nextData_itemsExtracted() async throws {
        let html = """
        <html><body>
        <script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"items":[
            {"id":"m111","name":"Album A","price":25,"thumbnails":["https://cdn/a.jpg"]},
            {"id":"m222","name":"Album B","price":3500}
        ]}}}
        </script>
        </body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["id"] as? String, "m111")
        XCTAssertEqual(items[0]["name"] as? String, "Album A")
        XCTAssertEqual(items[0]["price"] as? Double, 25)
        XCTAssertEqual(items[0]["thumbnailUrl"] as? String, "https://cdn/a.jpg")
        // >1000 heuristic: 3500 read as cents → $35
        XCTAssertEqual(items[1]["price"] as? Double, 35)
    }

    // MARK: - Phase 2: table rows

    func test_tableRow_nameAndPriceInsideLink() async throws {
        let html = """
        <html><body><table><tbody>
        <tr>
            <td><a href="/transaction/order_status/m333/">
                <img src="https://cdn/c.jpg"><p>Photocard Set</p><p>$12.50</p>
            </a></td>
            <td>07/08/26</td>
        </tr>
        </tbody></table></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["id"] as? String, "m333")
        XCTAssertEqual(items[0]["name"] as? String, "Photocard Set")
        XCTAssertEqual(items[0]["price"] as? Double, 12.5)
        XCTAssertEqual(items[0]["updatedStr"] as? String, "07/08/26")
    }

    /// Mercari's list rows put the title/price in cells NEXT TO the thumbnail anchor,
    /// not inside it — the original scan only searched inside the anchor and returned
    /// name/price = null, and the Swift side then dropped the whole item ("0 sales found").
    func test_tableRow_nameAndPriceOutsideLink_stillExtracted() async throws {
        let html = """
        <html><body><table><tbody>
        <tr>
            <td><a href="/transaction/order_status/m444/"><img src="https://cdn/d.jpg"></a></td>
            <td><p>Seonghyeon CORTIS Green</p></td>
            <td><span>$45.00</span></td>
            <td>07/07/26</td>
        </tr>
        </tbody></table></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["id"] as? String, "m444")
        XCTAssertEqual(items[0]["name"] as? String, "Seonghyeon CORTIS Green")
        XCTAssertEqual(items[0]["price"] as? Double, 45.0)
        XCTAssertEqual(items[0]["updatedStr"] as? String, "07/07/26")
    }

    /// Replicates the real in_progress row shape observed on device (2026-07-12 screenshot):
    /// the first plain text in the row is the transaction STATUS ("Awaiting rating from
    /// buyer"), and the item title lives in the thumbnail's alt attribute. The name finder
    /// must prefer img[alt] and never fall back to a status phrase.
    func test_tableRow_realShape_titleInImgAlt_statusNotUsedAsName() async throws {
        let html = """
        <html><body><table><tbody>
        <tr>
            <td><a href="/transaction/order_status/m11862301506/">
                <img src="https://cdn/t.jpg" alt="Taesan - BOYNEXTDOOR Home Album Sweet Home">
            </a></td>
            <td><p>Awaiting rating from buyer</p></td>
            <td><span>$60.00</span></td>
            <td>07/10/26</td>
        </tr>
        </tbody></table></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(first["id"] as? String, "m11862301506")
        XCTAssertEqual(first["name"] as? String, "Taesan - BOYNEXTDOOR Home Album Sweet Home")
        XCTAssertEqual(first["price"] as? Double, 60.0)
        XCTAssertEqual(first["statusText"] as? String, "Awaiting rating from buyer")
        XCTAssertEqual(first["updatedStr"] as? String, "07/10/26")
    }

    /// Uses the EXACT markup captured from mercari.com's desktop page source (2026-07-12):
    /// title is a <p> whose styled-components class contains "ItemsList__T2WithBreakWord",
    /// status is an element whose class contains "ItemStatusLabel". Row is div-based (no
    /// <tr>), anchor holds only the thumbnail. The sc- hash suffixes change per deploy —
    /// only the display-name fragments are stable.
    func test_divRow_realMercariClasses_titleAndStatusExtracted() async throws {
        let html = """
        <html><body><div id="root"><div class="ItemsList__Row-sc-249e96a8-3 abcDef">
            <a href="/transaction/order_status/m46397154598/">
                <img src="https://cdn/k.jpg">
            </a>
            <div>
                <p color="gray-dark" class="T2-sc-1um8956 ItemsList__T2WithBreakWord-sc-249e96a8-0 kQKWGo ccYYZm">JEONGYEON Twice \u{201C}This Is For\u{201D} World Tour Exclusive JEONGVELY Keychain</p>
                <div class="ItemStatusLabel__Container-sc-8f7274bc-0 hGmVcS"><span>Awaiting rating from buyer</span></div>
                <span>$16.20</span>
            </div>
        </div></div></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(first["id"] as? String, "m46397154598")
        XCTAssertEqual(first["name"] as? String, "JEONGYEON Twice \u{201C}This Is For\u{201D} World Tour Exclusive JEONGVELY Keychain")
        XCTAssertEqual(first["price"] as? Double, 16.2)
        XCTAssertEqual(first["statusText"] as? String, "Awaiting rating from buyer")
    }

    /// Even a status string that ISN'T in the known-phrase regex must be excluded from
    /// name candidates when it's inside an ItemStatusLabel-classed element.
    func test_divRow_unknownStatusPhraseInStatusLabel_notUsedAsName() async throws {
        let html = """
        <html><body><div><div class="ItemsList__Row-sc-1 x">
            <a href="/transaction/order_status/m1010/"><img src="x.jpg"></a>
            <div>
                <div class="ItemStatusLabel__Container-sc-2 y"><span>Some future status wording</span></div>
                <span>$5.00</span>
            </div>
        </div></div></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        let first = try XCTUnwrap(items.first)
        XCTAssertTrue(first["name"] is NSNull)
        XCTAssertEqual(first["statusText"] as? String, "Some future status wording")
    }

    /// No usable title anywhere (no alt, only a status phrase) — name must come back null,
    /// NOT the status string.
    func test_tableRow_onlyStatusText_nameStaysNull() async throws {
        let html = """
        <html><body><table><tbody>
        <tr>
            <td><a href="/transaction/order_status/m999/"><img src="x.jpg"></a></td>
            <td><p>Ship by Jul 15</p></td>
            <td><span>$10.00</span></td>
        </tr>
        </tbody></table></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        let first = try XCTUnwrap(items.first)
        XCTAssertTrue(first["name"] is NSNull)
        XCTAssertEqual(first["statusText"] as? String, "Ship by Jul 15")
        XCTAssertEqual(first["price"] as? Double, 10.0)
    }

    func test_tableRow_priceWithThousandsSeparator() async throws {
        let html = """
        <html><body><table><tbody>
        <tr>
            <td><a href="/us/item/m555/"><img src="x.jpg"></a></td>
            <td><p>Signed Album</p></td>
            <td><span>$1,234.56</span></td>
        </tr>
        </tbody></table></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["price"] as? Double, 1234.56)
    }

    /// An item Mercari renders with no name/price at all must still come back (with
    /// nulls) so enrichment / the fix-and-import UI can handle it — never dropped.
    func test_tableRow_missingNameAndPrice_stillReturnedWithNulls() async throws {
        let html = """
        <html><body><table><tbody>
        <tr>
            <td><a href="/transaction/order_status/m666/"><img src="x.jpg"></a></td>
            <td>07/06/26</td>
        </tr>
        </tbody></table></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["id"] as? String, "m666")
        XCTAssertTrue(items[0]["name"] is NSNull)
        XCTAssertTrue(items[0]["price"] is NSNull)
    }

    // MARK: - Phase 3: bare anchors

    func test_bareAnchors_extractedWithContainerFallback() async throws {
        let html = """
        <html><body><ul>
        <li>
            <a href="https://www.mercari.com/us/item/m777/"><img src="x.jpg"></a>
            <p>Home Album Sweet Home</p><span>$18.00</span>
        </li>
        </ul></body></html>
        """
        try await loadFixture(html)
        let (items, _) = try await runExtract()
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(first["id"] as? String, "m777")
        XCTAssertEqual(first["name"] as? String, "Home Album Sweet Home")
        XCTAssertEqual(first["price"] as? Double, 18.0)
    }

    // MARK: - Diagnostics

    func test_diagnostics_reportPageShape() async throws {
        let html = """
        <html><body>
        <a href="/transaction/order_status/m888/">x</a>
        <a href="/help_center">not an item</a>
        </body></html>
        """
        try await loadFixture(html)
        let (_, diag) = try await runExtract()
        XCTAssertEqual(diag["hasNextData"] as? Bool, false)
        XCTAssertEqual(diag["anchorCount"] as? Int, 2)
        XCTAssertEqual(diag["idAnchorCount"] as? Int, 1)
        XCTAssertEqual((diag["sampleHrefs"] as? [String])?.first, "/transaction/order_status/m888/")
    }

    func test_emptyPage_returnsZeroItemsWithDiagnostics() async throws {
        try await loadFixture("<html><body><div id=\"root\"></div></body></html>")
        let (items, diag) = try await runExtract()
        XCTAssertEqual(items.count, 0)
        XCTAssertEqual(diag["idAnchorCount"] as? Int, 0)
    }
}
