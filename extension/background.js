// Manifest V3 service worker
// Relays IMPORT_PRODUCT messages from content.js to the Cloud Function using a stored Firebase ID token.

const DASHBOARD_URL = "https://wonni-dropship.web.app";
const IMPORT_FUNCTION_URL = "https://us-central1-wonni-dropship.cloudfunctions.net/aliexpressImportProduct";

// Receive token + fee rate updates from the web app
chrome.runtime.onMessageExternal.addListener((message, _sender, sendResponse) => {
  if (message.type === "SET_TOKEN") {
    chrome.storage.local.set({ idToken: message.idToken, userEmail: message.email });
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
    handleImport(message.data).then(sendResponse).catch((e) => sendResponse({ error: e.message }));
    return true; // keep channel open for async response
  }
});

async function handleImport(productData) {
  const { idToken } = await chrome.storage.local.get(["idToken"]);
  if (!idToken) {
    // Open dashboard so user can sign in; token is saved by popup.js after login
    chrome.tabs.create({ url: DASHBOARD_URL + "/login" });
    throw new Error("Sign in to Wonni Drop first.");
  }

  const response = await fetch(IMPORT_FUNCTION_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify({ data: { scrapedData: productData } }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Import failed (${response.status}): ${body}`);
  }

  const json = await response.json();
  const productId = json?.result?.productId;
  chrome.tabs.create({ url: `${DASHBOARD_URL}/?imported=${productId}` });
  return { productId };
}
