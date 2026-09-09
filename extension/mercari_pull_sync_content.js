// Mercari pull-sync content script — runs on live item pages
// Scrapes current title/description/photos and sends them to background for diff detection

(function () {
  if (window.__wonniMercariPullSyncInjected) return;
  window.__wonniMercariPullSyncInjected = true;

  console.log("[Wonni Drop] Mercari pull-sync content script loaded.");

  // Extract item ID from current URL (mercari.com/us/item/mXXXX)
  function extractItemIdFromUrl() {
    const match = window.location.href.match(/\/item\/(m[A-Za-z0-9]+)/);
    return match ? match[1] : null;
  }

  // Scrape live listing data from the page
  async function scrapeLiveListingData() {
    try {
      const itemId = extractItemIdFromUrl();
      if (!itemId) {
        console.warn("[Wonni Drop] Could not extract item ID from URL");
        return null;
      }

      // Wait for page to load (try __NEXT_DATA__ first, fallback to DOM)
      let nextData = null;
      for (let i = 0; i < 50; i++) {
        const script = document.querySelector("script#__NEXT_DATA__");
        if (script) {
          try {
            nextData = JSON.parse(script.textContent);
            break;
          } catch (e) {
            console.warn("[Wonni Drop] Failed to parse __NEXT_DATA__");
          }
        }
        await new Promise((r) => setTimeout(r, 200));
      }

      let title = null;
      let description = null;
      let photos = [];

      if (nextData) {
        try {
          const pageProps = nextData.props?.pageProps;
          const item = pageProps?.item || pageProps?.items?.[0];
          if (item) {
            title = item.name || item.title;
            description = item.description || item.body;
            // Extract photo URLs from item.images or item.photos
            photos = (item.images || item.photos || []).map((img) =>
              typeof img === "string" ? img : img.url || img.imageUrl
            );
          }
        } catch (e) {
          console.warn("[Wonni Drop] Failed to extract from __NEXT_DATA__", e);
        }
      }

      // Fallback: DOM scraping
      if (!title) {
        const titleEl = document.querySelector("h1, [data-testid*='Title'], .item-name");
        title = titleEl?.textContent?.trim();
      }

      if (!description) {
        const descEl = document.querySelector(".item-description, [data-testid*='Description']");
        description = descEl?.textContent?.trim();
      }

      if (photos.length === 0) {
        const photoEls = document.querySelectorAll("img[src*='mercari'], img[src*='cloudinary']");
        photos = Array.from(photoEls)
          .map((img) => img.src || img.dataset.src)
          .filter((url) => url && url.includes("http"));
      }

      return {
        itemId,
        title: title || null,
        description: description || null,
        photos: [...new Set(photos)], // deduplicate URLs
      };
    } catch (err) {
      console.error("[Wonni Drop] Scrape error:", err);
      return null;
    }
  }

  // Listen for PULL_SYNC message from background
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message.type === "PULL_SYNC_CHECK") {
      scrapeLiveListingData()
        .then((data) => {
          if (data) {
            sendResponse({ success: true, data });
          } else {
            sendResponse({ success: false, error: "Could not scrape listing data" });
          }
        })
        .catch((err) => {
          sendResponse({ success: false, error: err.message });
        });
      return true; // keep channel open for async response
    }
  });
})();
