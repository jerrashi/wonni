//
//  MercariScanJS.swift
//  wonni
//
//  The JavaScript used to extract in-progress (pending) sales from Mercari's
//  mypage/listings/in_progress page. Kept as a plain string constant — no WebKit
//  import — so wonniTests can run the exact production script against fixture HTML
//  in a real WKWebView and lock its behavior down (github issue #50).
//

import Foundation

enum MercariScanJS {
    /// Runs via `WKWebView.callJS` (callAsyncJavaScript), hence the leading `return`.
    /// Returns JSON: { items: [{id, name, price, thumbnailUrl, updatedStr}], diag: {...} }.
    ///
    /// Items are extracted in three phases (first phase to produce results wins):
    ///   1. __NEXT_DATA__ pageProps arrays (id + name + price straight from Mercari's JSON)
    ///   2. Table rows — pairs each row's item link with its date cell; name/price are
    ///      searched inside the link first, then across the whole row (Mercari's list
    ///      markup puts the title/price in sibling cells, not inside the anchor)
    ///   3. Bare anchor scan — any link whose href contains an m<digits> item id
    ///
    /// Items missing name/price are STILL returned (with nulls) — the Swift side keeps
    /// them and routes them through enrichment / the flag-and-fix UI instead of silently
    /// dropping them, which is what made earlier versions look like "0 sales found".
    static let extractInProgressItems = #"""
    return (function() {
        var results = [];
        var seen = new Set();
        var dateRe = /^\d{2}\/\d{2}\/\d{2,4}$/;
        var idRe = /(m\d+)/;

        function extractId(href) {
            var m = String(href || '').match(idRe);
            return m ? m[1] : null;
        }

        // Phase 1: try __NEXT_DATA__ — broadest search across all known key paths
        var nd = document.getElementById('__NEXT_DATA__');
        if (nd) {
            try {
                var root = JSON.parse(nd.textContent || '');
                var pp = root.props && root.props.pageProps;
                var candidates = [];
                if (pp) {
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
                    // Rough cents-vs-dollars guess only — callers re-fetch the confirmed
                    // item-page price before writing to Firestore (github issue #38).
                    var price = it.price ? (it.price > 1000 ? it.price / 100 : it.price) : null;
                    var upd = it.updated || it.updatedAt || it.updated_at || null;
                    results.push({ id: extractedId, name: it.name || null,
                                   price: price,
                                   thumbnailUrl: (it.thumbnails && it.thumbnails[0]) || it.thumbnailUrl || null,
                                   updatedStr: (typeof upd === 'string' && dateRe.test(upd)) ? upd : null,
                                   statusText: (typeof it.status === 'string') ? it.status : null });
                }
            } catch(e) {}
        }

        // Transaction-status phrases shown on in_progress rows. These must never be
        // mistaken for the item title (observed live: every row's first plain text is the
        // status, e.g. "Awaiting rating from buyer", while the title is in the img alt).
        var statusRe = /^(awaiting|ship by|shipped|in transit|on the way|delivered|rate (the )?buyer|label (created|printed)|arriv|waiting|pending|order (placed|complete)|preparing|out for delivery|return)/i;

        // Name + price finder. Title preference (confirmed against mercari.com desktop
        // source, 2026-07-12): data-testid → the styled-components display-name class
        // "ItemsList__T2WithBreakWord" (the sc- hash suffixes change per deploy; the
        // display-name fragment is stable) → thumbnail alt → leaf text. The status label
        // ("Awaiting rating from buyer") is identified structurally by its
        // "ItemStatusLabel" class — anything inside one is excluded from name candidates
        // even if its wording isn't in the known-phrase regex.
        function extractNamePrice(el) {
            if (!el) return { name: null, price: null, statusText: null };
            var priceRe = /^\$[\d,\.]+/;
            var nameEl = el.querySelector('[data-testid="ItemName"],[data-testid="item-name"]')
                      || el.querySelector('[class*="ItemsList__T2WithBreakWord"]');
            var priceEl = el.querySelector('[data-testid="ItemPrice"],[data-testid="item-price"]');
            var name = nameEl ? nameEl.innerText.trim() : null;
            if (!name) {
                for (var img of el.querySelectorAll('img')) {
                    var alt = (img.getAttribute('alt') || '').trim();
                    if (alt.length > 3 && !alt.toLowerCase().includes('avatar') && !statusRe.test(alt)) {
                        name = alt; break;
                    }
                }
            }
            function inStatusLabel(t) {
                return t.closest && t.closest('[class*="ItemStatusLabel"]') !== null;
            }
            var texts = Array.from(el.querySelectorAll('p, span, td, div'))
                .filter(function(t) { return t.children.length === 0; });
            var statusEl = el.querySelector('[class*="ItemStatusLabel"]')
                        || texts.find(function(t) { return statusRe.test(t.innerText.trim()); });
            if (!priceEl) priceEl = texts.find(function(t) { return priceRe.test(t.innerText.trim()); });
            if (!name) {
                var textEl = texts.find(function(t) {
                    var s = t.innerText.trim();
                    return s.length > 3 && !priceRe.test(s) && !dateRe.test(s)
                        && !statusRe.test(s) && !inStatusLabel(t);
                });
                if (textEl) name = textEl.innerText.trim();
            }
            var priceText = priceEl ? priceEl.innerText.replace(/[^0-9\.]/g,'') : null;
            return {
                name: name,
                price: priceText ? parseFloat(priceText) || null : null,
                statusText: statusEl ? statusEl.innerText.trim() : null
            };
        }

        // Phase 2: DOM scan — walk <tr> rows first so links pair with their date cells
        if (results.length === 0) {
            for (var row of document.querySelectorAll('tr')) {
                var link = Array.from(row.querySelectorAll('a[href]'))
                    .find(function(a) { return idRe.test(a.href); });
                if (!link) continue;
                var eid = extractId(link.href);
                if (!eid || seen.has(eid)) continue;
                seen.add(eid);
                var dateTd = Array.from(row.querySelectorAll('td'))
                    .find(function(td) { return dateRe.test(td.innerText.trim()); });
                // Search inside the link first, then widen to the whole row — Mercari's
                // list rows keep the title/price in cells NEXT TO the thumbnail link.
                var np = extractNamePrice(link);
                if (np.name === null || np.price === null || np.statusText === null) {
                    var rowNp = extractNamePrice(row);
                    np = { name: np.name !== null ? np.name : rowNp.name,
                           price: np.price !== null ? np.price : rowNp.price,
                           statusText: np.statusText !== null ? np.statusText : rowNp.statusText };
                }
                var imgEl = row.querySelector('img');
                results.push({ id: eid, name: np.name, price: np.price,
                               thumbnailUrl: imgEl ? imgEl.src : null,
                               updatedStr: dateTd ? dateTd.innerText.trim() : null,
                               statusText: np.statusText });
            }
        }

        // Phase 3: bare link scan — filter on JS .href (always absolute)
        if (results.length === 0) {
            for (var a of document.querySelectorAll('a[href]')) {
                if (!idRe.test(a.href)) continue;
                var eid = extractId(a.href);
                if (!eid || seen.has(eid)) continue;
                seen.add(eid);
                var np = extractNamePrice(a);
                if (np.name === null || np.price === null || np.statusText === null) {
                    var container = a.closest('li, article, tr') || a.parentElement;
                    var cNp = extractNamePrice(container);
                    np = { name: np.name !== null ? np.name : cNp.name,
                           price: np.price !== null ? np.price : cNp.price,
                           statusText: np.statusText !== null ? np.statusText : cNp.statusText };
                }
                var imgEl = a.querySelector('img');
                results.push({ id: eid, name: np.name, price: np.price,
                               thumbnailUrl: imgEl ? imgEl.src : null,
                               updatedStr: null,
                               statusText: np.statusText });
            }
        }

        // Diagnostics — surfaced in the UI so a TestFlight user can screenshot exactly
        // what the scan saw when it finds nothing.
        var allAnchors = Array.from(document.querySelectorAll('a[href]'));
        var idAnchors = allAnchors.filter(function(a) { return idRe.test(a.href); });
        return JSON.stringify({
            items: results,
            url: window.location.href,
            count: results.length,
            diag: {
                readyState: document.readyState,
                hasNextData: !!nd,
                anchorCount: allAnchors.length,
                idAnchorCount: idAnchors.length,
                rowCount: document.querySelectorAll('tr').length,
                sampleHrefs: idAnchors.slice(0, 5).map(function(a) { return a.getAttribute('href'); }),
                bodyChars: (document.body && document.body.innerText || '').length
            }
        });
    })();
    """#
}
