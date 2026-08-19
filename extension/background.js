// Manifest V3 service worker
// Relays IMPORT_PRODUCT messages from content.js to the Cloud Function using a stored Firebase ID token.

const DEFAULT_DASHBOARD_URL = "https://wonni-app.web.app/web";
const FUNCTIONS_BASE = "https://us-central1-wonni-app.cloudfunctions.net";
const IMPORT_FUNCTIONS = {
  aliexpress: `${FUNCTIONS_BASE}/aliexpressImportProduct`,
  weverse: `${FUNCTIONS_BASE}/weverseImportProduct`,
};

// The dashboard SPA is always served at <origin>/web (Phase B merge, sharing
// wonni-app's Hosting site) — normalize to that regardless of what path the
// caller happened to be on when it sent its origin.
function normalizeDashboardUrl(rawUrl) {
  try {
    return new URL(rawUrl).origin + "/web";
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
  if (message.type === "START_MERCARI_CROSS_POST") {
    handleStartMercariCrossPost(message.payload)
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
  if (message.type === "START_MERCARI_EDIT") {
    handleStartMercariEdit(message.payload)
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
  if (message.type === "CHECK_MERCARI_SOLD") {
    handleCheckMercariSold()
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
  if (message.type === "CHECK_MERCARI_PULL_SYNC") {
    handleCheckMercariPullSync(message.mercariItemId)
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
  return true;
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
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
  if (message.type === "START_MERCARI_CROSS_POST") {
    handleStartMercariCrossPost(message.payload)
      .then(sendResponse)
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
  if (message.type === "GET_MERCARI_PAYLOAD") {
    chrome.storage.local.get(["pendingMercariPayload"], (res) => {
      sendResponse({ payload: res.pendingMercariPayload ?? null });
    });
    return true;
  }
  if (message.type === "GET_MERCARI_EDIT_PAYLOAD") {
    chrome.storage.local.get(["pendingMercariEditPayload"], (res) => {
      sendResponse({ payload: res.pendingMercariEditPayload ?? null });
    });
    return true;
  }
  if (message.type === "MERCARI_CROSS_POST_RESULT") {
    handleMercariCrossPostResult(message, sender.tab?.id)
      .then(() => sendResponse({ ok: true }))
      .catch(() => sendResponse({ ok: true })); // best-effort; content script doesn't retry on this response
    return true;
  }
  if (message.type === "MERCARI_EDIT_RESULT") {
    handleMercariEditResult(message, sender.tab?.id)
      .then(() => sendResponse({ ok: true }))
      .catch(() => sendResponse({ ok: true }));
    return true;
  }
  if (message.type === "FETCH_MERCARI_IMAGE") {
    fetchImageAsBase64(message.url)
      .then((base64) => sendResponse({ base64 }))
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
  if (message.type === "MERCARI_SOLD_CHECK_RESULT") {
    handleMercariSoldCheckResult(message.sold)
      .then(() => sendResponse({ ok: true }))
      .catch((e) => sendResponse({ error: e.message }));
    return true;
  }
});

// Content scripts' own fetch()/XHR calls are still subject to the PAGE's CORS policy
// in Manifest V3 — host_permissions only exempts requests made from a non-page
// context like this service worker. Mercari's page can't fetch our Storage-hosted
// product images directly (no Access-Control-Allow-Origin), so the background
// script fetches them here and hands the content script base64 bytes instead.
async function fetchImageAsBase64(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Image fetch failed (${res.status})`);
  const buffer = await res.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

// The content script reports its final outcome (success or timeout) here after
// driving the sell form. This is the only place that advances Firestore's
// listingStatus.mercari past "posting" — without it a cross-post looks stuck
// forever regardless of whether it actually succeeded.
async function handleMercariCrossPostResult(message, tabId) {
  const { idToken, pendingMercariPayload } = await chrome.storage.local.get(["idToken", "pendingMercariPayload"]);
  // Only clear the pending payload if it's still the one THIS report is about — a
  // stale/leftover tab from an earlier attempt (e.g. one that sat polling for its
  // full 3-minute timeout) can report long after a newer cross-post has already
  // stored its own payload; clearing unconditionally would wipe that newer attempt
  // out from under it before its content script ever reads it. Checking variantId
  // too matters now that multiple variants of the same product post sequentially.
  if (pendingMercariPayload?.productId === message.productId
    && pendingMercariPayload?.variantId === message.variantId) {
    await chrome.storage.local.remove(["pendingMercariPayload"]);
  }

  // Close the tab once the listing is confirmed live — speeds up bulk listing by
  // not leaving a trail of "done" tabs open. Only on success; leave failed/timed-out
  // tabs open so the form is there to finish or debug by hand.
  if (message.success && tabId != null) {
    chrome.tabs.remove(tabId).catch(() => {});
  }

  if (!idToken || !message.productId) return;

  await reportMercariStatus(idToken, message.productId, {
    variantId: message.variantId,
    status: message.success ? "active" : "failed",
    listingId: message.mercariItemId ?? null,
    url: message.mercariUrl ?? null,
    error: message.success ? null : (message.error ?? "Cross-post did not complete."),
    syncedTitle: message.syncedTitle,
    syncedDescription: message.syncedDescription,
    syncedPrice: message.syncedPrice,
    syncedImages: message.syncedImages,
  });
}

async function handleStartMercariCrossPost(payload) {
  if (!payload || !payload.title) {
    throw new Error("Invalid cross-post payload.");
  }
  await chrome.storage.local.set({ pendingMercariPayload: payload });
  const tab = await chrome.tabs.create({ url: "https://www.mercari.com/sell/", active: true });
  return { ok: true, tabId: tab.id };
}

// Pushes an edit payload (full desired state + diff of what changed) to an
// already-live Mercari listing by opening its edit page and letting
// mercari_content.js's runMercariEditFlow pick it up.
async function handleStartMercariEdit(payload) {
  if (!payload || !payload.productId || !payload.mercariItemId) {
    throw new Error("Invalid edit payload — missing productId or mercariItemId.");
  }
  await chrome.storage.local.set({ pendingMercariEditPayload: payload });
  const tab = await chrome.tabs.create({
    url: `https://www.mercari.com/sell/edit/${payload.mercariItemId}/`,
    active: true,
  });
  return { ok: true, tabId: tab.id };
}

// Mirrors handleMercariCrossPostResult, but for a sync-to-Mercari push: doesn't
// touch listingId/listingUrl (those don't change on an edit) and reports the
// new mercariSynced* baseline on success so the next push diffs against it.
async function handleMercariEditResult(message, tabId) {
  const { idToken, pendingMercariEditPayload } = await chrome.storage.local.get([
    "idToken", "pendingMercariEditPayload",
  ]);
  if (pendingMercariEditPayload?.productId === message.productId
    && pendingMercariEditPayload?.variantId === message.variantId) {
    await chrome.storage.local.remove(["pendingMercariEditPayload"]);
  }

  if (message.success && tabId != null) {
    chrome.tabs.remove(tabId).catch(() => {});
  }

  if (!idToken || !message.productId) return;

  await reportMercariStatus(idToken, message.productId, {
    variantId: message.variantId,
    status: message.success ? "active" : "failed",
    error: message.success ? null : (message.error ?? "Sync to Mercari did not complete."),
    syncedTitle: message.syncedTitle,
    syncedDescription: message.syncedDescription,
    syncedPrice: message.syncedPrice,
    syncedImages: message.syncedImages,
  });
}

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

// Reports a Mercari cross-post outcome to Firestore via updateMercariListingStatus.
// Best-effort — a failed status write shouldn't throw back into the content script.
async function reportMercariStatus(idToken, productId, outcome) {
  await fetch(`${FUNCTIONS_BASE}/updateMercariListingStatus`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${idToken}` },
    body: JSON.stringify({
      data: {
        productId,
        variantId: outcome.variantId ?? null,
        status: outcome.status,
        listingId: outcome.listingId ?? null,
        url: outcome.url ?? null,
        category: outcome.category ?? null,
        error: outcome.error ?? null,
        syncedTitle: outcome.syncedTitle ?? null,
        syncedDescription: outcome.syncedDescription ?? null,
        syncedPrice: outcome.syncedPrice ?? null,
        syncedImages: outcome.syncedImages ?? null,
      },
    }),
  }).catch(() => {});
}

// Opens Mercari's "in progress" listings page in a background tab so the
// content script can scrape sold items, record sales, and return the results.
async function handleCheckMercariSold() {
  const tab = await chrome.tabs.create({
    url: "https://www.mercari.com/mypage/listings/in_progress/?sortBy=7",
    active: false, // background tab
  });

  return { ok: true, tabId: tab.id };
}

// Opens a live Mercari item page and scrapes its current title/description/photos
// for pull-sync (importing changes made directly on Mercari).
async function handleCheckMercariPullSync(mercariItemId) {
  if (!mercariItemId) {
    throw new Error("Missing mercariItemId");
  }

  const itemUrl = `https://www.mercari.com/us/item/${mercariItemId}/`;

  // Open item page in background tab
  const tab = await chrome.tabs.create({ url: itemUrl, active: false });

  // Wait a moment for page to load, then send PULL_SYNC_CHECK to content script
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      chrome.tabs.remove(tab.id).catch(() => {});
      reject(new Error("Pull sync scrape timeout"));
    }, 15000); // 15 second timeout

    const checkContent = setInterval(async () => {
      try {
        chrome.tabs.sendMessage(tab.id, { type: "PULL_SYNC_CHECK" }, (response) => {
          if (chrome.runtime.lastError) {
            // Page not ready yet, wait a bit more
            return;
          }

          if (response?.success) {
            clearInterval(checkContent);
            clearTimeout(timeout);
            chrome.tabs.remove(tab.id).catch(() => {});
            resolve({ ok: true, data: response.data });
          }
        });
      } catch (err) {
        // Tab might have closed or message failed
      }
    }, 1000); // check every second
  });
}

// Processes sold items detected by mercari_sold_content.js — calls Cloud Function
// to match items to listings and record sales.
async function handleMercariSoldCheckResult(soldItems) {
  if (!Array.isArray(soldItems) || soldItems.length === 0) {
    console.log("[Wonni Drop] No sold items found");
    return;
  }

  const { idToken } = await chrome.storage.local.get(["idToken"]);
  if (!idToken) {
    console.error("[Wonni Drop] Not signed in, cannot record sales");
    return;
  }

  console.log(`[Wonni Drop] Found ${soldItems.length} sold items, recording via Cloud Function...`);

  try {
    const response = await fetch(`${FUNCTIONS_BASE}/recordMercariSalesBatch`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${idToken}`,
      },
      body: JSON.stringify({ data: { items: soldItems } }),
    });

    if (response.ok) {
      const result = await response.json();
      const successCount = result.result?.results?.filter((r) => r.success).length ?? 0;
      console.log(`[Wonni Drop] Recorded ${successCount} sale(s)`);
    } else {
      const error = await response.text();
      console.error("[Wonni Drop] recordMercariSalesBatch failed:", error);
    }
  } catch (err) {
    console.error("[Wonni Drop] Error calling recordMercariSalesBatch:", err);
  }
}
