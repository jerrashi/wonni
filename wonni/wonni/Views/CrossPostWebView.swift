//
//  CrossPostWebView.swift
//  wonni
//

import SwiftUI
import WebKit
import FirebaseFirestore
import FirebaseStorage
import Photos

// MARK: - Supporting Cross-Posting Types

struct CrossPostJob: Identifiable {
    var id = UUID()
    let platform: String
    let title: String
    let description: String
    let price: Double
    /// Firestore listing document ID — used to write crossPostStatus back after success.
    let listingId: String?
    /// Camera/picker flow: SwiftData item kept alive (deletion deferred) so photos are read
    /// directly from on-device storage when cross-posting runs — no copying, no re-downloading.
    let item: Item?
    /// Profile flow: existing published listings whose photos live only on Firebase Storage.
    let photoFirebasePaths: [String]

    init(
        platform: String,
        title: String,
        description: String,
        price: Double,
        listingId: String? = nil,
        item: Item? = nil,
        photoFirebasePaths: [String] = []
    ) {
        self.platform = platform
        self.title = title
        self.description = description
        self.price = price
        self.listingId = listingId
        self.item = item
        self.photoFirebasePaths = photoFirebasePaths
    }
}

// MARK: - Mercari Shipping Preferences

/// A shipping carrier the seller can restrict to. `matchToken` is matched as a substring
/// against Mercari's `data-carrier` attribute (e.g. "shippo_usps" contains "usps").
enum Carrier: String, Codable, CaseIterable, Identifiable {
    case usps, ups, fedex
    var id: String { rawValue }
    var matchToken: String { rawValue }
    var displayName: String {
        switch self {
        case .usps:  return "USPS"
        case .ups:   return "UPS"
        case .fedex: return "FedEx"
        }
    }
}

/// The overall shipping strategy. `shipOnOwn` skips the prepaid-label flow entirely;
/// the two prepaid modes drive carrier selection from Mercari's live rate list.
enum ShippingMode: String, Codable, CaseIterable, Identifiable {
    case shipOnOwn           // user provides their own label (SOYO radio)
    case cheapestPrepaid     // cheapest prepaid label across all carriers
    case cheapestAmongCarriers // cheapest prepaid label among `selectedCarriers`
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shipOnOwn:           return "Ship on my own"
        case .cheapestPrepaid:     return "Cheapest prepaid label"
        case .cheapestAmongCarriers: return "Cheapest among my carriers"
        }
    }
}

/// The seller's saved shipping choices, surfaced to the automation each run.
struct ShippingPreferences {
    /// Accept Mercari's suggested weight + label when offered (the "Use label" shortcut and
    /// any weight Mercari prefills). When false, we always enter our own weight and pick a
    /// carrier from the full list per `mode`.
    var acceptSuggestions: Bool = true
    var mode: ShippingMode = .cheapestPrepaid
    /// Considered only when `mode == .cheapestAmongCarriers`.
    var selectedCarriers: Set<Carrier> = [.usps]
}

/// One shipping label parsed out of Mercari's live carrier list. `value` is the radio
/// input's value attribute — what we tell the page to click once a choice is made.
struct MercariShippingOption: Decodable {
    let value: String
    let carrier: String   // e.g. "shippo_usps", "ups", "fedex"
    let name: String      // e.g. "USPS Ground Advantage"
    let priceCents: Int   // discounted price, in cents, for stable integer comparison
}

/// Mercari's shoebox threshold (inches). Items larger than this on any axis need dimensions.
enum MercariShipping {
    static let shoeboxLengthIn = 14.0
    static let shoeboxWidthIn = 10.0
    static let shoeboxHeightIn = 5.0

    /// True when the item exceeds the shoebox on any axis (so Mercari requires dimensions).
    static func isOversized(length: Double?, width: Double?, height: Double?) -> Bool {
        let l = length ?? 0, w = width ?? 0, h = height ?? 0
        return l > shoeboxLengthIn || w > shoeboxWidthIn || h > shoeboxHeightIn
    }
}

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Draft Reference (Tap to copy)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
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
        let escapedTitle = listingTitle.replacingOccurrences(of: "'", with: "\\'")
        let escapedDesc = listingDescription.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
        let priceStr = String(format: "%.2f", listingPrice)

        let jsScript = """
        (function() {
            var title = '\(escapedTitle)';
            var description = '\(escapedDesc)';
            var price = '\(priceStr)';
            var titleSelectors = ['input[name="title"]','input[placeholder*="title" i]','input[placeholder*="selling" i]','input[id*="title" i]'];
            for (var i = 0; i < titleSelectors.length; i++) {
                var el = document.querySelector(titleSelectors[i]);
                if (el) { el.value = title; el.dispatchEvent(new Event('input', { bubbles: true })); break; }
            }
            var descSelectors = ['textarea[name="description"]','textarea[placeholder*="description" i]','textarea[placeholder*="describe" i]'];
            for (var i = 0; i < descSelectors.length; i++) {
                var el = document.querySelector(descSelectors[i]);
                if (el) { el.value = description; el.dispatchEvent(new Event('input', { bubbles: true })); break; }
            }
            var priceSelectors = ['input[name="price"]','input[placeholder*="price" i]','input[id*="price" i]'];
            for (var i = 0; i < priceSelectors.length; i++) {
                var el = document.querySelector(priceSelectors[i]);
                if (el) { el.value = price; el.dispatchEvent(new Event('input', { bubbles: true })); break; }
            }
            return "Autofill completed!";
        })()
        """

        webView.evaluateJavaScript(jsScript) { result, error in
            if let error = error {
                print("[CrossPostWebView] Autofill error: \(error.localizedDescription)")
                triggerNotification("Autofill failed - try manual copy")
            } else {
                triggerNotification("Fields Autofilled!")
            }
        }
    }
}

// MARK: - WKWebView JS helper

