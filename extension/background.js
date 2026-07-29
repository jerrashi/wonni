// Manifest V3 service worker
// Relays IMPORT_PRODUCT messages from content.js to the Cloud Function using a stored Firebase ID token.

const DEFAULT_DASHBOARD_URL = "https://wonni-dropship.web.app";
const FUNCTIONS_BASE = "https://us-central1-wonni-dropship.cloudfunctions.net";
const IMPORT_FUNCTIONS = {
  aliexpress: `${FUNCTIONS_BASE}/aliexpressImportProduct`,
  weverse: `${FUNCTIONS_BASE}/weverseImportProduct`,
};
const MERCARI_SELL_URL = "https://www.mercari.com/sell/";

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
  if (message.type === "MERCARI_POST_QUEUE") {
    handleMercariPostQueue(message.listings ?? [])
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true; // async
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

// Posts a queue of Mercari listings one at a time — unlike import, this
// can't be handed off to a Cloud Function chunk-runner: each listing needs
// its own real browser tab to actually drive Mercari's sell form. Reports
// each outcome (success or failure) individually via updateMercariListingStatus
// so the web app's live Firestore listener reflects progress without any
// separate messaging channel back to it.
async function handleMercariPostQueue(listings) {
  const { idToken } = await chrome.storage.local.get(["idToken"]);
  if (!idToken) throw new Error("Sign in to Wonni Drop first.");
  if (!listings.length) return { ok: true, postedCount: 0 };

  let postedCount = 0;
  for (const listing of listings) {
    try {
      const result = await postOneMercariListing(listing);
      await reportMercariStatus(idToken, listing, { status: "active", ...result });
      postedCount += 1;
    } catch (err) {
      await reportMercariStatus(idToken, listing, { status: "failed", error: err.message ?? "Unknown error." });
    }
  }
  return { ok: true, postedCount };
}

async function reportMercariStatus(idToken, listing, outcome) {
  // Best-effort — a failed status write shouldn't stop the rest of the
  // queue from being attempted.
  await fetch(`${FUNCTIONS_BASE}/updateMercariListingStatus`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${idToken}` },
    body: JSON.stringify({
      data: {
        productId: listing.productId,
        variantId: listing.variantId ?? null,
        status: outcome.status,
        listingId: outcome.listingId ?? null,
        url: outcome.url ?? null,
        category: outcome.category ?? null,
        error: outcome.error ?? null,
      },
    }),
  }).catch(() => {});
}

function waitForTabComplete(tabId) {
  return new Promise((resolve) => {
    function listener(id, info) {
      if (id === tabId && info.status === "complete") {
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      }
    }
    chrome.tabs.onUpdated.addListener(listener);
  });
}

// Opens a real tab on Mercari's sell page (active, not backgrounded — some
// sites throttle/behave differently in inactive tabs, and this needs to
// reliably drive a live form) and hands the listing payload to
// mercari_content.js to fill in and submit. Leaves the tab open on failure
// so the user (or a debugging pass) can see exactly what went wrong; only
// closes it on success.
async function postOneMercariListing(listing) {
  const tab = await chrome.tabs.create({ url: MERCARI_SELL_URL, active: true });
  await waitForTabComplete(tab.id);
  // The sell page is a client-rendered SPA — "complete" fires once the HTML
  // shell loads, not once the form has actually hydrated and is ready for
  // scripted input, so give it a moment before messaging the content script.
  await new Promise((resolve) => setTimeout(resolve, 1500));

  const response = await chrome.tabs.sendMessage(tab.id, { type: "FILL_AND_SUBMIT_LISTING", listing });
  if (!response?.ok) throw new Error(response?.error ?? "Mercari posting failed.");

  await chrome.tabs.remove(tab.id).catch(() => {});
  return { listingId: response.listingId, url: response.url, category: response.category };
}
