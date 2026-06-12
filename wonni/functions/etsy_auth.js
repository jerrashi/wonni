/**
 * etsy_auth.js
 *
 * Firebase Cloud Function: etsyExchangeToken
 * Called by the iOS app after the user completes Etsy OAuth.
 * Exchanges the authorization code and PKCE verifier for access + refresh tokens,
 * fetches shop details, and persists them to Firestore.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const etsyClientId = defineSecret("ETSY_CLIENT_ID");
const etsySharedSecret = defineSecret("ETSY_SHARED_SECRET");

/**
 * Promise wrapper for https.request.
 */
function makeHttpRequest(options, bodyData = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: data,
        });
      });
    });

    req.on("error", reject);

    if (bodyData) {
      const payload = typeof bodyData === "string" ? bodyData : JSON.stringify(bodyData);
      req.write(payload);
    }
    req.end();
  });
}

/**
 * Performs the Etsy token exchange via the REST API.
 */
async function exchangeCodeForToken(clientId, clientSecret, code, verifier, redirectUri) {
  const bodyParams = {
    grant_type: "authorization_code",
    client_id: clientId,
    code: code,
    redirect_uri: redirectUri,
    code_verifier: verifier
  };
  
  if (clientSecret) {
    bodyParams.client_secret = clientSecret;
  }
  
  const body = new URLSearchParams(bodyParams).toString();

  const options = {
    hostname: "api.etsy.com",
    path: "/v3/public/oauth/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Content-Length": Buffer.byteLength(body),
    },
  };

  return makeHttpRequest(options, body);
}

/**
 * Retrieves the user's Etsy Shop details.
 * PKCE (public-client) apps use the keystring as x-api-key. Confidential apps require the
 * shared secret. We try the keystring first (correct for PKCE flows), then fall back to the
 * shared secret. Throws if neither works so etsyExchangeToken fails loudly instead of saving
 * an empty shopId that breaks every subsequent listing call.
 */
async function fetchEtsyShopDetails(accessToken, clientId, userId, clientSecret) {
  console.log(`[etsy_auth] Fetching shop details for userId=${userId} from Etsy`);

  // Try each candidate key in order: keystring first (PKCE/public apps), then shared secret.
  const candidates = [clientId];
  if (clientSecret && clientSecret !== clientId) candidates.push(clientSecret);

  for (const apiKey of candidates) {
    const options = {
      hostname: "openapi.etsy.com",
      path: `/v3/application/users/${userId}/shops`,
      method: "GET",
      headers: {
        "x-api-key": apiKey,
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    };

    const response = await makeHttpRequest(options);
    if (response.statusCode === 200) {
      try {
        const data = JSON.parse(response.body);
        if (data.results && data.results.length > 0) {
          const shop = data.results[0];
          console.log(`[etsy_auth] Found shop: ${shop.shop_name} (ID: ${shop.shop_id})`);
          return { shopId: String(shop.shop_id), shopName: shop.shop_name };
        }
        console.warn("[etsy_auth] Shop list returned 0 results — user has no Etsy shop");
        throw new Error("No Etsy shop found for this account. Make sure you have an active Etsy seller shop.");
      } catch (e) {
        if (e.message.includes("No Etsy shop")) throw e;
        console.error("[etsy_auth] Error parsing shop details response:", e.message);
      }
    } else if (response.statusCode === 403) {
      console.warn(`[etsy_auth] 403 with apiKey candidate, will try next if available: ${response.body}`);
    } else {
      console.warn(`[etsy_auth] Failed to fetch shop details (${response.statusCode}): ${response.body}`);
      break;
    }
  }

  throw new Error(
    "Could not retrieve your Etsy shop ID. " +
    "Make sure you have an active seller shop and that the Wonni app has the correct API credentials."
  );
}

/**
 * Refreshes the Etsy OAuth token using the user's refresh token.
 */
async function refreshEtsyToken(clientId, clientSecret, refreshToken) {
  const bodyParams = {
    grant_type: "refresh_token",
    client_id: clientId,
    refresh_token: refreshToken
  };
  
  if (clientSecret) {
    bodyParams.client_secret = clientSecret;
  }
  
  const body = new URLSearchParams(bodyParams).toString();

  const options = {
    hostname: "api.etsy.com",
    path: "/v3/public/oauth/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Content-Length": Buffer.byteLength(body)
    }
  };

  const response = await makeHttpRequest(options, body);
  if (response.statusCode !== 200) {
    throw new Error(`Etsy token refresh failed (${response.statusCode}): ${response.body}`);
  }
  return JSON.parse(response.body);
}

/**
 * Callable function: etsyExchangeToken
 *
 * Expected request.data:
 *   { code: string, codeVerifier: string, redirectUri: string }
 */
exports.etsyExchangeToken = onCall(
  { secrets: [etsyClientId, etsySharedSecret] },
  async (request) => {
    // Auth guard
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;

    const { code, codeVerifier, redirectUri } = request.data;
    if (!code || !codeVerifier || !redirectUri) {
      throw new HttpsError("invalid-argument", "code, codeVerifier, and redirectUri are required.");
    }

    console.log(`[etsyExchangeToken] Exchanging code for uid=${uid}`);

    try {
      const clientId = etsyClientId.value();
      const clientSecret = etsySharedSecret.value();

      const res = await exchangeCodeForToken(clientId, clientSecret, code, codeVerifier, redirectUri);
      if (res.statusCode !== 200) {
        throw new Error(`Etsy token exchange failed (${res.statusCode}): ${res.body}`);
      }

      const tokenData = JSON.parse(res.body);
      const accessToken = tokenData.access_token;
      
      // Etsy access tokens are prefixed with the user's numeric ID (e.g. 12345678.xxxx)
      const userId = accessToken.split(".")[0];
      if (!userId) {
        throw new Error("Could not parse user ID from access token.");
      }

      // Fetch shop details to display correct shop name in settings
      const shopDetails = await fetchEtsyShopDetails(accessToken, clientId, userId, clientSecret);

      // Persist to Firestore
      const db = admin.firestore();
      const integrationRef = db
        .collection("users")
        .doc(uid)
        .collection("integrations")
        .doc("etsy");

      const expiresAt = admin.firestore.Timestamp.fromMillis(
        Date.now() + tokenData.expires_in * 1000
      );

      await integrationRef.set(
        {
          platform: "etsy",
          isConnected: true,
          connectedUsername: shopDetails.shopName,
          shopId: shopDetails.shopId,
          connectedAt: admin.firestore.FieldValue.serverTimestamp(),
          accessToken: accessToken,
          refreshToken: tokenData.refresh_token ?? null,
          tokenExpiresAt: expiresAt,
          grantedScopes: tokenData.scope ?? null,
        },
        { merge: true }
      );

      console.log(`[etsyExchangeToken] Firestore updated for uid=${uid}, shop=${shopDetails.shopName}`);

      return { success: true, shopName: shopDetails.shopName, shopId: shopDetails.shopId };
    } catch (err) {
      console.error("[etsyExchangeToken] Token exchange failed:", err.message);
      throw new HttpsError("internal", `Etsy token exchange failed: ${err.message}`);
    }
  }
);

// Export helper for refreshing token
exports.refreshEtsyToken = refreshEtsyToken;
