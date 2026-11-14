// Mercari sold-items scanner — runs on mypage/listings/in_progress and /complete.
//
// Does NOTHING on its own (it used to auto-record every sale it saw). The web
// dashboard's Sales refresh asks background.js to open each list in a background
// tab; background.js then sends this script MERCARI_SCAN_TAB {knownIds} and it:
//   1. scrolls + extracts the rows, newest first (same three-phase extraction as
//      the iOS app's MercariScanJS, which is fixture-tested — keep them in step);
//   2. stops at the first row whose id is already known (recorded, waiting or
//      hidden): the list is newest first, so everything below it was seen before;
//   3. enriches each new row from its item + order-status pages (price, take-home,
//      sold date, photo) where those pages carry them;
//   4. answers with the rows. Recording happens on the dashboard
//      (reviewMercariSales / recordMercariSalesBatch), never here.
// A row missing its price or date is still returned: it shows as "Needs info".

(function () {
  if (window.__wonniMercariSoldInjected) return;
  window.__wonniMercariSoldInjected = true;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const dateRe = /^\d{2}\/\d{2}\/\d{2,4}$/;
  const idRe = /(m\d+)/;
  const statusRe = /^(awaiting|ship by|shipped|in transit|on the way|delivered|rate (the )?buyer|label (created|printed)|arriv|waiting|pending|order (placed|complete)|preparing|out for delivery|return|complete)/i;

  function extractId(href) {
    const m = String(href || "").match(idRe);
    return m ? m[1] : null;
  }

  function extractNamePrice(el) {
    if (!el) return { name: null, price: null };
    const priceRe = /^\$[\d,.]+/;
    const nameEl = el.querySelector('[data-testid="ItemName"],[data-testid="item-name"]')
      || el.querySelector('[class*="ItemsList__T2WithBreakWord"]');
    let priceEl = el.querySelector('[data-testid="ItemPrice"],[data-testid="item-price"]');
    let name = nameEl ? nameEl.innerText.trim() : null;
    if (!name) {
      for (const img of el.querySelectorAll("img")) {
        const alt = (img.getAttribute("alt") || "").trim();
        if (alt.length > 3 && !alt.toLowerCase().includes("avatar") && !statusRe.test(alt)) { name = alt; break; }
      }
    }
    const texts = Array.from(el.querySelectorAll("p, span, td, div")).filter((t) => t.children.length === 0);
    if (!priceEl) priceEl = texts.find((t) => priceRe.test(t.innerText.trim()));
    if (!name) {
      const t = texts.find((x) => {
        const s = x.innerText.trim();
        return s.length > 3 && !priceRe.test(s) && !dateRe.test(s) && !statusRe.test(s)
          && !(x.closest && x.closest('[class*="ItemStatusLabel"]'));
      });
      if (t) name = t.innerText.trim();
    }
    const priceText = priceEl ? priceEl.innerText.replace(/[^0-9.]/g, "") : null;
    return { name, price: priceText ? parseFloat(priceText) || null : null };
  }

  /** Rows currently on the page, in page order (newest first with sortBy=7). */
  function extractRows() {
    const results = [];
    const seen = new Set();
    const nd = document.getElementById("__NEXT_DATA__");
    if (nd) {
      try {
        const pp = JSON.parse(nd.textContent || "")?.props?.pageProps;
        let candidates = [];
        for (const v of Object.values(pp || {})) {
          if (Array.isArray(v) && v[0]?.id) candidates = candidates.concat(v);
          else if (v && typeof v === "object") {
            for (const v2 of Object.values(v)) if (Array.isArray(v2) && v2[0]?.id) candidates = candidates.concat(v2);
          }
        }
        for (const it of candidates) {
          const id = extractId(it.id) || extractId(it.itemId);
          if (!id || seen.has(id)) continue;
          seen.add(id);
          const upd = it.updated || it.updatedAt || it.updated_at || null;
          results.push({
            id, name: it.name || null,
            // Rough cents-vs-dollars guess; the item page price below wins when found.
            price: it.price ? (it.price > 1000 ? it.price / 100 : it.price) : null,
            thumbnailUrl: (it.thumbnails && it.thumbnails[0]) || it.thumbnailUrl || null,
            updatedStr: typeof upd === "string" && dateRe.test(upd) ? upd : null,
          });
        }
      } catch (e) { /* fall through to the DOM */ }
    }
    if (!results.length) {
      for (const row of document.querySelectorAll("tr")) {
        const link = Array.from(row.querySelectorAll("a[href]")).find((a) => idRe.test(a.href));
        const id = link && extractId(link.href);
        if (!id || seen.has(id)) continue;
        seen.add(id);
        const dateTd = Array.from(row.querySelectorAll("td")).find((td) => dateRe.test(td.innerText.trim()));
        let np = extractNamePrice(link);
        if (np.name === null || np.price === null) {
          const r = extractNamePrice(row);
          np = { name: np.name ?? r.name, price: np.price ?? r.price };
        }
        results.push({ id, ...np, thumbnailUrl: row.querySelector("img")?.src || null, updatedStr: dateTd ? dateTd.innerText.trim() : null });
      }
    }
    if (!results.length) {
      for (const a of document.querySelectorAll("a[href]")) {
        const id = idRe.test(a.href) && extractId(a.href);
        if (!id || seen.has(id)) continue;
        seen.add(id);
        let np = extractNamePrice(a);
        if (np.name === null || np.price === null) {
          const c = extractNamePrice(a.closest("li, article, tr") || a.parentElement);
          np = { name: np.name ?? c.name, price: np.price ?? c.price };
        }
        results.push({ id, ...np, thumbnailUrl: a.querySelector("img")?.src || null, updatedStr: null });
      }
    }
    return results;
  }

  async function fetchDoc(url) {
    try {
      const res = await fetch(url, { credentials: "include" });
      if (!res.ok) return null;
      return new DOMParser().parseFromString(await res.text(), "text/html");
    } catch { return null; }
  }
  const money = (s) => {
    const m = String(s || "").match(/\$\s*([0-9,]+(?:\.[0-9]{1,2})?)/);
    return m ? parseFloat(m[1].replace(/,/g, "")) : null;
  };
  const mdy = (s) => String(s || "").match(/(\d{1,2}\/\d{1,2}\/\d{2,4})/)?.[1] ?? null;

  /** Price / take-home / sold date / photo from the item + order-status pages. */
  async function enrich(id) {
    const out = {};
    const item = await fetchDoc(`https://www.mercari.com/us/item/${id}/`);
    if (item) {
      try {
        const pp = JSON.parse(item.getElementById("__NEXT_DATA__")?.textContent || "")?.props?.pageProps;
        const it = pp && (pp.item || pp.data?.item || pp.meta?.item);
        if (it?.price != null) out.price = it.price / 100;          // cents on the item page
        const photo = it?.photos?.[0]?.thumbnailUrl || it?.photos?.[0]?.url || it?.thumbnailUrl;
        if (photo && !/ogp_image|assets\/common/.test(photo)) out.thumbnailUrl = photo;
        if (it?.name) out.name = it.name;
      } catch { /* page without data */ }
      out.soldDate = out.soldDate || mdy(item.querySelector('[data-testid="ItemSoldTime"]')?.textContent);
    }
    const order = await fetchDoc(`https://www.mercari.com/transaction/order_status/${id}/`);
    if (order) {
      out.takeHome = money(order.querySelector('[data-testid="You-made-value"]')?.textContent);
      out.soldDate = mdy(order.querySelector('[data-testid="ItemSoldTime"]')?.textContent) || out.soldDate;
    }
    return out;
  }

  async function scanTab(knownIds) {
    const known = new Set(knownIds || []);
    if (/\/login|\/signup/.test(location.href)) return { needsLogin: true, rows: [] };
    // Wait for the list to render (Mercari is a client-rendered app).
    for (let i = 0; i < 15 && !document.querySelector('a[href*="/item/m"], #__NEXT_DATA__'); i++) await sleep(700);

    const fresh = [];
    let stopped = false, lastCount = 0, still = 0;
    for (let round = 0; round < 30 && !stopped; round++) {
      const rows = extractRows();
      for (const r of rows.slice(lastCount)) {
        if (known.has(r.id)) { stopped = true; break; }
        fresh.push(r);
      }
      if (stopped) break;
      if (rows.length <= lastCount) { if (++still >= 3) break; } else { still = 0; lastCount = rows.length; }
      window.scrollTo(0, document.body.scrollHeight);
      await sleep(1200);
    }

    const out = [];
    for (const r of fresh) {
      const e = await enrich(r.id);
      out.push({
        mercariItemId: r.id,
        title: e.name || r.name || null,
        priceSoldFor: e.price ?? r.price ?? null,
        takeHome: e.takeHome ?? null,
        soldDate: e.soldDate || r.updatedStr || null,
        thumbnailUrl: e.thumbnailUrl || r.thumbnailUrl || null,
      });
    }
    return { rows: out, stopped };
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "MERCARI_SCAN_TAB") return;
    scanTab(message.knownIds)
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message, rows: [] }));
    return true;
  });
})();
