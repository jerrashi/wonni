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

class URLExtractor: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isExtracting = false
    @Published var currentStatus = ""
    @Published var extractedListing: ExtractedListing?
    @Published var extractionError: Error?
    
    private var webView: WKWebView?
    private var completionPromise: ((Result<ExtractedListing, Error>) -> Void)?
    
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
    
    private var profileCompletionPromise: ((Result<[ListingPreview], Error>) -> Void)?
    
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
    
    private func extractMercari(url: URL) async throws -> ExtractedListing {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.isExtracting = true
                self.currentStatus = "Loading Mercari..."
                self.extractedListing = nil
                self.extractionError = nil
                
                self.completionPromise = { result in
                    self.isExtracting = false
                    switch result {
                    case .success(let listing):
                        self.extractedListing = listing
                        continuation.resume(returning: listing)
                    case .failure(let err):
                        self.extractionError = err
                        continuation.resume(throwing: err)
                    }
                }
                
                let config = WKWebViewConfiguration()
                // Mercari needs default site data
                config.websiteDataStore = .default()
                self.webView = WKWebView(frame: .zero, configuration: config)
                self.webView?.navigationDelegate = self
                self.webView?.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                
                let request = URLRequest(url: url)
                self.webView?.load(request)
            }
        }
    }
    
    private func extractMercariProfile(url: URL) async throws -> [ListingPreview] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.isExtracting = true
                self.currentStatus = "Loading Mercari Profile..."
                self.extractionError = nil
                
                self.profileCompletionPromise = { result in
                    self.isExtracting = false
                    switch result {
                    case .success(let listings):
                        continuation.resume(returning: listings)
                    case .failure(let err):
                        self.extractionError = err
                        continuation.resume(throwing: err)
                    }
                }
                
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                self.webView = WKWebView(frame: .zero, configuration: config)
                self.webView?.navigationDelegate = self
                self.webView?.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                
                let request = URLRequest(url: url)
                self.webView?.load(request)
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.currentStatus = "Extracting details..."
        }
        
        // Wait a short moment for dynamic elements to load
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.profileCompletionPromise != nil {
                self.runMercariProfileScript(webView: webView)
            } else {
                self.runMercariScript(webView: webView)
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completionPromise?(.failure(error))
        profileCompletionPromise?(.failure(error))
    }
    
    private func runMercariScript(webView: WKWebView) {
        // Mercari uses specific data-testid attributes we can target
        let script = """
        (function() {
            try {
                let title = document.querySelector('[data-testid="ItemName"]')?.innerText || "";
                let priceText = document.querySelector('[data-testid="ItemPrice"]')?.innerText || "";
                let desc = document.querySelector('[data-testid="ItemDescription"]')?.innerText || "";
                
                // Get all thumbnail images and convert them to the full res ones
                // Mercari thumbnails usually have "thumb" or something, but product images have data-testid="ItemImage"
                let imgElements = document.querySelectorAll('[data-testid="ItemImage"] img');
                let urls = [];
                for (let img of imgElements) {
                    if (img.src) {
                        urls.push(img.src);
                    }
                }
                
                // If ItemImage not found, try generic carousel images
                if (urls.length === 0) {
                    let fallbacks = document.querySelectorAll('.image-carousel img, [data-testid="Carousel"] img');
                    for (let img of fallbacks) {
                        if (img.src) urls.push(img.src);
                    }
                }
                
                return {
                    title: title,
                    priceText: priceText,
                    description: desc,
                    imageUrls: urls
                };
            } catch (e) {
                return { error: e.toString() };
            }
        })();
        """
        
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                self.completionPromise?(.failure(ExtractorError.extractionFailed(error.localizedDescription)))
                return
            }
            
            guard let dict = result as? [String: Any],
                  let title = dict["title"] as? String,
                  let priceText = dict["priceText"] as? String,
                  let description = dict["description"] as? String,
                  let imageUrls = dict["imageUrls"] as? [String] else {
                
                if let dict = result as? [String: Any], let errStr = dict["error"] as? String {
                    self.completionPromise?(.failure(ExtractorError.extractionFailed(errStr)))
                } else {
                    self.completionPromise?(.failure(ExtractorError.extractionFailed("Invalid response from JS")))
                }
                return
            }
            
            if title.isEmpty && imageUrls.isEmpty {
                // We might need to wait longer
                self.completionPromise?(.failure(ExtractorError.extractionFailed("Could not find item details on the page.")))
                return
            }
            
            // Parse price (e.g. "$12.00")
            let digits = priceText.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
            let price = Double(digits) ?? 0.0
            
            // Clean up URLs
            let uniqueUrls = Array(NSOrderedSet(array: imageUrls)) as! [String]
            
            let listing = ExtractedListing(
                title: title,
                price: price,
                description: description,
                imageUrls: uniqueUrls
            )
            
            self.completionPromise?(.success(listing))
        }
    }
    
    private func runMercariProfileScript(webView: WKWebView) {
        let script = """
        (function() {
            try {
                let items = [];
                // Look for links to item pages
                let links = document.querySelectorAll('a[href*="/item/m"]');
                for (let link of links) {
                    let url = link.href;
                    
                    let imgs = link.querySelectorAll('img');
                    let itemImg = null;
                    for (let i of imgs) {
                        // Prefer images that aren't obviously avatars or UI icons
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
                
                // Deduplicate by URL
                let uniqueItems = [];
                let urls = new Set();
                for (let item of items) {
                    if (!urls.has(item.url)) {
                        urls.add(item.url);
                        uniqueItems.push(item);
                    }
                }
                
                return uniqueItems;
            } catch (e) {
                return { error: e.toString() };
            }
        })();
        """
        
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                self.profileCompletionPromise?(.failure(ExtractorError.extractionFailed(error.localizedDescription)))
                return
            }
            
            if let dict = result as? [String: Any], let errStr = dict["error"] as? String {
                self.profileCompletionPromise?(.failure(ExtractorError.extractionFailed(errStr)))
                return
            }
            
            guard let itemsArray = result as? [[String: Any]] else {
                self.profileCompletionPromise?(.failure(ExtractorError.extractionFailed("Invalid response format from JS.")))
                return
            }
            
            let previews = itemsArray.compactMap { dict -> ListingPreview? in
                guard let url = dict["url"] as? String,
                      let thumbnailUrl = dict["thumbnailUrl"] as? String,
                      let title = dict["title"] as? String,
                      let priceText = dict["priceText"] as? String else {
                    return nil
                }
                
                let digits = priceText.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
                let price = Double(digits) ?? 0.0
                
                return ListingPreview(title: title, price: price, thumbnailUrl: thumbnailUrl, url: url)
            }
            
            self.profileCompletionPromise?(.success(previews))
        }
    }
}
