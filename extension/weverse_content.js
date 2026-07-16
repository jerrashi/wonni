// Runs on shop.weverse.io pages. On a sale detail page, scrapes the sale from
// the server-rendered __NEXT_DATA__ blob and injects an import overlay.

(function () {
  if (document.getElementById("wonni-drop-overlay")) return;

  const saleMatch = location.pathname.match(/\/artists\/(\d+)\/sales\/(\d+)/);
  if (!saleMatch) return; // not a product detail page
  const saleId = saleMatch[2];

  function scrapeSale() {
    const script = document.getElementById("__NEXT_DATA__");
    if (!script) return null;
    let nextData;
    try { nextData = JSON.parse(script.textContent); } catch { return null; }

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

    // Static structure — sale data is set via textContent below
    el.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
        <span style="font-size:14px;font-weight:600;color:#ff6b35">Wonni Drop</span>
        <button id="wonni-close" style="background:none;border:none;color:#888;cursor:pointer;font-size:18px;line-height:1">\xd7</button>
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

      // Server re-scrapes the page itself — we only need to send the URL
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

  // Wait for hydration; __NEXT_DATA__ is server-rendered so this is usually instant
  const start = Date.now();
  (function tryScrape() {
    const sale = scrapeSale();
    if (sale) return createOverlay(sale);
    if (Date.now() - start < 10000) setTimeout(tryScrape, 500);
  })();
})();
