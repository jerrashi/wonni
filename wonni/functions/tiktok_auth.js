const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const crypto = require("crypto");

const TT_APP_KEY = defineSecret("TIKTOK_APP_KEY");
const TT_APP_SECRET = defineSecret("TIKTOK_APP_SECRET");

function makeHttpsRequest(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

// Sign a TikTok Shop API request
// Signature = HMAC-SHA256(appSecret, path + sorted_query_params + body)
function signTiktokRequest(appSecret, path, params, bodyStr = "") {
  const sorted = Object.keys(params)
    .filter((k) => k !== "sign" && k !== "access_token")
    .sort()
    .map((k) => `${k}${params[k]}`)
    .join("");
  const input = `${path}${sorted}${bodyStr}`;
  return crypto.createHmac("sha256", appSecret).update(input).digest("hex");
}

// Exchange authorization code for access + refresh tokens
exports.tiktokExchangeToken = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { code, state } = request.data;
    if (!code) throw new HttpsError("invalid-argument", "Missing code.");

    const stateRef = admin.firestore().doc(`users/${uid}/oauthStates/tiktok`);
    const stateSnap = await stateRef.get();
    const stored = stateSnap.data();
    if (!stored?.nonce || stored.nonce !== state) {
      throw new HttpsError("invalid-argument", "Invalid OAuth state.");
    }
    if (Date.now() - stored.createdAt.toMillis() > 10 * 60 * 1000) {
      await stateRef.delete();
      throw new HttpsError("deadline-exceeded", "OAuth state expired.");
    }
    await stateRef.delete();

    const appKey = TT_APP_KEY.value();
    const appSecret = TT_APP_SECRET.value();
    const timestamp = Math.floor(Date.now() / 1000);

    const params = { app_key: appKey, auth_code: code, grant_type: "authorized_code", timestamp };
    const sign = signTiktokRequest(appSecret, "/api/v2/token/get", params);
    const qs = new URLSearchParams({ ...params, sign }).toString();

    const result = await makeHttpsRequest({
      hostname: "auth.tiktok-shops.com",
      path: `/api/v2/token/get?${qs}`,
      method: "GET",
    });

    let parsed;
    try { parsed = JSON.parse(result.body); } catch {
      throw new HttpsError("internal", "Invalid TikTok token response.");
    }

    if (parsed.code !== 0 || !parsed.data?.access_token) {
      throw new HttpsError("internal", `TikTok token error: ${parsed.message ?? result.body}`);
    }

    const { access_token, refresh_token, access_token_expire_in, seller_name, open_id } = parsed.data;
    const shopId = parsed.data.authorized_shops?.[0]?.shop_id ?? "";
    const shopCipher = parsed.data.authorized_shops?.[0]?.cipher ?? "";

    await admin.firestore().doc(`users/${uid}/integrations/tiktok`).set({
      accessToken: access_token,
      refreshToken: refresh_token,
      tokenExpiresAt: Date.now() + (access_token_expire_in ?? 3600) * 1000,
      shopId,
      shopCipher,
      connectedUsername: seller_name ?? open_id ?? "",
      isConnected: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);

// Exported helper — refreshes token if within 5 minutes of expiry
async function refreshTiktokToken(uid) {
  const db = admin.firestore();
  const ref = db.doc(`users/${uid}/integrations/tiktok`);
  const snap = await ref.get();
  const data = snap.data();
  if (!data) throw new Error("TikTok Shop not connected.");

  if (data.tokenExpiresAt - Date.now() > 5 * 60 * 1000) {
    return { accessToken: data.accessToken, shopId: data.shopId, shopCipher: data.shopCipher };
  }

  const appKey = TT_APP_KEY.value();
  const appSecret = TT_APP_SECRET.value();
  const timestamp = Math.floor(Date.now() / 1000);

  const params = { app_key: appKey, refresh_token: data.refreshToken, grant_type: "refresh_token", timestamp };
  const sign = signTiktokRequest(appSecret, "/api/v2/token/refresh", params);
  const qs = new URLSearchParams({ ...params, sign }).toString();

  const result = await makeHttpsRequest({
    hostname: "auth.tiktok-shops.com",
    path: `/api/v2/token/refresh?${qs}`,
    method: "GET",
  });

  const parsed = JSON.parse(result.body);
  if (parsed.code !== 0 || !parsed.data?.access_token) {
    throw new Error(`TikTok refresh failed: ${parsed.message}`);
  }

  const { access_token, refresh_token, access_token_expire_in } = parsed.data;
  await ref.update({
    accessToken: access_token,
    refreshToken: refresh_token ?? data.refreshToken,
    tokenExpiresAt: Date.now() + (access_token_expire_in ?? 3600) * 1000,
  });

  return { accessToken: access_token, shopId: data.shopId, shopCipher: data.shopCipher };
}

// Build signed headers for a TikTok Shop API call
function tiktokHeaders(appKey, appSecret, accessToken, path, params = {}, bodyStr = "") {
  const timestamp = Math.floor(Date.now() / 1000);
  const allParams = { ...params, app_key: appKey, timestamp };
  const sign = signTiktokRequest(appSecret, path, allParams, bodyStr);
  return {
    "x-tts-access-token": accessToken,
    "Content-Type": "application/json",
    "x-tts-timestamp": String(timestamp),
    "x-tts-app-key": appKey,
    "x-tts-sign": sign,
  };
}

module.exports = {
  tiktokExchangeToken: exports.tiktokExchangeToken,
  refreshTiktokToken,
  tiktokHeaders,
  signTiktokRequest,
  makeHttpsRequest,
  TT_APP_KEY,
  TT_APP_SECRET,
};
