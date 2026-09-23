//
//  WeverseAddressSheet.swift
//  wonni
//

import SwiftUI
import WebKit

// Shown from the "missing Weverse shipping address" pause in the shop
// import pipeline (see BulkImportSheet's runShippingEstimatePipeline) so the
// user can log in / add an address without leaving the app. Uses
// WKWebsiteDataStore.default() — the same persistent store
// WeverseShippingProbe's hidden WKWebView uses — so a session established
// here is visible to the probe's fetch() calls afterward.
struct WeverseAddressSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        return wv
    }()

    var body: some View {
        NavigationStack {
            MercariSheetWebView(webView: webView)
                .navigationTitle("Weverse Shipping Address")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear {
                    guard webView.url == nil,
                          let url = URL(string: "https://shop.weverse.io/en/my/delivery-address") else { return }
                    webView.load(URLRequest(url: url))
                }
        }
    }
}
