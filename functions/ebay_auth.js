const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const admin = require("firebase-admin");

const EBAY_CLIENT_ID = defineSecret("EBAY_CLIENT_ID");
const EBAY_CLIENT_SECRET = defineSecret("EBAY_CLIENT_SECRET");
const EBAY_RU_NAME = defineSecret("EBAY_RU_NAME"); // eBay "RuName" (redirect_uri value)
const EBAY_ENV = defineString("EBAY_ENV", { default: "sandbox" }); // "sandbox" | "production"

const EBAY_SCOPES = [
  "https://api.ebay.com/oauth/api_scope/sell.inventory",
  "https://api.ebay.com/oauth/api_scope/sell.account",
].join(" ");

function ebayApiHost() {
  return EBAY_ENV.value() === "production" ? "api.ebay.com" : "api.sandbox.ebay.com";
}

function basicAuthHeader() {
  const creds = `${EBAY_CLIENT_ID.value()}:${EBAY_CLIENT_SECRET.value()}`;
  return `Basic ${Buffer.from(creds).toString("base64")}`;
}

async function tokenRequest(bodyParams) {
  const response = await fetch(`https://${ebayApiHost()}/identity/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: basicAuthHeader(),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(bodyParams).toString(),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.access_token) {
    throw new Error(`eBay token error (${response.status}): ${json.error_description ?? JSON.stringify(json)}`);
  }
  return json;
}

// Exchange authorization code for access + refresh tokens
exports.dropshipEbayExchangeToken = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_RU_NAME] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { code, state } = request.data;
    if (!code) throw new HttpsError("invalid-argument", "Missing code.");

    // CSRF check, same pattern as TikTok
    const stateRef = admin.firestore().doc(`users/${uid}/oauthStates/ebay`);
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

    let tokens;
    try {
      tokens = await tokenRequest({
        grant_type: "authorization_code",
        code,
        redirect_uri: EBAY_RU_NAME.value(),
      });
    } catch (e) {
      throw new HttpsError("internal", e.message);
    }

    await admin.firestore().doc(`users/${uid}/integrations/ebay`).set({
      platform: "ebay",
      isConnected: true,
      connectedUsername: tokens.ebay_username || null, // eBay username if available from token
      connectedAt: admin.firestore.FieldValue.serverTimestamp(),
      // Web-specific OAuth token storage (iOS doesn't need this)
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      tokenExpiresAt: Date.now() + (tokens.expires_in ?? 7200) * 1000,
      refreshTokenExpiresAt: Date.now() + (tokens.refresh_token_expires_in ?? 0) * 1000,
      environment: EBAY_ENV.value(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);

// Refresh access token if within 5 minutes of expiry; returns a valid access token
async function refreshEbayToken(uid) {
  const ref = admin.firestore().doc(`users/${uid}/integrations/ebay`);
  const snap = await ref.get();
  const data = snap.data();
  if (!data?.isConnected) throw new HttpsError("failed-precondition", "eBay not connected.");

  if (data.tokenExpiresAt - Date.now() > 5 * 60 * 1000) {
    return data.accessToken;
  }

  const tokens = await tokenRequest({
    grant_type: "refresh_token",
    refresh_token: data.refreshToken,
    scope: EBAY_SCOPES,
  });

  await ref.update({
    accessToken: tokens.access_token,
    tokenExpiresAt: Date.now() + (tokens.expires_in ?? 7200) * 1000,
  });

  return tokens.access_token;
}

// Authenticated eBay REST call. Returns parsed JSON (or null for 204).
async function ebayRequest(uid, method, path, body) {
  const accessToken = await refreshEbayToken(uid);
  const response = await fetch(`https://${ebayApiHost()}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "Content-Language": "en-US",
      Accept: "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  if (response.status === 204) return null;
  const json = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = json.errors?.[0]?.message ?? JSON.stringify(json);
    const err = new Error(`eBay ${method} ${path} failed (${response.status}): ${detail}`);
    err.status = response.status;
    err.ebayErrors = json.errors ?? [];
    throw err;
  }
  return json;
}

module.exports = {
  dropshipEbayExchangeToken: exports.dropshipEbayExchangeToken,
  refreshEbayToken,
  ebayRequest,
  EBAY_CLIENT_ID,
  EBAY_CLIENT_SECRET,
  EBAY_RU_NAME,
};
