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

    // Variants — prefer the real per-SKU price/stock table (each entry
    // carries a skuAttr string like "14:200000343#Red;200007763:201336100#L"
    // plus a sku id) so the backend's skuAttr parser
    // (functions/aliexpress_product.js's mapAliexpressVariants) can build
    // real options/variants exactly like the DS-API import path does.
    // AliExpress's client-side JSON layout varies across pages/experiments,
    // so this searches for the list by shape (an array of objects each
    // carrying a skuAttr string) instead of one hardcoded key, since the
    // previous code (skuPropertyList's propId/propName/valueId/valueName
    // taxonomy) never matched what the backend parser reads and silently
    // produced zero variants for every extension-scraped import.
    const variants = scrapeVariants(skuInfo, price);

    return { productId, productUrl: location.href, title, price, images, variants };
  }

  function findSkuAttrList(root, depth) {
    if (!root || typeof root !== "object" || depth > 4) return null;
    if (Array.isArray(root)) {
      if (root.length && root.every((e) => e && typeof e === "object" && typeof e.skuAttr === "string")) {
        return root;
      }
      for (const entry of root) {
        const found = findSkuAttrList(entry, depth + 1);
        if (found) return found;
      }
      return null;
    }
    for (const key of Object.keys(root)) {
      const found = findSkuAttrList(root[key], depth + 1);
      if (found) return found;
    }
    return null;
  }

  // The backend (functions/aliexpress_product.js's parseSkuAttr) expects
  // "pid:vid#Name:Value" segments — but the page's internal per-SKU id list
  // may only carry bare "pid:vid" pairs with the human-readable name/value
  // living separately in skuPropertyList. Rebuild the canonical labeled
  // string from that taxonomy rather than assuming the scraped string
  // already has a label, so parsing is correct either way.
  function buildCanonicalSkuAttr(rawAttr, skuPropertyList) {
    if (typeof rawAttr !== "string" || !rawAttr) return "";
    const propById = new Map();
    (skuPropertyList ?? []).forEach((prop) => {
      const valueById = new Map();
      prop.skuPropertyValues?.forEach((val) => {
        valueById.set(String(val.propertyValueId), val.propertyValueDisplayName ?? val.skuPropertyImagePath ?? "");
      });
      propById.set(String(prop.skuPropertyId), { name: prop.skuPropertyName ?? "Option", valueById });
    });

    return rawAttr
      .split(";")
      .map((segment) => {
        const hashIdx = segment.indexOf("#");
        const idPart = hashIdx === -1 ? segment : segment.slice(0, hashIdx);
        const existingLabel = hashIdx === -1 ? "" : segment.slice(hashIdx + 1);
        const [pid, vid] = idPart.split(":");
        const prop = propById.get(pid);
        const valueName = prop?.valueById.get(vid);
        const label = valueName ? `${prop.name}:${valueName}` : existingLabel;
        return label ? `${idPart}#${label}` : idPart;
      })
      .filter(Boolean)
      .join(";");
  }

  function scrapeVariants(skuInfo, fallbackPrice) {
    const skuAttrList = findSkuAttrList(skuInfo, 0);
    if (skuAttrList) {
      return skuAttrList.map((sku) => ({
        skuId: sku.skuId ?? sku.skuID ?? sku.id ?? "",
        skuAttr: buildCanonicalSkuAttr(sku.skuAttr, skuInfo.skuPropertyList),
        price:
          parseFloat(
            sku.skuVal?.skuAmount?.value ??
              sku.skuVal?.actAmount?.value ??
              sku.skuActivityAmount?.value ??
              sku.price
          ) || fallbackPrice,
      }));
    }

    // Fallback: only the property/value taxonomy is available (no real SKU
    // combos linking them together) — seed one opaque "Option" dimension
    // (mirroring Weverse's opaque-variant-name fallback) so the import at
    // least captures something the user can split into real dimensions
    // later, instead of silently importing with zero variants.
    const variants = [];
    const skuProps = skuInfo.skuPropertyList ?? [];
    skuProps.forEach((prop) => {
      prop.skuPropertyValues?.forEach((val) => {
        const label = `${prop.skuPropertyName ?? "Option"} - ${
          val.propertyValueDisplayName ?? val.skuPropertyImagePath ?? ""
        }`.trim();
        if (!label) return;
        variants.push({
          skuId: `${prop.skuPropertyId}-${val.propertyValueId}`,
          skuAttr: `Option:${label}`,
          price: fallbackPrice,
        });
      });
    });
    return variants;
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
    // Suggested list price: 2× cost grossed up for ~10% fees, nearest dollar.
    // Matches the dashboard's "✨ Suggested" chip. The user can edit it, and
    // whatever's in the box on import becomes the product's listingPrice.
    el.querySelector("#wonni-sell").value = String(Math.round((2 * product.price) / 0.9));

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
      const sellInput = parseFloat(document.getElementById("wonni-sell")?.value);
      const listingPrice = sellInput > 0 ? sellInput : null;
      const status = document.getElementById("wonni-status");
      status.textContent = "Importing…";
      status.style.color = "#888";

      chrome.runtime.sendMessage(
        { type: "IMPORT_PRODUCT", data: { ...product, listingPrice } },
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