@MainActor
private extension WKWebView {
    /// Wraps callAsyncJavaScript — passing a real closure forces the correct overload
    /// so JS actually executes (the ambiguous void overload silently drops execution).
    func callJS(_ body: String, args: [String: Any] = [:], world: WKContentWorld? = nil) async throws -> Any? {
        let contentWorld = world ?? .page
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            callAsyncJavaScript(body, arguments: args, in: nil, in: contentWorld) { result in
                switch result {
                case .success(let value): cont.resume(returning: value)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - MercariPostingState

/// Per-session state for one Mercari cross-post. Created fresh each time the sheet opens —
/// each instance owns its own WKWebView so there are no singleton/shared-state races.
@MainActor
class MercariPostingState: NSObject, ObservableObject, WKNavigationDelegate {
    enum Status: Equatable {
        case loading, injecting, waitingForCategory, loginRequired, success
        case failed(String)
        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.injecting, .injecting),
                 (.waitingForCategory, .waitingForCategory),
                 (.loginRequired, .loginRequired), (.success, .success): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var status: Status = .loading
    /// Non-fatal advisory surfaced to the user (e.g. oversized item with no prepaid dimensions step).
    @Published var warning: String?
    /// True once the List button is enabled (all required fields are filled).
    @Published var isListingComplete: Bool = false
    /// Mercari item ID extracted from the post-success URL (e.g. "m1234567890").
    @Published var mercariItemId: String?

    let webView: WKWebView
    private var hasDetectedSuccess = false

    override init() {
        let config = WKWebViewConfiguration()
        // Shares cookies with MercariLoginView (both use WKWebsiteDataStore.default())
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        // Load immediately — page loads while photos are being fetched concurrently
        webView.load(URLRequest(url: URL(string: "https://www.mercari.com/sell/")!))
    }

    func reloadSellPage() {
        hasDetectedSuccess = false
        status = .loading
        webView.load(URLRequest(url: URL(string: "https://www.mercari.com/sell/")!))
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.hasDetectedSuccess else { return }
            let url = webView.url?.absoluteString ?? ""
            // Navigated away from /sell/ = user submitted the listing
            if url.contains("mercari.com") && !url.contains("mercari.com/sell/") && !url.isEmpty {
                self.hasDetectedSuccess = true
                // Extract Mercari item ID from URLs like /item/m1234567890/
                if let range = url.range(of: #"/item/(m[A-Za-z0-9]+)"#, options: .regularExpression) {
                    let segment = String(url[range])
                    self.mercariItemId = segment.components(separatedBy: "/").filter { !$0.isEmpty }.last
                }
                self.status = .success
            }
        }
    }

    // MARK: Field Injection

    func injectFields(
        title: String,
        description: String,
        price: Double,
        photoBase64Strings: [String],
        condition: String,
        suggestedCategory: String?,
        suggestedBrand: String?,
        weightLbs: Double?,
        lengthIn: Double?,
        widthIn: Double?,
        heightIn: Double?,
        preferences: ShippingPreferences
    ) async {
        status = .injecting

        // Wait for the webview to finish its initial navigation before running any JS.
        // callJS returns nil while the webview is mid-navigation, which would silently skip
        // all field injection and leave the form empty.
        var navAttempts = 0
        while webView.isLoading && navAttempts < 30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            navAttempts += 1
        }
        print("[MercariPostingState] Nav wait done (isLoading=\(webView.isLoading), attempts=\(navAttempts))")

        // Poll for React form mount (up to 10 s in 500 ms steps)
        let pollScript = """
        return new Promise(function(resolve) {
            var attempts = 0;
            (function check() {
                if (document.querySelector('input[data-testid="Title"]')) { resolve('ready'); }
                else if (++attempts >= 20) { resolve('timeout'); }
                else { setTimeout(check, 500); }
            })();
        });
        """
        let formResult = (try? await webView.callJS(pollScript)) as? String ?? "unknown"
        print("[MercariPostingState] Form poll: \(formResult)")

        let currentURL = webView.url?.absoluteString ?? ""
        if currentURL.contains("login") || currentURL.contains("signin") {
            status = .loginRequired
            return
        }

        let jsScript = """
            function setReactInput(el, value) {
                if (!el) return false;
                var lastValue = el.value;
                var proto = el.tagName === 'TEXTAREA'
                    ? window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement.prototype;
                var nativeSetter = Object.getOwnPropertyDescriptor(proto, 'value');
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, value); }
                else { el.value = value; }
                var tracker = el._valueTracker;
                if (tracker) { tracker.setValue(lastValue); }
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            }

            var titleEl = document.querySelector('input[data-testid="Title"]');
            setReactInput(titleEl, title);
            if (titleEl) { titleEl.focus(); titleEl.blur(); }

            var descEl = document.querySelector('textarea[data-testid="Description"]');
            setReactInput(descEl, description);
            if (descEl) { descEl.focus(); descEl.blur(); }

            var priceEl = document.querySelector('input[data-testid="Price"]');
            setReactInput(priceEl, price);
            if (priceEl) { priceEl.focus(); priceEl.blur(); }

            var conditionMap = {
                'new':            'ConditionNew',
                'newwithouttags': 'ConditionLikeNew',
                'likenew':        'ConditionLikeNew',
                'good':           'ConditionGood',
                'fair':           'ConditionFair',
                'poor':           'ConditionPoor',
                'forparts':       'ConditionPoor'
            };
            var conditionKey = condition.toLowerCase().replace(/[\\s_\\-]/g, '');
            var conditionTestId = conditionMap[conditionKey] || 'ConditionGood';
            var conditionLabel = document.querySelector('[data-testid="' + conditionTestId + '"]');
            if (conditionLabel) { conditionLabel.click(); }

            // Shipping — try several selectors since the id may vary
            var mercariRadio = document.querySelector('input#MERCARI[type="radio"]')
                || document.querySelector('input[value="MERCARI"][type="radio"]')
                || document.querySelector('input[data-testid="MERCARI"]');
            if (!mercariRadio) {
                var radios = document.querySelectorAll('input[type="radio"]');
                for (var ri = 0; ri < radios.length; ri++) {
                    var lbl = document.querySelector('label[for="' + radios[ri].id + '"]')
                        || radios[ri].closest('label')
                        || radios[ri].parentElement;
                    if (lbl && lbl.textContent.includes('Mercari') && !lbl.textContent.toLowerCase().includes('not a mercari')) {
                        mercariRadio = radios[ri];
                        break;
                    }
                }
            }
            var shippingStatus = 'not-found';
            if (mercariRadio && !mercariRadio.checked) {
                mercariRadio.click();
                mercariRadio.dispatchEvent(new Event('change', { bubbles: true }));
                shippingStatus = 'clicked';
            } else if (mercariRadio && mercariRadio.checked) {
                shippingStatus = 'already-checked';
            }

            var fileInput = document.querySelector('input[data-testid="SellPhotoInput"]');
            var photoStatus = fileInput ? 'found-no-photos' : 'no-file-input';
            if (fileInput && base64Photos.length > 0) {
                try {
                    var b64toBlob = function(b64Data) {
                        var byteCharacters = atob(b64Data);
                        var byteArrays = [];
                        for (var offset = 0; offset < byteCharacters.length; offset += 512) {
                            var slice = byteCharacters.slice(offset, offset + 512);
                            var byteNumbers = new Array(slice.length);
                            for (var i = 0; i < slice.length; i++) { byteNumbers[i] = slice.charCodeAt(i); }
                            byteArrays.push(new Uint8Array(byteNumbers));
                        }
                        return new Blob(byteArrays, {type: 'image/jpeg'});
                    };
                    var dt = new DataTransfer();
                    for (var pi = 0; pi < base64Photos.length; pi++) {
                        dt.items.add(new File([b64toBlob(base64Photos[pi])], 'photo_' + pi + '.jpg', {type: 'image/jpeg'}));
                    }
                    fileInput.files = dt.files;
                    fileInput.dispatchEvent(new Event('change', { bubbles: true }));
                    fileInput.dispatchEvent(new Event('input', { bubbles: true }));
                    photoStatus = 'attached-' + base64Photos.length;
                } catch(e) { photoStatus = 'error:' + e.message; }
            }

            return 'OK'
                + ' | title:' + (titleEl ? (titleEl.value.length > 0 ? 'filled' : 'empty') : 'not-found')
                + ' | desc:' + (descEl ? (descEl.value.length > 0 ? 'filled' : 'empty') : 'not-found')
                + ' | price:' + (priceEl ? (priceEl.value.length > 0 ? 'filled' : 'empty') : 'not-found')
                + ' | condition:' + conditionTestId
                + ' | shipping:' + shippingStatus
                + ' | photos:' + photoStatus;
        """

        let args: [String: Any] = [
            "title": title,
            "description": description,
            "price": String(format: "%.0f", price),
            "base64Photos": photoBase64Strings,
            "condition": condition
        ]

        let result = (try? await webView.callJS(jsScript, args: args)) as? String
        print("[MercariPostingState] Injection: \(String(describing: result))")

        guard result?.starts(with: "OK") == true else {
            status = .failed(result ?? "Injection failed — page may not be loaded")
            return
        }

        // 2. Category — the hard gate. The shipping carrier field stays disabled
        //    ("Add title and category to enable shipping") until a category is set.
        //    Tier 1: Mercari's suggested categories. Tier 2: fuzzy-match the AI category
        //    against the live dropdowns. Tier 3: fall back to "Other".
        let categoryResult = await selectCategory(suggestedCategory: suggestedCategory)
        print("[MercariPostingState] Category: \(categoryResult)")

        // 3. Smart Pricing auto-enables when the price field receives React events;
        //    turn it back off so it doesn't override the listed price.
        let smartResult = await disableSmartPricing()
        print("[MercariPostingState] SmartPricing: \(smartResult)")

        // 4. Brand — tiered: suggested chips → AI search → no brand.
        let brandResult = await selectBrand(suggestedBrand: suggestedBrand)
        print("[MercariPostingState] Brand: \(brandResult)")
        // Record the selected brand for future cross-post suggestions (fire-and-forget).
        if brandResult.hasPrefix("tier1:") || brandResult.hasPrefix("tier2:") {
            let selectedBrand = String(brandResult.dropFirst(6))
            MercariObservedDataRepository.shared.observeAndStore(brands: [selectedBrand])
        }

        // 5. Shipping — walk the multi-step carrier modal. Each step is polled, not timed,
        //    because the carrier list is fetched live from Mercari after a weight is entered.
        let shippingResult = await completeShipping(
            weightLbs: weightLbs, lengthIn: lengthIn, widthIn: widthIn, heightIn: heightIn,
            preferences: preferences
        )
        print("[MercariPostingState] Shipping: \(shippingResult)")

        // 5. Submit. Mercari disables its List button until the whole form validates, and
        //    submitListing() polls for that enabled state before clicking — so a missing category,
        //    carrier, title, or address can't produce a broken submission (the click waits, then
        //    reports 'list-btn:disabled'). We still hard-hold on async failures the button won't
        //    catch — a photo-upload error or a visible form error — leaving those for the user to
        //    finish by hand in the webview.
        let issues = await outstandingIssues()
        let blocking = issues.filter { $0 == "photo-upload-error" || $0.hasPrefix("error:") }
        if blocking.isEmpty {
            let submitResult = await submitListing()
            print("[MercariPostingState] Submit: \(submitResult)")
        } else {
            print("[MercariPostingState] Holding submit — blocking issues: \(blocking) (all: \(issues))")
        }

        // Poll once to set isListingComplete so the banner accurately reflects form state.
        // (The List button becomes enabled only after Mercari validates all required fields.)
        isListingComplete = await checkListingButtonEnabled()

        // The .success state is set by the navigation delegate when the page leaves /sell/.
        // If we're still here, leave a "review & list" resting state rather than a hard failure —
        // the form is filled as far as we could take it, so the user finishes in the webview.
        if status == .injecting { status = .waitingForCategory }
    }

    /// Pre-submit gate: returns human-readable issues that would make a submit fail. Empty = clean.
    /// Mercari renders validation errors lazily (only after a submit attempt / blur), so this
    /// checks field state positively rather than relying solely on visible error text.
    private func outstandingIssues() async -> [String] {
        let js = """
        return (function() {
            var issues = [];
            var title = document.querySelector('input[data-testid="Title"]');
            if (!title || !title.value.trim()) { issues.push('title-empty'); }

            // Photo upload failure toast (async upload may have errored).
            var bodyText = document.body.innerText || '';
            if (bodyText.indexOf('Something wrong happened') !== -1) { issues.push('photo-upload-error'); }

            // The shipping field text reflects whether category + carrier are set.
            var ship = document.querySelector('#sellShippingClassesInput, [data-testid="SelectShipping"]');
            if (ship) {
                var v = (ship.value || '').toLowerCase();
                if (!v || v.indexOf('add title') !== -1 || v.indexOf('enable shipping') !== -1) {
                    issues.push('category-or-shipping-missing');
                }
            }

            // Any currently-visible Mercari validation errors.
            var errs = document.querySelectorAll('[data-testid="SellFormError"]');
            for (var i = 0; i < errs.length; i++) {
                if (errs[i].offsetParent !== null) {
                    var t = errs[i].textContent.trim();
                    if (t) { issues.push('error:' + t); }
                }
            }
            return JSON.stringify(issues);
        })();
        """
        guard let json = (try? await webView.callJS(js)) as? String,
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    // MARK: Category Selection

    /// Sets the listing category through a tiered fallback:
    /// - Tier 1: accept Mercari's server-suggested category (most accurate).
    /// - Tier 2: fuzzy-match the AI-suggested category string against each live dropdown level.
    /// - Tier 3: select "Other" so shipping unlocks regardless.
    private func selectCategory(suggestedCategory: String?) async -> String {
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 6000; interval = interval || 200;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null;
                    try { r = fn(); } catch (e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        function realClick(el) {
            if (!el) return;
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        return (async function() {
            // Tier 1: Mercari's own suggested categories. The accordion is generated server-side
            // from the title + photos, so it only appears AFTER photo upload completes.
            var accordion = await waitFor(function() {
                return document.querySelector('[data-testid="SuggestedCategoriesAccordion"]');
            }, 15000);
            if (accordion) {
                if (accordion.getAttribute('aria-expanded') !== 'true') { realClick(accordion); }
                var first = await waitFor(function() {
                    return document.querySelector('[data-testid="SuggestedCategory1"]');
                }, 4000);
                if (first) {
                    realClick(first);
                    var confirmed = await waitFor(function() {
                        return first.getAttribute('data-selected') === 'true' ? 'y' : null;
                    }, 1500);
                    return confirmed ? 'tier1-suggested' : 'tier1-clicked';
                }
            }

            // Tier 2/3: walk the dropdowns, picking the best fuzzy match to the AI category
            // at each level, else "Other". An empty target degrades naturally to Tier 3.
            var targetWords = (target || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').split(/\\s+/).filter(Boolean);
            function scoreName(name) {
                var n = name.toLowerCase();
                var score = 0;
                for (var i = 0; i < targetWords.length; i++) { if (n.indexOf(targetWords[i]) !== -1) { score++; } }
                return score;
            }
            // Pick the best-matching option; returns 'matched' or 'other' for logging.
            async function pickLevel(triggerTestId, listSelector, optionTestId) {
                var trigger = document.querySelector('[data-testid="' + triggerTestId + '"]');
                if (!trigger) { return null; }
                realClick(trigger);
                var list = await waitFor(function() { return document.querySelector(listSelector); }, 2500);
                if (!list) { return null; }
                var opts = list.querySelectorAll('[data-testid="' + optionTestId + '"]');
                if (opts.length === 0) { return null; }
                var best = null, bestScore = 0, other = null;
                for (var i = 0; i < opts.length; i++) {
                    var txt = opts[i].textContent.trim();
                    if (txt.toLowerCase() === 'other') { other = opts[i]; }
                    var s = scoreName(txt);
                    if (s > bestScore) { bestScore = s; best = opts[i]; }
                }
                var chosen = bestScore > 0 ? best : (other || opts[opts.length - 1]);
                realClick(chosen);
                return (bestScore > 0) ? 'matched' : 'other';
            }

            var l0 = await pickLevel('CategoryL0', '#categoryId', 'CategoryL0-option');
            if (!l0) { return 'no-category-ui'; }
            var l1 = await pickLevel('CategoryL1', '#subCategoryId', 'CategoryL1-option');
            if (document.querySelector('[data-testid="CategoryL2"]')) {
                await pickLevel('CategoryL2', '#subSubCategoryId', 'CategoryL2-option');
            }
            return (l0 === 'matched' || l1 === 'matched') ? 'tier2-matched' : 'tier3-other';
        })();
        """
        let target = suggestedCategory ?? ""
        return (try? await webView.callJS(js, args: ["target": target])) as? String ?? "error"
    }

    // MARK: Smart Pricing

    /// Turns Smart Pricing off (the default behavior) if it auto-enabled after price injection.
    /// Polls for the toggle, clicks it with a real pointer sequence, and verifies it flipped off.
    /// Returns a status string ("disabled", "was-off", "still-on", "not-found").
    private func disableSmartPricing() async -> String {
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 5000; interval = interval || 250;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null; try { r = fn(); } catch (e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        // React switches often ignore a bare .click(); dispatch the full pointer/mouse sequence.
        function realClick(el) {
            if (!el) return;
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        function findToggle() {
            var t = document.querySelector('[data-testid*="SmartPricing"], [data-testid*="smartPricing"]');
            if (t) return t;
            var cands = document.querySelectorAll('input[type="checkbox"], button[role="switch"], [role="switch"]');
            for (var i = 0; i < cands.length; i++) {
                var anc = cands[i].closest('label') || cands[i].parentElement;
                if (anc && anc.textContent.toLowerCase().indexOf('smart pricing') !== -1) return cands[i];
            }
            var els = document.querySelectorAll('span, p, div');
            for (var j = 0; j < els.length; j++) {
                if (els[j].childElementCount === 0 && els[j].textContent.trim() === 'Smart Pricing') {
                    var btn = els[j].closest('[role="switch"]') || els[j].closest('button')
                        || (els[j].parentElement && els[j].parentElement.querySelector('[role="switch"]'));
                    if (btn) return btn;
                }
            }
            return null;
        }
        function isOn(t) {
            return t.checked === true
                || t.getAttribute('aria-checked') === 'true'
                || t.getAttribute('data-state') === 'checked'
                || (t.className && String(t.className).indexOf('checked') !== -1);
        }
        return (async function() {
            var toggle = await waitFor(findToggle, 5000);
            if (!toggle) { return 'not-found'; }
            if (!isOn(toggle)) { return 'was-off'; }
            var target = toggle.tagName === 'INPUT'
                ? (document.querySelector('label[for="' + toggle.id + '"]') || toggle.closest('label') || toggle)
                : toggle;
            realClick(target);
            toggle.dispatchEvent(new Event('change', { bubbles: true }));
            var off = await waitFor(function() { return isOn(toggle) ? null : 'off'; }, 1500);
            if (!off) { realClick(target); off = await waitFor(function() { return isOn(toggle) ? null : 'off'; }, 1500); }
            return off ? 'disabled' : 'still-on';
        })();
        """
        return (try? await webView.callJS(js)) as? String ?? "error"
    }

    // MARK: Brand Selection

    /// Selects the brand through a tiered fallback:
    /// - Tier 1: Use the first chip from Mercari's server-suggested brand list.
    /// - Tier 2: Type the AI-suggested brand into the search field and select the top match.
    /// - Tier 3: Select "No brand / Not sure".
    private func selectBrand(suggestedBrand: String?) async -> String {
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 5000; interval = interval || 200;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null; try { r = fn(); } catch(e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        function realClick(el) {
            if (!el) return;
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        function setReactInput(el, value) {
            if (!el) return false;
            var last = el.value;
            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (setter && setter.set) { setter.set.call(el, value); } else { el.value = value; }
            if (el._valueTracker) { el._valueTracker.setValue(last); }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
        }
        return (async function() {
            // Tier 1: Mercari's server-suggested brand chips.
            var suggested = document.querySelector('[data-testid="SuggestedBrandSection"]');
            if (suggested) {
                // Pick first chip that is NOT the "No brand / Not sure" option.
                var chips = suggested.querySelectorAll('[data-testid^="SuggestedBrand-"]:not([data-testid="NoBrandLink"])');
                if (chips.length > 0) {
                    var label = chips[0].querySelector('label');
                    var input = chips[0].querySelector('input[type="checkbox"]');
                    if (label) { realClick(label); }
                    else if (input) { realClick(input); input.dispatchEvent(new Event('change', { bubbles: true })); }
                    var name = (chips[0].querySelector('[class*="ChoiceText"]') || chips[0]).textContent.trim();
                    return 'tier1:' + name;
                }
            }

            // Tier 2: AI-suggested brand — type into the brand search field, pick first dropdown match.
            if (suggestedBrandName) {
                var brandInput = await waitFor(function() {
                    return document.querySelector('[data-testid="BrandSearchInput"], [data-testid="BrandInput"], input[placeholder*="brand" i]');
                }, 3000);
                if (brandInput) {
                    realClick(brandInput);
                    setReactInput(brandInput, suggestedBrandName);
                    var option = await waitFor(function() {
                        var opts = document.querySelectorAll('[data-testid*="BrandOption"], [data-testid*="BrandSuggestion"], li[role="option"]');
                        return opts.length > 0 ? opts[0] : null;
                    }, 3000);
                    if (option) {
                        realClick(option);
                        return 'tier2:' + suggestedBrandName;
                    }
                }
            }

            // Tier 3: "No brand / Not sure".
            var noBrand = document.querySelector('[data-testid="NoBrandLink"] label, [data-testid="NoBrandLink"] input');
            if (noBrand) {
                realClick(noBrand);
                return 'tier3:no-brand';
            }
            return 'brand-ui-not-found';
        })();
        """
        let brand = suggestedBrand ?? ""
        return (try? await webView.callJS(js, args: ["suggestedBrandName": brand])) as? String ?? "error"
    }

    /// Returns true when Mercari's List button is currently enabled (all required fields valid).
    private func checkListingButtonEnabled() async -> Bool {
        let js = """
        return (function() {
            var btn = document.querySelector('[data-testid="ListButton"]');
            return (btn && !btn.disabled) ? 'yes' : 'no';
        })();
        """
        return ((try? await webView.callJS(js)) as? String) == "yes"
    }

    // MARK: Shipping Flow

    /// The values Mercari's "How heavy will the package be?" modal needs before it enables its Next
    /// button: a non-zero weight (whole pounds + ounces) and an answer to the shoebox question.
    struct MercariWeightEntry {
        let lb: Int
        let oz: Int
        /// Answer to "Will your item fit in a shoebox?" (14"×10"×5"). `false` reveals dimension inputs.
        let fitsInShoebox: Bool
    }

    /// Derives a guaranteed-fillable weight entry, supplying safe defaults when the listing has no
    /// weight or no dimensions (Mercari blocks the modal's Next button without both a positive
    /// weight and an explicit shoebox answer).
    ///
    /// Two judgment calls live here — this is the part worth your input:
    ///  1. Fallback weight when none is set — too light under-buys the prepaid label (you eat an
    ///     overage at the counter); too heavy over-buys it (eats into proceeds). USPS Ground
    ///     Advantage pricing steps at 4 / 8 / 12 / 15.99 oz, then per pound.
    ///  2. Shoebox answer when dimensions are unknown — "Yes" keeps the cheap small-package flow;
    ///     "No" forces Mercari to demand box dimensions, a step some categories don't even offer.
    private func mercariWeightEntry(
        weightLbs: Double?, lengthIn: Double?, widthIn: Double?, heightIn: Double?
    ) -> MercariWeightEntry {
        // Only answer "No" (doesn't fit) when we actually know it's oversized — otherwise saying No
        // dead-ends on a dimensions step we have no numbers to fill.
        let knowDims = lengthIn != nil && widthIn != nil && heightIn != nil
        let fits = !(knowDims && MercariShipping.isOversized(length: lengthIn, width: widthIn, height: heightIn))

        if let w = weightLbs, w > 0 {
            var lb = Int(w)
            var oz = Int(((w - Double(lb)) * 16).rounded())
            if oz >= 16 { lb += oz / 16; oz %= 16 }   // normalize e.g. 16 oz → 1 lb 0 oz
            if lb == 0 && oz == 0 { oz = 1 }           // never submit a zero weight
            return MercariWeightEntry(lb: lb, oz: oz, fitsInShoebox: fits)
        }

        // TODO(you): the listing has no weight — choose the fallback Mercari should price against.
        // See trade-off (1) in the doc comment. Default below is ~6 oz (a light padded-mailer item).
        let fallbackOz = 6
        return MercariWeightEntry(lb: 0, oz: fallbackOz, fitsInShoebox: fits)
    }

    /// Walks Mercari's shipping flow per the seller's preferences:
    /// - `shipOnOwn`: select the SOYO radio and stop (no carrier flow).
    /// - prepaid: open the shipping field → dismiss the "weigh accurately" popup → either accept
    ///   Mercari's "Use label" (if `acceptSuggestions` and offered) or enter weight (+ shoebox /
    ///   dimensions) → parse the live carrier list → pick per `mode` → Save.
    private func completeShipping(
        weightLbs: Double?, lengthIn: Double?, widthIn: Double?, heightIn: Double?,
        preferences: ShippingPreferences
    ) async -> String {
        if preferences.mode == .shipOnOwn {
            return await selectShipOnOwn()
        }

        // Mercari gates the weight modal's Next button on a non-zero weight AND an answered
        // "fits in a shoebox?" question. The listing may carry neither, so derive safe defaults.
        let entry = mercariWeightEntry(
            weightLbs: weightLbs, lengthIn: lengthIn, widthIn: widthIn, heightIn: heightIn
        )
        let haveDims = lengthIn != nil && widthIn != nil && heightIn != nil

        let open = await openShippingAndSubmitWeight(
            lb: entry.lb, oz: entry.oz,
            acceptSuggestions: preferences.acceptSuggestions,
            fitsInShoebox: entry.fitsInShoebox, haveDims: haveDims,
            lengthIn: Int((lengthIn ?? 0).rounded()),
            widthIn: Int((widthIn ?? 0).rounded()),
            heightIn: Int((heightIn ?? 0).rounded())
        )
        print("[MercariPostingState] Shipping/openWeight: \(open)")

        // "Use label" was accepted — Mercari already chose a label, nothing left to pick.
        if open == "used-recommended" { return "recommended-accepted" }
        // Oversized item in a category with no dimensions step: a prepaid label risks an overage
        // fee. Advise the seller to ship on their own and bake shipping into the price.
        if open == "oversized-no-dimension-step" {
            warning = "This item looks oversized but Mercari didn't ask for box dimensions for this category. A prepaid label may incur an overage fee — consider \"Ship on your own\" and add shipping to the price."
        }
        // Any state other than a clean weight submission can't proceed to the carrier list.
        guard open == "weight-submitted" else { return open }

        // The carrier list is fetched after weight submission — wait for it, parse it.
        let options = await fetchShippingOptions()
        print("[MercariPostingState] Shipping/options: \(options.count) found")
        guard !options.isEmpty else { return "no-options" }

        guard let chosen = pickShippingOption(from: options, preferences: preferences) else {
            return "no-match"
        }
        let saved = await chooseShippingOption(value: chosen)
        return "picked:\(chosen)|\(saved)"
    }

    /// Ship-on-your-own path: select the SOYO radio (overriding the prepaid default) and stop.
    private func selectShipOnOwn() async -> String {
        let js = """
        return (function() {
            var soyo = document.querySelector('input#SOYO[type="radio"], input[value="SOYO"][type="radio"]');
            if (!soyo) { return 'soyo-not-found'; }
            if (!soyo.checked) {
                soyo.click();
                soyo.dispatchEvent(new Event('change', { bubbles: true }));
            }
            return 'ship-on-own';
        })();
        """
        return (try? await webView.callJS(js)) as? String ?? "error:soyo"
    }

    /// Stage 1: open the shipping field, clear the "weigh accurately" interstitial, then either
    /// accept the recommended label (when allowed + offered) or enter weight/dimensions and submit
    /// to fetch the carrier list. Returns "used-recommended", "weight-submitted", or a diagnostic.
    private func openShippingAndSubmitWeight(
        lb: Int, oz: Int, acceptSuggestions: Bool,
        fitsInShoebox: Bool, haveDims: Bool, lengthIn: Int, widthIn: Int, heightIn: Int
    ) async -> String {
        let args: [String: Any] = [
            "lb": lb, "oz": oz, "acceptSuggestions": acceptSuggestions,
            "fitsInShoebox": fitsInShoebox, "haveDims": haveDims,
            "lengthIn": lengthIn, "widthIn": widthIn, "heightIn": heightIn
        ]
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 6000; interval = interval || 200;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null; try { r = fn(); } catch (e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        function setReactInput(el, value) {
            if (!el) return false;
            var last = el.value;
            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (setter && setter.set) { setter.set.call(el, value); } else { el.value = value; }
            if (el._valueTracker) { el._valueTracker.setValue(last); }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
        }
        function btnByText(t) {
            var bs = document.querySelectorAll('button');
            for (var i = 0; i < bs.length; i++) { if (bs[i].textContent.trim() === t) return bs[i]; }
            return null;
        }
        // Some Mercari controls are Link/anchor-styled and ignore a bare .click() under React;
        // dispatch a full pointer/mouse sequence so the handler actually fires.
        function realClick(el) {
            if (!el) return;
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        // True once a real carrier name is showing in the shipping field (modal accepted/closed).
        function shippingChosen() {
            var s = document.querySelector('#sellShippingClassesInput, [data-testid="SelectShipping"]');
            if (!s) return false;
            var v = (s.value || '').toLowerCase();
            return v.length > 0 && v.indexOf('add title') === -1 && v.indexOf('enable shipping') === -1 && v.indexOf('select') === -1;
        }
        // Answers Mercari's "Will your item fit in a shoebox?" question. This radio gates the weight
        // modal's Next button; fire a real change on the chosen option, because a visually
        // pre-selected default is often NOT yet committed to React state. Returns how it matched.
        function answerShoebox(scope, fits) {
            scope = scope || document;
            var direct = scope.querySelector(fits
                ? '[data-testid="ItemFitInShoeboxYes"], [data-testid="ShoeboxYes"]'
                : '[data-testid="ItemFitInShoeboxNo"], [data-testid="ShoeboxNo"]');
            if (direct) {
                var dl = document.querySelector('label[for="' + direct.id + '"]') || direct.closest('label') || direct;
                realClick(dl);
                direct.dispatchEvent(new Event('change', { bubbles: true }));
                return 'testid';
            }
            // Fallback: match the Yes/No radio by its label text within the modal scope.
            var want = fits ? 'yes' : 'no';
            var radios = scope.querySelectorAll('input[type="radio"]');
            for (var i = 0; i < radios.length; i++) {
                var rl = document.querySelector('label[for="' + radios[i].id + '"]') || radios[i].closest('label') || radios[i].parentElement;
                var txt = (rl ? rl.textContent : '').trim().toLowerCase();
                if (txt === want) {
                    realClick(rl || radios[i]);
                    radios[i].dispatchEvent(new Event('change', { bubbles: true }));
                    return 'label';
                }
            }
            return 'not-found';
        }
        return (async function() {
            // The shipping field only becomes enabled once category is set — which itself just
            // happened, so allow generous time for React to enable it.
            var field = await waitFor(function() {
                var el = document.querySelector('#sellShippingClassesInput, [data-testid="SelectShipping"]');
                return (el && !el.disabled) ? el : null;
            }, 15000);
            if (!field) { return 'no-shipping-field'; }
            realClick(field);

            // The "Weigh and measure your package accurately" interstitial may appear first.
            var gotIt = await waitFor(function() { return btnByText('Got it'); }, 3000);
            if (gotIt) {
                // Scope the "Don't show this again" checkbox to the popup that owns the Got it button.
                var popup = gotIt.closest('div[role="dialog"]') || gotIt.parentElement;
                var dontShow = null;
                var labels = (popup || document).querySelectorAll('label');
                for (var i = 0; i < labels.length; i++) {
                    if (labels[i].textContent.toLowerCase().includes("don't show")) {
                        dontShow = labels[i].querySelector('input[type="checkbox"]');
                        break;
                    }
                }
                if (dontShow && !dontShow.checked) { realClick(dontShow); }
                realClick(gotIt);
            }

            // Option A: accept Mercari's recommended label — ONLY if the seller allows it and it
            // actually appears (it isn't always offered). Verify it closes the modal before trusting it.
            if (acceptSuggestions) {
                var useLabel = await waitFor(function() {
                    return document.querySelector('[data-testid="UseThisButton"]');
                }, 2500);
                if (useLabel) {
                    realClick(useLabel);
                    var accepted = await waitFor(function() { return shippingChosen() ? 'y' : null; }, 3500);
                    if (accepted) { return 'used-recommended'; }
                    // Didn't take — fall through to the explicit weight + carrier-list path.
                }
            }

            // Option B: the weight modal ("How heavy will the package be?").
            var lbEl = await waitFor(function() {
                return document.querySelector('[data-testid="ItemWeightInPounds"], #lb');
            }, 6000);
            var ozEl = document.querySelector('[data-testid="ItemWeightInOunces"], #oz');
            if (!lbEl && !ozEl) {
                // No weight modal surfaced — a label may already be chosen.
                return shippingChosen() ? 'used-recommended' : 'no-weight-modal';
            }
            var modal = (lbEl || ozEl).closest('div[role="dialog"], [role="dialog"]');

            // Keep Mercari's prefilled weight only when the seller opted to accept suggestions;
            // otherwise write our weight (guaranteed non-zero by mercariWeightEntry).
            var hasPrefill = (lbEl && parseFloat(lbEl.value) > 0) || (ozEl && parseFloat(ozEl.value) > 0);
            if (!(hasPrefill && acceptSuggestions)) {
                if (lbEl) { setReactInput(lbEl, String(lb)); lbEl.focus(); lbEl.blur(); }
                if (ozEl) { setReactInput(ozEl, String(oz)); ozEl.focus(); ozEl.blur(); }
            }

            // Answer "Will your item fit in a shoebox?" — a newer required gate. The radio often
            // isn't registered in React state even when one option looks pre-selected, so this
            // always fires a real change. Without it the Next button stays disabled forever.
            var shoeboxStatus = answerShoebox(modal, fitsInShoebox);

            // Saying "No" reveals dimension inputs; fill them only when we know the dimensions.
            // If the item is oversized but no dimensions step exists for this category, a prepaid
            // label risks an overage fee — surface that so the seller can ship on their own.
            if (!fitsInShoebox && haveDims) {
                var lenEl = await waitFor(function() {
                    return document.querySelector('[data-testid="InputLength"], #Length');
                }, 2500);
                if (lenEl) {
                    var widEl = document.querySelector('[data-testid="InputWidth"], #Width');
                    var heiEl = document.querySelector('[data-testid="InputHeight"], #Height');
                    setReactInput(lenEl, String(lengthIn));
                    if (widEl) { setReactInput(widEl, String(widthIn)); }
                    if (heiEl) { setReactInput(heiEl, String(heightIn)); }
                } else {
                    return 'oversized-no-dimension-step';
                }
            }

            // The Next button ("SelectCarrierButton") exists immediately but stays DISABLED until
            // React validates weight + shoebox. Poll for it to become *enabled* before clicking —
            // the old code clicked it the moment it existed, so a disabled button silently no-op'd
            // and we falsely reported the weight as submitted.
            var next = await waitFor(function() {
                var b = document.querySelector('[data-testid="SelectCarrierButton"]');
                return (b && !b.disabled) ? b : null;
            }, 6000);
            if (next) { realClick(next); return 'weight-submitted'; }

            // Still disabled after filling everything — report field state so Swift can log why.
            var btn = document.querySelector('[data-testid="SelectCarrierButton"]');
            if (btn) {
                return 'next-disabled|shoebox:' + shoeboxStatus
                    + '|lb:' + (lbEl ? (lbEl.value || '0') : '-')
                    + '|oz:' + (ozEl ? (ozEl.value || '0') : '-');
            }
            return shippingChosen() ? 'used-recommended' : 'weight-next-not-found';
        })();
        """
        return (try? await webView.callJS(js, args: args)) as? String ?? "error:open"
    }

    /// Stage 2: wait for the live carrier list and parse each option into structured data.
    private func fetchShippingOptions() async -> [MercariShippingOption] {
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 8000; interval = interval || 250;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null; try { r = fn(); } catch (e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        return (async function() {
            var container = await waitFor(function() {
                var nodes = document.querySelectorAll('[data-testid="AvailableShippingOption"]');
                return nodes.length > 0 ? nodes : null;
            }, 10000);
            if (!container) { return '[]'; }
            var out = [];
            for (var i = 0; i < container.length; i++) {
                var node = container[i];
                var radio = node.querySelector('input[type="radio"]');
                if (!radio) { continue; }
                // The first dollar amount in the price heading is the discounted price.
                var priceEl = node.querySelector('[data-testid$="Price"]') || node;
                var match = (priceEl.textContent || '').match(/\\$([0-9]+(?:\\.[0-9]{1,2})?)/);
                var cents = match ? Math.round(parseFloat(match[1]) * 100) : 999999;
                out.push({
                    value: radio.value,
                    carrier: node.getAttribute('data-carrier') || '',
                    name: node.getAttribute('data-display-name') || '',
                    priceCents: cents
                });
            }
            return JSON.stringify(out);
        })();
        """
        guard let json = (try? await webView.callJS(js)) as? String,
              let data = json.data(using: .utf8),
              let options = try? JSONDecoder().decode([MercariShippingOption].self, from: data)
        else { return [] }
        return options
    }

    /// Stage 3: select the chosen label's radio, then click Save to close the modal.
    private func chooseShippingOption(value: String) async -> String {
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 4000; interval = interval || 200;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null; try { r = fn(); } catch (e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        function realClick(el) {
            if (!el) return;
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        return (async function() {
            var radio = document.querySelector('input[type="radio"][value="' + targetValue + '"]');
            if (!radio) { return 'radio-not-found'; }
            var label = document.querySelector('label[for="' + radio.id + '"]') || radio.closest('label') || radio;
            realClick(label);
            radio.dispatchEvent(new Event('change', { bubbles: true }));
            var save = await waitFor(function() {
                return document.querySelector('[data-testid="SelectCarrierSaveButton"]');
            }, 3000);
            if (!save) { return 'save-not-found'; }
            realClick(save);
            return 'saved';
        })();
        """
        return (try? await webView.callJS(js, args: ["targetValue": value])) as? String ?? "error:choose"
    }

    // MARK: Submit

    /// Submits the listing once category + carrier have made the form valid. The List button stays
    /// disabled until Mercari finishes validating, so this polls for it to become *enabled* before
    /// clicking — clicking it while disabled silently no-ops (the bug that made submit look broken).
    private func submitListing() async -> String {
        let js = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 6000; interval = interval || 250;
            return new Promise(function(resolve) {
                var start = Date.now();
                (function loop() {
                    var r = null; try { r = fn(); } catch (e) {}
                    if (r) { resolve(r); return; }
                    if (Date.now() - start >= timeout) { resolve(null); return; }
                    setTimeout(loop, interval);
                })();
            });
        }
        function realClick(el) {
            if (!el) return;
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        return (async function() {
            var listBtn = await waitFor(function() {
                var b = document.querySelector('[data-testid="ListButton"]');
                return (b && !b.disabled) ? b : null;
            }, 6000);
            if (!listBtn) {
                return document.querySelector('[data-testid="ListButton"]') ? 'list-btn:disabled' : 'list-btn:not-found';
            }
            var form = listBtn.closest('form');
            if (form && form.requestSubmit) { form.requestSubmit(listBtn); }
            else { realClick(listBtn); }
            // Some flows pop a confirmation dialog; accept it if one appears within a short window.
            var confirm = await waitFor(function() {
                var bs = document.querySelectorAll('div[role="dialog"] button, [role="dialog"] button');
                for (var i = 0; i < bs.length; i++) {
                    var t = bs[i].textContent.trim().toLowerCase();
                    if ((t === 'list' || t === 'confirm' || t.indexOf('list it') !== -1 || t.indexOf('yes') === 0) && !bs[i].disabled) {
                        return bs[i];
                    }
                }
                return null;
            }, 2000);
            if (confirm) { realClick(confirm); return 'submitted-confirmed'; }
            return 'submitted';
        })();
        """
        return (try? await webView.callJS(js)) as? String ?? "error:submit"
    }

    // MARK: Carrier Ranking

    /// Picks which shipping label to select from Mercari's live list, honoring the seller's
    /// preference. Returns the `value` of the chosen option, or nil if nothing matches.
    ///
    /// `.cheapestPrepaid` takes the cheapest across all carriers. `.cheapestAmongCarriers`
    /// takes the cheapest among the seller's selected carriers, falling back to the cheapest
    /// overall if none of those carriers are offered for this item.
    func pickShippingOption(from options: [MercariShippingOption], preferences: ShippingPreferences) -> String? {
        let cheapestOverall = options.min { $0.priceCents < $1.priceCents }
        switch preferences.mode {
        case .shipOnOwn:
            return nil // handled before the carrier list; not reached here
        case .cheapestPrepaid:
            return cheapestOverall?.value
        case .cheapestAmongCarriers:
            let tokens = preferences.selectedCarriers.map { $0.matchToken }
            let cheapestSelected = options
                .filter { opt in tokens.contains { opt.carrier.lowercased().contains($0) } }
                .min { $0.priceCents < $1.priceCents }
            return (cheapestSelected ?? cheapestOverall)?.value
        }
    }
}

// MARK: - MercariLoginView

struct MercariLoginView: UIViewRepresentable {
    var onLoginSuccess: (String) -> Void
    var onLoginFailure: (String) -> Void

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MercariLoginView
        var hasHandled = false

        init(_ parent: MercariLoginView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? ""
            let isLoginOrAuth = url.contains("/login") || url.contains("/oauth") || url.contains("auth") || url.contains("identity")
            if !hasHandled && url.contains("mercari.com") && !isLoginOrAuth {
                scrapeUsername(webView: webView, attempts: 0)
            }
        }

        private func scrapeUsername(webView: WKWebView, attempts: Int) {
            let getUsernameJS = """
            (function() {
                let exactElement = document.querySelector('[data-testid="UserName"]')?.innerText;
                if (exactElement && exactElement.length > 0) {
                    return exactElement.startsWith('@') ? exactElement.substring(1) : exactElement;
                }
                let nextData = document.getElementById('__NEXT_DATA__');
                if (nextData) {
                    try {
                        let jsonText = nextData.innerText;
                        let nicknameMatch = jsonText.match(/"nickname":"([^"]+)"/);
                        if (nicknameMatch && nicknameMatch[1]) return nicknameMatch[1];
                        let usernameMatch = jsonText.match(/"username":"([^"]+)"/);
                        if (usernameMatch && usernameMatch[1]) return usernameMatch[1];
                        let nameMatch = jsonText.match(/"name":"([^"]+)"/);
                        if (nameMatch && nameMatch[1]) return nameMatch[1];
                    } catch(e) {}
                }
                let possibleName = document.querySelector('h1')?.innerText;
                if (possibleName && possibleName.length > 0 && possibleName !== 'My Page') {
                    return possibleName;
                }
                let scripts = document.querySelectorAll('script');
                for (let s of scripts) {
                    let text = s.innerText;
                    if (text.includes('"nickname":')) {
                        let match = text.match(/"nickname":"([^"]+)"/);
                        if (match && match[1]) return match[1];
                    }
                    if (text.includes('"username":')) {
                        let match = text.match(/"username":"([^"]+)"/);
                        if (match && match[1]) return match[1];
                    }
                }
                let metaName = document.querySelector('meta[name="twitter:title"]')?.content;
                if (metaName && metaName.includes('Mercari')) {
                     return metaName.replace(/\\| Mercari/g, '').trim();
                }
                return null;
            })();
            """

            webView.evaluateJavaScript(getUsernameJS) { [weak self] result, error in
                guard let self = self else { return }
                if let username = result as? String, !username.isEmpty {
                    self.hasHandled = true
                    self.parent.onLoginSuccess(username)
                } else {
                    if attempts < 4 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.scrapeUsername(webView: webView, attempts: attempts + 1)
                        }
                    } else {
                        self.parent.onLoginFailure("Failed to scrape Mercari username from the page.")
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://www.mercari.com/login/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct MercariConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            MercariLoginView(onLoginSuccess: { username in
                Task {
                    try? await IntegrationRepository.shared.linkPlatformWithMock(platform: "mercari", username: username)
                    dismiss()
                }
            }, onLoginFailure: { errorMsg in
                Task {
                    try? await IntegrationRepository.shared.linkPlatformWithMock(platform: "mercari", username: "Mercari User")
                }
                self.errorMessage = errorMsg
                self.showError = true
            })
            .navigationTitle("Connect Mercari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Login Error", isPresented: $showError) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
        }
    }
}

// MARK: - MercariShippingPreferencesView

/// Lets the seller choose how the Mercari autofill handles shipping. Used both as one-time setup
/// before the first cross-post (`isFirstTimeSetup`) and as an editable Settings screen. Writes the
/// local AppStorage cache and syncs to Firestore for cross-device persistence.
struct MercariShippingPreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("mercariAcceptSuggestions") private var acceptSuggestions = true
    @AppStorage("mercariShippingMode") private var shippingModeRaw = ShippingMode.cheapestPrepaid.rawValue
    @AppStorage("mercariSelectedCarriers") private var selectedCarriersRaw = Carrier.usps.rawValue
    @AppStorage("mercariPrefsConfigured") private var prefsConfigured = false

    /// When true, shown as one-time setup before the first cross-post (vs. editing in Settings).
    var isFirstTimeSetup = false
    var onSaved: (() -> Void)? = nil

    // Local editing copies, committed on Save.
    @State private var accept = true
    @State private var mode: ShippingMode = .cheapestPrepaid
    @State private var carriers: Set<Carrier> = [.usps]

    var body: some View {
        Form {
            Section {
                Toggle("Use Mercari's suggested weight & label", isOn: $accept)
            } footer: {
                Text("When Mercari offers a recommended label (\"Use label\") or pre-fills a weight, accept it automatically. Turn off to always enter your own weight and pick a carrier yourself.")
            }

            Section("Shipping method") {
                Picker("Method", selection: $mode) {
                    ForEach(ShippingMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if mode == .cheapestAmongCarriers {
                Section {
                    ForEach(Carrier.allCases) { carrier in
                        Toggle(carrier.displayName, isOn: bindingFor(carrier))
                    }
                } header: {
                    Text("Carriers to consider")
                } footer: {
                    Text("We'll pick the cheapest label among these carriers, falling back to the overall cheapest if none are offered.")
                }
            }
        }
        .navigationTitle(isFirstTimeSetup ? "Shipping preferences" : "Mercari shipping")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isFirstTimeSetup ? "Continue" : "Save") { save() }
                    .disabled(mode == .cheapestAmongCarriers && carriers.isEmpty)
            }
        }
        .onAppear(perform: loadLocal)
    }

    private func bindingFor(_ carrier: Carrier) -> Binding<Bool> {
        Binding(
            get: { carriers.contains(carrier) },
            set: { isOn in
                if isOn { carriers.insert(carrier) } else { carriers.remove(carrier) }
            }
        )
    }

    private func loadLocal() {
        accept = acceptSuggestions
        mode = ShippingMode(rawValue: shippingModeRaw) ?? .cheapestPrepaid
        let parsed = Set(selectedCarriersRaw.split(separator: ",").compactMap { Carrier(rawValue: String($0)) })
        carriers = parsed.isEmpty ? [.usps] : parsed
    }

    private func save() {
        let carrierList = Array(carriers).map { $0.rawValue }
        acceptSuggestions = accept
        shippingModeRaw = mode.rawValue
        selectedCarriersRaw = carrierList.joined(separator: ",")
        prefsConfigured = true
        Task {
            await IntegrationRepository.shared.saveMercariShippingPreferences(
                acceptSuggestions: accept, mode: mode.rawValue, carriers: carrierList
            )
        }
        onSaved?()
        dismiss()
    }
}

// MARK: - MercariAutoPosterView

struct MercariAutoPosterView: View {
    let job: CrossPostJob
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = MercariPostingState()
    @State private var showLogin = false
    @State private var hasInjected = false

    // Seller shipping preferences. Synced to Firestore so they persist across devices; the
    // AppStorage copies are the local cache the injection reads.
    @AppStorage("mercariAcceptSuggestions") private var acceptSuggestions = true
    @AppStorage("mercariShippingMode") private var shippingModeRaw = ShippingMode.cheapestPrepaid.rawValue
    /// Comma-separated carrier raw values used when mode == .cheapestAmongCarriers (e.g. "usps,ups").
    @AppStorage("mercariSelectedCarriers") private var selectedCarriersRaw = Carrier.usps.rawValue
    /// Set once the seller has chosen their shipping preferences (collected on first cross-post).
    @AppStorage("mercariPrefsConfigured") private var prefsConfigured = false
    @State private var showPrefSetup = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                MercariSheetWebView(webView: state.webView)
                VStack(spacing: 0) {
                    statusBanner
                    if let warning = state.warning {
                        warningBanner(warning)
                    }
                }
            }
            .navigationTitle("Post to Mercari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin, onDismiss: {
                hasInjected = false
                state.reloadSellPage()
                Task { await fetchPhotosAndInject() }
            }) {
                MercariConnectSheet()
            }
            .sheet(isPresented: $showPrefSetup) {
                // First-time setup: collect shipping preferences before the autofill runs.
                NavigationStack {
                    MercariShippingPreferencesView(isFirstTimeSetup: true, onSaved: {
                        Task { await fetchPhotosAndInject() }
                    })
                }
                .interactiveDismissDisabled(true)
            }
        }
        .task { await loadPreferencesThenStart() }
        .onChange(of: state.status) { _, newStatus in
            switch newStatus {
            case .success:
                Task { await updateFirestore() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { dismiss() }
            case .loginRequired:
                showLogin = true
            default: break
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var statusBanner: some View {
        switch state.status {
        case .loading:
            banner(icon: nil, text: "Loading Mercari…", bg: .ultraThinMaterial)
        case .injecting:
            banner(icon: nil, text: "Filling in fields…", bg: .ultraThinMaterial)
        case .waitingForCategory:
            HStack(spacing: 10) {
                Image(systemName: state.isListingComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(state.isListingComplete ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isListingComplete ? "Ready to list!" : "Review & complete form")
                        .font(.subheadline.weight(.semibold))
                    Text(state.isListingComplete ? "Tap List to publish" : "Some fields still need your attention")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                if state.isListingComplete {
                    Color.green.opacity(0.08)
                } else {
                    Rectangle().fill(Material.ultraThinMaterial)
                }
            }
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
        case .success:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                Text("Listed on Mercari!").font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.green.opacity(0.15))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.green.opacity(0.3)), alignment: .bottom)
        case .failed:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                Text("Autofill failed — fill fields manually").font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
        case .loginRequired:
            EmptyView()
        }
    }

    private func banner(icon: String?, text: String, bg: Material) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text(text).font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(bg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.warning = nil
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.3)), alignment: .bottom)
    }

    // MARK: Logic

    /// Pulls saved preferences from Firestore (so they sync to a new device), then either starts
    /// the autofill or collects preferences first if the seller has never set them.
    private func loadPreferencesThenStart() async {
        // Firestore is the source of truth for cross-device sync; mirror into the local cache.
        if let remote = await IntegrationRepository.shared.loadMercariShippingPreferences() {
            acceptSuggestions = remote.acceptSuggestions
            shippingModeRaw = remote.mode
            selectedCarriersRaw = remote.carriers.joined(separator: ",")
            prefsConfigured = true
        }

        if prefsConfigured {
            await fetchPhotosAndInject()
        } else {
            // First Mercari cross-post on this account — collect preferences before autofilling.
            showPrefSetup = true
        }
    }

    private func fetchPhotosAndInject() async {
        guard !hasInjected else { return }
        hasInjected = true

        var photoBase64Strings: [String] = []
        if let item = job.item {
            if !item.photosData.isEmpty {
                photoBase64Strings = item.photosData.map { $0.base64EncodedString() }
            } else {
                for identifier in item.sourceAssetIdentifiers {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                    guard let asset = assets.firstObject else { continue }
                    let options = PHImageRequestOptions()
                    options.deliveryMode = .highQualityFormat
                    options.isNetworkAccessAllowed = true
                    let data: Data? = await withCheckedContinuation { continuation in
                        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                            continuation.resume(returning: data)
                        }
                    }
                    if let data { photoBase64Strings.append(data.base64EncodedString()) }
                }
            }
        } else if !job.photoFirebasePaths.isEmpty {
            for path in job.photoFirebasePaths {
                let ref = Storage.storage().reference(withPath: path)
                if let data = try? await ref.data(maxSize: 15 * 1024 * 1024) {
                    photoBase64Strings.append(data.base64EncodedString())
                }
            }
        }

        let selectedCarriers = Set(
            selectedCarriersRaw.split(separator: ",").compactMap { Carrier(rawValue: String($0)) }
        )
        let preferences = ShippingPreferences(
            acceptSuggestions: acceptSuggestions,
            mode: ShippingMode(rawValue: shippingModeRaw) ?? .cheapestPrepaid,
            selectedCarriers: selectedCarriers.isEmpty ? [.usps] : selectedCarriers
        )

        await state.injectFields(
            title: job.title,
            description: job.description,
            price: job.price,
            photoBase64Strings: photoBase64Strings,
            condition: job.item?.condition ?? "good",
            suggestedCategory: job.item?.aiSuggestedCategory,
            suggestedBrand: job.item?.aiSuggestedBrand,
            weightLbs: job.item?.weightLbs,
            lengthIn: job.item?.lengthIn,
            widthIn: job.item?.widthIn,
            heightIn: job.item?.heightIn,
            preferences: preferences
        )
    }

    private func updateFirestore() async {
        guard let listingId = job.listingId else { return }
        var update: [String: Any] = [
            "crossPostStatus.mercari": "posted",
            "updatedAt": Timestamp(date: Date())
        ]
        if let mercariId = state.mercariItemId {
            update["crossPostListingIds.mercari"] = mercariId
            print("[MercariAutoPosterView] Storing Mercari item ID: \(mercariId)")
        }
        try? await Firestore.firestore().collection("listings").document(listingId).updateData(update)
        print("[MercariAutoPosterView] Firestore updated for listing \(listingId)")
    }
}

/// Renders an existing WKWebView in a SwiftUI view hierarchy without triggering a reload.
struct MercariSheetWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
