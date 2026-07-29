// Runs on shop.weverse.io pages.
// Detects an importable page (single product, order history, or a generic
// list page) and shows a small dismissible button; clicking it opens the
// real extension popup (popup.html) in an injected iframe, so there is only
// one implementation of "what does a found item look like" to maintain.

(function () {
  // ── Helper: parse __NEXT_DATA__ dehydrated state ──────────────────────────
  function getNextData() {
    const script = document.getElementById("__NEXT_DATA__");
    if (!script) return null;
    try {
      return JSON.parse(script.textContent);
    } catch {
      return null;
    }
  }

  // ── Scrape all items on current list page (Artist Shop or related-items rail) ─
  function scrapePageItems() {
    const items = [];
    const seenSaleIds = new Set();

    // 1. Inspect __NEXT_DATA__ React Query state
    const nextData = getNextData();
    const queries = nextData?.props?.pageProps?.$dehydratedState?.queries ?? [];

    for (const q of queries) {
      const data = q?.state?.data;
      if (!data) continue;

      // Sales array in shop / artist / category queries
      const salesList = Array.isArray(data) ? data : (data.sales ?? data.content ?? data.items ?? data.list ?? []);
      if (Array.isArray(salesList)) {
        for (const item of salesList) {
          const saleId = String(item.saleId ?? item.id ?? item.code ?? "");
          if (saleId && !seenSaleIds.has(saleId)) {
            seenSaleIds.add(saleId);
            const artistId = location.pathname.match(/\/artists\/(\d+)/)?.[1] ?? "1";
            const currency = location.pathname.match(/\/shop\/([A-Z]{3})/)?.[1] ?? "USD";
            items.push({
              saleId,
              productUrl: item.productUrl ?? `https://shop.weverse.io/en/shop/${currency}/artists/${artistId}/sales/${saleId}`,
              title: item.name ?? item.saleName ?? item.title ?? "Weverse Item",
              thumbnailUrl: item.thumbnailImageUrl ?? item.imageUrl ?? item.image ?? "",
              price: item.price?.salePrice ?? item.price?.originalPrice ?? item.price ?? 0,
              artist: item.labelArtistInfo?.name ?? item.artistName ?? "",
              status: item.status ?? "SALE",
            });
          }
        }
      }
    }

    // 2. DOM Fallback: Parse links matching /sales/(\d+) on page
    const links = document.querySelectorAll('a[href*="/sales/"]');
    links.forEach((link) => {
      const match = link.href.match(/\/sales\/(\d+)/);
      if (!match) return;
      const saleId = match[1];
      if (seenSaleIds.has(saleId)) return;
      seenSaleIds.add(saleId);

      const card = link.closest("li, div") ?? link;
      const img = link.querySelector("img");
      const titleEl = link.querySelector('[class*="title"], [class*="name"], span, p, h3, h4');

      // Images are frequently lazy-loaded (data-src/srcset filled in on
      // scroll) — a bare img.src is often still a blank placeholder.
      const thumbnailUrl =
        img?.currentSrc || img?.src || img?.dataset?.src || img?.getAttribute("data-src") || "";

      // The DOM fallback previously never attempted a price at all
      // (hardcoded 0) — look for a price-shaped node near the link and
      // parse the leading currency amount out of it.
      const priceEl = card.querySelector('[class*="price"]');
      const priceMatch = priceEl?.textContent?.match(/[\d,]+(\.\d+)?/);
      const price = priceMatch ? parseFloat(priceMatch[0].replace(/,/g, "")) : 0;

      items.push({
        saleId,
        productUrl: link.href,
        title: titleEl?.textContent?.trim() || img?.alt || `Weverse Item ${saleId}`,
        thumbnailUrl,
        price,
        artist: "",
        status: "SALE",
      });
    });

    return items;
  }

  // ── Order history: real API, not scraping ────────────────────────────────
  // shop.weverse.io/en/order/history renders order rows with href="#none" —
  // there's no saleId anywhere in the DOM or in __NEXT_DATA__ (confirmed:
  // that page's dehydrated queries are just app-shell state — user profile,
  // artist list, currency settings). The order list itself is fetched at
  // runtime from this endpoint instead.
  const ORDER_HISTORY_ENDPOINT = "https://shop.weverse.io/api/wvs/internal/order/api/v1/order";
  const ORDER_HISTORY_MAX_PAGES = 10;

  function isCancelledOrderItem(item) {
    if (item.status === "PAYMENT_CANCELED") return true;
    const haystack = `${item.status ?? ""} ${item.statusDisplayName ?? ""}`.toLowerCase();
    return haystack.includes("cancel");
  }

  async function fetchOrderHistory() {
    const items = [];
    let lastId = null;

    for (let page = 0; page < ORDER_HISTORY_MAX_PAGES; page++) {
      const url = new URL(ORDER_HISTORY_ENDPOINT);
      url.searchParams.set("orderStatusFilter", "");
      url.searchParams.set("itemFilter", "");
      if (lastId) url.searchParams.set("lastId", lastId);

      const response = await fetch(url.toString(), { credentials: "include" });
      if (!response.ok) {
        throw new Error(`Order history request failed (${response.status}).`);
      }
      const json = await response.json();

      for (const group of json.orderGroups ?? []) {
        for (const detail of group.orderDetails ?? []) {
          for (const item of detail.orderItems ?? []) {
            if (isCancelledOrderItem(item)) continue;
            items.push({
              saleId: String(item.saleId),
              productUrl: `https://shop.weverse.io/en/shop/${group.currencyCode}/artists/${item.artistId}/sales/${item.saleId}`,
              title: item.saleName ?? "Weverse Order",
              thumbnailUrl: item.imageUrl ?? "",
              price: item.salePrice ?? item.originalPrice ?? 0,
              artist: "",
              status: item.status ?? "",
              orderSheetNumber: detail.orderSheetNumber ?? null,
              orderSheetGroupNumber: group.orderSheetGroupNumber ?? null,
            });
          }
        }
      }

      if (json.isEnded || !json.lastId) break;
      lastId = json.lastId;
    }

    return items;
  }

  // ── Single-sale scraping (product-detail page) ──────────────────────────
  function scrapeSingleSale(saleId) {
    const nextData = getNextData();
    const queries = nextData?.props?.pageProps?.$dehydratedState?.queries ?? [];
    const saleQuery = queries.find((q) => {
      const key = q.queryKey ?? [];
      return String(key[0] ?? "").includes("/sales/") && String(key[1]?.saleId) === String(saleId);
    });
    const sale = saleQuery?.state?.data;
    if (!sale?.saleId) return null;

    return {
      saleId: String(sale.saleId),
      productUrl: location.href,
      title: sale.name ?? "",
      thumbnailUrl: sale.thumbnailImageUrls?.[0] ?? "",
      price: sale.price?.salePrice ?? sale.price?.originalPrice ?? 0,
      status: sale.status ?? "",
      imageCount: (sale.thumbnailImageUrls?.length ?? 0) + (sale.detailImages?.length ?? 0),
      variantCount: sale.option?.options?.length ?? 0,
      artist: sale.labelArtistInfo?.name ?? "",
    };
  }

  // ── Message handling (popup, whether opened from the toolbar icon or the
  //    in-page iframe, calls into this content script for page-derived data) ─
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "SCRAPE_PAGE_ITEMS") {
      sendResponse({ items: scrapePageItems(), pageUrl: location.href, title: document.title });
      return true;
    }
    if (message.type === "SCRAPE_SINGLE_ITEM") {
      const saleMatch = location.pathname.match(/\/artists\/(\d+)\/sales\/(\d+)/);
      const sale = saleMatch ? scrapeSingleSale(saleMatch[2]) : null;
      sendResponse({ item: sale });
      return true;
    }
    if (message.type === "FETCH_ORDER_HISTORY") {
      fetchOrderHistory()
        .then((items) => sendResponse({ items }))
        .catch((err) => sendResponse({ error: err.message }));
      return true; // async
    }
  });

  // ── Page-type detection + dismissible button ─────────────────────────────
  if (document.getElementById("wonni-drop-button")) return;

  const saleMatch = location.pathname.match(/\/artists\/(\d+)\/sales\/(\d+)/);
  const isOrderHistoryPage = /\/order\/history/.test(location.pathname);

  function createButton() {
    const btn = document.createElement("button");
    btn.id = "wonni-drop-button";
    btn.style.cssText = `
      position: fixed; bottom: 24px; right: 24px; z-index: 999999;
      width: 48px; height: 48px; border-radius: 50%; border: none;
      background: #ff6b35; color: white; font-family: -apple-system, sans-serif;
      font-size: 18px; font-weight: 700; cursor: grab;
      box-shadow: 0 4px 16px rgba(0,0,0,0.35);
      display: flex; align-items: center; justify-content: center;
      user-select: none;
    `;
    btn.textContent = "W";
    btn.title = "Wonni Drop — click to import";

    const closeBtn = document.createElement("span");
    closeBtn.textContent = "×";
    closeBtn.style.cssText = `
      position: absolute; top: -6px; right: -6px; width: 18px; height: 18px;
      border-radius: 50%; background: #1a1a1a; color: #f0f0f0; font-size: 13px;
      line-height: 18px; text-align: center; cursor: pointer;
    `;
    closeBtn.title = "Hide";
    btn.appendChild(closeBtn);

    document.body.appendChild(btn);

    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      btn.remove();
      closePopupIframe();
    });

    // Drag-to-reposition; a pointerdown/up with negligible movement counts
    // as a click that opens the popup instead.
    let dragState = null;
    btn.addEventListener("pointerdown", (e) => {
      if (e.target === closeBtn) return;
      // Capture the button's true on-screen position before any drag-related
      // style mutation happens — reading offsetLeft/offsetTop *after*
      // clearing right/bottom (below) would return the button's collapsed
      // static-flow position instead of where it visually is, which is what
      // caused the button to snap to the left edge on the first drag.
      const rect = btn.getBoundingClientRect();
      dragState = { startX: e.clientX, startY: e.clientY, moved: false, originLeft: rect.left, originTop: rect.top };
      btn.setPointerCapture(e.pointerId);
    });
    btn.addEventListener("pointermove", (e) => {
      if (!dragState) return;
      const dx = e.clientX - dragState.startX;
      const dy = e.clientY - dragState.startY;
      if (Math.abs(dx) > 4 || Math.abs(dy) > 4) {
        if (!dragState.moved) {
          // Switch from right/bottom-anchored to left/top-anchored using the
          // rect captured at pointerdown, so this doesn't jump.
          btn.style.right = "auto";
          btn.style.bottom = "auto";
          btn.style.left = `${dragState.originLeft}px`;
          btn.style.top = `${dragState.originTop}px`;
        }
        dragState.moved = true;
        btn.style.cursor = "grabbing";
        const maxLeft = window.innerWidth - btn.offsetWidth;
        const maxTop = window.innerHeight - btn.offsetHeight;
        const currentLeft = parseFloat(btn.style.left);
        const currentTop = parseFloat(btn.style.top);
        btn.style.left = `${Math.min(Math.max(currentLeft + dx, 0), maxLeft)}px`;
        btn.style.top = `${Math.min(Math.max(currentTop + dy, 0), maxTop)}px`;
        dragState.startX = e.clientX;
        dragState.startY = e.clientY;
      }
    });
    btn.addEventListener("pointerup", (e) => {
      if (e.target === closeBtn) { dragState = null; return; }
      const wasDrag = dragState?.moved;
      dragState = null;
      btn.style.cursor = "grab";
      if (!wasDrag) togglePopupIframe(btn);
    });

    return btn;
  }

  // ── Popup iframe: the exact same popup.html/popup.js the toolbar icon
  //    opens, injected into the page instead of the browser's native popup
  //    window (chrome.action.openPopup() requires a user-gesture context
  //    that doesn't reliably survive the content-script -> background
  //    message hop, so this sidesteps that entirely). ────────────────────
  let iframeWrapper = null;

  function closePopupIframe() {
    if (iframeWrapper) {
      iframeWrapper.remove();
      iframeWrapper = null;
      document.removeEventListener("mousedown", onOutsideClick, true);
    }
  }

  function onOutsideClick(e) {
    if (iframeWrapper && !iframeWrapper.contains(e.target) && e.target.id !== "wonni-drop-button") {
      closePopupIframe();
    }
  }

  const POPUP_WIDTH = 340;
  const POPUP_HEIGHT = 480;
  const POPUP_MARGIN = 12;

  // Prefer opening above the button, right-aligned to its right edge — but
  // the button is draggable anywhere on screen, so this has to clamp against
  // the actual viewport instead of assuming there's room in that direction.
  function computeIframePosition(anchorBtn) {
    const rect = anchorBtn.getBoundingClientRect();

    let left = rect.right - POPUP_WIDTH;
    let top = rect.top - POPUP_HEIGHT - POPUP_MARGIN;
    if (top < POPUP_MARGIN) top = rect.bottom + POPUP_MARGIN; // no room above — go below instead

    const maxLeft = window.innerWidth - POPUP_WIDTH - POPUP_MARGIN;
    const maxTop = window.innerHeight - POPUP_HEIGHT - POPUP_MARGIN;
    left = Math.min(Math.max(left, POPUP_MARGIN), Math.max(maxLeft, POPUP_MARGIN));
    top = Math.min(Math.max(top, POPUP_MARGIN), Math.max(maxTop, POPUP_MARGIN));

    return { left, top };
  }

  function togglePopupIframe(anchorBtn) {
    if (iframeWrapper) {
      closePopupIframe();
      return;
    }

    const { left, top } = computeIframePosition(anchorBtn);
    iframeWrapper = document.createElement("div");
    iframeWrapper.style.cssText = `
      position: fixed; z-index: 999999;
      left: ${left}px; top: ${top}px;
      width: ${POPUP_WIDTH}px; height: ${POPUP_HEIGHT}px; border-radius: 10px; overflow: hidden;
      box-shadow: 0 8px 32px rgba(0,0,0,0.5);
    `;

    const iframe = document.createElement("iframe");
    iframe.src = chrome.runtime.getURL("popup.html");
    iframe.style.cssText = "width: 100%; height: 100%; border: none;";
    iframeWrapper.appendChild(iframe);
    document.body.appendChild(iframeWrapper);

    setTimeout(() => document.addEventListener("mousedown", onOutsideClick, true), 0);
  }

  window.addEventListener("message", (event) => {
    if (!iframeWrapper) return;
    const iframe = iframeWrapper.querySelector("iframe");
    if (event.source !== iframe?.contentWindow) return;
    if (event.data?.type === "WONNI_CLOSE_POPUP") closePopupIframe();
  });

  // ── Detect on load ────────────────────────────────────────────────────────
  if (saleMatch) {
    const saleId = saleMatch[2];
    const start = Date.now();
    (function tryScrape() {
      if (scrapeSingleSale(saleId)) return createButton();
      if (Date.now() - start < 10000) setTimeout(tryScrape, 500);
    })();
  } else if (isOrderHistoryPage) {
    createButton();
  } else {
    const start = Date.now();
    (function tryScrape() {
      if (scrapePageItems().length > 0) return createButton();
      if (Date.now() - start < 5000) setTimeout(tryScrape, 500);
    })();
  }
})();
