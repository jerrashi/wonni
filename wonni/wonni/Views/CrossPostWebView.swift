//
//  CrossPostWebView.swift
//  wonni
//

import SwiftUI
import WebKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
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
    /// When true, the seller wants the buyer to pay shipping (Mercari "Offer free shipping? → No").
    /// Defaults to false = free shipping (Mercari's own default).
    let buyerPaysShipping: Bool

    init(
        platform: String,
        title: String,
        description: String,
        price: Double,
        listingId: String? = nil,
        item: Item? = nil,
        photoFirebasePaths: [String] = [],
        buyerPaysShipping: Bool = false
    ) {
        self.platform = platform
        self.title = title
        self.description = description
        self.price = price
        self.listingId = listingId
        self.item = item
        self.photoFirebasePaths = photoFirebasePaths
        self.buyerPaysShipping = buyerPaysShipping
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
extension WKWebView {
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

// Shared WKProcessPool for all Mercari WebViews — reusing the same web process within an
// app launch helps stabilise Mercari's device fingerprint across consecutive auto-poster sessions.
let mercariProcessPool = WKProcessPool()

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
    /// Set to "submitted" or "submitted-confirmed" once the List button click succeeds.
    /// Observed by MercariAutoPosterView to write a Firestore "pending" record immediately —
    /// Mercari is a React SPA so the navigation delegate may not fire after a route change.
    @Published var latestSubmitResult: String?
    /// Fires when the user successfully logs in via the inline WebView (not a separate sheet).
    /// MercariAutoPosterView watches this to reload the sell page and restart injection.
    @Published var loginJustCompleted = false
    /// Fine-grained step label updated throughout injectFields — drives the posting pill bar.
    @Published var injectionStep: String = ""

    let webView: WKWebView
    private var hasDetectedSuccess = false
    /// Guards against re-entrant/duplicate autofill. SwiftUI can re-run the trigger (and the
    /// simulator's flaky WebContent process can reload the page), which previously fired several
    /// concurrent injection passes that fought over the same form — a carrier would save in one
    /// pass and be cleared by another. One run per page load; reset on an explicit reload/retry.
    private var hasStartedInjection = false

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
        hasStartedInjection = false
        status = .loading
        webView.load(URLRequest(url: URL(string: "https://www.mercari.com/sell/")!))
    }

    // Resets the injection guard so a resume pass can run without reloading the page.
    func prepareForResume() {
        hasDetectedSuccess = false
        hasStartedInjection = false
        status = .injecting
    }

    // Probes the current DOM to find out which steps are already complete.
    struct FormProbe {
        var formMounted: Bool      // all core fields exist in DOM
        var titleFilled: Bool
        var descFilled: Bool
        var priceFilled: Bool
        var uploadedPhotoCount: Int
        var hasPhotoError: Bool
        var shippingFullySet: Bool  // shipping field shows a carrier (category + carrier both done)
    }

    func probeFormState() async -> FormProbe {
        let js = """
        return (function() {
            var title = document.querySelector('input[data-testid="Title"]');
            var desc  = document.querySelector('textarea[data-testid="Description"]');
            var price = document.querySelector('input[data-testid="Price"]');
            var bodyText = document.body ? (document.body.innerText || '') : '';
            var hasPhotoError = bodyText.indexOf('Something wrong happened') !== -1;
            var photoCount = document.querySelectorAll('img[src^="blob:"]').length;
            var ship = document.querySelector('#sellShippingClassesInput, [data-testid="SelectShipping"]');
            var shipValue = ship ? (ship.value || '').trim() : '';
            var shippingFullySet = !!(shipValue
                && shipValue.indexOf('Add title') === -1
                && shipValue.indexOf('enable shipping') === -1
                && shipValue.length > 0);
            return JSON.stringify({
                formMounted:       !!(title && desc && price),
                titleFilled:       !!(title && title.value.trim().length > 0),
                descFilled:        !!(desc  && desc.value.trim().length  > 0),
                priceFilled:       !!(price && price.value.trim().length > 0),
                uploadedPhotoCount: photoCount,
                hasPhotoError:     hasPhotoError,
                shippingFullySet:  shippingFullySet
            });
        })();
        """
        guard let json = (try? await webView.callJS(js)) as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return FormProbe(formMounted: false, titleFilled: false, descFilled: false,
                                priceFilled: false, uploadedPhotoCount: 0,
                                hasPhotoError: false, shippingFullySet: false) }
        return FormProbe(
            formMounted:        dict["formMounted"]        as? Bool ?? false,
            titleFilled:        dict["titleFilled"]        as? Bool ?? false,
            descFilled:         dict["descFilled"]         as? Bool ?? false,
            priceFilled:        dict["priceFilled"]        as? Bool ?? false,
            uploadedPhotoCount: dict["uploadedPhotoCount"] as? Int  ?? 0,
            hasPhotoError:      dict["hasPhotoError"]      as? Bool ?? false,
            shippingFullySet:   dict["shippingFullySet"]   as? Bool ?? false
        )
    }

    // Resume from wherever the form is right now — only re-runs steps that look incomplete.
    func resumeInjection(
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
        buyerPaysShipping: Bool,
        preferences: ShippingPreferences
    ) async {
        guard !hasStartedInjection else { return }
        hasStartedInjection = true
        status = .injecting

        let probe = await probeFormState()

        // If the form isn't even in the DOM the page didn't load — fall back to a full reload.
        if !probe.formMounted {
            hasStartedInjection = false
            reloadSellPage()
            return
        }

        // Re-fill any core field that's missing (idempotent — React accepts repeated sets).
        if !probe.titleFilled || !probe.descFilled || !probe.priceFilled {
            injectionStep = "Re-filling fields…"
            let jsFields = """
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
                    el.dispatchEvent(new Event('input',  { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    return true;
                }
                var titleEl = document.querySelector('input[data-testid="Title"]');
                var descEl  = document.querySelector('textarea[data-testid="Description"]');
                var priceEl = document.querySelector('input[data-testid="Price"]');
                if (titleEl && !titleEl.value.trim()) { setReactInput(titleEl, title); titleEl.blur(); }
                if (descEl  && !descEl.value.trim())  { setReactInput(descEl,  description); descEl.blur(); }
                if (priceEl && !priceEl.value.trim()) { setReactInput(priceEl, price); priceEl.blur(); }
                var conditionMap = {
                    'new':'ConditionNew','newwithouttags':'ConditionLikeNew',
                    'likenew':'ConditionLikeNew','good':'ConditionGood',
                    'fair':'ConditionFair','poor':'ConditionPoor','forparts':'ConditionPoor'
                };
                var conditionTestId = conditionMap[condition.toLowerCase().replace(/[\\s_\\-]/g,'')] || 'ConditionGood';
                var conditionLabel = document.querySelector('[data-testid="' + conditionTestId + '"]');
                if (conditionLabel) { conditionLabel.click(); }
                return 'ok';
            """
            _ = try? await webView.callJS(jsFields, args: [
                "title": title, "description": description,
                "price": String(format: "%.0f", price), "condition": condition
            ])
        }

        // Retry photos if there's an upload error or no photos made it through.
        let needsPhotos = (probe.hasPhotoError || probe.uploadedPhotoCount == 0)
                          && !photoBase64Strings.isEmpty
        if needsPhotos {
            injectionStep = "Retrying photo upload…"
            var photosOK = false
            for attempt in 1...4 {
                let attachResult = await attachPhotos(photoBase64Strings)
                print("[MercariPostingState] Photo resume attempt \(attempt): \(attachResult)")
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !(await outstandingIssues().contains("photo-upload-error")) {
                    photosOK = true
                    break
                }
            }
            if !photosOK { print("[MercariPostingState] Photos still failing after resume retries") }
        }

        // Category + shipping — only run if not already set.
        if !probe.shippingFullySet {
            injectionStep = "Selecting category…"
            let categoryResult = await selectCategory(suggestedCategory: suggestedCategory)
            print("[MercariPostingState] Category resume: \(categoryResult)")
        }

        // Smart pricing (idempotent toggle).
        _ = await disableSmartPricing()

        // Brand (re-run: idempotent, confirms or sets the brand chip).
        let brandResult = await selectBrand(suggestedBrand: suggestedBrand)
        print("[MercariPostingState] Brand resume: \(brandResult)")

        // Shipping — only run if the carrier isn't set yet.
        if !probe.shippingFullySet {
            injectionStep = "Setting up shipping…"
            let shippingResult = await completeShipping(
                weightLbs: weightLbs, lengthIn: lengthIn,
                widthIn: widthIn, heightIn: heightIn,
                preferences: preferences
            )
            print("[MercariPostingState] Shipping resume: \(shippingResult)")
        }

        let _ = await selectShippingPayer(buyerPays: buyerPaysShipping)

        injectionStep = "Submitting…"
        var photoFailed = false
        for attempt in 0..<3 {
            photoFailed = await outstandingIssues().contains("photo-upload-error")
            if !photoFailed { break }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        if !photoFailed {
            let submitResult = await submitListing()
            print("[MercariPostingState] Submit resume: \(submitResult)")
            if submitResult.starts(with: "submitted") { latestSubmitResult = submitResult }
        } else {
            print("[MercariPostingState] Holding submit — photo upload still failing after resume")
        }

        Task { await pollForSuccessModal() }
        isListingComplete = await checkListingButtonEnabled()
        if status == .injecting { status = .waitingForCategory }
    }

    /// Accepts an already-posted Mercari listing (its ID was captured earlier or linked by hand)
    /// rather than posting again. Prevents duplicate listings.
    func acceptExisting(id: String) {
        hasStartedInjection = true   // block any injection attempt
        hasDetectedSuccess = true
        mercariItemId = id
        status = .success
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.hasDetectedSuccess else { return }
            let url = webView.url?.absoluteString ?? ""
            // A redirect to Mercari's login/auth page means the user isn't signed in — NOT a
            // successful listing. Without this guard the generic "navigated away from /sell/"
            // heuristic below mistook the login redirect for success, marked the item listed,
            // and auto-dismissed the login sheet before the user could sign in.
            let lower = url.lowercased()
            let isAuthRedirect = lower.contains("/login") || lower.contains("/signin")
                || lower.contains("/oauth") || lower.contains("auth") || lower.contains("identity")
            if url.contains("mercari.com") && isAuthRedirect {
                self.status = .loginRequired
                return
            }
            // User was on the login screen and successfully navigated to a non-auth Mercari page.
            // Signal the view to reload the sell page and restart injection rather than treating
            // this navigation as a successful listing submission.
            if self.status == .loginRequired && url.contains("mercari.com") {
                self.loginJustCompleted = true
                return
            }
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

    enum FormWaitResult { case ready, login, timedOut }

    /// Polls the live page for Mercari's sell-form title input, returning as soon as it mounts.
    /// Crucially, it tolerates `callAsyncJavaScript` throwing while the WebContent process is still
    /// cold-starting or the SPA is mid-hydration — those throws are treated as "not ready yet" and
    /// retried, rather than aborting the whole autofill (the bug that made the first post fail).
    private func waitForSellForm(timeout: TimeInterval) async -> FormWaitResult {
        let probe = """
        return (function() {
            if (document.querySelector('input[data-testid="Title"]')) { return 'form'; }
            var u = (location && location.href) ? location.href.toLowerCase() : '';
            if (u.indexOf('login') !== -1 || u.indexOf('signin') !== -1) { return 'login'; }
            return 'wait';
        })();
        """
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = (try? await webView.callJS(probe)) as? String
            if result == "form" { return .ready }
            if result == "login" { return .login }
            // nil (JS not ready yet) or "wait" → keep polling
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return .timedOut
    }

    /// Attaches the listing photos to Mercari's hidden file input as one DataTransfer set. Mercari
    /// uploads them asynchronously afterward, so the caller polls for success/error and re-calls
    /// this on failure.
    private func attachPhotos(_ base64Strings: [String]) async -> String {
        let js = """
        var fileInput = document.querySelector('input[data-testid="SellPhotoInput"]');
        if (!fileInput) { return 'no-file-input'; }
        if (!base64Photos || base64Photos.length === 0) { return 'no-photos'; }
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
            return 'attached-' + base64Photos.length;
        } catch (e) { return 'error:' + e.message; }
        """
        return (try? await webView.callJS(js, args: ["base64Photos": base64Strings])) as? String ?? "error"
    }

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
        buyerPaysShipping: Bool,
        preferences: ShippingPreferences
    ) async {
        // Run exactly one injection pass per page load. Without this, overlapping passes raced each
        // other on the form (e.g. carrier saved by one pass, reset by the next).
        guard !hasStartedInjection else {
            print("[MercariPostingState] injectFields skipped — a pass is already in progress")
            return
        }
        hasStartedInjection = true
        status = .injecting

        // Wait until the sell form is actually on the page before touching any field.
        //
        // The old approach waited for `webView.isLoading == false`, then ran a single JS poll.
        // Both are unreliable and caused the first cross-post of every session to fail:
        //  • Mercari is a React SPA that holds long-lived connections open, so `isLoading` often
        //    never settles to false — the 30s nav-wait just exhausted every time.
        //  • `callAsyncJavaScript` THROWS (it doesn't wait) when the main frame isn't ready yet.
        //    On the first post the WebContent process is cold-starting (~2.5s in your logs), so
        //    that single poll threw, returned "unknown", and injection ran against a blank page.
        //    The second post only worked because the process was already warm.
        // waitForSellForm polls the real form element and tolerates those early failures, so the
        // first post is now as reliable as the second.
        switch await waitForSellForm(timeout: 45) {
        case .login:
            status = .loginRequired
            return
        case .timedOut:
            status = .failed("Mercari's sell page didn't finish loading. Tap Retry to try again.")
            return
        case .ready:
            break
        }
        injectionStep = "Filling out form…"

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

            return 'OK'
                + ' | title:' + (titleEl ? (titleEl.value.length > 0 ? 'filled' : 'empty') : 'not-found')
                + ' | desc:' + (descEl ? (descEl.value.length > 0 ? 'filled' : 'empty') : 'not-found')
                + ' | price:' + (priceEl ? (priceEl.value.length > 0 ? 'filled' : 'empty') : 'not-found')
                + ' | condition:' + conditionTestId
                + ' | shipping:' + shippingStatus;
        """

        let args: [String: Any] = [
            "title": title,
            "description": description,
            "price": String(format: "%.0f", price),
            "condition": condition
        ]

        let result = (try? await webView.callJS(jsScript, args: args)) as? String
        print("[MercariPostingState] Injection: \(String(describing: result))")

        guard result?.starts(with: "OK") == true else {
            status = .failed(result ?? "Injection failed — page may not be loaded")
            return
        }
        // If every core field reports not-found, the React form hasn't mounted yet.
        // Don't proceed to category/brand/shipping — surface a recoverable error.
        let formNotMounted = result?.contains("title:not-found") == true
            && result?.contains("desc:not-found") == true
            && result?.contains("price:not-found") == true
        if formNotMounted {
            status = .failed("Mercari form didn't load in time — tap the reload button and try again")
            return
        }

        // 1b. Photos — Mercari uploads them asynchronously and intermittently fails with a
        //     "Something wrong happened" toast. Re-attaching almost always fixes it, so attach,
        //     wait for the upload to settle, and retry several times before giving up.
        if !photoBase64Strings.isEmpty {
            injectionStep = "Uploading photos…"
            var photosOK = false
            for attempt in 1...4 {
                let attachResult = await attachPhotos(photoBase64Strings)
                print("[MercariPostingState] Photos attempt \(attempt): \(attachResult)")
                // Let the async upload complete (or error). Larger sets take longer.
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !(await outstandingIssues().contains("photo-upload-error")) {
                    photosOK = true
                    break
                }
                print("[MercariPostingState] Photo upload errored — re-attaching")
            }
            if !photosOK { print("[MercariPostingState] Photos still failing after retries") }
        }

        // 2. Category — the hard gate. The shipping carrier field stays disabled
        //    ("Add title and category to enable shipping") until a category is set.
        //    Tier 1: Mercari's suggested categories. Tier 2: fuzzy-match the AI category
        //    against the live dropdowns. Tier 3: fall back to "Other".
        injectionStep = "Selecting category…"
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
        injectionStep = "Setting up shipping…"
        let shippingResult = await completeShipping(
            weightLbs: weightLbs, lengthIn: lengthIn, widthIn: widthIn, heightIn: heightIn,
            preferences: preferences
        )
        print("[MercariPostingState] Shipping: \(shippingResult)")

        // 5b. "Offer buyers free shipping?" — Yes (seller pays, the default) vs No (buyer pays).
        let payerResult = await selectShippingPayer(buyerPays: buyerPaysShipping)
        print("[MercariPostingState] ShippingPayer: \(payerResult)")

        // 5. Submit. Mercari disables its List button until the whole form validates, and
        //    submitListing() polls for that enabled state before clicking — so a missing category,
        //    carrier, title, or address can't produce a broken submission (the click waits, then
        //    reports 'list-btn:disabled'). We still hard-hold on async failures the button won't
        //    catch — a photo-upload error or a visible form error — leaving those for the user to
        //    finish by hand in the webview.
        // submitListing() polls for Mercari's List button to become *enabled* before clicking, so
        // unfinished validation (missing category/carrier/title/address) just prevents the click —
        // it can't produce a broken listing. That makes a hard pre-gate on validation text harmful:
        // a stale "Please select a shipping carrier" (which clears once React catches up after the
        // carrier saves) would needlessly hold a submittable listing. The only failure the button
        // wouldn't catch is a photo-upload error, so that's the sole hold — and it's re-checked,
        // because Mercari shows a transient "Something wrong happened" that resolves on upload retry.
        injectionStep = "Submitting…"
        var photoFailed = false
        for attempt in 0..<3 {
            photoFailed = await outstandingIssues().contains("photo-upload-error")
            if !photoFailed { break }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        if !photoFailed {
            let submitResult = await submitListing()
            print("[MercariPostingState] Submit: \(submitResult)")
            if submitResult.starts(with: "submitted") {
                latestSubmitResult = submitResult
            }
        } else {
            print("[MercariPostingState] Holding submit — photo upload failed after re-checks")
        }

        // Watch for the post-success screen regardless of whether WE clicked List. The user often
        // finishes by hand (e.g. after fixing photos the autofill missed), and that path needs to
        // capture the item ID too. Guarded by hasDetectedSuccess, so it's a no-op once detected.
        Task { await pollForSuccessModal() }

        // Poll once to set isListingComplete so the banner accurately reflects form state.
        // (The List button becomes enabled only after Mercari validates all required fields.)
        isListingComplete = await checkListingButtonEnabled()

        // The .success state is set either by pollForSuccessModal or the navigation delegate.
        // If we're still here, leave a "review & list" resting state rather than a hard failure —
        // the form is filled as far as we could take it, so the user finishes in the webview.
        if status == .injecting { status = .waitingForCategory }
    }

    /// Polls the DOM for Mercari's post-success modal ("Post another item" / "Share your listing").
    /// Mercari's React router does not navigate away from /sell/ after submission, so the
    /// navigation delegate never fires. This is the only reliable success signal.
    private func pollForSuccessModal() async {
        guard !hasDetectedSuccess else { return }
        let js = """
        return (function() {
            var buttons = document.querySelectorAll('button, a');
            for (var i = 0; i < buttons.length; i++) {
                var t = (buttons[i].textContent || '').trim().toLowerCase();
                if (t.indexOf('post another') !== -1 || t.indexOf('share your listing') !== -1) {
                    return 'success';
                }
            }
            // Also check for the success heading/toast text.
            var body = (document.body && document.body.innerText) || '';
            if (body.indexOf('Listed!') !== -1
                || body.indexOf('Your item has been listed') !== -1
                || body.indexOf('Your listing is live') !== -1
                || /your listing is live/i.test(body)) {
                return 'success';
            }
            return 'not-found';
        })();
        """
        // Up to ~4 minutes — long enough to cover the user manually finishing the listing by hand.
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !hasDetectedSuccess else { return }
            let result = (try? await webView.callJS(js)) as? String ?? "not-found"
            if result == "success" {
                hasDetectedSuccess = true
                // Capture the Mercari item ID *before* flipping to .success, so updateFirestore()
                // (which fires on the .success change) persists it. Without this the ID was almost
                // never saved — the navigation delegate it used to rely on doesn't fire on the SPA.
                if mercariItemId == nil {
                    mercariItemId = await extractMercariItemId()
                }
                print("[MercariPostingState] Success modal detected, itemId=\(mercariItemId ?? "nil")")
                status = .success
                return
            }
        }
        print("[MercariPostingState] Success poll ended — success screen not detected")
    }

    /// Extracts the Mercari item ID (e.g. "m1234567890") from the post-success screen. First scrapes
    /// any item link / share-URL already on the page; if none is present, opens "Share your listing"
    /// (which surfaces the listing URL) and re-scrapes. Non-destructive scrape is tried first so we
    /// only pop the share sheet when we have to.
    private func extractMercariItemId() async -> String? {
        let js = #"""
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
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        function findId() {
            var re = /\/item\/(m[A-Za-z0-9]+)/;
            var links = document.querySelectorAll('a[href*="/item/"]');
            for (var i = 0; i < links.length; i++) {
                var m = (links[i].getAttribute('href') || '').match(re);
                if (m) return m[1];
            }
            var fields = document.querySelectorAll('input, textarea');
            for (var j = 0; j < fields.length; j++) {
                var m2 = (fields[j].value || '').match(re);
                if (m2) return m2[1];
            }
            var body = (document.body && document.body.innerText) || '';
            var m3 = body.match(re);
            if (m3) return m3[1];
            return null;
        }
        return (async function() {
            var id = findId();
            if (id) return id;
            var btns = document.querySelectorAll('button, a');
            for (var i = 0; i < btns.length; i++) {
                var t = (btns[i].textContent || '').trim().toLowerCase();
                if (t.indexOf('share your listing') !== -1 || t === 'share') { realClick(btns[i]); break; }
            }
            await waitFor(findId, 4000);
            return findId();
        })();
        """#
        return (try? await webView.callJS(js)) as? String
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
            var toggle = await waitFor(findToggle, 8000);
            if (!toggle) { return 'not-found'; }
            if (!isOn(toggle)) { return 'was-off'; }
            var target = toggle.tagName === 'INPUT'
                ? (document.querySelector('label[for="' + toggle.id + '"]') || toggle.closest('label') || toggle)
                : toggle;
            // Retry the toggle a few times — the click sometimes lands before React wires it up.
            for (var attempt = 0; attempt < 3; attempt++) {
                realClick(target);
                toggle.dispatchEvent(new Event('change', { bubbles: true }));
                // Mercari shows a "Turn off Smart Pricing?" confirmation dialog — dismiss it.
                var confirmBtn = await waitFor(function() {
                    var bs = document.querySelectorAll('[role="dialog"] button, [role="alertdialog"] button');
                    for (var i = 0; i < bs.length; i++) {
                        var t = bs[i].textContent.trim().toLowerCase();
                        if ((t === 'turn off' || t === 'confirm' || t === 'ok' || t === 'yes') && !bs[i].disabled) {
                            return bs[i];
                        }
                    }
                    return null;
                }, 1500);
                if (confirmBtn) { realClick(confirmBtn); }
                var off = await waitFor(function() { return isOn(toggle) ? null : 'off'; }, 2000);
                if (off) { return 'disabled'; }
            }
            return 'still-on';
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
            // Wait specifically for the SERVER-SUGGESTED brand chips. They're generated from the
            // title + photos and appear a beat after the rest of the brand UI, so waiting for "any
            // brand UI" (search box / no-brand link) used to resolve early and wrongly pick "No
            // brand". Give the suggestions a real window — they only show once photos finish.
            var suggested = await waitFor(function() {
                return document.querySelector('[data-testid="SuggestedBrandSection"]');
            }, 12000);

            // Tier 1: Mercari's server-suggested brand chips.
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

    /// Sets Mercari's "Offer buyers free shipping?" dropdown to match the seller's preference:
    /// free shipping = "Yes (Recommended)" (seller pays, the default), buyer-pays = "No".
    /// Opens the custom listbox (a div, not a native <select>) and clicks the option by testid.
    private func selectShippingPayer(buyerPays: Bool) async -> String {
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
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        return (async function() {
            // The trigger and the options <ul> share data-testid="ShippingPayerOption"; the trigger
            // is the one with aria-haspopup="listbox".
            var trigger = document.querySelector('[data-testid="ShippingPayerOption"][aria-haspopup="listbox"]')
                || document.querySelector('#ShippingPayerOption[aria-haspopup="listbox"]');
            if (!trigger) { return 'payer-field-not-found'; }
            var currentlyNo = (trigger.textContent || '').trim().toLowerCase() === 'no';
            if (buyerPays && currentlyNo) { return 'already-buyer-pays'; }
            if (!buyerPays && !currentlyNo) { return 'already-free'; }
            realClick(trigger);
            var wantTestId = buyerPays ? 'FreeShippingNoButton' : 'FreeShippingYesButton';
            var option = await waitFor(function() {
                return document.querySelector('[data-testid="' + wantTestId + '"]');
            }, 3000);
            if (!option) { return 'option-not-found'; }
            realClick(option);
            return buyerPays ? 'set-buyer-pays' : 'set-free';
        })();
        """
        return (try? await webView.callJS(js, args: ["buyerPays": buyerPays])) as? String ?? "error:payer"
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
            var radio = await waitFor(function() {
                return document.querySelector('input[type="radio"][value="' + targetValue + '"]');
            }, 4000);
            if (!radio) { return 'radio-not-found'; }
            var label = document.querySelector('label[for="' + radio.id + '"]') || radio.closest('label') || radio;
            // Retry the selection until the radio actually registers as checked.
            for (var a = 0; a < 3 && !radio.checked; a++) {
                realClick(label);
                radio.dispatchEvent(new Event('change', { bubbles: true }));
                await waitFor(function() { return radio.checked ? 'y' : null; }, 1000);
            }
            var save = await waitFor(function() {
                return document.querySelector('[data-testid="SelectCarrierSaveButton"]');
            }, 4000);
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
    var onDismiss: () -> Void = {}
    @StateObject private var state = MercariPostingState()
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
    @State private var showCloseWithoutIdConfirm = false

    // Pill is always visible; isExpanded drives a fullScreenCover for the live WebView.
    @State private var isExpanded = false

    // True when the user must see and interact with the live Mercari page.
    // loginRequired is included so anti-bot checks and the login form are always visible
    // rather than hidden behind a headless overlay.
    private var requiresUserInteraction: Bool {
        switch state.status {
        case .waitingForCategory, .failed, .loginRequired: return true
        default: return false
        }
    }

    // Step label shown in the compact pill. Falls back to status-based text before injection starts.
    private var pillStepText: String {
        if !state.injectionStep.isEmpty { return state.injectionStep }
        switch state.status {
        case .loading:            return "Connecting to Mercari…"
        case .injecting:          return "Posting your listing…"
        case .waitingForCategory: return "Review needed"
        case .loginRequired:      return "Login required"
        case .failed:             return "Something went wrong"
        case .success:            return "Listed on Mercari!"
        }
    }

    // MARK: Pill view (compact non-blocking mode)

    private var pillView: some View {
        HStack(spacing: 12) {
            if state.status == .success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                                   value: state.injectionStep)
                }
                .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(pillStepText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(job.title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(red: 0.1, green: 0.0, blue: 0.35).opacity(0.85)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    var body: some View {
        // Pill is always shown inline (via safeAreaInset in ProfileView) — sits above the tab bar.
        // The WebView runs headlessly behind it. isExpanded drives a fullScreenCover for the
        // live editing experience when user interaction is required.
        pillView
            .background(
                Group {
                    if !isExpanded {
                        MercariSheetWebView(webView: state.webView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(0.01)
                            .allowsHitTesting(false)
                    }
                }
            )
            .fullScreenCover(isPresented: $isExpanded) {
                NavigationStack {
                    ZStack(alignment: .top) {
                        MercariSheetWebView(webView: state.webView)

                        if requiresUserInteraction {
                            VStack(spacing: 0) {
                                statusBanner
                                if let warning = state.warning {
                                    warningBanner(warning)
                                }
                            }
                        } else if state.status == .success {
                            VStack(spacing: 20) {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 52)).foregroundStyle(.green)
                                Text("Listed on Mercari!")
                                    .font(.title2.weight(.semibold))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemBackground))
                        }
                    }
                    .navigationTitle("Post to Mercari")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                if state.mercariItemId?.isEmpty == false {
                                    isExpanded = false
                                    onDismiss()
                                } else {
                                    showCloseWithoutIdConfirm = true
                                }
                            }
                        }
                        if !requiresUserInteraction && state.status != .success {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        isExpanded = false
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "Close without confirming listing?",
                    isPresented: $showCloseWithoutIdConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Close anyway", role: .destructive) { isExpanded = false; onDismiss() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The listing may not have been created on Mercari. Close anyway and manually verify?")
                }
            }
            .sheet(isPresented: $showPrefSetup) {
                NavigationStack {
                    MercariShippingPreferencesView(isFirstTimeSetup: true, onSaved: {
                        Task { await fetchPhotosAndInject() }
                    })
                }
                .interactiveDismissDisabled(true)
            }
            .task { await loadPreferencesThenStart() }
            .onChange(of: state.status) { _, newStatus in
                switch newStatus {
                case .success:
                    Task {
                        await updateFirestore()
                        guard state.mercariItemId?.isEmpty == false else {
                            await MainActor.run { state.status = .failed("Listing ID not confirmed — verify on Mercari") }
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            isExpanded = false
                            onDismiss()
                        }
                    }
                default: break
                }
            }
            .onChange(of: requiresUserInteraction) { _, needs in
                guard needs, !isExpanded else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }
            .onChange(of: state.loginJustCompleted) { _, completed in
                guard completed else { return }
                state.loginJustCompleted = false
                hasInjected = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = false
                }
                state.reloadSellPage()
                Task { await fetchPhotosAndInject() }
            }
            .onChange(of: state.latestSubmitResult) { _, result in
                guard result != nil else { return }
                Task {
                    await writeMercariPending()
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard state.status != .success else { return }
                    await updateFirestore()
                    if state.mercariItemId?.isEmpty != false {
                        await MainActor.run {
                            state.injectionStep = ""
                            state.status = .failed("Submission not confirmed — verify your listing on Mercari")
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isExpanded = true
                            }
                        }
                    } else {
                        isExpanded = false
                        onDismiss()
                    }
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
        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autofill couldn't finish").font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Retry") {
                    hasInjected = false
                    state.prepareForResume()
                    Task { await fetchPhotosAndResume() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
        case .loginRequired:
            HStack(spacing: 10) {
                Image(systemName: "lock.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log in to Mercari below")
                        .font(.subheadline.weight(.semibold))
                    Text("Complete any verification, then autofill resumes automatically")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
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
        // If this listing already has a Mercari ID (captured earlier, or linked by hand), it's
        // already live — accept it instead of posting a duplicate.
        if let listingId = job.listingId,
           let doc = try? await Firestore.firestore().collection("listings").document(listingId).getDocument(),
           let existingId = (doc.data()?["crossPostListingIds"] as? [String: String])?["mercari"],
           !existingId.isEmpty {
            print("[MercariAutoPosterView] Listing already on Mercari (\(existingId)) — accepting, not re-posting")
            state.acceptExisting(id: existingId)
            return
        }

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
            buyerPaysShipping: job.buyerPaysShipping,
            preferences: preferences
        )
    }

    // Same photo-fetch as fetchPhotosAndInject, but calls resumeInjection instead of injectFields.
    // Used by Retry so the page isn't reloaded when only a mid-injection step failed.
    private func fetchPhotosAndResume() async {
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

        await state.resumeInjection(
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
            buyerPaysShipping: job.buyerPaysShipping,
            preferences: preferences
        )
    }

    private func updateFirestore() async {
        guard let listingId = job.listingId else { return }
        // Only mark Mercari as "posted" when we actually captured a valid listing ID/URL.
        // Without one we can't prove the item went live, and a false "posted" both lies to the
        // user and blocks re-posting. Leave the status as "pending" so the user can retry.
        guard let mercariId = state.mercariItemId, !mercariId.isEmpty else {
            print("[MercariAutoPosterView] No Mercari item ID captured — not marking posted")
            return
        }
        let update: [String: Any] = [
            "crossPostStatus.mercari": "posted",
            "crossPostListingIds.mercari": mercariId,
            "updatedAt": Timestamp(date: Date())
        ]
        try? await Firestore.firestore().collection("listings").document(listingId).updateData(update)
        print("[MercariAutoPosterView] Firestore updated for listing \(listingId) with Mercari ID \(mercariId)")
    }

    /// Writes "pending" to Firestore as soon as the List button click succeeds.
    /// Mercari uses React Router so the navigation delegate may never fire after submission —
    /// this ensures the badge appears even when URL-change detection is unreliable.
    private func writeMercariPending() async {
        guard let listingId = job.listingId else { return }
        // Store start time locally so the timeout check (EditListingSheet) needs zero extra reads.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "mercariPendingStart_\(listingId)")
        // Don't overwrite a confirmed "posted" status that arrived first.
        try? await Firestore.firestore().collection("listings").document(listingId).updateData([
            "crossPostStatus.mercari": "pending",
            "updatedAt": Timestamp(date: Date())
        ])
        print("[MercariAutoPosterView] Wrote mercari=pending for listing \(listingId)")
    }
}

