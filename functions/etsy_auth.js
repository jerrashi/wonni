const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { SecretManagerServiceClient } = require("@google-cloud/secret-manager");

const secretManager = new SecretManagerServiceClient();
const PROJECT_ID = process.env.GCLOUD_PROJECT;

async function getSecret(secretName) {
  const request = {
    name: `projects/${PROJECT_ID}/secrets/${secretName}/versions/latest`,
  };
  const [version] = await secretManager.accessSecretVersion(request);
  return version.payload.data.toString();
}

// Exchange PKCE authorization code for access token
exports.etsyExchangeToken = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { code, codeVerifier, redirectUri } = request.data;
  if (!code || !codeVerifier) {
    throw new HttpsError("invalid-argument", "Missing code or codeVerifier.");
  }

  try {
    const clientId = await getSecret("ETSY_CLIENT_ID");
    const clientSecret = await getSecret("ETSY_SHARED_SECRET");

    // Exchange code for access token using PKCE
    const tokenResponse = await fetch("https://api.etsy.com/v3/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        code,
        code_verifier: codeVerifier,
      }).toString(),
    });

    if (!tokenResponse.ok) {
      const error = await tokenResponse.text();
      throw new Error(`Etsy token error (${tokenResponse.status}): ${error}`);
    }

    const tokenData = await tokenResponse.json();
    if (!tokenData.access_token) {
      throw new Error("No access token in Etsy response");
    }

    // Fetch shop info to get shop name and ID
    const shopResponse = await fetch("https://openapi.etsy.com/v3/application/shops", {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });

    if (!shopResponse.ok) {
      throw new Error(`Failed to fetch Etsy shop info (${shopResponse.status})`);
    }

    const shopData = await shopResponse.json();
    const shop = shopData.results?.[0];
    if (!shop) throw new Error("No shop found in Etsy account");

    // Store token and shop info in Firestore
    await admin.firestore().doc(`users/${uid}/integrations/etsy`).set({
      platform: "etsy",
      isConnected: true,
      connectedUsername: shop.shop_name,
      connectedAt: admin.firestore.FieldValue.serverTimestamp(),
      accessToken: tokenData.access_token,
      // Etsy DOES return a refresh_token — storing it is what lets
      // getActiveEtsyToken keep the connection alive past the 1h access token.
      refreshToken: tokenData.refresh_token ?? null,
      tokenExpiresAt: Date.now() + (tokenData.expires_in ?? 3600) * 1000,
      shopId: String(shop.shop_id),
      shopName: shop.shop_name,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { shopName: shop.shop_name };
  } catch (e) {
    console.error("Etsy token exchange error:", e);
    throw new HttpsError("internal", e.message || "Failed to connect Etsy account");
  }
});

/**
 * Exchange an Etsy refresh_token for a fresh access token.
 * Etsy: POST api.etsy.com/v3/public/oauth/token, PKCE clients omit the secret.
 */
async function refreshEtsyToken(refreshToken) {
  if (!refreshToken) throw new Error("No Etsy refresh token on record — reconnect Etsy.");
  const clientId = await getEtsyClientId();
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: clientId,
    refresh_token: refreshToken,
  });
  try {
    const secret = await getSecret("ETSY_SHARED_SECRET");
    if (secret) body.set("client_secret", secret);
  } catch { /* PKCE-only app — no secret */ }

  const res = await fetch("https://api.etsy.com/v3/public/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  if (!res.ok) {
    throw new Error(`Etsy token refresh failed (${res.status}): ${await res.text()}`);
  }
  return res.json();
}

/**
 * Valid Etsy access token, refreshing (and persisting the new token) when it's
 * within 5 min of expiry. Just the token string — use getActiveEtsyToken for
 * the token + shopId + clientId bundle the listing functions need.
 */
async function getValidEtsyToken(uid) {
  return (await getActiveEtsyToken(uid)).accessToken;
}

/**
 * The full Etsy auth bundle for a user: { accessToken, shopId, clientId }.
 * Refreshes the token if near expiry, and auto-recovers a missing shopId from
 * the /users/{id}/shops endpoint. Throws failed-precondition (reconnect) when
 * the account isn't usable.
 */
async function getActiveEtsyToken(uid) {
  const db = admin.firestore();
  const ref = db.doc(`users/${uid}/integrations/etsy`);
  const data = (await ref.get()).data();
  if (!data?.isConnected) {
    throw new HttpsError("failed-precondition", "Etsy not connected. Reconnect in Settings.");
  }

  const clientId = await getEtsyClientId();
  let accessToken = data.accessToken;

  const expiresAt = typeof data.tokenExpiresAt === "number"
    ? data.tokenExpiresAt
    : data.tokenExpiresAt?.toMillis?.() ?? 0;
  if (Date.now() > expiresAt - 5 * 60 * 1000) {
    if (!data.refreshToken) {
      throw new HttpsError("failed-precondition", "Etsy session expired — reconnect Etsy in Settings.");
    }
    const t = await refreshEtsyToken(data.refreshToken);
    accessToken = t.access_token;
    await ref.update({
      accessToken: t.access_token,
      refreshToken: t.refresh_token ?? data.refreshToken,
      tokenExpiresAt: Date.now() + (t.expires_in ?? 3600) * 1000,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  let shopId = data.shopId ? String(data.shopId) : null;
  if (!shopId) {
    // The Etsy user id is the prefix of the access token ("<userId>.<random>").
    const etsyUserId = accessToken.split(".")[0];
    const res = await fetch(`https://openapi.etsy.com/v3/application/users/${etsyUserId}/shops`, {
      headers: { "x-api-key": clientId, Authorization: `Bearer ${accessToken}` },
    });
    if (res.ok) {
      const shop = (await res.json()).results?.[0];
      if (shop) {
        shopId = String(shop.shop_id);
        await ref.update({ shopId, shopName: shop.shop_name ?? data.shopName ?? null });
      }
    }
  }
  if (!shopId) {
    throw new HttpsError(
      "failed-precondition",
      "No Etsy seller shop found. Make sure your shop is open (etsy.com/sell) and reconnect Etsy.",
    );
  }
  return { accessToken, shopId, clientId };
}

// Etsy v3 requires the app's keystring as `x-api-key` on every call.
let _etsyClientId = null;
async function getEtsyClientId() {
  if (_etsyClientId) return _etsyClientId;
  _etsyClientId = await getSecret("ETSY_CLIENT_ID");
  return _etsyClientId;
}

module.exports = {
  etsyExchangeToken: exports.etsyExchangeToken,
  getValidEtsyToken,
  getActiveEtsyToken,
  refreshEtsyToken,
  getEtsyClientId,
};
