// Runs on AliExpress product pages (aliexpress.com/item/*)
// Scrapes product data from server-rendered JSON blobs and injects the margin overlay.

(function () {
  if (document.getElementById("wonni-drop-overlay")) return; // already injected

  // ── 1. Scrape product data ──────────────────────────────────────────────

  function scrapeProduct() {
    // AliExpress embeds product data in window.runParams (most reliable)
    const scripts = Array.from(document.querySelectorAll("script:not([src])"));
    let runParams = null;

    for (const s of scripts) {
      const text = s.textContent;
      if (text.includes("window.runParams")) {
        const match = text.match(/window\.runParams\s*=\s*(\{[\s\S]*?\});\s*(?:window|var|let|const|$)/);
        if (match) {
          try { runParams = JSON.parse(match[1]); break; } catch { /* keep trying */ }
        }
      }
      // Fallback: __AER_DATA__
      if (text.includes("__AER_DATA__")) {
        const match = text.match(/__AER_DATA__\s*=\s*(\{[\s\S]*?\});/);
        if (match) {
          try { runParams = JSON.parse(match[1]); break; } catch {}
        }
      }
    }

    const data = runParams?.data ?? runParams ?? {};
    const productInfo = data.productInfoComponent ?? data.pageComponent?.componentDataMap?.productInfo?.model ?? {};
    const priceInfo = data.priceComponent ?? data.pageComponent?.componentDataMap?.priceInfo?.model ?? {};
    const imageInfo = data.imageComponent ?? data.pageComponent?.componentDataMap?.imageList?.model ?? {};
    const skuInfo = data.skuComponent ?? data.pageComponent?.componentDataMap?.skuInfo?.model ?? {};

    // Extract product ID from URL
    const idMatch = location.pathname.match(/\/item\/(\d+)\.html/);
    const productId = idMatch?.[1] ?? "";

    // Title
    const title =
      productInfo.subject ??
      document.querySelector(".product-title-text")?.textContent?.trim() ??
      document.title.replace(" - AliExpress", "").trim();

    // Price (min of range)
    const priceStr =
      priceInfo.discountPrice?.minAmount?.value ??
      priceInfo.originalPrice?.minAmount?.value ??
      document.querySelector(".product-price-value")?.textContent?.replace(/[^0-9.]/g, "") ??
      "0";
    const price = parseFloat(priceStr) || 0;

    // Images
    const images = (imageInfo.imagePathList ?? [])
      .map((p) => (p.startsWith("http") ? p : `https:${p}`))
      .filter(Boolean)
      .slice(0, 8);
    if (!images.length) {
      document.querySelectorAll(".images-view-item img, .slider-item img").forEach((img) => {
        const src = img.dataset.src ?? img.src;
        if (src && !src.includes("placeholder")) images.push(src);
      });
    }

    // Variants
    const variants = [];
    const skuProps = skuInfo.skuPropertyList ?? [];
    skuProps.forEach((prop) => {
      prop.skuPropertyValues?.forEach((val) => {
        variants.push({ propId: prop.skuPropertyId, propName: prop.skuPropertyName, valueId: val.propertyValueId, valueName: val.propertyValueDisplayName ?? val.skuPropertyImagePath });
      });
    });

    return { productId, productUrl: location.href, title, price, images, variants };
  }

  // ── 2. Inject overlay UI ───────────────────────────────────────────────

  function createOverlay(product) {
    const el = document.createElement("div");
    el.id = "wonni-drop-overlay";
    el.style.cssText = `
      position: fixed; top: 120px; right: 20px; width: 280px;
      background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 10px;
      padding: 16px; z-index: 999999; font-family: -apple-system, sans-serif;
      color: #f0f0f0; box-shadow: 0 8px 32px rgba(0,0,0,0.6);
    `;

    // Static structure — no user data interpolated into innerHTML
    el.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
        <span style="font-size:14px;font-weight:600;color:#ff6b35">Wonni Drop</span>
        <button id="wonni-close" style="background:none;border:none;color:#888;cursor:pointer;font-size:18px;line-height:1">\xd7</button>
      </div>
      <div style="font-size:12px;color:#888;margin-bottom:4px">Margin Calculator</div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:12px">
        <div>
          <div style="font-size:11px;color:#888;margin-bottom:3px">AliExpress Cost</div>
          <input id="wonni-cost" type="number" step="0.01"
            style="width:100%;padding:6px 8px;background:#0f0f0f;border:1px solid #2a2a2a;border-radius:6px;color:#f0f0f0;font-size:13px" />
        </div>
        <div>
          <div style="font-size:11px;color:#888;margin-bottom:3px">TikTok Sell Price</div>
          <input id="wonni-sell" type="number" step="0.01"
            style="width:100%;padding:6px 8px;background:#0f0f0f;border:1px solid #2a2a2a;border-radius:6px;color:#f0f0f0;font-size:13px" />
        </div>
      </div>
      <div id="wonni-margin-display" style="background:#0f0f0f;border-radius:6px;padding:10px;margin-bottom:12px;font-size:13px"></div>
      <button id="wonni-import-btn"
        style="width:100%;padding:10px;background:#ff6b35;color:white;border:none;border-radius:6px;font-size:13px;font-weight:600;cursor:pointer">
        Import to Dashboard
      </button>
      <div id="wonni-status" style="margin-top:8px;font-size:12px;text-align:center;color:#888"></div>
    `;

    document.body.appendChild(el);

    // Set input values via DOM after insertion (keeps product data out of innerHTML)
    el.querySelector("#wonni-cost").value = product.price.toFixed(2);
    el.querySelector("#wonni-sell").value = (product.price * 2.5).toFixed(2);

    // Fee rate from extension storage (set by Settings page)
    let feeRate = 0.075;
    chrome.storage.local.get(["tiktokFeeRate"], (r) => {
      if (r.tiktokFeeRate) feeRate = r.tiktokFeeRate;
      updateMargin();
    });

    function updateMargin() {
      const cost = parseFloat(document.getElementById("wonni-cost")?.value) || 0;
      const sell = parseFloat(document.getElementById("wonni-sell")?.value) || 0;
      const shipping = 0; // TODO: add shipping input
      const grossMargin = sell * (1 - feeRate) - cost - shipping;
      const pct = sell > 0 ? ((grossMargin / sell) * 100).toFixed(1) : 0;
      const color = grossMargin > 0 ? "#22c55e" : "#ef4444";
      const display = document.getElementById("wonni-margin-display");
      if (display) {
        display.textContent = "";
        const amountSpan = document.createElement("span");
        amountSpan.style.cssText = `color:${color};font-weight:600`;
        amountSpan.textContent = `$${grossMargin.toFixed(2)}`;
        const labelSpan = document.createElement("span");
        labelSpan.style.color = "#888";
        labelSpan.textContent = " margin ";
        const pctSpan = document.createElement("span");
        pctSpan.style.color = color;
        pctSpan.textContent = `(${pct}%)`;
        const feeNote = document.createElement("div");
        feeNote.style.cssText = "color:#888;font-size:11px;margin-top:3px";
        feeNote.textContent = `After ~${(feeRate * 100).toFixed(1)}% TikTok fees`;
        display.append(amountSpan, labelSpan, pctSpan, feeNote);
      }
    }

    el.querySelector("#wonni-cost").addEventListener("input", updateMargin);
    el.querySelector("#wonni-sell").addEventListener("input", updateMargin);
    updateMargin();

    el.querySelector("#wonni-close").addEventListener("click", () => el.remove());

    el.querySelector("#wonni-import-btn").addEventListener("click", () => {
      const sellPrice = parseFloat(document.getElementById("wonni-sell")?.value) || product.price * 2.5;
      const status = document.getElementById("wonni-status");
      status.textContent = "Importing…";
      status.style.color = "#888";

      chrome.runtime.sendMessage(
        { type: "IMPORT_PRODUCT", data: { ...product, suggestedSellPrice: sellPrice } },
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

  // Wait for page to hydrate before scraping
  setTimeout(() => {
    const product = scrapeProduct();
    createOverlay(product);
  }, 1500);
})();