/// Renders an existing WKWebView in a SwiftUI view hierarchy without triggering a reload.
struct MercariSheetWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - MercariListingEditSheet

/// Opens the seller's existing Mercari listing page in a web view so they can tap Edit and
/// update it. Provides clipboard access to the current Wonni values as a reference.
struct MercariListingEditSheet: View {
    let url: URL
    let title: String
    let description: String
    let price: Double
    @Environment(\.dismiss) private var dismiss

    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        return wv
    }()
    @State private var showClipboardNotification = false
    @State private var notificationText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Title").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(title).font(.subheadline).lineLimit(1)
                        }
                        .onTapGesture { copyToClipboard(title, label: "Title") }

                        Divider().frame(height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Price").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(String(format: "$%.2f", price)).font(.subheadline.weight(.semibold))
                        }
                        .onTapGesture { copyToClipboard(String(format: "%.0f", price), label: "Price") }

                        Divider().frame(height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Description").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(description).font(.subheadline).lineLimit(1)
                        }
                        .onTapGesture { copyToClipboard(description, label: "Description") }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)

                    CrossPostWebView(url: url, webView: webView)
                }

                if showClipboardNotification {
                    VStack {
                        Text(notificationText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 8).padding(.horizontal, 16)
                            .background(Color.black.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(.top, 20)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("Update Mercari Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { webView.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func copyToClipboard(_ text: String, label: String) {
        UIPasteboard.general.string = text
        notificationText = "Copied \(label)!"
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { showClipboardNotification = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showClipboardNotification = false }
        }
    }
}

// MARK: - Mercari Sync (Level 1)



/// Sync Level 1 UI: pulls the Mercari item's current price/availability, diffs it against the
/// Wonni listing, and offers to apply the changes. Declining just closes — the diff is shown again
/// on the next sync. (eBay revise/end from a sync is a follow-up.)
struct MercariSyncSheet: View {
    let listing: UserListing
    let mercariId: String
    /// Called after a successful Firestore update so the parent can reload.
    var onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = MercariItemLoader()
    @State private var applyError: String?
    @State private var isApplying = false

    @State private var applyPrice = true
    @State private var applyTitle = false
    @State private var applyDescription = false

    private var listingPrice: Double { listing.price ?? 0 }
    private var priceDiffers: Bool {
        guard let m = loader.priceDollars else { return false }
        return abs(m - listingPrice) >= 0.01
    }
    private var soldDiffers: Bool { loader.isSold && listing.status != .sold }
    private var titleDiffers: Bool {
        guard let m = loader.name, !m.isEmpty else { return false }
        return m != listing.customTitle
    }
    private var descriptionDiffers: Bool {
        guard let m = loader.descriptionText, !m.isEmpty else { return false }
        return m != listing.customDescription
    }
    private var hasChanges: Bool { priceDiffers || soldDiffers || titleDiffers || descriptionDiffers }


    var body: some View {
        NavigationStack {
            Group {
                switch loader.phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your Mercari listing…").foregroundStyle(.secondary)
                    }
                case .failed:
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text("Couldn't read the Mercari listing.").font(.headline)
                        Text("It may be private, removed, or need you to be logged into Mercari.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let url = URL(string: "https://www.mercari.com/us/item/\(mercariId)/") {
                            Link("Open on Mercari", destination: url)
                        }
                    }
                    .padding()
                case .loaded:
                    if loader.statusRaw == "inactive" {
                        inactiveView
                    } else {
                        resultList
                    }
                }
            }
            .navigationTitle("Sync from Mercari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            // Full-frame background so iOS doesn't throttle JS on the webview.
            // A 1×1 frame is treated as off-screen and pauses callAsyncJavaScript.
            .background(
                MercariSheetWebView(webView: loader.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            )
        }
        .task { await loader.load(itemId: mercariId) }
    }

    @ViewBuilder private var resultList: some View {
        List {
            Section("Price") {
                row(label: "Wonni", value: money(listingPrice))
                row(label: "Mercari", value: loader.priceDollars.map(money) ?? "—", highlight: priceDiffers)
                if priceDiffers {
                    Toggle("Update Price", isOn: $applyPrice)
                }
            }
            Section("Availability") {
                row(label: "Wonni", value: listing.status == .sold ? "Sold" : "Active")
                row(label: "Mercari", value: loader.isSold ? "Sold" : "Active", highlight: soldDiffers)
            }
            if titleDiffers {
                Section("Title") {
                    row(label: "Wonni", value: listing.customTitle ?? "—")
                    row(label: "Mercari", value: loader.name ?? "—", highlight: true)
                    Toggle("Update Title", isOn: $applyTitle)
                }
            }
            if descriptionDiffers {
                Section("Description") {
                    row(label: "Wonni", value: String((listing.customDescription ?? "—").prefix(80)))
                    row(label: "Mercari", value: String((loader.descriptionText ?? "—").prefix(80)), highlight: true)
                    Toggle("Update Description", isOn: $applyDescription)
                }
            }
            Section {
                if hasChanges {
                    Button {
                        Task { await apply() }
                    } label: {
                        HStack {
                            if isApplying { ProgressView() }
                            Text("Update listing with Mercari changes").fontWeight(.semibold)
                        }
                    }
                    .disabled(isApplying)
                } else {
                    Label("Wonni already matches Mercari", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let err = applyError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                if hasChanges {
                    Text("Changes will be applied to Wonni and cascaded to eBay automatically.")
                }
            }
        }
    }

    private func row(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(highlight ? .orange : .primary)
                .fontWeight(highlight ? .semibold : .regular)
        }
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    // Shown when Mercari serves the "no longer for sale" page — the listing was deactivated or
    // sold there. The action depends on why: a pending-deactivation listing just needs the stale
    // reminder cleared; an otherwise-active listing can be marked sold out across platforms.
    @ViewBuilder private var inactiveView: some View {
        VStack(spacing: 16) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("No longer active on Mercari").font(.headline)
            if listing.pendingMercariDeactivation == true {
                Text("This sold on another platform and you'd been asked to deactivate it on Mercari. It's now inactive — you're all set.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Task { await markHandled() } } label: {
                    HStack { if isApplying { ProgressView() }; Text("Mark as handled") }
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(isApplying)
            } else if listing.status != .sold {
                Text("This listing is inactive on Mercari but still active on Wonni. If it sold, mark it sold out to end it everywhere.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Task { await markSoldOut() } } label: {
                    HStack { if isApplying { ProgressView() }; Text("Mark sold out in Wonni") }
                        .fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).disabled(isApplying)
            } else {
                Text("Already sold out in Wonni — nothing to do.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let url = URL(string: "https://www.mercari.com/us/item/\(mercariId)/") {
                Link("Open on Mercari", destination: url).font(.subheadline)
            }
            if let err = applyError { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Clears the stale "deactivate on Mercari" reminder once Mercari confirms the item is inactive.
    private func markHandled() async {
        guard let listingId = listing.id else { return }
        isApplying = true; applyError = nil
        do {
            try await Firestore.firestore().collection("listings").document(listingId)
                .updateData(["pendingMercariDeactivation": FieldValue.delete(),
                             "updatedAt": Timestamp(date: Date())])
            onApplied()
            dismiss()
        } catch { applyError = "Couldn't update the listing. Try again." }
        isApplying = false
    }

    // Marks an otherwise-active listing sold out and cascades qty=0 to eBay/Etsy.
    private func markSoldOut() async {
        guard let listingId = listing.id else { return }
        isApplying = true; applyError = nil
        do {
            _ = try await callCloudFunction("markSoldOutAndCascade", ["listingId": listingId])
            // markSoldOutAndCascade re-flags Mercari for deactivation, but Mercari is already
            // inactive here, so clear that flag to avoid a phantom "Action needed" entry.
            try? await Firestore.firestore().collection("listings").document(listingId)
                .updateData(["pendingMercariDeactivation": FieldValue.delete()])
            onApplied()
            dismiss()
        } catch { applyError = "Couldn't mark sold out. Try again." }
        isApplying = false
    }

    private func apply() async {
        guard let listingId = listing.id else { return }
        isApplying = true
        applyError = nil
        var update: [String: Any] = ["updatedAt": Timestamp(date: Date())]
        if priceDiffers && applyPrice, let m = loader.priceDollars { update["price"] = m }
        if titleDiffers && applyTitle, let t = loader.name { update["customTitle"] = t }
        if descriptionDiffers && applyDescription, let d = loader.descriptionText { update["customDescription"] = d }
        do {
            try await Firestore.firestore().collection("listings").document(listingId).updateData(update)
            // Cascade any field changes to eBay in one call
            let anyFieldChanged = priceDiffers || titleDiffers || descriptionDiffers
            if anyFieldChanged && listing.crossPostStatus?["ebay"] == "posted" {
                Task { _ = try? await callCloudFunction("ebayUpdateListing", ["listingId": listingId]) }
            }
            if soldDiffers {
                // Record the sale — take-home will be backfilled async by the transaction loader
                let sale = Sale(
                    userId: "",
                    listingId: listingId,
                    listingTitle: listing.customTitle,
                    coverPhotoPath: listing.coverPhotoPath,
                    platform: "mercari",
                    platformOrderId: mercariId,
                    priceSoldFor: loader.priceDollars ?? listing.price ?? 0,
                    takeHome: nil,
                    status: .pending,
                    soldAt: Timestamp(date: Date())
                )
                let saleId = try? await SaleRepository.shared.recordSale(sale)

                // Cascade quantity decrement
                _ = try? await callCloudFunction("decrementAndCascade", [
                    "listingId": listingId,
                    "platform": "mercari"
                ])

                // Async: scrape take-home from the Mercari transaction page and backfill
                if let sid = saleId {
                    Task {
                        await fetchAndBackfillMercariTakeHome(saleId: sid, mercariId: mercariId)
                    }
                }
            } else if loader.isSold && listing.pendingMercariDeactivation == true {
                // Mercari is already sold and there's a stale deactivation flag — the listing sold
                // ON Mercari (not elsewhere), so clear the flag and cascade eBay if still posted.
                try? await Firestore.firestore().collection("listings").document(listingId)
                    .updateData(["pendingMercariDeactivation": FieldValue.delete(),
                                 "updatedAt": Timestamp(date: Date())])
                if listing.crossPostStatus?["ebay"] == "posted" {
                    _ = try? await callCloudFunction("decrementAndCascade", [
                        "listingId": listingId,
                        "platform": "mercari"
                    ])
                }
            }
            onApplied()
            dismiss()
        } catch {
            applyError = "Couldn't update the listing. Try again."
        }
        isApplying = false
    }

    // Loads the Mercari transaction/order_status page and backfills takeHome + tracking on the Sale.
    private func fetchAndBackfillMercariTakeHome(saleId: String, mercariId: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MercariTakeHomeScraper(mercariId: mercariId) { data in
                    Task {
                        var update: [String: Any] = ["updatedAt": Timestamp(date: Date())]
                        if let th = data.takeHome { update["takeHome"] = th }
                        if let tn = data.trackingNumber { update["trackingNumber"] = tn }
                        if let c = data.carrier { update["carrier"] = c }
                        try? await SaleRepository.shared.updateSale(id: saleId, data: update)
                        continuation.resume()
                    }
                } onFail: {
                    continuation.resume()
                }.start()
            }
        }
    }
}

// MARK: - MercariProfileSyncSheet

/// Shown from the Profile tab when the user wants to check or act on all their Mercari-linked
/// listings in one place. Listings with pending Cloud Function flags appear at the top.
struct MercariProfileSyncSheet: View {
    var onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var syncManager: MercariSyncManager
    
    @State private var listings: [UserListing] = []
    @State private var isLoading = true
    @State private var listingToSync: UserListing?
    @State private var listingToDeactivate: UserListing?
    @State private var listingToRelist: CrossPostJob?
    @State private var deactivateSelectMode = false
    @State private var selectedDeactivateIds: Set<String> = []

    private var pendingListings: [UserListing] {
        listings.filter { $0.pendingMercariDeactivation == true || $0.pendingMercariRelist == true }
    }
    private var normalListings: [UserListing] {
        listings.filter { $0.pendingMercariDeactivation != true && $0.pendingMercariRelist != true }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listings.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No Mercari-linked listings").font(.headline)
                        Text("Cross-post a listing to Mercari first, then come back here to sync.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !pendingListings.isEmpty {
                            Section {
                                ForEach(pendingListings) { listing in
                                    pendingRow(listing)
                                }
                                if deactivateSelectMode && !selectedDeactivateIds.isEmpty {
                                    Button {
                                        Task {
                                            for id in selectedDeactivateIds {
                                                await clearFlag("pendingMercariDeactivation", for: id)
                                            }
                                            selectedDeactivateIds = []
                                            deactivateSelectMode = false
                                            onComplete()
                                        }
                                    } label: {
                                        Label("Mark \(selectedDeactivateIds.count) as Handled", systemImage: "checkmark.circle.fill")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                    .listRowBackground(Color.clear)
                                }
                            } header: {
                                HStack {
                                    Label("Action needed", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).textCase(nil)
                                    Spacer()
                                    if deactivateSelectMode {
                                        Button("Cancel") {
                                            deactivateSelectMode = false
                                            selectedDeactivateIds = []
                                        }
                                        .font(.caption).foregroundStyle(.orange)
                                    } else {
                                        Button("Select") { deactivateSelectMode = true }
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        Section("All Mercari listings (\(normalListings.count))") {
                            ForEach(normalListings) { listing in
                                Button {
                                    listingToSync = listing
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(listing.customTitle ?? "Untitled")
                                                .font(.subheadline).lineLimit(1)
                                            if let price = listing.price {
                                                Text(String(format: "$%.2f", price))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mercari Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if syncManager.isPillVisible || isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Sync All") {
                            let toSync = normalListings + pendingListings
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                syncManager.startSyncAll(listings: toSync, onComplete: onComplete)
                                syncManager.showProgressSheet = true
                            }
                        }
                        .disabled(normalListings.isEmpty)
                    }
                }
            }
            .sheet(item: $listingToSync) { listing in
                if let id = listing.crossPostListingIds?["mercari"] {
                    MercariSyncSheet(listing: listing, mercariId: id) {
                        Task { await reload() }
                        onComplete()
                    }
                }
            }
            .sheet(item: $listingToDeactivate) { listing in
                if let id = listing.crossPostListingIds?["mercari"],
                   let url = URL(string: "https://www.mercari.com/us/item/\(id)/") {
                    MercariDeactivateActionSheet(
                        listing: listing, url: url,
                        onHandled: {
                            Task {
                                await clearFlag("pendingMercariDeactivation", for: listing.id ?? "")
                                onComplete()
                            }
                        }
                    )
                }
            }
            .sheet(item: $listingToRelist) { job in
                MercariAutoPosterView(job: job)
                    .onDisappear {
                        Task {
                            if let id = job.listingId {
                                await clearFlag("pendingMercariRelist", for: id)
                                onComplete()
                            }
                            await reload()
                        }
                    }
            }
        }
        .task { await reload() }
    }



    @ViewBuilder private func pendingRow(_ listing: UserListing) -> some View {
        let isDeactivate = listing.pendingMercariDeactivation == true
        let listingId = listing.id ?? ""
        let isSelected = selectedDeactivateIds.contains(listingId)
        HStack(alignment: .top, spacing: 10) {
            if deactivateSelectMode && isDeactivate {
                Button {
                    if isSelected { selectedDeactivateIds.remove(listingId) }
                    else { selectedDeactivateIds.insert(listingId) }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(isSelected ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            // Photo thumbnail
            Group {
                if let path = listing.photoPaths.first ?? listing.coverPhotoPath {
                    StorageImage(path: path).frame(width: 52, height: 52).cornerRadius(8)
                } else {
                    Color(.systemGray5).frame(width: 52, height: 52).cornerRadius(8)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listing.customTitle ?? "Untitled")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let price = listing.price {
                            Text(String(format: "$%.2f", price))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Label(
                        isDeactivate ? "Deactivate needed" : "Re-list needed",
                        systemImage: isDeactivate ? "minus.circle.fill" : "arrow.up.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDeactivate ? .red : .blue)
                    .labelStyle(.iconOnly)
                }
                if isDeactivate {
                    Text("Sold elsewhere (qty=0). Deactivate on Mercari.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !deactivateSelectMode {
                        Button {
                            listingToDeactivate = listing
                        } label: {
                            Label("Deactivate on Mercari", systemImage: "minus.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                } else {
                    Text("Sold on Mercari. Re-list since you still have stock.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        listingToRelist = CrossPostJob(
                            platform: "mercari",
                            title: listing.customTitle ?? "",
                            description: listing.customDescription ?? "",
                            price: listing.price ?? 0,
                            listingId: listing.id,
                            photoFirebasePaths: listing.photoPaths,
                            buyerPaysShipping: listing.shippingInfo?.buyerPaysShipping ?? false
                        )
                    } label: {
                        Label("Re-list on Mercari", systemImage: "arrow.up.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if deactivateSelectMode && isDeactivate {
                if isSelected { selectedDeactivateIds.remove(listingId) }
                else { selectedDeactivateIds.insert(listingId) }
            }
        }
    }

    private func reload() async {
        isLoading = true
        guard let userId = Auth.auth().currentUser?.uid else { isLoading = false; return }
        let db = Firestore.firestore()
        // Fetch all user listings that have a Mercari cross-post ID or a pending Mercari flag
        let snap = try? await db.collection("listings")
            .whereField("userId", isEqualTo: userId)
            .getDocuments()
        let all = snap?.documents.compactMap { try? $0.data(as: UserListing.self) } ?? []
        listings = all
            .filter { $0.crossPostListingIds?["mercari"] != nil }
            .sorted { ($0.updatedAt?.dateValue() ?? .distantPast) > ($1.updatedAt?.dateValue() ?? .distantPast) }
        isLoading = false
    }

    private func clearFlag(_ flag: String, for listingId: String) async {
        guard !listingId.isEmpty else { return }
        try? await Firestore.firestore().collection("listings").document(listingId)
            .updateData([flag: FieldValue.delete()])
        await reload()
    }
}

/// Presents the Mercari listing in a web view with a "Mark as handled" toolbar button.
/// The user manually deactivates/marks the item as sold on Mercari, then confirms.

// ─────────────────────────────────────────────────────────────
// MercariTransactionData
// ─────────────────────────────────────────────────────────────

struct MercariTransactionData {
    let takeHome: Double?
    let trackingNumber: String?
    let carrier: String?
}

// ─────────────────────────────────────────────────────────────
// MercariTransactionLoader
// Loads the Mercari transaction page for a listing and extracts
// the "You made" take-home value and optional shipping tracking info.
// ─────────────────────────────────────────────────────────────

struct MercariTransactionLoader: UIViewRepresentable {
    let mercariId: String
    var onDataFound: (MercariTransactionData) -> Void
    var onError: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator
        wv.isHidden = true
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        guard context.coordinator.mercariId != mercariId else { return }
        context.coordinator.mercariId = mercariId
        let url = URL(string: "https://www.mercari.com/transaction/order_status/\(mercariId)")!
        wv.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDataFound: onDataFound, onError: onError)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var mercariId: String = ""
        var onDataFound: (MercariTransactionData) -> Void
        var onError: ((String) -> Void)?
        private var phase: Phase = .transactionPage
        private var pendingTakeHome: Double?
        private var extracted = false

        enum Phase { case transactionPage, trackingPage }

        init(onDataFound: @escaping (MercariTransactionData) -> Void, onError: ((String) -> Void)?) {
            self.onDataFound = onDataFound
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !extracted else { return }
            switch phase {
            case .transactionPage:
                extractTransactionData(webView: webView, attempt: 0)
            case .trackingPage:
                extractTrackingData(webView: webView, attempt: 0)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError?("Failed to load Mercari page: \(error.localizedDescription)")
        }

        private func extractTransactionData(webView: WKWebView, attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                guard let self, let webView, !self.extracted else { return }
                let js = """
                    (function() {
                        var el = document.querySelector('[data-testid="You-made-value"]');
                        var takeHome = el ? el.textContent : null;
                        var btn = document.querySelector('[data-testid="ShippingCTAButton"]');
                        var trackingHref = btn ? btn.getAttribute('href') : null;
                        return { takeHome: takeHome, trackingHref: trackingHref };
                    })()
                    """
                webView.evaluateJavaScript(js) { [weak self, weak webView] result, _ in
                    guard let self, let webView else { return }
                    var takeHome: Double? = nil
                    var trackingHref: String? = nil
                    if let dict = result as? [String: Any] {
                        if let text = dict["takeHome"] as? String {
                            let cleaned = text.trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: "$", with: "")
                                .replacingOccurrences(of: ",", with: "")
                            takeHome = Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
                        }
                        trackingHref = dict["trackingHref"] as? String
                    }
                    if takeHome != nil || trackingHref != nil {
                        self.pendingTakeHome = takeHome
                        if let href = trackingHref, let url = URL(string: href.hasPrefix("http") ? href : "https://www.mercari.com\(href)") {
                            self.phase = .trackingPage
                            webView.load(URLRequest(url: url))
                        } else {
                            self.extracted = true
                            self.onDataFound(MercariTransactionData(takeHome: takeHome, trackingNumber: nil, carrier: nil))
                        }
                    } else if attempt < 1 {
                        self.extractTransactionData(webView: webView, attempt: attempt + 1)
                    } else {
                        self.onError?("Could not find transaction data on Mercari page.")
                    }
                }
            }
        }

        private func extractTrackingData(webView: WKWebView, attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak webView] in
                guard let self, let webView, !self.extracted else { return }
                webView.evaluateJavaScript(MercariTakeHomeScraper.trackingPageJS) { [weak self] result, _ in
                    guard let self else { return }
                    var trackingNumber: String? = nil
                    var carrier: String? = nil
                    if let dict = result as? [String: Any] {
                        trackingNumber = dict["trackingNumber"] as? String
                        carrier = dict["carrier"] as? String
                    }
                    if trackingNumber != nil || carrier != nil || attempt >= 1 {
                        self.extracted = true
                        self.onDataFound(MercariTransactionData(
                            takeHome: self.pendingTakeHome,
                            trackingNumber: trackingNumber,
                            carrier: carrier
                        ))
                    } else {
                        self.extractTrackingData(webView: webView, attempt: attempt + 1)
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MercariTakeHomeScraper
// Standalone (non-SwiftUI) WKWebView scraper for background use.
// Used by MercariSyncSheet to backfill takeHome + tracking on a Sale after apply().
// Two-phase: (1) transaction/order_status page → take-home + shipping button check,
//            (2) if shipped, tracking page → tracking number + carrier.
// ─────────────────────────────────────────────────────────────

final class MercariTakeHomeScraper: NSObject, WKNavigationDelegate {
    private let mercariId: String
    private let onSuccess: (MercariTransactionData) -> Void
    private let onFail: () -> Void
    private var webView: WKWebView?
    private var phase: Phase = .transactionPage
    private var pendingTakeHome: Double?
    private var extracted = false
    // Strong self-reference so ARC doesn't deallocate us before callbacks fire.
    private var retainCycle: MercariTakeHomeScraper?

    private enum Phase { case transactionPage, trackingPage }

    // JS to extract tracking number and carrier from Mercari's tracking help page.
    static let trackingPageJS = """
        (function() {
            var allText = document.body ? document.body.innerText : '';
            var trackingNumber = null;
            var patterns = [
                /\\b(9[2-4]\\d{18,20})\\b/,
                /\\b(1Z[A-Z0-9]{16})\\b/i,
                /\\b(\\d{15,22})\\b/,
                /\\b([A-Z]{2}\\d{9}[A-Z]{2})\\b/
            ];
            for (var i = 0; i < patterns.length; i++) {
                var m = allText.match(patterns[i]);
                if (m) { trackingNumber = m[1]; break; }
            }
            var carrier = null;
            var imgs = document.querySelectorAll('img');
            var keys = ['usps','ups','fedex','dhl','ontrac','lasership','amazon'];
            for (var j = 0; j < imgs.length; j++) {
                var src = (imgs[j].src || '').toLowerCase();
                var alt = (imgs[j].alt || '').toLowerCase();
                for (var k = 0; k < keys.length; k++) {
                    if (src.indexOf(keys[k]) !== -1 || alt.indexOf(keys[k]) !== -1) {
                        carrier = keys[k] === 'usps' ? 'USPS' :
                                  keys[k] === 'ups' ? 'UPS' :
                                  keys[k] === 'fedex' ? 'FedEx' :
                                  keys[k] === 'dhl' ? 'DHL' :
                                  keys[k][0].toUpperCase() + keys[k].slice(1);
                        break;
                    }
                }
                if (carrier) break;
            }
            return { trackingNumber: trackingNumber, carrier: carrier };
        })()
        """

    init(mercariId: String, onSuccess: @escaping (MercariTransactionData) -> Void, onFail: @escaping () -> Void) {
        self.mercariId = mercariId
        self.onSuccess = onSuccess
        self.onFail = onFail
    }

    func start() {
        retainCycle = self
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = self
        webView = wv
        let url = URL(string: "https://www.mercari.com/transaction/order_status/\(mercariId)")!
        wv.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !extracted else { return }
        switch phase {
        case .transactionPage:
            extractTransactionData(webView: webView, attempt: 0)
        case .trackingPage:
            extractTrackingData(webView: webView, attempt: 0)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish { self.onFail() }
    }

    private func extractTransactionData(webView: WKWebView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView, !self.extracted else { return }
            let js = """
                (function() {
                    var el = document.querySelector('[data-testid="You-made-value"]');
                    var takeHome = el ? el.textContent : null;
                    var btn = document.querySelector('[data-testid="ShippingCTAButton"]');
                    var trackingHref = btn ? btn.getAttribute('href') : null;
                    return { takeHome: takeHome, trackingHref: trackingHref };
                })()
                """
            webView.evaluateJavaScript(js) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                var takeHome: Double? = nil
                var trackingHref: String? = nil
                if let dict = result as? [String: Any] {
                    if let text = dict["takeHome"] as? String {
                        let cleaned = text.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "$", with: "")
                            .replacingOccurrences(of: ",", with: "")
                        takeHome = Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
                    }
                    trackingHref = dict["trackingHref"] as? String
                }
                if takeHome != nil || trackingHref != nil {
                    self.pendingTakeHome = takeHome
                    if let href = trackingHref, let url = URL(string: href.hasPrefix("http") ? href : "https://www.mercari.com\(href)") {
                        self.phase = .trackingPage
                        webView.load(URLRequest(url: url))
                    } else {
                        self.extracted = true
                        self.finish { self.onSuccess(MercariTransactionData(takeHome: takeHome, trackingNumber: nil, carrier: nil)) }
                    }
                } else if attempt < 1 {
                    self.extractTransactionData(webView: webView, attempt: attempt + 1)
                } else {
                    self.finish { self.onFail() }
                }
            }
        }
    }

    private func extractTrackingData(webView: WKWebView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak webView] in
            guard let self, let webView, !self.extracted else { return }
            webView.evaluateJavaScript(MercariTakeHomeScraper.trackingPageJS) { [weak self] result, _ in
                guard let self else { return }
                var trackingNumber: String? = nil
                var carrier: String? = nil
                if let dict = result as? [String: Any] {
                    trackingNumber = dict["trackingNumber"] as? String
                    carrier = dict["carrier"] as? String
                }
                if trackingNumber != nil || carrier != nil || attempt >= 1 {
                    self.extracted = true
                    self.finish { self.onSuccess(MercariTransactionData(
                        takeHome: self.pendingTakeHome,
                        trackingNumber: trackingNumber,
                        carrier: carrier
                    )) }
                } else {
                    self.extractTrackingData(webView: webView, attempt: attempt + 1)
                }
            }
        }
    }

    private func finish(callback: () -> Void) {
        callback()
        retainCycle = nil
    }
}

private struct MercariDeactivateActionSheet: View {
    let listing: UserListing
    let url: URL
    var onHandled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmAlert = false
    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        return wv
    }()

    var body: some View {
        NavigationStack {
            CrossPostWebView(url: url, webView: webView)
                .navigationTitle("Deactivate on Mercari")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") { showConfirmAlert = true }
                            .fontWeight(.semibold)
                    }
                }
                .alert("Mark as Handled?", isPresented: $showConfirmAlert) {
                    Button("Yes, I deactivated it") {
                        onHandled()
                        dismiss()
                    }
                    Button("Not yet", role: .cancel) {}
                } message: {
                    Text("Did you deactivate or mark this Mercari listing as sold?")
                }
        }
    }
}

// MARK: - MercariAutoEditState

/// Headless Mercari listing editor. Navigates to the Mercari edit form, autofills updated
/// title/description/price/condition, and submits. Falls back to a visible WebView with clipboard
/// helpers if anything goes wrong.
@MainActor
final class MercariAutoEditState: NSObject, ObservableObject, WKNavigationDelegate {
    enum Phase: Equatable {
        case navigating, injecting, success, manualFallback(String)
    }

    @Published var phase: Phase = .navigating
    @Published var isWebViewVisible = false

    let webView: WKWebView
    private var hasStarted = false
    private var taskId = UUID()

    let mercariItemId: String
    let title: String
    let listingDescription: String
    let price: Double
    let condition: String
    // When set, skips headless autofill and opens the webview directly so the user can edit manually.
    let manualReason: String?

    var photoBase64Strings: [String] = []
    var photosWereUpdated: Bool = false

    init(mercariItemId: String, title: String, listingDescription: String, price: Double, condition: String, manualReason: String? = nil) {
        self.mercariItemId = mercariItemId
        self.title = title
        self.listingDescription = listingDescription
        self.price = price
        self.condition = condition
        self.manualReason = manualReason
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
        if manualReason != nil { isWebViewVisible = true }
    }

    func start(photoBase64Strings: [String] = [], photosWereUpdated: Bool = false) {
        guard !hasStarted else { return }
        hasStarted = true
        self.photoBase64Strings = photoBase64Strings
        self.photosWereUpdated = photosWereUpdated
        if manualReason == nil {
            AppTaskQueue.shared.begin(id: taskId, label: "Updating Mercari listing…")
        }
        let urlStr = "https://www.mercari.com/sell/edit/\(mercariItemId)/"
        if let url = URL(string: urlStr) {
            webView.load(URLRequest(url: url))
        } else {
            AppTaskQueue.shared.complete(id: taskId)
            phase = .manualFallback("Invalid Mercari item ID")
            isWebViewVisible = true
        }
    }

    func restart() {
        guard manualReason == nil else { return }
        let savedPhotos = photoBase64Strings
        let savedPhotosUpdated = photosWereUpdated
        hasStarted = false
        taskId = UUID()
        phase = .navigating
        isWebViewVisible = false
        start(photoBase64Strings: savedPhotos, photosWereUpdated: savedPhotosUpdated)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await runEditAutofill() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppTaskQueue.shared.complete(id: taskId)
        phase = .manualFallback("Page failed to load — edit manually")
        isWebViewVisible = true
    }

    func attachPhotos(_ base64Strings: [String]) async -> String {
        let js = """
        var fileInput = document.querySelector('input[data-testid="SellPhotoInput"], input[type="file"]');
        if (!fileInput) { return 'no-file-input'; }
        if (!base64Photos || base64Photos.length === 0) { return 'no-photos'; }
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
            return 'attached-' + base64Photos.length;
        } catch (e) { return 'error:' + e.message; }
        """
        return (try? await webView.callJS(js, args: ["base64Photos": base64Strings])) as? String ?? "error"
    }

    private func runEditAutofill() async {
        // Manual-only mode: webview is already visible; nothing to autofill.
        if manualReason != nil { return }
        guard case .navigating = phase else { return }
        phase = .injecting
        defer { AppTaskQueue.shared.complete(id: taskId) }

        // Wait for the edit form to mount (same Title field check as create flow)
        let deadline = Date().addingTimeInterval(30)
        var formReady = false
        while Date() < deadline {
            let result = (try? await webView.callJS("""
                return (function() {
                    if (document.querySelector('input[data-testid="Title"]')) return 'form';
                    var u = location.href.toLowerCase();
                    if (u.indexOf('login') !== -1) return 'login';
                    return 'wait';
                })();
            """)) as? String
            if result == "form" { formReady = true; break }
            if result == "login" {
                phase = .manualFallback("Sign in to Mercari first")
                isWebViewVisible = true
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        guard formReady else {
            phase = .manualFallback("Edit form didn't load — edit manually")
            isWebViewVisible = true
            return
        }

        // Inject title, description, price, condition
        let conditionMap: [String: String] = [
            "new": "ConditionNew", "newwithouttags": "ConditionLikeNew", "likenew": "ConditionLikeNew",
            "good": "ConditionGood", "fair": "ConditionFair", "poor": "ConditionPoor", "forparts": "ConditionPoor"
        ]
        let conditionKey = condition.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        let conditionTestId = conditionMap[conditionKey] ?? "ConditionGood"

        let injectJS = """
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
        var conditionLabel = document.querySelector('[data-testid="' + conditionTestId + '"]');
        if (conditionLabel) { conditionLabel.click(); }
        return (titleEl ? 'ok' : 'no-title');
        """
        let priceStr = String(format: "%.0f", price)
        let injectResult = (try? await webView.callJS(injectJS, args: [
            "title": title, "description": listingDescription, "price": priceStr, "conditionTestId": conditionTestId
        ])) as? String ?? "error"

        guard injectResult.hasPrefix("ok") else {
            phase = .manualFallback("Couldn't fill form fields — edit manually")
            isWebViewVisible = true
            return
        }

        if photosWereUpdated {
            // Delete all existing photos
            let deletePhotosJS = """
            var btns = Array.from(document.querySelectorAll('button[aria-label="Delete photo"], button[aria-label="Remove photo"], [data-testid="SellPhotoPreview"] button, [data-testid="PhotoPreview"] button'));
            for (var btn of btns) { btn.click(); }
            return 'deleted-' + btns.length;
            """
            _ = try? await webView.callJS(deletePhotosJS)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            if !photoBase64Strings.isEmpty {
                var photosOK = false
                for attempt in 1...4 {
                    let attachResult = await attachPhotos(photoBase64Strings)
                    print("[MercariAutoEditState] Photos attempt \(attempt): \(attachResult)")
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    
                    let checkErrorJS = "return (document.body.innerText || '').indexOf('Something wrong happened') !== -1 ? 'error' : 'ok';"
                    let errorResult = (try? await webView.callJS(checkErrorJS)) as? String
                    if errorResult != "error" {
                        photosOK = true
                        break
                    }
                }
                if !photosOK {
                    print("[MercariAutoEditState] Photos failed after retries")
                }
            }
        }

        // Disable smart pricing if it auto-enabled
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let _ = await disableSmartPricing()

        // Click save/update button
        let saveJS = """
        function waitFor(fn, timeout, interval) {
            timeout = timeout || 6000; interval = interval || 250;
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
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
            });
        }
        return (async function() {
            var btn = await waitFor(function() {
                var b = document.querySelector('[data-testid="SaveButton"], [data-testid="UpdateButton"]');
                if (b && !b.disabled) return b;
                // Fallback: any non-disabled button with text save/update
                var btns = document.querySelectorAll('button[type="submit"], button');
                for (var i = 0; i < btns.length; i++) {
                    var t = btns[i].textContent.trim().toLowerCase();
                    if ((t === 'save' || t === 'update' || t === 'save changes') && !btns[i].disabled) return btns[i];
                }
                return null;
            }, 8000);
            if (!btn) return 'btn-not-found';
            realClick(btn);
            return 'submitted';
        })();
        """
        let saveResult = (try? await webView.callJS(saveJS)) as? String ?? "error"
        if saveResult == "submitted" {
            // Poll for navigation away from the edit URL or a success signal on the page.
            // Mercari may redirect to the listing detail or show an inline success toast.
            let successDeadline = Date().addingTimeInterval(15)
            var editSucceeded = false
            while Date() < successDeadline {
                try? await Task.sleep(nanoseconds: 750_000_000)
                let check = (try? await webView.callJS("""
                    return (function() {
                        var url = location.href.toLowerCase();
                        if (url.indexOf('/sell/edit/') === -1) return 'navigated';
                        var body = document.body ? document.body.innerText : '';
                        if (/updated|changes saved|listing updated/i.test(body)) return 'success-text';
                        return 'wait';
                    })();
                """)) as? String ?? "wait"
                if check == "navigated" || check == "success-text" {
                    editSucceeded = true
                    break
                }
            }
            if editSucceeded {
                phase = .success
            } else {
                phase = .manualFallback("Mercari didn't confirm the update — check your listing manually")
                isWebViewVisible = true
            }
        } else {
            phase = .manualFallback("Couldn't find the save button — tap it manually")
            isWebViewVisible = true
        }
    }

    private func disableSmartPricing() async -> String {
        let js = """
        function waitFor(fn, t, i) {
            t = t||3000; i = i||250;
            return new Promise(function(resolve) {
                var s = Date.now();
                (function loop() {
                    var r=null; try{r=fn();}catch(e){}
                    if(r){resolve(r);return;}
                    if(Date.now()-s>=t){resolve(null);return;}
                    setTimeout(loop,i);
                })();
            });
        }
        function realClick(el) {
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type) {
                el.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,view:window}));
            });
        }
        function findToggle() {
            var t = document.querySelector('[data-testid*="SmartPricing"],[data-testid*="smartPricing"]');
            if(t) return t;
            var cands = document.querySelectorAll('input[type="checkbox"],button[role="switch"],[role="switch"]');
            for(var i=0;i<cands.length;i++){
                var a=cands[i].closest('label')||cands[i].parentElement;
                if(a&&a.textContent.toLowerCase().indexOf('smart pricing')!==-1) return cands[i];
            }
            return null;
        }
        function isOn(t) {
            return t.checked===true||t.getAttribute('aria-checked')==='true'||t.getAttribute('data-state')==='checked';
        }
        return (async function() {
            var toggle = await waitFor(findToggle, 3000);
            if(!toggle||!isOn(toggle)) return 'not-found-or-off';
            var target = toggle.tagName==='INPUT'?(document.querySelector('label[for="'+toggle.id+'"]')||toggle.closest('label')||toggle):toggle;
            realClick(target);
            var confirmBtn = await waitFor(function(){
                var bs=document.querySelectorAll('[role="dialog"] button,[role="alertdialog"] button');
                for(var i=0;i<bs.length;i++){var t=bs[i].textContent.trim().toLowerCase();if((t==='turn off'||t==='confirm'||t==='ok')&&!bs[i].disabled)return bs[i];}
                return null;
            }, 1500);
            if(confirmBtn) realClick(confirmBtn);
            return 'disabled';
        })();
        """
        return (try? await webView.callJS(js)) as? String ?? "error"
    }
}

struct MercariAutoEditSheet: View {
    let listing: UserListing
    let mercariId: String
    var onDone: () -> Void

    @StateObject private var state: MercariAutoEditState
    @Environment(\.dismiss) private var dismiss
    @State private var sheetDetent: PresentationDetent = .height(80)

    let photosWereUpdated: Bool

    init(listing: UserListing, mercariId: String, photosWereUpdated: Bool = false, onDone: @escaping () -> Void) {
        self.listing = listing
        self.mercariId = mercariId
        self.onDone = onDone
        self.photosWereUpdated = photosWereUpdated
        _state = StateObject(wrappedValue: MercariAutoEditState(
            mercariItemId: mercariId,
            title: listing.customTitle ?? "",
            listingDescription: listing.customDescription ?? "",
            price: listing.price ?? 0,
            condition: listing.condition.rawValue,
            manualReason: nil
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if state.isWebViewVisible {
                    MercariSheetWebView(webView: state.webView)
                        .ignoresSafeArea()
                } else {
                    statusContent
                }
            }
            .navigationTitle(state.isWebViewVisible ? "Update Mercari Listing" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state.isWebViewVisible {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onDone(); dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { state.webView.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                } else if case .manualFallback = state.phase {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onDone(); dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.height(80), .large], selection: $sheetDetent)
        .task {
            if photosWereUpdated {
                var base64Photos: [String] = []
                for path in listing.photoPaths {
                    if let data = try? await StorageService.shared.downloadImageData(path: path) {
                        base64Photos.append(data.base64EncodedString())
                    }
                }
                state.start(photoBase64Strings: base64Photos, photosWereUpdated: true)
            } else {
                state.start()
            }
        }
        .onChange(of: state.phase) { _, newPhase in
            switch newPhase {
            case .success:
                onDone()
                dismiss()
            case .manualFallback:
                sheetDetent = .large
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state.phase {
        case .navigating, .injecting:
            // Progress is shown in the shared AppTaskQueue pill bar — nothing to show here.
            Color.clear
        case .success:
            Color.clear
        case .manualFallback(let reason):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Update Failed")
                    .font(.title2.weight(.bold))
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Button("Retry") {
                        sheetDetent = .height(80)
                        state.restart()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Edit Manually in Browser") {
                        state.isWebViewVisible = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
        }
    }
}
//
//  MercariSyncManager.swift
//  wonni
//



@MainActor
final class MercariItemLoader: ObservableObject {
    enum Phase: Equatable { case loading, loaded, failed }

    @Published var phase: Phase = .loading
    @Published var priceDollars: Double?
    @Published var isSold: Bool = false
    @Published var statusRaw: String?
    @Published var name: String?
    @Published var descriptionText: String?
    @Published var thumbnailUrl: String?

    let webView: WKWebView
    private let navDelegate = SaleNavDelegate()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = navDelegate
    }

    func load(itemId: String) async {
        phase = .loading
        priceDollars = nil; isSold = false; statusRaw = nil; name = nil; descriptionText = nil; thumbnailUrl = nil
        guard let url = URL(string: "https://www.mercari.com/us/item/\(itemId)/") else {
            phase = .failed; return
        }
        navDelegate.reset()
        webView.load(URLRequest(url: url))
        _ = await navDelegate.waitForLoad(timeout: 20)

        let js = #"""
        return (function() {
            var out = { price: null, status: null, name: null, description: null, photo: null };
            var nd = document.getElementById('__NEXT_DATA__');
            var text = nd ? (nd.textContent || '') : '';
            if (text) {
                try {
                    var json = JSON.parse(text);
                    var pp = json && json.props && json.props.pageProps;
                    var item = (pp && pp.item) ||
                               (pp && pp.data && pp.data.item) ||
                               (pp && pp.meta && pp.meta.item);
                    if (item) {
                        if (item.description) out.description = item.description;
                        if (item.price != null) out.price = item.price / 100;
                        if (item.status) out.status = item.status.toLowerCase();
                        // Extract first photo URL from photos array
                        var photos = item.photos || [];
                        if (photos.length > 0) {
                            out.photo = photos[0].thumbnailUrl || photos[0].url || null;
                        }
                        if (!out.photo && item.thumbnailUrl) out.photo = item.thumbnailUrl;
                        if (!out.photo && item.photo_url) out.photo = item.photo_url;
                    }
                } catch(e) {}
                if (!out.status) {
                    var sm = text.match(/"status"\s*:\s*"([^"]+)"/);
                    if (sm) out.status = sm[1].toLowerCase();
                }
                if (out.price === null) {
                    var pm = text.match(/"price"\s*:\s*(\d+(?:\.\d+)?)/);
                    if (pm) out.price = parseFloat(pm[1]) / 100;
                }
            }
            // og:image is a reliable first-photo fallback when __NEXT_DATA__ has no photos array
            if (!out.photo) {
                var og = document.querySelector('meta[property="og:image"]');
                if (og && og.content) out.photo = og.content;
            }
            // DOM query for title is more reliable than NEXT_DATA which often contains the seller name
            var nameEl = document.querySelector('[data-testid="ItemName"]');
            if (nameEl && nameEl.innerText) {
                out.name = nameEl.innerText.trim();
            }
            if (!out.name) {
                var metaTitle = document.querySelector('meta[property="og:title"]');
                if (metaTitle && metaTitle.content) {
                    var c = metaTitle.content;
                    if (c.endsWith(' - Mercari')) c = c.slice(0, -10);
                    out.name = c.trim();
                }
            }
            if (out.price === null) {
                var body = (document.body && document.body.innerText) || '';
                var bm = body.match(/\$\s?([0-9,]+(?:\.[0-9]{2})?)/);
                if (bm) out.price = parseFloat(bm[1].replace(/,/g, ''));
            }
            // Body-text status fallback intentionally omitted — too many false positives
            // (e.g. "47 items sold" in seller stats). Trust __NEXT_DATA__ status only.
            // Product ribbon check: "Inactive" ribbon means the listing was deactivated (not sold).
            // Must run before the CTA button fallback so it takes priority.
            if (!out.status) {
                var ribbonEl = document.querySelector('[class*="RibbonTitle"]');
                if (ribbonEl && ribbonEl.innerText) out.status = ribbonEl.innerText.trim().toLowerCase();
            }
            // CTA button fallback: "item sold" (not logged in) or "view order" (seller
            // logged in) are exact button labels only present when the item is sold.
            if (!out.status) {
                var btns = Array.from(document.querySelectorAll('button'));
                for (var b of btns) {
                    var t = (b.innerText || b.textContent || '').trim().toLowerCase();
                    if (t === 'item sold' || t === 'view order') { out.status = 'sold_out'; break; }
                }
            }
            // Removed/deactivated listing: Mercari serves a generic "no longer for sale" page with
            // no __NEXT_DATA__ item. Detect that copy so the loader returns a definitive "inactive"
            // status instead of timing out and reporting a generic read failure.
            if (!out.status && out.price === null) {
                var bodyText = ((document.body && document.body.innerText) || '').toLowerCase();
                if (/no longer (for sale|available)/.test(bodyText)) {
                    out.status = 'inactive';
                }
            }
            return JSON.stringify(out);
        })();
        """#

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let json = (try? await webView.callJS(js)) as? String,
               let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let price = (obj["price"] as? NSNumber)?.doubleValue
                let status = obj["status"] as? String
                if price != nil || status != nil {
                    priceDollars = price
                    statusRaw = status
                    name = obj["name"] as? String
                    descriptionText = obj["description"] as? String
                    thumbnailUrl = obj["photo"] as? String
                    let s = (status ?? "").lowercased()
                    // Match exact Mercari status strings; contains("sold") was triggering on
                    // seller-stats text ("47 items sold") when the body fallback ran.
                    isSold = s == "sold_out" || s.hasSuffix("sold_out") || s == "trading"
                    phase = .loaded
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        phase = .failed
    }
}

struct MercariSyncResult {
    var title: String?
    var description: String?
    var price: Double?
    var isSold: Bool
    var statusRaw: String?
}

@MainActor
class MercariSyncManager: ObservableObject {
    @Published var isPillVisible = false
    @Published var showProgressSheet = false

    @Published var currentIndex = 0
    @Published var totalCount = 0
    @Published var jobs: [UserListing] = []

    @Published var syncResults: [String: MercariSyncResult] = [:]
    @Published var isFinished = false

    let loader = MercariItemLoader()
    private var syncTaskId = UUID()
    
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(currentIndex) / Double(totalCount)
    }
    
    func startSyncAll(listings: [UserListing], onComplete: @escaping () -> Void) {
        self.jobs = listings
        self.totalCount = listings.count
        self.currentIndex = 0
        self.isPillVisible = true
        self.syncResults = [:]
        self.isFinished = false
        syncTaskId = UUID()
        AppTaskQueue.shared.begin(
            id: syncTaskId,
            label: "Syncing with Mercari",
            detail: "0 of \(listings.count)",
            progress: 0,
            onTap: { [weak self] in self?.showProgressSheet = true }
        )
        
        Task {
            await processQueue()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    self.isPillVisible = false
                }
                AppTaskQueue.shared.complete(id: self.syncTaskId)
            }
            onComplete()
        }
    }
    
    private func processQueue() async {
        for (index, listing) in jobs.enumerated() {
            guard let mercariId = listing.crossPostListingIds?["mercari"],
                  let listingId = listing.id else { continue }

            self.currentIndex = index + 1
            AppTaskQueue.shared.update(
                id: syncTaskId,
                detail: "\(index + 1) of \(totalCount)",
                progress: Double(index + 1) / Double(max(totalCount, 1))
            )
            await loader.load(itemId: mercariId)
            guard loader.phase == .loaded else { continue }

            let result = MercariSyncResult(
                title: loader.name,
                description: loader.descriptionText,
                price: loader.priceDollars,
                isSold: loader.isSold,
                statusRaw: loader.statusRaw
            )
            self.syncResults[listingId] = result

            // This listing was flagged "go deactivate on Mercari" (it sold on another platform).
            // Mercari now confirms it's inactive/sold, so the user already handled it — clear the
            // stale flag here so the "Action needed" list stops nagging about it.
            if listing.pendingMercariDeactivation == true && (result.statusRaw == "inactive" || result.isSold) {
                try? await Firestore.firestore().collection("listings").document(listingId)
                    .updateData(["pendingMercariDeactivation": FieldValue.delete(),
                                 "updatedAt": FieldValue.serverTimestamp()])
            }
        }
        self.isFinished = true
    }

    func applyBulkEdits(selectedIds: Set<String>, applyTitle: Bool, applyPrice: Bool, applyDescription: Bool, applyStatus: Bool) async {
        for listing in jobs where selectedIds.contains(listing.id ?? "") {
            guard let listingId = listing.id, let result = syncResults[listingId] else { continue }
            
            let mercariIsSold = result.isSold
            let ebayIsPosted = listing.crossPostStatus?["ebay"] == "posted"

            let mercariIsInactive = result.statusRaw == "inactive"
            if applyStatus && listing.pendingMercariDeactivation == true && (mercariIsSold || mercariIsInactive) {
                try? await Firestore.firestore().collection("listings").document(listingId)
                    .updateData(["pendingMercariDeactivation": FieldValue.delete(),
                                 "updatedAt": FieldValue.serverTimestamp()])
            }

            let priceDiff = result.price.map { abs($0 - (listing.price ?? 0)) >= 0.01 } ?? false
            let soldDiff = mercariIsSold && listing.status != ListingStatus.sold
            let titleDiff = result.title != nil && result.title != listing.customTitle
            let descDiff = result.description != nil && result.description != listing.customDescription

            var update: [String: Any] = ["updatedAt": FieldValue.serverTimestamp()]
            if applyPrice && priceDiff, let p = result.price { update["price"] = p }
            if applyTitle && titleDiff, let t = result.title { update["customTitle"] = t }
            if applyDescription && descDiff, let d = result.description { update["customDescription"] = d }

            if !update.keys.filter({ $0 != "updatedAt" }).isEmpty {
                try? await Firestore.firestore().collection("listings").document(listingId).updateData(update)
            }

            if applyPrice && priceDiff && ebayIsPosted {
                _ = try? await callCloudFunction("ebayUpdateListing", ["listingId": listingId])
            }

            if applyStatus && mercariIsSold {
                if ebayIsPosted {
                    _ = try? await callCloudFunction("decrementAndCascade", ["listingId": listingId, "platform": "mercari"])
                }
                if soldDiff {
                    let sale = Sale(
                        userId: listing.userId,
                        listingId: listingId,
                        listingTitle: listing.customTitle,
                        coverPhotoPath: listing.coverPhotoPath,
                        platform: "mercari",
                        platformOrderId: listing.crossPostListingIds?["mercari"] ?? "",
                        priceSoldFor: result.price ?? listing.price ?? 0,
                        takeHome: nil,
                        status: .pending,
                        soldAt: Timestamp(date: Date())
                    )
                    _ = try? await SaleRepository.shared.recordSale(sale)
                }
            }
        }
    }
}

struct MercariSaleResult {
    var takeHome: Double?
    var trackingNumber: String?
    var carrier: String?
    var thumbnailUrl: String?
    var status: SaleStatus?
}

@MainActor
final class MercariSaleSyncManager: ObservableObject {
    @Published var isRunning = false
    @Published var currentIndex = 0
    @Published var totalCount = 0
    @Published var currentStatus = ""

    let webView: WKWebView
    private let navDelegate = SaleNavDelegate()
    private var saleTaskId = UUID()
    
    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = mercariProcessPool
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = navDelegate
        self.webView = wv
    }
    
    func sync(sales: [Sale]) async {
        // Sync all non-terminal Mercari sales to catch delivery/cancellation changes.
        let mercariSales = sales.filter {
            $0.platform == "mercari" &&
            $0.status != .complete && $0.status != .cancelled && $0.status != .returned
        }
        guard !mercariSales.isEmpty else {
            print("[MercariSaleSync] No mercari sales needing sync")
            return
        }
        
        isRunning = true
        totalCount = mercariSales.count
        currentIndex = 0

        print("[MercariSaleSync] Starting headless sync for \(mercariSales.count) sales")

        for (i, sale) in mercariSales.enumerated() {
            currentIndex = i + 1
            guard let platformOrderId = sale.platformOrderId, !platformOrderId.isEmpty else {
                print("[MercariSaleSync] Skipping sale \(sale.id ?? "?") - no platformOrderId")
                continue
            }

            currentStatus = "Syncing \(i + 1)/\(mercariSales.count)..."
            print("[MercariSaleSync] Loading order page for item \(platformOrderId)")
            
            let needsPhoto = sale.coverPhotoPath == nil
            if let result = await loadSaleData(itemId: platformOrderId, fetchPhoto: needsPhoto) {
                var update: [String: Any] = [:]
                if let th = result.takeHome, sale.takeHome != th {
                    update["takeHome"] = th
                    print("[MercariSaleSync] takeHome = \(th) for \(platformOrderId)")
                }
                if let tr = result.trackingNumber, sale.trackingNumber != tr {
                    update["trackingNumber"] = tr
                    print("[MercariSaleSync] tracking = \(tr) for \(platformOrderId)")
                }
                if let c = result.carrier, sale.carrier != c {
                    update["carrier"] = c
                }
                if let photo = result.thumbnailUrl, sale.coverPhotoPath == nil {
                    update["thumbnailUrl"] = photo
                    print("[MercariSaleSync] thumbnailUrl backfilled for \(platformOrderId)")
                }
                if let newStatus = result.status, newStatus != sale.status {
                    update["status"] = newStatus.rawValue
                    print("[MercariSaleSync] status → \(newStatus.rawValue) for \(platformOrderId)")
                }

                if !update.isEmpty {
                    update["updatedAt"] = FieldValue.serverTimestamp()
                    if let id = sale.id {
                        try? await Firestore.firestore().collection("sales").document(id).updateData(update)
                        print("[MercariSaleSync] Updated Firestore for sale \(id)")
                    }
                }
            }
        }
        
        currentStatus = "Done"
        print("[MercariSaleSync] Sync complete")
        isRunning = false
    }
    
    private func loadSaleData(itemId: String, fetchPhoto: Bool = false) async -> MercariSaleResult? {
        guard let url = URL(string: "https://www.mercari.com/transaction/order_status/\(itemId)/") else {
            return nil
        }
        
        navDelegate.reset()
        webView.load(URLRequest(url: url))
        
        let loaded = await navDelegate.waitForLoad(timeout: 10)
        if !loaded { print("[MercariSaleSync] Order page timed out for \(itemId)") }

        // Wait for React/Next.js hydration
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        
        var result = MercariSaleResult()
        
        let jsOrder = """
        (function() {
            var out = { takeHome: null, hasTracking: false, status: null, debug: '' };
            var takeHomeEl = document.querySelector('p[data-testid="You-made-value"]');
            if (takeHomeEl) {
                out.debug += 'Found takeHome: ' + takeHomeEl.innerText + '; ';
                var text = takeHomeEl.innerText.replace(/[^0-9.]/g, '');
                if (text) out.takeHome = parseFloat(text);
            } else {
                out.debug += 'No takeHome el; ';
            }
            var trackingBtn = document.querySelector('a[data-testid="ShippingCTAButton"]');
            if (trackingBtn) { out.hasTracking = true; }
            var stepEl = document.querySelector('[data-testid="TimelineStepName"]');
            var step = stepEl ? stepEl.innerText.trim().toLowerCase() : '';
            out.debug += 'step: ' + step + '; ';
            if (step === 'complete') {
                out.status = 'complete';
            } else if (step === 'delivery') {
                out.status = 'delivered';
            } else if (step === 'in transit') {
                out.status = 'shipped';
            } else if (step.includes('cancel')) {
                out.status = 'cancelled';
            } else if (step.includes('return')) {
                out.status = 'returned';
            }
            out.debug += 'url: ' + window.location.href;
            return JSON.stringify(out);
        })();
        """

        var hasTracking = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                if let jsResult = try await webView.evaluateJavaScript(jsOrder) as? String {
                    print("[MercariSaleSync] JS: \(jsResult)")
                    if let data = jsResult.data(using: .utf8),
                       let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if dict["takeHome"] != nil || dict["hasTracking"] as? Bool == true || dict["status"] != nil {
                            result.takeHome = dict["takeHome"] as? Double
                            hasTracking = dict["hasTracking"] as? Bool ?? false
                            if let s = dict["status"] as? String { result.status = SaleStatus(rawValue: s) }
                            break
                        }
                    }
                }
            } catch {
                print("[MercariSaleSync] JS error (order): \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        
        if hasTracking {
            currentStatus = "Loading tracking..."
            guard let trackingUrl = URL(string: "https://www.mercari.com/us/help_center/tracking/\(itemId)") else {
                return result
            }
            
            navDelegate.reset()
            webView.load(URLRequest(url: trackingUrl))
            let trackingLoaded = await navDelegate.waitForLoad(timeout: 10)
            if !trackingLoaded { print("[MercariSaleSync] Tracking page timed out") }

            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let jsTracking = """
            (function() {
                var out = { trackingNumber: null, carrier: null };
                var numEl = document.querySelector('span[data-testid="Tracking-TrackingNumber"]');
                if (numEl && numEl.innerText) { out.trackingNumber = numEl.innerText.trim(); }
                var carrierEl = document.querySelector('img[data-testid="Tracking-CarrierLogo"]');
                if (carrierEl && carrierEl.alt) { out.carrier = carrierEl.alt.trim().toUpperCase(); }
                return JSON.stringify(out);
            })();
            """
            
            let trackingDeadline = Date().addingTimeInterval(8)
            while Date() < trackingDeadline {
                do {
                    if let jsResult = try await webView.evaluateJavaScript(jsTracking) as? String {
                        print("[MercariSaleSync] Tracking JS: \(jsResult)")
                        if let data = jsResult.data(using: .utf8),
                           let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if dict["trackingNumber"] != nil {
                                result.trackingNumber = dict["trackingNumber"] as? String
                                result.carrier = dict["carrier"] as? String
                                break
                            }
                        }
                    }
                } catch {
                    print("[MercariSaleSync] JS error (tracking): \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }

        // Load the item page to get the cover photo — the order page's og:image is a
        // generic Mercari brand image, so the item page is the reliable photo source.
        if fetchPhoto, let itemUrl = URL(string: "https://www.mercari.com/us/item/\(itemId)/") {
            navDelegate.reset()
            webView.load(URLRequest(url: itemUrl))
            let itemLoaded = await navDelegate.waitForLoad(timeout: 15)
            if itemLoaded {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let jsPhoto = """
                (function() {
                    var nd = document.getElementById('__NEXT_DATA__');
                    if (nd) {
                        try {
                            var jd = JSON.parse(nd.textContent || '');
                            var pp = jd && jd.props && jd.props.pageProps;
                            var item = (pp && (pp.item || (pp.data && pp.data.item) || (pp.meta && pp.meta.item)));
                            if (item) {
                                var photos = item.photos || [];
                                if (photos.length > 0) {
                                    var p = photos[0].thumbnailUrl || photos[0].url || null;
                                    if (p) return p;
                                }
                                if (item.thumbnailUrl) return item.thumbnailUrl;
                                if (item.photo_url) return item.photo_url;
                            }
                        } catch(e) {}
                    }
                    var og = document.querySelector('meta[property="og:image"]');
                    if (og && og.content) return og.content;
                    return null;
                })();
                """
                if let photo = (try? await webView.evaluateJavaScript(jsPhoto)) as? String, !photo.isEmpty {
                    result.thumbnailUrl = photo
                    print("[MercariSaleSync] Got photo from item page for \(itemId)")
                } else {
                    print("[MercariSaleSync] No photo found on item page for \(itemId)")
                }
            }
        }

        return result
    }

    // MARK: - New sale discovery

    // Navigates to the Mercari sold-items listings page, ensures "Last updated" sort,
    // then scrolls and extracts items — stopping once 3 consecutive known order IDs
    // are encountered. Saves genuinely new items as Sale records.
    // Both "In Progress" and "Complete" sections are covered because __NEXT_DATA__
    // and the DOM link fallback operate on the full page regardless of section.
    /// Scans Mercari's in-progress transactions and returns newly discovered items.
    /// Stops at the first known order ID or when an item's updated date is before `stopBeforeDate`.
    /// Callers decide whether to auto-save or present for manual selection.
    func scanForNewSales(knownOrderIds: Set<String>, stopBeforeDate: Date? = nil) async -> [MercariFoundSaleItem] {
        // sortBy=7 = Last Updated, so we get newest sales first without needing dropdown interaction.
        // /in_progress/ shows transactions currently being traded — complete ones are already tracked.
        guard let url = URL(string: "https://www.mercari.com/mypage/listings/in_progress/?sortBy=7") else { return [] }
        navDelegate.reset()
        webView.load(URLRequest(url: url))
        guard await navDelegate.waitForLoad(timeout: 10) else {
            print("[MercariSaleSync] scanForNewSales: page timed out")
            return []
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Mercari item IDs always match /m\d+/. We look for that pattern in any link href
        // since the in-progress page may link to /transaction/order_status/m[id]/ rather
        // than /us/item/m[id]/, and the URL scheme can vary by page/experiment.
        let extractJS = """
        return (function() {
            var results = [];
            var seen = new Set();
            var dateRe = /^\\d{2}\\/\\d{2}\\/\\d{2,4}$/;
            var idRe = /(m\\d+)/;

            function extractId(href) {
                var m = href.match(idRe);
                return m ? m[1] : null;
            }

            // Phase 1: try __NEXT_DATA__ — broadest search across all known key paths
            var nd = document.getElementById('__NEXT_DATA__');
            if (nd) {
                try {
                    var root = JSON.parse(nd.textContent || '');
                    // Flatten everything under pageProps into candidate arrays
                    var pp = root.props && root.props.pageProps;
                    var candidates = [];
                    if (pp) {
                        // Walk all top-level and one-level-deep keys looking for arrays of objects with id+name
                        for (var k in pp) {
                            var v = pp[k];
                            if (Array.isArray(v) && v.length && v[0] && v[0].id) candidates = candidates.concat(v);
                            else if (v && typeof v === 'object') {
                                for (var k2 in v) {
                                    var v2 = v[k2];
                                    if (Array.isArray(v2) && v2.length && v2[0] && v2[0].id) candidates = candidates.concat(v2);
                                }
                            }
                        }
                    }
                    for (var it of candidates) {
                        var sid = String(it.id || '');
                        var extractedId = extractId(sid) || extractId(it.itemId || '');
                        if (!extractedId || seen.has(extractedId)) continue;
                        seen.add(extractedId);
                        var upd = it.updated || it.updatedAt || it.updated_at || null;
                        var price = it.price ? (it.price > 1000 ? it.price / 100 : it.price) : null;
                        results.push({ id: extractedId, name: it.name || null,
                                       price: price, thumbnailUrl: (it.thumbnails && it.thumbnails[0]) || it.thumbnailUrl || null,
                                       updatedStr: null });
                    }
                } catch(e) {}
            }

            // Phase 2: DOM scan — walk <tr> rows first to pair links with date cells
            if (results.length === 0) {
                for (var row of document.querySelectorAll('tr')) {
                    // Any anchor whose href contains a Mercari item ID
                    var link = Array.from(row.querySelectorAll('a[href]'))
                        .find(function(a) { return idRe.test(a.href) && a.href.includes('mercari.com'); });
                    if (!link) continue;
                    var eid = extractId(link.href);
                    if (!eid || seen.has(eid)) continue;
                    seen.add(eid);
                    var dateTd = Array.from(row.querySelectorAll('td'))
                        .find(function(td) { return dateRe.test(td.innerText.trim()); });
                    var nameEl = row.querySelector('[data-testid="ItemName"],[data-testid="item-name"],td p,td span');
                    var priceEl = row.querySelector('[data-testid="ItemPrice"],[data-testid="item-price"]');
                    var priceText = priceEl ? priceEl.innerText.replace(/[^0-9.]/g,'') : null;
                    var imgEl = row.querySelector('img');
                    results.push({ id: eid,
                                   name: nameEl ? nameEl.innerText.trim() : null,
                                   price: priceText ? parseFloat(priceText) || null : null,
                                   thumbnailUrl: imgEl ? imgEl.src : null,
                                   updatedStr: dateTd ? dateTd.innerText.trim() : null });
                }
            }

            // Phase 3: bare link scan (no row context, no dates)
            if (results.length === 0) {
                for (var a of document.querySelectorAll('a[href*="mercari.com"]')) {
                    var eid = extractId(a.href);
                    if (!eid || seen.has(eid)) continue;
                    seen.add(eid);
                    var nameEl = a.querySelector('[data-testid="ItemName"],p');
                    var priceEl = a.querySelector('[data-testid="ItemPrice"],span');
                    var imgEl = a.querySelector('img');
                    var priceText = priceEl ? priceEl.innerText.replace(/[^0-9.]/g,'') : null;
                    results.push({ id: eid,
                                   name: nameEl ? nameEl.innerText.trim() : null,
                                   price: priceText ? parseFloat(priceText) || null : null,
                                   thumbnailUrl: imgEl ? imgEl.src : null,
                                   updatedStr: null });
                }
            }

            return JSON.stringify({ items: results, url: window.location.href, count: results.length });
        })();
        """

        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MM/dd/yy"  // Mercari shows e.g. 06/25/26
            return f
        }()

        var newItems: [MercariFoundSaleItem] = []
        var lastCount = 0
        var done = false

        for _ in 0..<30 {
            guard !done else { break }
            _ = try? await webView.callJS("window.scrollTo(0, document.body.scrollHeight); return null;")
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            guard let json = (try? await webView.callJS(extractJS)) as? String,
                  let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = root["items"] as? [[String: Any]] else { continue }

            print("[MercariSaleSync] scan: \(arr.count) items on page, url=\(root["url"] as? String ?? "?")")

            if arr.count <= lastCount { break }

            for dict in arr.dropFirst(lastCount) {
                guard let id = dict["id"] as? String, !id.isEmpty else { continue }

                // Stop at the first sale we already know about — list is newest-first
                if knownOrderIds.contains(id) { done = true; break }

                // Stop once we reach an item updated before the start of the last-sync day
                if let cutoff = stopBeforeDate,
                   let dateStr = dict["updatedStr"] as? String,
                   let itemDate = dateFormatter.date(from: dateStr),
                   itemDate < cutoff {
                    done = true; break
                }

                let name = dict["name"] as? String
                let price = (dict["price"] as? NSNumber)?.doubleValue
                guard let n = name, !n.isEmpty, let p = price, p > 0 else {
                    print("[MercariSaleSync] skipping item \(id): missing name or price")
                    continue
                }
                newItems.append(MercariFoundSaleItem(
                    id: id,
                    name: n,
                    price: p,
                    thumbnailUrl: dict["thumbnailUrl"] as? String
                ))
            }
            lastCount = arr.count
        }

        print("[MercariSaleSync] scanForNewSales: \(newItems.count) new item(s)")
        return newItems
    }

    private func ensureLastUpdatedSort() async {
        let checkJS = """
        return (function() {
            var btn = document.querySelector('[data-testid="Listings-SortBy"]');
            return btn ? btn.innerText.trim() : '';
        })();
        """
        guard let current = (try? await webView.callJS(checkJS)) as? String,
              current.lowercased() != "last updated" else { return }

        _ = try? await webView.callJS("""
        return (function() {
            var btn = document.querySelector('[data-testid="Listings-SortBy"]');
            if (btn) { btn.click(); return true; }
            return false;
        })();
        """)
        try? await Task.sleep(nanoseconds: 800_000_000)

        _ = try? await webView.callJS("""
        return (function() {
            var opts = document.querySelectorAll('[role="option"], [role="listbox"] *');
            for (var opt of opts) {
                if (opt.innerText && opt.innerText.trim().toLowerCase() === 'last updated') {
                    opt.click(); return true;
                }
            }
            return false;
        })();
        """)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

// MARK: - Navigation Delegate for waiting on page loads

private class SaleNavDelegate: NSObject, WKNavigationDelegate {
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
        print("[MercariSaleSync] Page loaded: \(webView.url?.absoluteString ?? "?")")
        didFinish = true
        if let c = continuation {
            continuation = nil
            c.resume(returning: true)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[MercariSaleSync] Page failed: \(error.localizedDescription)")
        didFinish = true
        if let c = continuation {
            continuation = nil
            c.resume(returning: false)
        }
    }
}

