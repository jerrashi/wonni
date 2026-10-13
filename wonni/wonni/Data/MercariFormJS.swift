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
}
