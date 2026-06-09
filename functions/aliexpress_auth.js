const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const crypto = require("crypto");

const AE_APP_KEY = defineSecret("ALIEXPRESS_APP_KEY");
const AE_APP_SECRET = defineSecret("ALIEXPRESS_APP_SECRET");
const AE_API_HOST = "api-sg.aliexpress.com";

// Sign AliExpress API request (Taobao Open Platform HMAC-SHA256)
function signRequest(params, appSecret) {
  const sorted = Object.keys(params)
    .sort()
    .map((k) => `${k}${params[k]}`)
    .join("");
  return crypto.createHmac("sha256", appSecret).update(sorted).digest("hex").toUpperCase();
}

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

// Exchange authorization code for access + refresh tokens
exports.aliexpressExchangeToken = onCall(
  { secrets: [AE_APP_KEY, AE_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { code, redirectUri, state } = request.data;
    if (!code) throw new HttpsError("invalid-argument", "Missing code.");

    const stateRef = admin.firestore().doc(`users/${uid}/oauthStates/aliexpress`);
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

    const appKey = AE_APP_KEY.value();
    const appSecret = AE_APP_SECRET.value();

    const params = {
      app_key: appKey,
      code,
      grant_type: "authorization_code",
      redirect_uri: redirectUri,
      timestamp: String(Date.now()),
      sign_method: "sha256",
    };
    params.sign = signRequest(params, appSecret);

    const body = new URLSearchParams(params).toString();
    const result = await makeHttpsRequest(
      {
        hostname: "oauth.aliexpress.com",
        path: "/token",
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      body
    );

    let parsed;
    try {
      parsed = JSON.parse(result.body);
    } catch {
      throw new HttpsError("internal", "Invalid token response from AliExpress.");
    }

    if (!parsed.access_token) {
      throw new HttpsError("internal", `AliExpress token error: ${parsed.error_description ?? result.body}`);
    }

    const expiresAt = Date.now() + (parsed.expire_time ?? 3600) * 1000;

    await admin.firestore().doc(`users/${uid}/integrations/aliexpress`).set({
      accessToken: parsed.access_token,
      refreshToken: parsed.refresh_token,
      tokenExpiresAt: expiresAt,
      connectedUsername: parsed.account ?? parsed.user_nick ?? "",
      isConnected: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);

// Exported helper — refreshes token if within 5 minutes of expiry
async function refreshAliexpressToken(uid) {
  const db = admin.firestore();
  const ref = db.doc(`users/${uid}/integrations/aliexpress`);
  const snap = await ref.get();
  const data = snap.data();
  if (!data) throw new Error("AliExpress not connected.");

  if (data.tokenExpiresAt - Date.now() > 5 * 60 * 1000) {
    return data.accessToken;
  }

  const appKey = AE_APP_KEY.value();
  const appSecret = AE_APP_SECRET.value();

  const params = {
    app_key: appKey,
    refresh_token: data.refreshToken,
    grant_type: "refresh_token",
    timestamp: String(Date.now()),
    sign_method: "sha256",
  };
  params.sign = signRequest(params, appSecret);

  const body = new URLSearchParams(params).toString();
  const result = await makeHttpsRequest(
    {
      hostname: "oauth.aliexpress.com",
      path: "/token",
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    },
    body
  );

  const parsed = JSON.parse(result.body);
  if (!parsed.access_token) throw new Error(`AliExpress refresh failed: ${parsed.error_description}`);

  await ref.update({
    accessToken: parsed.access_token,
    refreshToken: parsed.refresh_token ?? data.refreshToken,
    tokenExpiresAt: Date.now() + (parsed.expire_time ?? 3600) * 1000,
  });

  return parsed.access_token;
}

// Call an AliExpress API method (POST to gateway)
async function callAliexpressApi(method, params, uid) {
  const appKey = AE_APP_KEY.value();
  const appSecret = AE_APP_SECRET.value();
  const accessToken = await refreshAliexpressToken(uid);

  const allParams = {
    method,
    app_key: appKey,
    access_token: accessToken,
    timestamp: String(Date.now()),
    sign_method: "sha256",
    format: "json",
    v: "2.0",
    ...params,
  };
  allParams.sign = signRequest(allParams, appSecret);

  const body = new URLSearchParams(allParams).toString();
  const result = await makeHttpsRequest(
    {
      hostname: AE_API_HOST,
      path: "/sync",
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Content-Length": Buffer.byteLength(body),
      },
    },
    body
  );

  return JSON.parse(result.body);
}

module.exports = { aliexpressExchangeToken: exports.aliexpressExchangeToken, refreshAliexpressToken, callAliexpressApi, signRequest };
