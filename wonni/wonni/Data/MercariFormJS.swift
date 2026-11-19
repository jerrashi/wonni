//
//  MercariFormJS.swift
//  wonni
//
//  JavaScript that drives Mercari's sell / edit form, kept as plain string constants
//  (no WebKit import) so wonniTests can run the exact production script against
//  fixture HTML in a real WKWebView — the same rule MercariScanJS follows: capture
//  the markup first, make the test fail, then fix the script.
//
//  The Chrome extension (extension/mercari_content.js, `disableSmartPricing`) carries
//  a copy of `disableSmartPricing` below. Keep the two in step.
//

import Foundation

enum MercariFormJS {

    // MARK: Smart Pricing policy

    /// Below this list price Mercari's own Smart Pricing floor (it recommends ~75–80% of
    /// the price, minimum $9) lands under $9 and the submit is rejected with
    /// "smart pricing must be greater than $9". Desktop hides the whole section for
    /// prices of $9 and under; the mobile WKWebView does not, so we have to turn it off.
    static let smartPricingForceOffBelow: Double = 10

    /// Whether the automation must guarantee Smart Pricing is off (or hidden) before it
    /// taps List. Above the threshold the seller's preference decides; below it the
    /// listing cannot be submitted with Smart Pricing on, whatever the preference says.
    static func mustDisableSmartPricing(price: Double, keepSmartPricing: Bool) -> Bool {
        if price < smartPricingForceOffBelow { return true }
        return !keepSmartPricing
    }

    /// Smart Pricing is chosen at three levels (decided 2026-11-02): the account
    /// setting, the Post menu's toggle for one run, and a value set on the draft or
    /// listing itself. The most specific one the user actually touched wins; the Post
    /// menu toggle starts at the account value each time, so "most recent" and "most
    /// specific" agree. Under $10 the answer is always off (`mustDisableSmartPricing`).
    static func resolveSmartPricing(price: Double, account: Bool, posting: Bool?, listing: Bool?) -> Bool {
        if price < smartPricingForceOffBelow { return false }
        return listing ?? posting ?? account
    }

    // MARK: Smart Pricing script

