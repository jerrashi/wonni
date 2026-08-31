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
      // Web-specific OAuth token storage
      accessToken: tokenData.access_token,
      tokenExpiresAt: Date.now() + (tokenData.expires_in ?? 3600) * 1000,
      shopId: shop.shop_id,
      shopName: shop.shop_name,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { shopName: shop.shop_name };
  } catch (e) {
    console.error("Etsy token exchange error:", e);
    throw new HttpsError("internal", e.message || "Failed to connect Etsy account");
  }
});

// Helper: Get valid access token, refreshing if needed
async function getValidEtsyToken(uid) {
  const db = admin.firestore();
  const ref = db.doc(`users/${uid}/integrations/etsy`);
  const snap = await ref.get();
  const data = snap.data();

  if (!data?.isConnected) {
    throw new Error("Etsy not connected.");
  }

  // Token is still valid
  if (data.tokenExpiresAt - Date.now() > 5 * 60 * 1000) {
    return data.accessToken;
  }

  // Token expired or expiring soon — Etsy doesn't provide refresh tokens in standard OAuth
  // User must re-authorize
  throw new Error("Etsy token expired. Please reconnect your Etsy account.");
}

module.exports = { etsyExchangeToken: exports.etsyExchangeToken, getValidEtsyToken };
