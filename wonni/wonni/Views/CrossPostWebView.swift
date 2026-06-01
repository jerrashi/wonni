//
//  CrossPostWebView.swift
//  wonni
//

import SwiftUI
import WebKit

public struct CrossPostWebView: UIViewRepresentable {
    public let url: URL
    public let webView: WKWebView
    
    public init(url: URL, webView: WKWebView) {
        self.url = url
        self.webView = webView
    }
    
    public func makeUIView(context: Context) -> WKWebView {
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }
    
    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

public struct CrossPostContainerView: View {
    let platformName: String
    let listingTitle: String
    let listingDescription: String
    let listingPrice: Double
    @Environment(\.dismiss) private var dismiss
    
    @State private var webView = WKWebView()
    @State private var isLoading = true
    @State private var showClipboardNotification = false
    @State private var notificationText = ""
    
    var targetURL: URL {
        if platformName.lowercased() == "mercari" {
            return URL(string: "https://www.mercari.com/sell/")!
        } else {
            return URL(string: "https://www.facebook.com/marketplace/create/item")!
        }
    }
    
    public init(platformName: String, listingTitle: String, listingDescription: String, listingPrice: Double) {
        self.platformName = platformName
        self.listingTitle = listingTitle
        self.listingDescription = listingDescription
        self.listingPrice = listingPrice
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    // Quick Reference Header Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Draft Reference (Tap to copy)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 12) {
                            // Title Reference
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Title")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(listingTitle)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .onTapGesture {
                                UIPasteboard.general.string = listingTitle
                                triggerNotification("Copied Title!")
                            }
                            
                            Divider().frame(height: 24)
                            
                            // Price Reference
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Price")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "$%.2f", listingPrice))
                                    .font(.subheadline.weight(.semibold))
                            }
                            .onTapGesture {
                                UIPasteboard.general.string = String(format: "%.2f", listingPrice)
                                triggerNotification("Copied Price!")
                            }
                            
                            Divider().frame(height: 24)
                            
                            // Description Reference
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Description")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(listingDescription)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .onTapGesture {
                                UIPasteboard.general.string = listingDescription
                                triggerNotification("Copied Description!")
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundStyle(Color(.separator)),
                        alignment: .bottom
                    )
                    
                    CrossPostWebView(url: targetURL, webView: webView)
                }
                
                // Floating Action Trigger
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            executeAutofill()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars")
                                Text("Autofill Fields")
                                    .font(.headline)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            .background(Color.purple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .shadow(radius: 6)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                    }
                }
                
                // Copy Alert HUD
                if showClipboardNotification {
                    VStack {
                        Text(notificationText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(Color.black.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(.top, 20)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("Cross-post to \(platformName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        webView.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
    
    private func triggerNotification(_ text: String) {
        notificationText = text
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            showClipboardNotification = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showClipboardNotification = false
            }
        }
    }
    
    private func executeAutofill() {
        // Escaping JavaScript strings properly
        let escapedTitle = listingTitle.replacingOccurrences(of: "'", with: "\\'")
        let escapedDesc = listingDescription.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
        let priceStr = String(format: "%.2f", listingPrice)
        
        let jsScript = """
        (function() {
            var title = '\(escapedTitle)';
            var description = '\(escapedDesc)';
            var price = '\(priceStr)';
            
            // --- Autofill Title ---
            var titleSelectors = [
                'input[name="title"]',
                'input[placeholder*="title" i]',
                'input[placeholder*="selling" i]',
                'input[id*="title" i]',
                'label[aria-label="Title"] input'
            ];
            for (var i = 0; i < titleSelectors.length; i++) {
                var el = document.querySelector(titleSelectors[i]);
                if (el) {
                    el.value = title;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    break;
                }
            }
            
            // --- Autofill Description ---
            var descSelectors = [
                'textarea[name="description"]',
                'textarea[placeholder*="description" i]',
                'textarea[placeholder*="describe" i]',
                'textarea[id*="description" i]',
                'label[aria-label="Description"] textarea'
            ];
            for (var i = 0; i < descSelectors.length; i++) {
                var el = document.querySelector(descSelectors[i]);
                if (el) {
                    el.value = description;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    break;
                }
            }
            
            // --- Autofill Price ---
            var priceSelectors = [
                'input[name="price"]',
                'input[placeholder*="price" i]',
                'input[placeholder*="0.00" i]',
                'input[placeholder*="0" i]',
                'input[id*="price" i]',
                'label[aria-label="Price"] input'
            ];
            for (var i = 0; i < priceSelectors.length; i++) {
                var el = document.querySelector(priceSelectors[i]);
                if (el) {
                    el.value = price;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    break;
                }
            }
            
            return "Autofill completed!";
        })()
        """
        
        webView.evaluateJavaScript(jsScript) { result, error in
            if let error = error {
                print("[CrossPostWebView] JavaScript Injection Error: \(error.localizedDescription)")
                triggerNotification("Autofill failed - try manual copy")
            } else {
                print("[CrossPostWebView] JavaScript Injection Result: \(String(describing: result))")
                triggerNotification("Fields Autofilled!")
            }
        }
    }
}
