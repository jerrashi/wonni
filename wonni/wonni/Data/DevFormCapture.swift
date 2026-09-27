//
//  DevFormCapture.swift
//  wonni
//
//  DEBUG-only tool: dumps the live DOM of a cross-post WebView (Facebook Marketplace,
//  Mercari, …) to Firestore so it can be read remotely (via the Firebase MCP tools)
//  without needing physical access to the device or a Mac + Web Inspector. This is the
//  "crawler" input path: the human drives the WebView to a screen (category picked,
//  condition page, etc.), taps Capture, types one line of context, and the dump lands
//  in Firestore for later processing into the fbFieldSets/fbOptionSets tables (see
//  github issue #66 design comment 2026-09-26).
//
//  #if DEBUG so this never ships in a release/TestFlight build — no UI for it exists
//  outside a local Xcode build.
//
#if DEBUG
import SwiftUI
import WebKit
import FirebaseAuth
import FirebaseFirestore

enum DevFormCapture {
    /// Serializes `document.querySelector('#screen-root') ?? document.body` (scripts/styles
    /// stripped, capped at ~700KB to stay under Firestore's 1MiB document limit) plus the
    /// current URL/title, and writes it to `devCaptures/{uid}/captures/{autoId}`.
    static func capture(webView: WKWebView, platform: String, label: String) async -> Result<Void, Error> {
        guard let uid = Auth.auth().currentUser?.uid else {
            return .failure(NSError(domain: "DevFormCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
        }
        let js = """
        (function() {
            try {
                var root = document.querySelector('#screen-root') || document.body;
                var clone = root.cloneNode(true);
                clone.querySelectorAll('script,style,noscript').forEach(function(n) { n.remove(); });
                var html = clone.outerHTML;
                if (html.length > 700000) html = html.slice(0, 700000) + '...TRUNCATED';
                return JSON.stringify({ html: html, url: window.location.href, title: document.title });
            } catch (e) {
                return JSON.stringify({ error: e.message });
            }
        })()
        """
        do {
            let raw = try await webView.callJS(js) as? String ?? "{}"
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(NSError(domain: "DevFormCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad JS result"]))
            }
            if let err = parsed["error"] as? String {
                return .failure(NSError(domain: "DevFormCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: err]))
            }
            try await Firestore.firestore()
                .collection("devCaptures").document(uid).collection("captures")
                .addDocument(data: [
                    "platform": platform,
                    "label": label,
                    "url": parsed["url"] as? String ?? "",
                    "pageTitle": parsed["title"] as? String ?? "",
                    "html": parsed["html"] as? String ?? "",
                    "capturedAt": Timestamp(date: Date()),
                ])
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// Small toolbar affordance: a "Capture" button that prompts for a one-line label
/// (e.g. "furniture — after selecting condition"), then calls `DevFormCapture.capture`.
struct DevFormCaptureButton: View {
    let webView: WKWebView
    let platform: String
    @State private var showPrompt = false
    @State private var label = ""
    @State private var status: String?

    var body: some View {
        Button {
            showPrompt = true
        } label: {
            Image(systemName: "ladybug")
        }
        .alert("Capture this screen", isPresented: $showPrompt) {
            TextField("What's on screen? (e.g. furniture condition page)", text: $label)
            Button("Capture") {
                let l = label
                label = ""
                Task {
                    let result = await DevFormCapture.capture(webView: webView, platform: platform, label: l)
                    switch result {
                    case .success: status = "Captured ✓"
                    case .failure(let e): status = "Capture failed: \(e.localizedDescription)"
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .top) {
            if let status {
                Text(status)
                    .font(.caption2)
                    .padding(4)
                    .background(.thinMaterial)
                    .offset(y: 28)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.status = nil }
                    }
            }
        }
    }
}
#endif
