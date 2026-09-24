//
//  WeverseShippingProbe.swift
//  wonni
//

import Foundation
import WebKit

enum WeverseProbeErrorCode: String {
    case outOfStock = "OUT_OF_STOCK"
    case missingAddress = "MISSING_ADDRESS"
    case unknown = "UNKNOWN"
}

struct WeverseProbeError: Error, LocalizedError {
    let message: String
    let code: WeverseProbeErrorCode

    var errorDescription: String? { message }
}

// Best-effort probe of a Weverse sale's checkout shipping fee, ported from
// extension/weverse_content.js's probeShippingCost — see that file's own
// caveat comment: shop.weverse.io's cart/order-sheet API is undocumented,
// inferred by pattern-matching a confirmed endpoint, and unverified against
// the live site from this sandboxed environment. Runs as JS fetch() calls
// inside a hidden WKWebView so it rides the same cookies as a real,
// logged-in Weverse session (WeverseAddressSheet shares the same
// WKWebsiteDataStore.default() for that reason) — no "place order"/payment
// step is ever touched, matching the extension's documented boundary.
@MainActor
final class WeverseShippingProbe {
    private let webView: WKWebView
    private let navDelegate = ProbeNavDelegate()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let hiddenWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        hiddenWebView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        hiddenWebView.navigationDelegate = navDelegate
        self.webView = hiddenWebView
    }

    func probeShippingCost(saleUrl: String, saleId: String) async throws -> Double {
        // Load the sale page first so the fetch() calls below run in
        // shop.weverse.io's own origin — required for its cookies to attach.
        if let url = URL(string: saleUrl) {
            navDelegate.reset()
            webView.load(URLRequest(url: url))
            _ = await navDelegate.waitForLoad(timeout: 15)
        }

        let script = """
        (async function() {
            const CART_BASE = "https://shop.weverse.io/api/wvs/internal/cart/api/v1/cart";
            const ORDER_SHEET_PREVIEW_ENDPOINT = "https://shop.weverse.io/api/wvs/internal/order/api/v1/order/sheet";

            function classifyProbeError(message) {
                const haystack = (message ?? "").toLowerCase();
                if (/sold ?out|out of stock|no stock|inventory/.test(haystack)) return "OUT_OF_STOCK";
                if (/address|shipping information|delivery info/.test(haystack)) return "MISSING_ADDRESS";
                return "UNKNOWN";
            }

            async function addToCartForProbe(saleId) {
                const response = await fetch(CART_BASE + "/items", {
                    method: "POST",
                    credentials: "include",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ saleId: saleId, quantity: 1 }),
                });
                if (!response.ok) {
                    const bodyText = await response.text().catch(() => "");
                    const err = new Error("Add-to-cart failed (" + response.status + ").");
                    err.errorCode = classifyProbeError(bodyText + " " + response.status);
                    throw err;
                }
                const json = await response.json();
                const cartItemId = json?.cartItemId ?? json?.id ?? json?.data?.cartItemId ?? json?.data?.id;
                if (cartItemId == null) {
                    const err = new Error("Add-to-cart response had no cart item id.");
                    err.errorCode = "UNKNOWN";
                    throw err;
                }
                return cartItemId;
            }

            async function removeFromCartForProbe(cartItemId) {
                try {
                    await fetch(CART_BASE + "/items/" + cartItemId, { method: "DELETE", credentials: "include" });
                } catch (e) {
                    // Best-effort cleanup.
                }
            }

            async function previewOrderSheetFee(cartItemId) {
                const response = await fetch(ORDER_SHEET_PREVIEW_ENDPOINT, {
                    method: "POST",
                    credentials: "include",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ cartItemIds: [cartItemId] }),
                });
                if (!response.ok) {
                    const bodyText = await response.text().catch(() => "");
                    const err = new Error("Order-sheet preview failed (" + response.status + ").");
                    err.errorCode = classifyProbeError(bodyText + " " + response.status);
                    throw err;
                }
                const sheet = await response.json();
                const hasAddress = sheet?.hasDeliveryAddress ?? sheet?.data?.hasDeliveryAddress
                    ?? (sheet?.deliveryAddress !== undefined ? sheet.deliveryAddress != null : undefined)
                    ?? (sheet?.data?.deliveryAddress !== undefined ? sheet.data.deliveryAddress != null : undefined);
                if (hasAddress === false) {
                    const err = new Error("No shipping address saved on this Weverse account.");
                    err.errorCode = "MISSING_ADDRESS";
                    throw err;
                }

                const groups = sheet?.orderGroups ?? sheet?.data?.orderGroups ?? [sheet?.data ?? sheet];
                for (const group of groups) {
                    const fee = group?.deliveryFee ?? group?.shippingFee ?? group?.deliveryPrice
                        ?? group?.delivery?.fee ?? group?.shipping?.fee;
                    if (typeof fee === "number") return fee;
                }
                const err = new Error("Order-sheet response had no recognizable delivery fee field.");
                err.errorCode = "UNKNOWN";
                throw err;
            }

            let cartItemId;
            try {
                cartItemId = await addToCartForProbe("\(saleId)");
            } catch (err) {
                return { shippingCost: null, error: err.message, errorCode: err.errorCode ?? "UNKNOWN" };
            }

            try {
                const shippingCost = await previewOrderSheetFee(cartItemId);
                return { shippingCost: shippingCost };
            } catch (err) {
                return { shippingCost: null, error: err.message, errorCode: err.errorCode ?? "UNKNOWN" };
            } finally {
                await removeFromCartForProbe(cartItemId);
            }
        })();
        """

        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page)
        guard let dict = result as? [String: Any] else {
            throw WeverseProbeError(message: "Unexpected probe response.", code: .unknown)
        }
        if let shippingCost = dict["shippingCost"] as? Double {
            return shippingCost
        }
        if let shippingCostNum = dict["shippingCost"] as? NSNumber {
            return shippingCostNum.doubleValue
        }
        let message = dict["error"] as? String ?? "Shipping probe failed."
        let codeStr = dict["errorCode"] as? String ?? "UNKNOWN"
        throw WeverseProbeError(message: message, code: WeverseProbeErrorCode(rawValue: codeStr) ?? .unknown)
    }
}

private class ProbeNavDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var didFinish = false

    func reset() {
        didFinish = false
        continuation = nil
    }

    func waitForLoad(timeout: TimeInterval) async -> Bool {
        if didFinish { return true }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self.continuation {
                    self.continuation = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        if let pending = continuation {
            continuation = nil
            pending.resume(returning: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        didFinish = true
        if let pending = continuation {
            continuation = nil
            pending.resume(returning: false)
        }
    }
}
