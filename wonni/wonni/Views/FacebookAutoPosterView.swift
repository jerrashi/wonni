//
//  FacebookAutoPosterView.swift
//  wonni
//
//  Facebook Marketplace cross-post sheet. Replaced the old CrossPostContainerView on
//  2026-10-01: that view was a web view under a "Draft Reference" copy-chip header, a
//  status strip, and a floating "Autofill Fields" button the user had to tap (and
//  re-tap — every tap re-ran the category picker). This one mirrors
//  MercariAutoPosterView: the page fills itself as soon as the form is on screen, the
//  only chrome is a one-line status banner, and problems surface as text in that
//  banner with a Retry.
//
//  Facebook's mobile form is server-rendered "MComponent" UI — see
//  docs/dom-captures/facebook-marketplace.md for every selector used here and why
//  nothing but `data-name` / visible label text is stable.
//

import SwiftUI
import WebKit
import Photos
import FirebaseFirestore

struct FacebookAutoPosterView: View {
    let job: CrossPostJob
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case loading
        case loginRequired
        case filling(String)
        /// Fill finished. `issues` is empty when everything landed; otherwise each entry
        /// is one short "what to check" string shown verbatim in the banner.
        case review(issues: [String])
        case posted
    }

    @State private var webView = WKWebView()
    @State private var phase: Phase = .loading
    @State private var hasStartedFill = false
    @State private var fbPostedId: String?
    @State private var fbSawCreatePage = false
    @State private var fbFinishedOnSellingPage = false

    // Account-level posting defaults (collected on the first Facebook post, editable in
    // Settings). Firestore is the source of truth; AppStorage is the local cache the
    // fill reads, same split MercariAutoPosterView uses for shipping preferences.
    @AppStorage("facebookOfferShipping") private var defaultOfferShipping = false
    @AppStorage("facebookHideFromFriends") private var defaultHideFromFriends = false
    @AppStorage("facebookPrefsConfigured") private var prefsConfigured = false
    @State private var showPrefSetup = false

    private static let createURL = URL(string: "https://www.facebook.com/marketplace/create/item")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                if fbFinishedOnSellingPage && fbPostedId == nil {
                    Button("I published it — mark as posted") {
                        Task { await markFacebookPosted(id: nil) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(8)
                }
                CrossPostWebView(url: Self.createURL, webView: webView)
            }
            .onReceive(webView.publisher(for: \.url)) { url in
                handleFacebookURLChange(url)
            }
            .navigationTitle("Post to Facebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        hasStartedFill = false
                        phase = .loading
                        webView.load(URLRequest(url: Self.createURL))
                        Task { await runFill() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload and fill again")
                }
                #if DEBUG
                // Dev-only DOM capture tool — see DevFormCapture.swift. Never present in a
                // release/TestFlight build.
                ToolbarItem(placement: .primaryAction) {
                    DevFormCaptureButton(webView: webView, platform: "facebook")
                }
                #endif
            }
            .sheet(isPresented: $showPrefSetup) {
                NavigationStack {
                    FacebookPostingPreferencesView(isFirstTimeSetup: true, onSaved: {
                        Task { await runFill() }
                    })
                }
                .interactiveDismissDisabled(true)
            }
            .task { await loadPreferencesThenStart() }
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var statusBanner: some View {
        switch phase {
        case .loading:
            progressBanner("Loading Facebook…")
        case .filling(let step):
            progressBanner(step)
        case .loginRequired:
            iconBanner(icon: "lock.circle.fill", tint: .orange,
                       title: "Log in to Facebook below",
                       subtitle: "Autofill starts on its own once the listing form appears")
        case .posted:
            iconBanner(icon: "checkmark.circle.fill", tint: .green,
                       title: "Posted to Facebook Marketplace", subtitle: nil)
        case .review(let issues):
            HStack(spacing: 10) {
                Image(systemName: issues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(issues.isEmpty ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issues.isEmpty ? "Ready — review and tap Publish" : "Check before publishing")
                        .font(.subheadline.weight(.semibold))
                    if !issues.isEmpty {
                        Text(issues.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !issues.isEmpty {
                    Button("Retry") {
                        hasStartedFill = false
                        Task { await runFill() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                if issues.isEmpty { Color.green.opacity(0.08) } else { Rectangle().fill(Material.ultraThinMaterial) }
            }
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
        }
    }

    private func progressBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
    }

    private func iconBanner(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(tint == .green ? AnyShapeStyle(Color.green.opacity(0.15)) : AnyShapeStyle(.ultraThinMaterial))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color(.separator)), alignment: .bottom)
    }

    // MARK: Start-up

    private func loadPreferencesThenStart() async {
        if let remote = await IntegrationRepository.shared.loadFacebookPostingPreferences() {
            defaultOfferShipping = remote.offerShipping
            defaultHideFromFriends = remote.hideFromFriends
            prefsConfigured = true
        }
        if prefsConfigured {
            await runFill()
        } else {
            // First Facebook post on this account — collect the two defaults first.
            showPrefSetup = true
        }
    }

    // MARK: Fill pipeline

    /// One pass per page load. Waits for the form (or the login page), fills every field
    /// it can, and lands in `.review` with the list of anything that didn't take.
    @MainActor
    private func runFill() async {
        guard !hasStartedFill else { return }
        hasStartedFill = true
        phase = .loading

        // Wait for the form. The login page is not a failure — show it, keep waiting, and
        // start filling the moment the form appears after sign-in (`waitForForm` keeps
        // polling through the login state; only a true timeout exits).
        switch await waitForForm() {
        case .ready:
            break
        case .timedOut:
            phase = .review(issues: ["Form never loaded — tap ↻ to reload"])
            return
        }

        var issues: [String] = []

        phase = .filling("Filling title, price, description…")
        let missed = (try? await webView.callJS(Self.fillBasicsJS, args: [
            "title": job.title,
            "price": String(format: "%.0f", job.price.rounded()),
            "desc": job.description
        ])) as? String ?? ""
        if !missed.isEmpty { issues.append("couldn't fill \(missed)") }

        if let loc = job.facebookLocation, !loc.isEmpty {
            phase = .filling("Setting location…")
            let result = (try? await webView.callJS(Self.fillLocationJS, args: ["location": loc])) as? String ?? "error"
            if !result.hasPrefix("selected") { issues.append("location (\(result))") }
        }

        // Category + brand come from the shared Gemini pipeline (same products/{id} doc
        // eBay/Etsy use). Best-effort: a blank result just leaves Category manual.
        phase = .filling("Picking category…")
        var category = job.suggestedFacebookCategory
        var brand = job.suggestedBrand
        if let productId = job.listingId, category == nil {
            let resolved = await Self.resolveFacebookSuggestedFields(productId: productId)
            category = category ?? resolved.category
            brand = brand ?? resolved.brand
        }
        if let category, !category.isEmpty {
            let result = (try? await webView.callJS(Self.fillCategoryJS, args: ["category": category])) as? String ?? "error"
            // "already" = the control no longer reads "Select" — set by an earlier pass or
            // by hand. Never re-open the picker in that case (the old view did, on every tap).
            if !(result.hasPrefix("selected") || result == "already") { issues.append("category") }
        } else {
            issues.append("category")
        }

        if let brand, !brand.isEmpty {
            _ = try? await webView.callJS(Self.fillBrandJS, args: ["brand": brand])
        }
        phase = .filling("Setting condition…")
        let conditionR = (try? await webView.callJS(Self.fillConditionJS, args: ["condition": Self.facebookConditionLabel(job.condition)])) as? String ?? "error"
        if !conditionR.hasPrefix("selected") { issues.append("condition") }

        // Shipping + visibility toggles: per-listing override on the product doc wins,
        // otherwise the account default collected on first post.
        phase = .filling("Applying shipping and visibility…")
        let overrides = await Self.loadListingToggleOverrides(productId: job.listingId)
        let offerShipping = Self.effectiveToggle(override: overrides.offerShipping, accountDefault: defaultOfferShipping)
        let hideFromFriends = Self.effectiveToggle(override: overrides.hideFromFriends, accountDefault: defaultHideFromFriends)
        for (label, wantOn) in [("Offer shipping", offerShipping), ("Hide from friends", hideFromFriends)] {
            let result = (try? await webView.callJS(Self.setToggleJS, args: ["label": label, "on": wantOn])) as? String ?? "error"
            if !(result.hasPrefix("set") || result == "already") { issues.append("\(label.lowercased()) (\(result))") }
        }

        phase = .filling("Attaching photos…")
        let photos = await Self.loadPhotoBase64(job)
        if photos.isEmpty {
            issues.append("no photos found")
        } else {
            let result = (try? await webView.callJS(Self.attachPhotosJS, args: ["base64Photos": photos])) as? String ?? "error"
            // "attached-N/M"
            let attached = Int(result.split(separator: "-").last?.split(separator: "/").first ?? "") ?? 0
            if attached < photos.count { issues.append("photos \(attached)/\(photos.count)") }
        }

        phase = .review(issues: issues)
    }

    enum FormWait { case ready, timedOut }

    /// Polls for the form's Title input. A login page flips the banner to "log in below"
    /// and keeps polling (up to ten minutes — the user is typing a password) instead of
    /// giving up; the plain not-yet-loaded case times out after a minute.
    private func waitForForm() async -> FormWait {
        var deadline = Date().addingTimeInterval(60)
        let loginDeadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let result = (try? await webView.callJS(Self.probeFormJS)) as? String
            if result == "form" { return .ready }
            if result == "login" || Self.isFacebookLoginURL(webView.url) {
                if phase != .loginRequired { phase = .loginRequired }
                deadline = loginDeadline
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .timedOut
    }

    // MARK: Pure helpers (unit-tested in FacebookAutofillPolicyTests)

    /// Facebook bounces an unauthenticated create-item request through one of these.
    /// `checkpoint` / `two_step_verification` are the "confirm it's you" interstitials —
    /// still "needs the user", so they're treated as login too.
    nonisolated static func isFacebookLoginURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.lowercased()
        let markers = ["/login", "login.php", "/checkpoint", "/two_step_verification", "/recover", "/confirmemail"]
        return markers.contains { path.contains($0) }
    }

    /// Listing-level override (nil = "use default") layered over the account default.
    nonisolated static func effectiveToggle(override: Bool?, accountDefault: Bool) -> Bool {
        override ?? accountDefault
    }

    /// Facebook has 4 Condition options; Wonni's `ItemCondition` has 7. Collapse the two
    /// extras Facebook doesn't distinguish: `newWithoutTags` reads as "New" to a buyer,
    /// and `poor`/`forParts` both map to Facebook's worst bucket, "Used - Fair".
    nonisolated static func facebookConditionLabel(_ raw: String) -> String {
        switch ItemCondition(rawValue: raw) {
        case .new, .newWithoutTags: return "New"
        case .likeNew: return "Used - Like New"
        case .fair, .poor, .forParts: return "Used - Fair"
        case .good, .none: return "Used - Good"
        }
    }

    // MARK: Data

    /// `job.listingId` IS a `products/{id}` doc id (`ProductRepository.syncProduct` writes
    /// the draft there; `postToWonni` reuses the id for `listings/{id}`), so per-listing
    /// Facebook toggles live on the product doc and are read from there in every flow —
    /// draft publish, profile cross-post, and retry alike. Nil fields = no override.
    private static func loadListingToggleOverrides(productId: String?) async -> (offerShipping: Bool?, hideFromFriends: Bool?) {
        guard let productId,
              let data = try? await ProductRepository.shared.fetchProduct(productId: productId) else { return (nil, nil) }
        return (data["facebookOfferShipping"] as? Bool, data["facebookHideFromFriends"] as? Bool)
    }

    /// Calls the shared `aiAutofillListing` Cloud Function with `includeFacebookCategory`,
    /// then re-reads the product doc for the values it wrote. Best-effort.
    private static func resolveFacebookSuggestedFields(productId: String) async -> (category: String?, brand: String?) {
        _ = try? await callCloudFunction("aiAutofillListing", ["productId": productId, "includeFacebookCategory": true] as [String: Any])
        guard let data = try? await ProductRepository.shared.fetchProduct(productId: productId) else { return (nil, nil) }
        return (data["facebookCategory"] as? String, data["brand"] as? String)
    }

    private static func loadPhotoBase64(_ job: CrossPostJob) async -> [String] {
        var out: [String] = []
        if let item = job.item {
            // Per photo: the draft's own bytes when it has them, the photo library otherwise.
            let localPhotos = item.localPhotoDataByAsset()
            for identifier in item.sourceAssetIdentifiers {
                if let local = localPhotos[identifier] { out.append(local.base64EncodedString()); continue }
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { continue }
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                let data: Data? = await withCheckedContinuation { continuation in
                    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { bytes, _, _, _ in continuation.resume(returning: bytes) }
                }
                if let data { out.append(data.base64EncodedString()) }
            }
        } else {
            for path in job.photoFirebasePaths {
                // Path or URL form — see StorageService.photoLocation.
                if let data = try? await StorageService.shared.downloadImageData(path: path, maxSize: 15 * 1024 * 1024) {
                    out.append(data.base64EncodedString())
                }
            }
        }
        return out
    }

    // MARK: Success detection

    /// The compose form lives at `/marketplace/selling/item/?listing_id` (Facebook routes
    /// there client-side from the create URL). `listing_id` populating with digits, or a
    /// later `/marketplace/item/{id}` page, is treated as a publish; landing back on the
    /// selling list without an id shows the manual "I published it" button instead.
    private func handleFacebookURLChange(_ url: URL?) {
        guard let url else { return }
        let path = url.path
        let isComposeForm = path.contains("/marketplace/selling/item") || path.contains("/marketplace/create")
        let isSellingList = (path.contains("/marketplace/you/selling") || path.contains("/marketplace/selling"))
            && !path.contains("/item")

        if isComposeForm {
            fbSawCreatePage = true
            let listingId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "listing_id" })?.value
            if let listingId, !listingId.isEmpty, listingId.allSatisfy(\.isNumber), fbPostedId == nil {
                Task { await markFacebookPosted(id: listingId) }
            }
            return
        }
        guard fbSawCreatePage, fbPostedId == nil else { return }
        if let range = path.range(of: #"/marketplace/item/(\d+)"#, options: .regularExpression) {
            let id = String(path[range].split(separator: "/").last ?? "")
            Task { await markFacebookPosted(id: id) }
        } else if isSellingList {
            fbFinishedOnSellingPage = true
        }
    }

    private func markFacebookPosted(id: String?) async {
        guard let listingId = job.listingId else { return }
        var update: [String: Any] = [
            "crossPostStatus.facebook": "posted",
            "updatedAt": Timestamp(date: Date())
        ]
        if let id { update["crossPostListingIds.facebook"] = id }
        try? await Firestore.firestore().collection("listings").document(listingId).updateData(update)
        fbPostedId = id ?? "manual"
        phase = .posted
        // Detection already worked before this view existed; the sheet just never
        // closed. Leave the green banner up long enough to register, then go.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        dismiss()
    }

    // MARK: JS

    /// "form" once the Title input exists; "login" on Facebook's sign-in page (URL or the
    /// password field — the mobile login form keeps `name="pass"`); "wait" otherwise.
    private static let probeFormJS = """
    return (function() {
        if (document.querySelector('[data-name="title"] input, input[data-name="title"]')) { return 'form'; }
        var u = (location && location.href) ? location.href.toLowerCase() : '';
        if (u.indexOf('/login') !== -1 || u.indexOf('login.php') !== -1 || u.indexOf('/checkpoint') !== -1
            || u.indexOf('two_step_verification') !== -1 || document.querySelector('input[name="pass"], form#login_form')) { return 'login'; }
        return 'wait';
    })();
    """

    /// Title/Price/Description are real inputs wrapped in `div[data-name=…]`; set through
    /// the native value setter so Facebook's own input listeners see the change.
    private static let fillBasicsJS = """
    function setNative(el, v) {
        var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    function fillByName(name, value) {
        var wrap = document.querySelector('[data-name="' + name + '"]');
        if (!wrap) return false;
        var el = (wrap.tagName === 'INPUT' || wrap.tagName === 'TEXTAREA') ? wrap : wrap.querySelector('input,textarea');
        if (!el) return false;
        el.focus();
        setNative(el, value);
        el.blur();
        return true;
    }
    var missed = [];
    if (!fillByName('title', title)) missed.push('title');
    if (!fillByName('price', price)) missed.push('price');
    if (!fillByName('description', desc)) missed.push('description');
    return missed.join(', ');
    """

    /// Shared label → control lookup for the base form's label-above-control groups.
    private static let controlForLabelJS = """
    function controlForLabel(labelText) {
        var spans = Array.from(document.querySelectorAll('span.f1, span.f2'));
        var labelSpan = spans.find(function (s) { return s.innerText.trim() === labelText; });
        if (!labelSpan) return null;
        var labelDiv = labelSpan.closest('[data-mcomponent="ServerTextArea"]');
        if (!labelDiv || !labelDiv.parentElement) return null;
        var group = labelDiv.parentElement;
        var controlWrap = Array.from(group.children).find(function (c) {
            return c !== labelDiv && (c.className || '').indexOf('nb') !== -1;
        });
        if (!controlWrap) return null;
        return controlWrap.querySelector('[data-focusable="true"]') || controlWrap;
    }
    """

    /// Category is a full-screen picker with two same-text row kinds (section header with
    /// an `[aria-hidden]` icon vs. the real selectable row). Resolves "already" without
    /// opening the picker when the control no longer reads "Select" — the fix for the
    /// picker re-opening on every autofill run.
    private static let fillCategoryJS = controlForLabelJS + """
    return new Promise(function(resolve) {
        var ctl = controlForLabel('Category');
        if (!ctl) { resolve('no-category-field'); return; }
        var current = (ctl.innerText || '').trim();
        if (current && current !== 'Select') { resolve('already'); return; }
        ctl.click();
        var deadline = Date.now() + 4000;
        function waitForRow() {
            var rows = document.querySelectorAll('[data-focusable="true"]');
            for (var i = 0; i < rows.length; i++) {
                var el = rows[i];
                if (el.querySelector('[aria-hidden="true"]')) continue;
                var span = el.querySelector('span.f1');
                var t = span ? span.innerText.trim() : '';
                if (t === category) { el.click(); resolve('selected:' + t); return; }
            }
            if (Date.now() > deadline) {
                var back = document.querySelector('[aria-label="Back"]');
                if (back) back.click();
                resolve('option-not-found');
                return;
            }
            setTimeout(waitForRow, 250);
        }
        setTimeout(waitForRow, 300);
    });
    """

    /// Brand is a real `<input data-name="brand">` that only exists once a category with a
    /// brand field is picked, so this polls briefly.
    private static let fillBrandJS = """
    return new Promise(function(resolve) {
        function setNative(el, v) {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        var deadline = Date.now() + 3000;
        function tryFill() {
            var wrap = document.querySelector('[data-name="brand"]');
            var el = wrap && (wrap.tagName === 'INPUT' ? wrap : wrap.querySelector('input'));
            if (el) { el.focus(); setNative(el, brand); el.blur(); resolve('set:' + brand); return; }
            if (Date.now() > deadline) { resolve('no-brand-field'); return; }
            setTimeout(tryFill, 250);
        }
        tryFill();
    });
    """

    /// Condition's option rows render inline once a category is picked. Polls for them
    /// (the category re-render takes a beat) and clicks the matching row. `+` in
    /// Facebook's label markup is a space-encoding artifact, normalized before comparing.
    private static let fillConditionJS = """
    return new Promise(function(resolve) {
        var target = condition.trim();
        var deadline = Date.now() + 4000;
        function tryPick() {
            var rows = document.querySelectorAll('[data-focusable="true"]');
            for (var i = 0; i < rows.length; i++) {
                var span = rows[i].querySelector('span.f1');
                if (!span) continue;
                var t = (span.innerText || '').split('+').join(' ').trim();
                if (t === target) { rows[i].click(); resolve('selected:' + t); return; }
            }
            if (Date.now() > deadline) { resolve('option-not-found:' + target); return; }
            setTimeout(tryPick, 300);
        }
        tryPick();
    });
    """

    /// Flips a labelled switch row ("Offer shipping", "Hide from friends") to `on`. Looks
    /// for the label text, then the nearest switch/checkbox in the same row group and
    /// reads its state from `aria-checked` / `checked` before deciding whether to click,
    /// so a re-run never toggles it back. These rows had no DOM capture as of 2026-10-01 —
    /// the returned token ("no-label" / "no-switch" / "set:on") is what the banner shows
    /// so a failure pinpoints which assumption broke.
    private static let setToggleJS = """
    return new Promise(function(resolve) {
        var want = !!on;
        var spans = Array.from(document.querySelectorAll('span.f1, span.f2, span'));
        var labelSpan = spans.find(function (s) { return (s.innerText || '').trim() === label; });
        if (!labelSpan) { resolve('no-label'); return; }
        function stateOf(el) {
            if (el.getAttribute('aria-checked') != null) return el.getAttribute('aria-checked') === 'true';
            if (el.tagName === 'INPUT') return !!el.checked;
            var inner = el.querySelector('input[type="checkbox"]');
            if (inner) return !!inner.checked;
            return null;
        }
        var node = labelSpan, sw = null;
        for (var depth = 0; depth < 6 && node && !sw; depth++) {
            node = node.parentElement;
            if (!node) break;
            sw = node.querySelector('[role="switch"], [role="checkbox"], input[type="checkbox"], [aria-checked]');
        }
        if (!sw) { resolve('no-switch'); return; }
        var current = stateOf(sw);
        if (current === want) { resolve('already'); return; }
        var target = sw.closest('[data-focusable="true"]') || sw;
        target.click();
        setTimeout(function() {
            var after = stateOf(sw);
            if (after === want || after === null) resolve('set:' + (want ? 'on' : 'off'));
            else resolve('no-change');
        }, 400);
    });
    """

    /// Photos go in one at a time: Facebook's mobile form accepts a single file per
    /// "Add photos" tap (confirmed on device 2026-10-01 — the old all-at-once
    /// DataTransfer left at most one photo attached). Per photo: tap the add row, wait for
    /// the file input to appear, hand it one file, wait for the preview count to grow,
    /// repeat. If the input advertises `multiple`, everything remaining goes in one shot.
    /// Resolves "attached-N/M".
    private static let attachPhotosJS = """
    return new Promise(function(resolve) {
        var total = base64Photos.length, attached = 0, index = 0;
        function fileAt(i) {
            var bin = atob(base64Photos[i]); var bytes = new Uint8Array(bin.length);
            for (var j = 0; j < bin.length; j++) { bytes[j] = bin.charCodeAt(j); }
            return new File([bytes], 'photo_' + i + '.jpg', {type: 'image/jpeg'});
        }
        function previewCount() {
            return document.querySelectorAll('#screen-root img[src^="blob:"], #screen-root img[src^="data:"], img[src^="blob:"]').length;
        }
        function addRow() {
            var rows = document.querySelectorAll('[data-focusable="true"]');
            for (var i = 0; i < rows.length; i++) {
                var t = (rows[i].innerText || '').trim().toLowerCase();
                if (t.indexOf('add') === 0 && t.indexOf('photo') !== -1) return rows[i];
            }
            return null;
        }
        function waitFor(pred, ms, cb) {
            var deadline = Date.now() + ms;
            (function poll() {
                var v = pred();
                if (v) { cb(v); return; }
                if (Date.now() > deadline) { cb(null); return; }
                setTimeout(poll, 200);
            })();
        }
        function step() {
            if (index >= total) { resolve('attached-' + attached + '/' + total); return; }
            var before = previewCount();
            var row = addRow();
            if (row) row.click();
            waitFor(function() { return document.querySelector('input[type="file"]'); }, 3000, function(input) {
                if (!input) { resolve('attached-' + attached + '/' + total + ' (no-file-input)'); return; }
                var dt = new DataTransfer();
                var batch = input.hasAttribute('multiple') ? total - index : 1;
                for (var b = 0; b < batch; b++) { dt.items.add(fileAt(index + b)); }
                try {
                    input.files = dt.files;
                    input.dispatchEvent(new Event('change', { bubbles: true }));
                    input.dispatchEvent(new Event('input', { bubbles: true }));
                } catch (e) { resolve('attached-' + attached + '/' + total + ' (' + e.message + ')'); return; }
                index += batch;
                waitFor(function() { return previewCount() > before ? true : null; }, 8000, function(grew) {
                    if (grew) attached += batch;
                    step();
                });
            });
        }
        step();
    });
    """

    /// Tapping Location pushes a full "Change location" search-and-pick screen (not a text
    /// field, and not a URL change — polled entirely from JS).
    private static let fillLocationJS = """
    return new Promise(function(resolve) {
        var wrap = document.querySelector('[data-name="location"]');
        if (!wrap) { resolve('no-location-field'); return; }
        wrap.click();
        var pickerDeadline = Date.now() + 4000;
        function waitForPicker() {
            var input = document.querySelector('input[placeholder="Location"][aria-label="Search on Facebook"]');
            if (input) { typeAndPick(input); return; }
            if (Date.now() > pickerDeadline) { resolve('picker-not-found'); return; }
            setTimeout(waitForPicker, 200);
        }
        function typeAndPick(input) {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, location);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            var matchDeadline = Date.now() + 4000;
            function waitForMatch() {
                var rows = document.querySelectorAll('[data-focusable="true"][role="button"]');
                for (var i = 0; i < rows.length; i++) {
                    var t = (rows[i].innerText || '').trim();
                    if (t.toLowerCase().indexOf(location.toLowerCase()) === 0) { rows[i].click(); resolve('selected:' + t); return; }
                }
                if (Date.now() > matchDeadline) {
                    var back = document.querySelector('[aria-label="Back"]');
                    if (back) back.click();
                    resolve('no-match');
                    return;
                }
                setTimeout(waitForMatch, 300);
            }
            setTimeout(waitForMatch, 400);
        }
        waitForPicker();
    });
    """
}

// MARK: - FacebookPostingPreferencesView

/// The two Facebook Marketplace defaults the fill applies to every listing: whether to
/// offer shipping and whether to hide the listing from friends. Shown once before the
/// first Facebook post (`isFirstTimeSetup`) and editable afterwards in Settings. A
/// listing can override either in its own settings sheet (Default / On / Off).
struct FacebookPostingPreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("facebookOfferShipping") private var offerShipping = false
    @AppStorage("facebookHideFromFriends") private var hideFromFriends = false
    @AppStorage("facebookPrefsConfigured") private var prefsConfigured = false

    var isFirstTimeSetup = false
    var onSaved: (() -> Void)?

    @State private var offer = false
    @State private var hide = false

    var body: some View {
        Form {
            Section {
                Toggle("Offer shipping", isOn: $offer)
            } footer: {
                Text("Turn on Facebook's \"Offer shipping\" option so buyers outside your area can purchase. Off means local pickup only.")
            }
            Section {
                Toggle("Hide from friends", isOn: $hide)
            } footer: {
                Text("Keep your Marketplace listings out of your friends' feeds. Either setting can be changed per listing in that listing's settings.")
            }
        }
        .navigationTitle(isFirstTimeSetup ? "Facebook defaults" : "Facebook Marketplace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isFirstTimeSetup ? "Continue" : "Save") { save() }
            }
        }
        .onAppear {
            offer = offerShipping
            hide = hideFromFriends
        }
    }

    private func save() {
        offerShipping = offer
        hideFromFriends = hide
        prefsConfigured = true
        Task {
            await IntegrationRepository.shared.saveFacebookPostingPreferences(offerShipping: offer, hideFromFriends: hide)
        }
        onSaved?()
        dismiss()
    }
}
