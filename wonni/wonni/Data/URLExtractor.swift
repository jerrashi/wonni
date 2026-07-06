//
//  URLExtractor.swift
//  wonni
//

import Foundation
import WebKit
import Combine

struct ExtractedListing {
    var title: String
    var price: Double
    var description: String
    var imageUrls: [String]
    var condition: String = ""
}

struct ListingPreview: Identifiable, Hashable {
    var id: String { url }
    var title: String
    var price: Double
    var thumbnailUrl: String
    var url: String
}

enum ExtractorError: Error, LocalizedError {
    case invalidURL
    case unsupportedPlatform
    case extractionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The provided URL is invalid."
        case .unsupportedPlatform: return "This URL is not supported yet."
        case .extractionFailed(let msg): return "Failed to extract details: \(msg)"
        }
    }
}

@MainActor
class URLExtractor: NSObject, ObservableObject {
    @Published var isExtracting = false
    @Published var currentStatus = ""
    @Published var extractedListing: ExtractedListing?
    @Published var extractionError: Error?
    
    /// Embed this in the view hierarchy for reliable JS execution
    let webView: WKWebView
    private let navDelegate = ExtractorNavDelegate()
    
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.processPool = mercariProcessPool
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
        super.init()
        wv.navigationDelegate = navDelegate
    }
    
    func extract(from urlString: String) async throws -> ExtractedListing {
        guard let url = URL(string: urlString) else {
            throw ExtractorError.invalidURL
        }
        
        let host = url.host?.lowercased() ?? ""
        if host.contains("mercari.com") {
            return try await extractMercari(url: url)
        } else {
            throw ExtractorError.unsupportedPlatform
        }
    }
    
    func extractProfileListings(from urlString: String) async throws -> [ListingPreview] {
        guard let url = URL(string: urlString) else {
            throw ExtractorError.invalidURL
        }
        
        let host = url.host?.lowercased() ?? ""
        if host.contains("mercari.com") {
            return try await extractMercariProfile(url: url)
        } else {
            throw ExtractorError.unsupportedPlatform
        }
    }
    
    // MARK: - Single Mercari Listing
    
    private func extractMercari(url: URL) async throws -> ExtractedListing {
        isExtracting = true
        currentStatus = "Loading Mercari..."
        extractedListing = nil
        extractionError = nil
        
        navDelegate.reset()
        webView.load(URLRequest(url: url))
        
        print("[URLExtractor] Loading \(url.absoluteString)")
        let loaded = await navDelegate.waitForLoad(timeout: 15)
        if !loaded { print("[URLExtractor] Page load timed out") }
        
        currentStatus = "Extracting details..."
        
        // Wait for React/Next.js hydration
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        
        let script = """
        (function() {
            try {
                let title = document.querySelector('[data-testid="ItemName"]')?.innerText || "";
                let priceText = document.querySelector('[data-testid="ItemPrice"]')?.innerText || "";
                let desc = document.querySelector('[data-testid="ItemDescription"]')?.innerText || "";
                
                // Try og:title meta tag as fallback for title
                if (!title) {
                    let ogTitle = document.querySelector('meta[property="og:title"]');
                    if (ogTitle) title = ogTitle.getAttribute('content') || "";
                }
                
                let imgElements = document.querySelectorAll('[data-testid="ItemImage"] img');
                let urls = [];
                for (let img of imgElements) {
                    if (img.src) urls.push(img.src);
                }

                if (urls.length === 0) {
                    let fallbacks = document.querySelectorAll('.image-carousel img, [data-testid="Carousel"] img');
                    for (let img of fallbacks) {
                        if (img.src) urls.push(img.src);
                    }
                }

                // Broader fallback for sold items — Mercari uses different containers on sold pages
                if (urls.length === 0) {
                    let altImgs = document.querySelectorAll('[data-testid*="Item"] img, [data-testid*="Photo"] img, [data-testid*="image"] img');
                    for (let img of altImgs) {
                        if (img.src && !img.src.includes('avatar') && !img.src.includes('profile')) {
                            urls.push(img.src);
                        }
                    }
                }

                // Fallback: any Mercari CDN image on the page
                if (urls.length === 0) {
                    let allImgs = document.querySelectorAll('img');
                    for (let img of allImgs) {
                        if (img.src && (img.src.includes('mercdn.net') || img.src.includes('mercari-images'))) {
                            urls.push(img.src);
                        }
                    }
                }

                // Fallback: og:image
                if (urls.length === 0) {
                    let ogImg = document.querySelector('meta[property="og:image"]');
                    if (ogImg && ogImg.getAttribute('content')) {
                        urls.push(ogImg.getAttribute('content'));
                    }
                }
                
                return {
                    title: title,
                    priceText: priceText,
                    description: desc,
                    imageUrls: urls,
                    debug: 'url: ' + window.location.href + '; title: ' + document.title
                };
            } catch (e) {
                return { error: e.toString() };
            }
        })();
        """
        
        // Poll with retries
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            do {
                let result = try await webView.evaluateJavaScript(script)
                if let dict = result as? [String: Any] {
                    if let errStr = dict["error"] as? String {
                        print("[URLExtractor] JS error: \(errStr)")
                        throw ExtractorError.extractionFailed(errStr)
                    }
                    
                    let title = dict["title"] as? String ?? ""
                    let priceText = dict["priceText"] as? String ?? ""
                    let description = dict["description"] as? String ?? ""
                    let imageUrls = dict["imageUrls"] as? [String] ?? []
                    let debug = dict["debug"] as? String ?? ""
                    
                    print("[URLExtractor] Result: title=\(title), images=\(imageUrls.count), debug=\(debug)")
                    
                    if !title.isEmpty || !imageUrls.isEmpty {
                        let digits = priceText.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
                        let price = Double(digits) ?? 0.0
                        let uniqueUrls = Array(NSOrderedSet(array: imageUrls)) as! [String]
                        
                        let listing = ExtractedListing(
                            title: title,
                            price: price,
                            description: description,
                            imageUrls: uniqueUrls
                        )
                        
                        isExtracting = false
                        extractedListing = listing
                        return listing
                    }
                }
            } catch let error as ExtractorError {
                isExtracting = false
                throw error
            } catch {
                print("[URLExtractor] JS eval error: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        
        isExtracting = false
        throw ExtractorError.extractionFailed("Could not find item details on the page.")
    }
    
    // MARK: - Mercari Profile
    
    private func extractMercariProfile(url: URL) async throws -> [ListingPreview] {
        isExtracting = true
        currentStatus = "Loading Mercari Profile..."
        extractionError = nil
        
        navDelegate.reset()
        webView.load(URLRequest(url: url))
        
        print("[URLExtractor] Loading profile \(url.absoluteString)")
        let loaded = await navDelegate.waitForLoad(timeout: 15)
        if !loaded { print("[URLExtractor] Profile page load timed out") }
        
        currentStatus = "Scanning listings..."
        
        // Wait for React/Next.js hydration
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        
        let script = """
        return await new Promise((resolve) => {
            try {
                let forSaleBtn = Array.from(document.querySelectorAll('a, button, div')).find(el => 
                    el.innerText && el.innerText.trim().toLowerCase() === 'for sale' && el.offsetHeight > 0
                );
                
                if (forSaleBtn) {
                    forSaleBtn.click();
                }

                setTimeout(() => {
                    let lastHeight = 0;
                    let attempts = 0;
                    let scrollLimit = 50; // max scrolls to prevent infinite loop
                    let scrolls = 0;
                    
                    let scrollInterval = setInterval(() => {
                        window.scrollTo(0, document.body.scrollHeight);
                        let newHeight = document.body.scrollHeight;
                        scrolls++;
                        
                        if (newHeight === lastHeight || scrolls > scrollLimit) {
                            attempts++;
                            if (attempts >= 6 || scrolls > scrollLimit) { 
                                clearInterval(scrollInterval);
                                extractItems();
                            }
                        } else {
                            lastHeight = newHeight;
                            attempts = 0;
                        }
                    }, 500);

                    function extractItems() {
                        let items = [];
                        let links = document.querySelectorAll('a[href*="/item/m"]');
                        for (let link of links) {
                            let isSold = false;
                            let textNodes = [...link.querySelectorAll('*')].map(n => n.innerText);
                            for (let text of textNodes) {
                                if (text && text.trim().toUpperCase() === 'SOLD') {
                                    isSold = true;
                                    break;
                                }
                            }
                            if (isSold) continue;
                            
                            let url = link.href;
                            
                            let imgs = link.querySelectorAll('img');
                            let itemImg = null;
                            for (let i of imgs) {
                                if (i.src && !i.src.includes('avatar') && !i.src.includes('profile')) {
                                    itemImg = i;
                                    break;
                                }
                            }
                            if (!itemImg && imgs.length > 0) itemImg = imgs[0];
                            let thumbnailUrl = itemImg ? itemImg.src : "";
                            
                            let text = link.innerText || "";
                            let priceMatch = text.match(/\\$\\s*([0-9,.]+)/);
                            let priceText = priceMatch ? priceMatch[0] : "$0";
                            
                            let title = "";
                            let nameNode = link.querySelector('[data-testid="ItemName"]');
                            if (nameNode && nameNode.innerText) {
                                title = nameNode.innerText.trim();
                            }
                            
                            if (!title) {
                                let lines = text.split('\\n')
                                    .map(s => s.trim())
                                    .filter(s => s.length > 0 
                                              && !s.startsWith('$') 
                                              && !s.match(/^[0-9,.]+$/) 
                                              && s.toLowerCase() !== "free shipping"
                                              && s.toLowerCase() !== "sold"
                                              && !s.toLowerCase().includes(" % off")
                                    );
                                let longestLine = "";
                                for (let line of lines) {
                                    if (line.length > longestLine.length) {
                                        longestLine = line;
                                    }
                                }
                                if (longestLine) {
                                    title = longestLine;
                                }
                            }
                            
                            if (!title && itemImg && itemImg.alt) {
                                title = itemImg.alt;
                            }
                            
                            if (!title) {
                                title = "Mercari Item";
                            }
                            
                            if (url && thumbnailUrl) {
                                items.push({
                                    url: url,
                                    thumbnailUrl: thumbnailUrl,
                                    title: title,
                                    priceText: priceText
                                });
                            }
                        }
                        
                        let uniqueItems = [];
                        let urls = new Set();
                        for (let item of items) {
                            if (!urls.has(item.url)) {
                                urls.add(item.url);
                                uniqueItems.push(item);
                            }
                        }
                        
                        resolve({ items: uniqueItems, debug: 'found ' + uniqueItems.length + ' items, url: ' + window.location.href });
                    }
                }, 1500);
            } catch (e) {
                resolve({ error: e.toString() });
            }
        });
        """
        
        // Poll with retries. Since scrolling might take up to 25 seconds, we give it a 45 second deadline
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            do {
                // Using callAsyncJavaScript which awaits the Promise implicitly
                let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page)
                if let dict = result as? [String: Any] {
                    if let errStr = dict["error"] as? String {
                        print("[URLExtractor] Profile JS error: \(errStr)")
                        throw ExtractorError.extractionFailed(errStr)
                    }
                    
                    let debug = dict["debug"] as? String ?? ""
                    print("[URLExtractor] Profile: \(debug)")
                    
                    if let itemsArray = dict["items"] as? [[String: Any]], !itemsArray.isEmpty {
                        let previews = itemsArray.compactMap { item -> ListingPreview? in
                            guard let url = item["url"] as? String,
                                  let thumbnailUrl = item["thumbnailUrl"] as? String,
                                  let title = item["title"] as? String,
                                  let priceText = item["priceText"] as? String else {
                                return nil
                            }
                            
                            let digits = priceText.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
                            let price = Double(digits) ?? 0.0
                            
                            return ListingPreview(title: title, price: price, thumbnailUrl: thumbnailUrl, url: url)
                        }
                        
                        isExtracting = false
                        return previews
                    }
                }
            } catch let error as ExtractorError {
                isExtracting = false
                throw error
            } catch {
                print("[URLExtractor] Profile JS eval error: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        
        isExtracting = false
        throw ExtractorError.extractionFailed("Could not find any listings on this profile page.")
    }
}

// MARK: - Navigation Delegate

private class ExtractorNavDelegate: NSObject, WKNavigationDelegate {
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
                if let c = self.continuation {
                    self.continuation = nil
                    c.resume(returning: false)
                }
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[URLExtractor] Page loaded: \(webView.url?.absoluteString ?? "?")")
        didFinish = true
        if let c = continuation {
            continuation = nil
            c.resume(returning: true)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[URLExtractor] Page failed: \(error.localizedDescription)")
        didFinish = true
        if let c = continuation {
            continuation = nil
            c.resume(returning: false)
        }
    }
}
