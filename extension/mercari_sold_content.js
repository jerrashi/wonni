// Mercari sold-detection content script — runs on the user's "in progress" listings page
// Scrapes sold items, enriches with order-status details, calls recordMercariSale for each

(function () {
  if (window.__wonniMercariSoldInjected) return;
  window.__wonniMercariSoldInjected = true;

  console.log("[Wonni Drop] Mercari sold-detection content script loaded.");

  async function scrapeInProgressItems() {
    try {
      // Wait for __NEXT_DATA__ to be available (up to 10s)
      let nextData = null;
      for (let i = 0; i < 50; i++) {
        const script = document.querySelector("script#__NEXT_DATA__");
        if (script) {
          nextData = JSON.parse(script.textContent);
          break;
        }
        await new Promise((r) => setTimeout(r, 200));
      }

      if (!nextData) {
        console.warn("[Wonni Drop] No __NEXT_DATA__ found");
        return [];
      }

      // Extract items from Mercari's page state — the structure varies, so try multiple paths
      const items = [];
      try {
        const props = nextData.props?.pageProps;
        if (props?.itemList?.items) {
          items.push(...props.itemList.items);
        }
      } catch (e) {
        console.warn("[Wonni Drop] Failed to extract items from __NEXT_DATA__", e);
      }

      // Also try DOM scraping as fallback (tr rows, if they're visible)
      const rows = document.querySelectorAll("tbody tr");
      if (rows.length > 0 && items.length === 0) {
        console.log(`[Wonni Drop] Found ${rows.length} DOM rows, trying to scrape...`);
        rows.forEach((row) => {
          const link = row.querySelector("a[href*='/item/']");
          const status = row.textContent;
          if (link && status) {
            const itemIdMatch = link.href.match(/\/item\/(m[A-Za-z0-9]+)/);
            if (itemIdMatch) {
              items.push({
                id: itemIdMatch[1],
                url: link.href,
                name: link.textContent.trim(),
                statusText: status,
              });
            }
          }
        });
      }

      return items;
    } catch (err) {
      console.error("[Wonni Drop] Scrape error:", err);
      return [];
    }
  }

  // Scrape a single item's order-status page for sale details
  async function enrichItem(itemId) {
    try {
      const statusUrl = `https://www.mercari.com/transaction/order_status/${itemId}/`;
      const response = await fetch(statusUrl);
      if (!response.ok) return null;

      const html = await response.text();
      const parser = new DOMParser();
      const doc = parser.parseFromString(html, "text/html");

      // Parse sold date, take-home, etc. from data-testid selectors
      const soldDateEl = doc.querySelector("[data-testid*='Time'], [data-testid*='Date']");
      const takeHomeEl = doc.querySelector("[data-testid*='You-made'], [data-testid*='TakeHome']");
      const priceEl = doc.querySelector("[data-testid*='Price'], [data-testid*='Sold']");

      const soldDate = soldDateEl?.textContent?.match(/(\d{1,2})\/(\d{1,2})\/(\d{2,4})/)?.[0];
      const takeHomeMatch = takeHomeEl?.textContent?.match(/\$([0-9,]+(?:\.[0-9]{2})?)/);
      const priceMatch = priceEl?.textContent?.match(/\$([0-9,]+(?:\.[0-9]{2})?)/);

      return {
        soldDate,
        takeHome: takeHomeMatch ? parseFloat(takeHomeMatch[1].replace(/,/g, "")) : null,
        priceSoldFor: priceMatch ? parseFloat(priceMatch[1].replace(/,/g, "")) : null,
      };
    } catch (err) {
      console.warn(`[Wonni Drop] Enrich failed for ${itemId}:`, err);
      return null;
    }
  }

  // Main flow: scrape, enrich, and send to background script for recording
  async function detectAndRecordSoldItems() {
    console.log("[Wonni Drop] Starting sold-item detection...");
    const items = await scrapeInProgressItems();
    console.log(`[Wonni Drop] Found ${items.length} items`);

    if (items.length === 0) {
      chrome.runtime.sendMessage({
        type: "MERCARI_SOLD_CHECK_RESULT",
        sold: [],
      });
      return;
    }

    const sold = [];
    for (const item of items) {
      const enrich = await enrichItem(item.id);
      if (enrich && enrich.priceSoldFor) {
        sold.push({
          mercariItemId: item.id,
          priceSoldFor: enrich.priceSoldFor,
          takeHome: enrich.takeHome,
          soldDate: enrich.soldDate,
          title: item.name || item.title || "",
        });
      }
    }

    console.log(`[Wonni Drop] Found ${sold.length} sold items`);
    chrome.runtime.sendMessage({
      type: "MERCARI_SOLD_CHECK_RESULT",
      sold,
    });
  }

  // Auto-run on page load
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", detectAndRecordSoldItems);
  } else {
    detectAndRecordSoldItems();
  }
})();
