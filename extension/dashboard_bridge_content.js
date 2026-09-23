// Runs on the Wonni dashboard's own origin (wonni-app.web.app / localhost —
// see manifest.json's content_scripts match list), NOT shop.weverse.io.
//
// Bridges window.wonniExtension.estimateShipping(productUrl) — called from
// web/src/components/WeverseShopImportModal.jsx — from the page's own JS
// world into this content script's chrome.runtime access. A content script
// can't hand the page a function that reaches across the isolated-world
// boundary directly, so this injects a small page-context script that talks
// back to this content script via window.postMessage, which then relays to
// background.js's ESTIMATE_SHIPPING_COST handler (which opens a background
// tab on shop.weverse.io to run weverse_content.js's probeShippingCost).
(function () {
  const BRIDGE_SOURCE = "wonni-dashboard-bridge";

  // Runs in the PAGE's own JS context, not this content script's isolated
  // one — window.wonniExtension only becomes visible to page code this way.
  // BRIDGE_SOURCE is inlined as a literal (not closed over) since
  // Function.prototype.toString() only serializes the function body text;
  // referencing the outer const here would be a ReferenceError once
  // re-evaluated in the page's own global scope.
  function installPageBridge() {
    if (window.wonniExtension) return;
    window.wonniExtension = {
      estimateShipping(productUrl) {
        return new Promise((resolve, reject) => {
          const requestId = `${Date.now()}-${Math.random()}`;
          function onMessage(event) {
            if (event.source !== window || event.data?.source !== "wonni-dashboard-bridge") return;
            if (event.data.type !== "ESTIMATE_SHIPPING_RESPONSE" || event.data.requestId !== requestId) return;
            window.removeEventListener("message", onMessage);
            if (event.data.error) {
              reject(Object.assign(new Error(event.data.error), { errorCode: event.data.errorCode }));
            } else {
              resolve(event.data.shippingCost);
            }
          }
          window.addEventListener("message", onMessage);
          window.postMessage(
            { source: "wonni-dashboard-bridge", type: "ESTIMATE_SHIPPING_REQUEST", requestId, productUrl },
            "*"
          );
        });
      },
      // Opens Weverse's own shipping-address settings in a new tab so the
      // user can fill one in, when a probe comes back MISSING_ADDRESS.
      openWeverseAddressPage() {
        window.postMessage({ source: "wonni-dashboard-bridge", type: "OPEN_ADDRESS_PAGE_REQUEST" }, "*");
      },
    };
  }

  const script = document.createElement("script");
  script.textContent = `(${installPageBridge.toString()})();`;
  (document.head || document.documentElement).appendChild(script);
  script.remove();

  // Relay page requests into the extension's own message-passing world.
  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== BRIDGE_SOURCE) return;

    if (event.data.type === "ESTIMATE_SHIPPING_REQUEST") {
      chrome.runtime.sendMessage(
        { type: "ESTIMATE_SHIPPING_COST", productUrl: event.data.productUrl },
        (response) => {
          window.postMessage({
            source: BRIDGE_SOURCE,
            type: "ESTIMATE_SHIPPING_RESPONSE",
            requestId: event.data.requestId,
            shippingCost: response?.shippingCost ?? null,
            error: chrome.runtime.lastError?.message ?? response?.error ?? null,
            errorCode: response?.errorCode ?? null,
          }, "*");
        }
      );
    }
    if (event.data.type === "OPEN_ADDRESS_PAGE_REQUEST") {
      chrome.runtime.sendMessage({ type: "OPEN_WEVERSE_ADDRESS_PAGE" });
    }
  });
})();
