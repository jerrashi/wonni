// Manifest V3 service worker
// Relays IMPORT_PRODUCT messages from content.js to the Cloud Function using a stored Firebase ID token.

const DEFAULT_DASHBOARD_URL = "https://wonni-dropship.web.app";
const FUNCTIONS_BASE = "https://us-central1-wonni-dropship.cloudfunctions.net";
const IMPORT_FUNCTIONS = {
  aliexpress: `${FUNCTIONS_BASE}/aliexpressImportProduct`,
  weverse: `${FUNCTIONS_BASE}/weverseImportProduct`,
};

function normalizeDashboardUrl(rawUrl) {
  try {
    return new URL(rawUrl).origin;
  } catch {
    return DEFAULT_DASHBOARD_URL;
  }
}

async function getDashboardUrl() {
  const { dashboardBaseUrl } = await chrome.storage.local.get(["dashboardBaseUrl"]);
  return normalizeDashboardUrl(dashboardBaseUrl);
}

// Receive token + fee rate updates from the web app
chrome.runtime.onMessageExternal.addListener((message, _sender, sendResponse) => {
  if (message.type === "SET_TOKEN") {
    chrome.storage.local.set({ idToken: message.idToken, userEmail: message.email });
    sendResponse({ ok: true });
  }
  if (message.type === "SET_DASHBOARD_URL") {
    chrome.storage.local.set({ dashboardBaseUrl: normalizeDashboardUrl(message.dashboardBaseUrl) });
    sendResponse({ ok: true });
  }
  if (message.type === "SET_FEE_RATE") {
    chrome.storage.local.set({ tiktokFeeRate: message.feeRate });
    sendResponse({ ok: true });
  }
  return true;
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message.type === "IMPORT_PRODUCT") {
    handleImport(message.data, message.source ?? "aliexpress")
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true; // keep channel open for async response
  }
  if (message.type === "BULK_IMPORT_PRODUCTS") {
    handleBulkImport(message.items, message.source ?? "weverse")
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
});

async function handleImport(productData, source) {
  const { idToken } = await chrome.storage.local.get(["idToken"]);
  const dashboardUrl = await getDashboardUrl();
  if (!idToken) {
    // Open dashboard so user can sign in; token is saved by popup.js after login
    chrome.tabs.create({ url: `${dashboardUrl}/login` });
    throw new Error("Sign in to Wonni Drop first.");
  }

  // Weverse: server re-scrapes from the URL. AliExpress: send scraped page data.
  const payload = source === "weverse"
    ? { productUrl: productData.productUrl }
    : { scrapedData: productData };

  const response = await fetch(IMPORT_FUNCTIONS[source] ?? IMPORT_FUNCTIONS.aliexpress, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify({ data: payload }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Import failed (${response.status}): ${body}`);
  }

  const json = await response.json();
  const productId = json?.result?.productId;
  chrome.tabs.create({ url: `${dashboardUrl}/?imported=${productId}` });
  return { productId };
}

async function handleBulkImport(items, source) {
  const { idToken } = await chrome.storage.local.get(["idToken"]);
  const dashboardUrl = await getDashboardUrl();
  if (!idToken) {
    chrome.tabs.create({ url: `${dashboardUrl}/login` });
    throw new Error("Sign in to Wonni Drop first.");
  }

  const endpoint = `${FUNCTIONS_BASE}/weverseBulkImportProducts`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify({ data: { items } }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Bulk import failed (${response.status}): ${body}`);
  }

  const json = await response.json();
  return json?.result ?? { importedCount: 0 };
}
