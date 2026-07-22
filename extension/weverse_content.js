// Runs on shop.weverse.io pages.
// Handles single-item overlay on detail pages and SCRAPE_PAGE_ITEMS messages from popup.

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

  // ── Scrape all items on current list page (Artist Shop or My Orders) ────────
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

      // Order items on My Orders page
      const ordersList = data.orders ?? data.orderItems ?? [];
      if (Array.isArray(ordersList)) {
        for (const order of ordersList) {
          const orderItems = order.orderItems ?? order.items ?? [order];
          for (const item of orderItems) {
            const saleId = String(item.saleId ?? item.productId ?? "");
            if (saleId && !seenSaleIds.has(saleId)) {
              seenSaleIds.add(saleId);
              items.push({
                saleId,
                productUrl: `https://shop.weverse.io/en/shop/USD/artists/1/sales/${saleId}`,
                title: item.saleName ?? item.productName ?? item.name ?? "Ordered Item",
                thumbnailUrl: item.thumbnailImageUrl ?? item.imageUrl ?? "",
                price: item.price ?? item.orderPrice ?? 0,
                artist: item.artistName ?? "",
                status: item.orderStatus ?? "ORDERED",
              });
            }
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

      const img = link.querySelector("img");
      const titleEl = link.querySelector('[class*="title"], [class*="name"], span, p, h3, h4');

      items.push({
        saleId,
        productUrl: link.href,
        title: titleEl?.textContent?.trim() || img?.alt || `Weverse Item ${saleId}`,
        thumbnailUrl: img?.src || "",
        price: 0,
        artist: "",
        status: "SALE",
      });
    });

    return items;
  }

  // ── Listen for messages from Extension Popup ────────────────────────────────
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === "SCRAPE_PAGE_ITEMS") {
      const items = scrapePageItems();
      sendResponse({ items, pageUrl: location.href, title: document.title });
      return true;
    }
  });

  // ── Single Product Overlay on Detail Pages ──────────────────────────────────
  if (document.getElementById("wonni-drop-overlay")) return;

  const saleMatch = location.pathname.match(/\/artists\/(\d+)\/sales\/(\d+)/);
  if (!saleMatch) return; // not a product detail page
  const saleId = saleMatch[2];

  function scrapeSingleSale() {
    const nextData = getNextData();
    const queries = nextData?.props?.pageProps?.$dehydratedState?.queries ?? [];
    const saleQuery = queries.find((q) => {
      const key = q.queryKey ?? [];
      return String(key[0] ?? "").includes("/sales/") && String(key[1]?.saleId) === String(saleId);
    });
    const sale = saleQuery?.state?.data;
    if (!sale?.saleId) return null;

    return {
      title: sale.name ?? "",
      price: sale.price?.salePrice ?? sale.price?.originalPrice ?? 0,
      status: sale.status ?? "",
      imageCount: (sale.thumbnailImageUrls?.length ?? 0) + (sale.detailImages?.length ?? 0),
      variantCount: sale.option?.options?.length ?? 0,
      artist: sale.labelArtistInfo?.name ?? "",
    };
  }

  function createOverlay(sale) {
    const el = document.createElement("div");
    el.id = "wonni-drop-overlay";
    el.style.cssText = `
      position: fixed; top: 120px; right: 20px; width: 280px;
      background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 10px;
      padding: 16px; z-index: 999999; font-family: -apple-system, sans-serif;
      color: #f0f0f0; box-shadow: 0 8px 32px rgba(0,0,0,0.6);
    `;

    el.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
        <span style="font-size:14px;font-weight:600;color:#ff6b35">Wonni Drop</span>
        <button id="wonni-close" style="background:none;border:none;color:#888;cursor:pointer;font-size:18px;line-height:1">×</button>
      </div>
      <div id="wonni-title" style="font-size:13px;font-weight:600;margin-bottom:6px"></div>
      <div id="wonni-meta" style="font-size:12px;color:#888;margin-bottom:12px"></div>
      <button id="wonni-import-btn"
        style="width:100%;padding:10px;background:#ff6b35;color:white;border:none;border-radius:6px;font-size:13px;font-weight:600;cursor:pointer">
        Import to Dashboard
      </button>
      <div id="wonni-status" style="margin-top:8px;font-size:12px;text-align:center;color:#888"></div>
    `;
    document.body.appendChild(el);

    el.querySelector("#wonni-title").textContent = sale.title;
    el.querySelector("#wonni-meta").textContent =
      `${sale.artist} · $${sale.price} · ${sale.imageCount} images · ${sale.variantCount} variants` +
      (sale.status && sale.status !== "SALE" ? ` · ${sale.status}` : "");

    el.querySelector("#wonni-close").addEventListener("click", () => el.remove());

    el.querySelector("#wonni-import-btn").addEventListener("click", () => {
      const status = el.querySelector("#wonni-status");
      status.textContent = "Importing…";
      status.style.color = "#888";

      chrome.runtime.sendMessage(
        { type: "IMPORT_PRODUCT", source: "weverse", data: { productUrl: location.href, title: sale.title } },
        (response) => {
          if (chrome.runtime.lastError || response?.error) {
            status.textContent = response?.error ?? "Import failed — are you signed in?";
            status.style.color = "#ef4444";
          } else {
            status.textContent = "Imported! Opening dashboard…";
            status.style.color = "#22c55e";
          }
        }
      );
    });
  }

  const start = Date.now();
  (function tryScrape() {
    const sale = scrapeSingleSale();
    if (sale) return createOverlay(sale);
    if (Date.now() - start < 10000) setTimeout(tryScrape, 500);
  })();
})();