    /// Runs via `WKWebView.callJS` (callAsyncJavaScript), hence the leading `return`.
    ///
    /// Real markup (captured 2026-10-12 from mercari.com/sell):
    ///   <button data-testid="SmartPricingAccordion" aria-expanded="true">…</button>
    ///   <button data-testid="SmartPricingButton" role="button" aria-pressed="true">ON</button>
    ///   <input data-testid="SmartPricingFloorPrice" value="9.00">
    ///
    /// The earlier script matched `[data-testid*="SmartPricing"]`, whose FIRST hit is the
    /// accordion header, which has no checked state — so it reported "was-off" and skipped.
    ///
    /// Must run LAST, right before Submit: setting shipping re-renders the pricing section
    /// and can switch Smart Pricing back on.
    ///
    /// Resolves to one of:
    ///   "hidden"     — no Smart Pricing section on the page (Mercari hides it ≤ $9 on desktop)
    ///   "was-off"    — section present, toggle already OFF
    ///   "disabled"   — toggle was ON, we turned it OFF and verified
    ///   "still-on"   — toggle stayed ON after 3 attempts
    ///   "no-toggle"  — accordion present but the ON/OFF button never appeared
    static let disableSmartPricing = #"""
    function waitFor(fn, timeout, interval) {
        timeout = timeout || 5000; interval = interval || 200;
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
    // React buttons often ignore a bare .click(); send the full pointer/mouse sequence.
    function realClick(el) {
        if (!el) return;
        ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function(type) {
            el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        });
    }
    function accordion() { return document.querySelector('[data-testid="SmartPricingAccordion"]'); }
    function toggle() {
        var t = document.querySelector('[data-testid="SmartPricingButton"]');
        if (t) return t;
        // Fallback: the ON/OFF button inside the Smart Pricing container.
        var acc = accordion();
        var box = acc ? acc.parentElement : null;
        var btns = box ? box.querySelectorAll('button[aria-pressed]') : [];
        for (var i = 0; i < btns.length; i++) {
            var txt = (btns[i].textContent || '').trim().toUpperCase();
            if (txt === 'ON' || txt === 'OFF') return btns[i];
        }
        return null;
    }
    function isOn(t) {
        if (t.getAttribute('aria-pressed') === 'true') return true;
        if (t.getAttribute('aria-pressed') === 'false') return false;
        return (t.textContent || '').trim().toUpperCase() === 'ON';
    }
    function confirmButton() {
        var bs = document.querySelectorAll('[role="dialog"] button, [role="alertdialog"] button');
        for (var i = 0; i < bs.length; i++) {
            var t = (bs[i].textContent || '').trim().toLowerCase();
            if ((t === 'turn off' || t === 'confirm' || t === 'ok' || t === 'yes') && !bs[i].disabled) return bs[i];
        }
        return null;
    }
    return (async function() {
        var acc = await waitFor(accordion, 3000);
        if (!acc) { return 'hidden'; }
        // The toggle lives inside the accordion body — expand it if collapsed.
        if (acc.getAttribute('aria-expanded') === 'false') { realClick(acc); }
        var t = await waitFor(toggle, 4000);
        if (!t) { return 'no-toggle'; }
        if (!isOn(t)) { return 'was-off'; }
        for (var attempt = 0; attempt < 3; attempt++) {
            realClick(t);
            var confirm = await waitFor(confirmButton, 1200);
            if (confirm) { realClick(confirm); }
            var off = await waitFor(function() { var c = toggle(); return (c && !isOn(c)) ? 'off' : null; }, 2000);
            if (off) { return 'disabled'; }
            t = toggle() || t;
        }
        return 'still-on';
    })();
    """#

    /// True when a `disableSmartPricing` result means the form can be submitted.
    /// Shown after a $10+ listing posts with Smart Pricing still on although the seller
    /// wanted it off (the post goes ahead; this is the warning the user asked for).
    static let smartPricingLeftOnMessage = "Listed, but Smart Pricing is still on — Mercari may lower the price over time. Open the listing on Mercari and turn it off."

    static func smartPricingIsOff(_ result: String) -> Bool {
        result == "hidden" || result == "was-off" || result == "disabled"
    }

    // MARK: Listing status + sold-out controls (the listing's own page)

    /// Maps `readItemStatus`'s result. Anything unrecognised is `.unknown`, which is never
    /// acted on.
    static func listingState(raw: String?) -> MercariListingState {
        let status = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch status {
        case "on_sale", "active": return .active
        case "inactive", "stop", "stopped": return .inactive
        case "sold", "sold_out", "item_sold_out", "trading": return .sold
        case "unavailable": return .unavailable
        default: return status.hasSuffix("sold_out") ? .sold : .unknown
        }
    }

    /// The listing's status, or "" while the page has not rendered one. Reads only the
    /// item's own `status`: a text search of the page data also matches the seller's.
    /// Takes `itemId`.
    static let readItemStatus = #"""
    return (function() {
        var nd = document.getElementById('__NEXT_DATA__');
        if (nd) {
            try {
                var pp = JSON.parse(nd.textContent || '').props.pageProps;
                var item = pp && (pp.item || (pp.data && pp.data.item) || (pp.meta && pp.meta.item));
                if (item && typeof item.status === 'string' && item.status && (!item.id || item.id === itemId)) {
                    return item.status.toLowerCase();
                }
            } catch (e) {}
        }
        var ribbon = document.querySelector('[class*="RibbonTitle"]');
        if (ribbon && ribbon.textContent.trim()) { return ribbon.textContent.trim().toLowerCase(); }
        var buttons = document.querySelectorAll('button');
        for (var i = 0; i < buttons.length; i++) {
            var label = (buttons[i].textContent || '').trim().toLowerCase();
            if (label === 'item sold' || label === 'view order') { return 'sold_out'; }
        }
        var body = ((document.body && document.body.innerText) || '').toLowerCase();
        if (/no longer (for sale|available)/.test(body)) { return 'unavailable'; }
        return '';
    })();
    """#

    /// The seller's edit page: `login`, `form` (the listing exists), `gone`, or `wait`.
    static let editPageState = #"""
    return (function() {
        var href = location.href.toLowerCase();
        if (href.indexOf('login') !== -1 || href.indexOf('signin') !== -1) { return 'login'; }
        if (document.querySelector('input[data-testid="Title"]')) { return 'form'; }
        if (location.pathname.indexOf('/sell/edit/') === -1) { return 'gone'; }
        var body = (document.body && document.body.innerText) || '';
        if (/no longer (for sale|available)|not found|doesn.t exist|can.t find/i.test(body)) { return 'gone'; }
        return 'wait';
    })();
    """#

    /// Clicks the visible control labelled exactly Deactivate / Delete (optionally
    /// "... listing" / "... item"). Photo delete buttons are skipped. Takes `verb`
    /// ("deactivate" | "delete"). Returns `clicked` or `none`.
    static let pressListingControl = #"""
    return (function() {
        var pattern = new RegExp('^' + verb + '( (this )?(listing|item))?$', 'i');
        var controls = document.querySelectorAll('button, a, [role="button"], [role="menuitem"]');
        for (var i = 0; i < controls.length; i++) {
            var el = controls[i];
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') { continue; }
            if (!el.getClientRects().length) { continue; }
            var text = (el.textContent || '').replace(/\s+/g, ' ').trim();
            if (!pattern.test(text)) { continue; }
            var aria = (el.getAttribute('aria-label') || '').toLowerCase();
            if (aria.indexOf('photo') !== -1 || el.closest('[data-testid*="Photo"]')) { continue; }
            el.click();
            return 'clicked';
        }
        return 'none';
    })();
    """#

    /// Accepts the confirm dialog a control opened. Only ever looks inside a dialog, so it
    /// can't press an unrelated button on the page. Takes `verb`. Returns `confirmed`,
    /// `no-confirm` (a dialog without a matching button) or `no-dialog`.
    static let confirmListingDialog = #"""
    return (function() {
        var dialogs = document.querySelectorAll('[role="dialog"], [role="alertdialog"], [aria-modal="true"], [data-testid*="Modal"], [data-testid*="Dialog"]');
        if (!dialogs.length) { return 'no-dialog'; }
        var pattern = new RegExp('^((yes,? )?' + verb + '( (this )?(listing|item))?|yes|confirm)$', 'i');
        for (var d = 0; d < dialogs.length; d++) {
            var buttons = dialogs[d].querySelectorAll('button');
            for (var b = 0; b < buttons.length; b++) {
                var text = (buttons[b].textContent || '').replace(/\s+/g, ' ').trim();
                if (!buttons[b].disabled && pattern.test(text)) { buttons[b].click(); return 'confirmed'; }
            }
        }
        return 'no-confirm';
    })();
    """#

    /// Visible control labels, for the failure message when a control can't be found.
    static let visibleControlLabels = #"""
    return (function() {
        var seen = [];
        document.querySelectorAll('button, [role="button"]').forEach(function(el) {
            var text = (el.textContent || '').replace(/\s+/g, ' ').trim();
            if (text && text.length <= 30 && el.getClientRects().length && seen.indexOf(text) === -1) { seen.push(text); }
        });
        return seen.slice(0, 12).join(', ');
    })();
    """#
}
