/**
 * sale_fetch.js
 *
 * Cloud Functions for fetching platform-provided take-home after a sale.
 *   ebayGetOrderTakeHome  — eBay Finances API
 *   etsyGetReceiptTakeHome — Etsy Payments API
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const { refreshEtsyToken } = require("./etsy_auth");

if (admin.apps.length === 0) admin.initializeApp();

const ebayClientId = defineSecret("EBAY_CLIENT_ID");
const ebayCertId   = defineSecret("EBAY_CERT_ID");
const etsyClientId = defineSecret("ETSY_CLIENT_ID");

// ─────────────────────────────────────────────────────────────
// HTTP helper
// ─────────────────────────────────────────────────────────────

function makeRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolve({ statusCode: res.statusCode, body: data }));
    });
    req.on("error", reject);
    if (body) req.write(typeof body === "string" ? body : JSON.stringify(body));
    req.end();
  });
}

// ─────────────────────────────────────────────────────────────
// eBay token helper
// ─────────────────────────────────────────────────────────────

async function getEbayToken(uid, clientId, certId, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("ebay");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected || !doc.data().refreshToken) return null;
  const d = doc.data();
  if ((d.tokenExpiresAt?.toDate().getTime() ?? 0) > Date.now() + 300000) {
    return { accessToken: d.accessToken, isSandbox: d.isSandbox || false };
  }
  const creds = Buffer.from(`${clientId}:${certId}`).toString("base64");
  const scope = encodeURIComponent(
    "https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.fulfillment https://api.ebay.com/oauth/api_scope/sell.finances"
  );
  const reqBody = `grant_type=refresh_token&refresh_token=${encodeURIComponent(d.refreshToken)}&scope=${scope}`;
  const res = await makeRequest({
    hostname: d.isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com",
    path: "/identity/v1/oauth2/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Authorization": `Basic ${creds}`,
      "Content-Length": Buffer.byteLength(reqBody),
    },
  }, reqBody);
  if (res.statusCode !== 200) throw new Error(`eBay token refresh failed (${res.statusCode}): ${res.body}`);
  const token = JSON.parse(res.body);
  const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + token.expires_in * 1000);
  await ref.update({ accessToken: token.access_token, tokenExpiresAt: expiresAt });
  return { accessToken: token.access_token, isSandbox: d.isSandbox || false };
}

// ─────────────────────────────────────────────────────────────
// Etsy token helper
// ─────────────────────────────────────────────────────────────

async function getEtsyToken(uid, clientId, clientSecret, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("etsy");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected || !doc.data().refreshToken) return null;
  const d = doc.data();
  if ((d.tokenExpiresAt?.toDate().getTime() ?? 0) > Date.now() + 300000) {
    return { accessToken: d.accessToken, shopId: d.shopId };
  }
  const tokenData = await refreshEtsyToken(clientId, clientSecret, d.refreshToken);
  const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + tokenData.expires_in * 1000);
  await ref.update({ accessToken: tokenData.access_token, tokenExpiresAt: expiresAt });
  return { accessToken: tokenData.access_token, shopId: d.shopId };
}

// ─────────────────────────────────────────────────────────────
// ebayGetOrderTakeHome
// ─────────────────────────────────────────────────────────────

exports.ebayGetOrderTakeHome = onCall(
  { secrets: [ebayClientId, ebayCertId] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const { orderId } = request.data;
    if (!orderId) throw new HttpsError("invalid-argument", "orderId is required.");

    const db = admin.firestore();
    const uid = request.auth.uid;
    const tokenInfo = await getEbayToken(uid, ebayClientId.value(), ebayCertId.value(), db);
    if (!tokenInfo) throw new HttpsError("failed-precondition", "eBay account not connected.");

    const host = tokenInfo.isSandbox ? "apiz.sandbox.ebay.com" : "apiz.ebay.com";
    const res = await makeRequest({
      hostname: host,
      path: `/sell/finances/v1/transaction?orderId=${encodeURIComponent(orderId)}`,
      method: "GET",
      headers: {
        "Authorization": `Bearer ${tokenInfo.accessToken}`,
        "Content-Type": "application/json",
        "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
      },
    });

    if (res.statusCode === 403) {
      throw new HttpsError(
        "permission-denied",
        "eBay Finances permission missing. Please reconnect your eBay account in Settings."
      );
    }
    if (res.statusCode !== 200) {
      throw new HttpsError("internal", `eBay Finances API error (${res.statusCode}): ${res.body}`);
    }

    const data = JSON.parse(res.body);
    const transactions = data.transactions ?? [];
    if (transactions.length === 0) {
      throw new HttpsError("not-found", "No eBay transactions found for this order ID.");
    }
    const tx = transactions[0];
    const gross = parseFloat(tx.amount?.value ?? "0");
    const fees  = parseFloat(tx.totalFeeAmount?.value ?? "0");
    const takeHome = Math.round((gross - fees) * 100) / 100;

    console.log(`[ebayGetOrderTakeHome] orderId=${orderId} gross=${gross} fees=${fees} net=${takeHome}`);
    return { takeHome };
  }
);

// ─────────────────────────────────────────────────────────────
// etsyGetReceiptTakeHome
// ─────────────────────────────────────────────────────────────

exports.etsyGetReceiptTakeHome = onCall(
  { secrets: [etsyClientId] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const { receiptId } = request.data;
    if (!receiptId) throw new HttpsError("invalid-argument", "receiptId is required.");

    const db = admin.firestore();
    const uid = request.auth.uid;
    // etsySharedSecret is optional for PKCE-only clients
    const tokenInfo = await getEtsyToken(uid, etsyClientId.value(), null, db);
    if (!tokenInfo) throw new HttpsError("failed-precondition", "Etsy account not connected.");
    if (!tokenInfo.shopId) throw new HttpsError("failed-precondition", "Etsy shop ID not found.");

    const res = await makeRequest({
      hostname: "openapi.etsy.com",
      path: `/v3/application/shops/${tokenInfo.shopId}/payments?receipt_id=${encodeURIComponent(receiptId)}`,
      method: "GET",
      headers: {
        "x-api-key": etsyClientId.value(),
        "Authorization": `Bearer ${tokenInfo.accessToken}`,
        "Content-Type": "application/json",
      },
    });

    if (res.statusCode === 403) {
      throw new HttpsError(
        "permission-denied",
        "Etsy Transactions permission missing. Please reconnect your Etsy account in Settings."
      );
    }
    if (res.statusCode !== 200) {
      throw new HttpsError("internal", `Etsy Payments API error (${res.statusCode}): ${res.body}`);
    }

    const data = JSON.parse(res.body);
    const results = data.results ?? [];
    if (results.length === 0) {
      throw new HttpsError("not-found", "No Etsy payments found for this receipt ID.");
    }
    // Sum amount_net across all payments for the receipt (multi-item orders have multiple rows)
    let totalNet = 0;
    for (const payment of results) {
      const net = payment.amount_net;
      if (net) totalNet += net.amount / (net.divisor || 100);
    }
    const takeHome = Math.round(totalNet * 100) / 100;

    console.log(`[etsyGetReceiptTakeHome] receiptId=${receiptId} net=${takeHome}`);
    return { takeHome };
  }
);
