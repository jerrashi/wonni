/**
 * ebay_auth.js
 *
 * Firebase Cloud Function: ebayExchangeToken
 * Unified OAuth token exchange for both iOS and web app.
 * Supports multiple eBay credential sets (ios, web) to enable true backend consolidation.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const https = require("https");
const { SecretManagerServiceClient } = require("@google-cloud/secret-manager");

// Destination registered with eBay Commerce Notifications (set in .env).
// All per-user ORDER_CONFIRMATION subscriptions share this one destination.
const NOTIFICATION_DESTINATION_ID = process.env.EBAY_NOTIFICATION_DESTINATION_ID ?? "";
const PROJECT_ID = process.env.GCP_PROJECT || "wonni-app";

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const secretManager = new SecretManagerServiceClient();

/**
 * Fetch eBay credentials from Google Cloud Secret Manager.
 * credentialSet: "ios" (wonni-app's own eBay) or "web" (dropship's eBay)
 */
async function getEbayCredentials(credentialSet) {
  const mapping = {
    ios: { clientId: "EBAY_CLIENT_ID", certId: "EBAY_CERT_ID" },
    web: { clientId: "DROPSHIP_EBAY_CLIENT_ID", certId: "DROPSHIP_EBAY_CLIENT_SECRET" }
  };

  if (!mapping[credentialSet]) {
    throw new Error(`Unknown credential set: ${credentialSet}`);
  }

  const { clientId: clientIdSecret, certId: certIdSecret } = mapping[credentialSet];

  try {
    const [clientIdResp] = await secretManager.accessSecretVersion({
      name: `projects/${PROJECT_ID}/secrets/${clientIdSecret}/versions/latest`,
    });
    const [certIdResp] = await secretManager.accessSecretVersion({
      name: `projects/${PROJECT_ID}/secrets/${certIdSecret}/versions/latest`,
    });

    return {
      clientId: clientIdResp.payload.data.toString(),
      certId: certIdResp.payload.data.toString(),
    };
  } catch (err) {
    throw new Error(`Failed to fetch eBay credentials (${credentialSet}): ${err.message}`);
  }
}

/**
 * Performs the eBay token exchange via the REST API.
 * Returns { access_token, refresh_token, expires_in, token_type, ... }
 */
function exchangeCodeForToken(clientId, certId, ruName, code, isSandbox) {
  return new Promise((resolve, reject) => {
    const credentials = Buffer.from(`${clientId}:${certId}`).toString("base64");
    const body = new URLSearchParams({
      grant_type:   "authorization_code",
      code:         code,
      redirect_uri: ruName,
    }).toString();

    const host    = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
    const options = {
      hostname: host,
      path:     "/identity/v1/oauth2/token",
      method:   "POST",
      headers: {
        "Content-Type":  "application/x-www-form-urlencoded",
        "Authorization": `Basic ${credentials}`,
        "Content-Length": Buffer.byteLength(body),
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          const parsed = JSON.parse(data);
          if (res.statusCode === 200) {
            resolve(parsed);
          } else {
            reject(new Error(`eBay token endpoint error (${res.statusCode}): ${data}`));
          }
        } catch (e) {
          reject(new Error(`Failed to parse eBay response: ${data}`));
        }
      });
    });

    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

/**
 * Callable function: ebayExchangeToken
 *
 * Expected request.data:
 *   { code: string, ruName: string, isSandbox: boolean, credentialSet: "ios" | "web" }
 *   credentialSet defaults to "ios" for backwards compatibility.
 *
 * The caller must be authenticated (Firebase Auth UID is used to scope the write).
 */
exports.ebayExchangeToken = onCall(
  { memory: "512MB", timeoutSeconds: 60 },
  async (request) => {
    // ── Auth guard ──────────────────────────────────────────────────────
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;

    const { code, ruName, isSandbox = false, credentialSet = "ios" } = request.data;
    if (!code || !ruName) {
      throw new HttpsError("invalid-argument", "code and ruName are required.");
    }

    console.log(`[ebayExchangeToken] Exchanging code for uid=${uid}, credentialSet=${credentialSet}, sandbox=${isSandbox}`);

    // ── Fetch credentials from Secret Manager ────────────────────────────
    let credentials;
    try {
      credentials = await getEbayCredentials(credentialSet);
    } catch (err) {
      console.error("[ebayExchangeToken] Credential fetch failed:", err.message);
      throw new HttpsError("internal", err.message);
    }

    // ── Token exchange ──────────────────────────────────────────────────
    let tokenData;
    try {
      tokenData = await exchangeCodeForToken(
        credentials.clientId,
        credentials.certId,
        ruName,
        code,
        isSandbox
      );
    } catch (err) {
      console.error("[ebayExchangeToken] Token exchange failed:", err.message);
      throw new HttpsError("internal", `eBay token exchange failed: ${err.message}`);
    }

    console.log(`[ebayExchangeToken] Token exchange succeeded for uid=${uid}`);

    // ── Fetch eBay user info ────────────────────────────────────────────
    // Retrieve username (for display in Settings) and internal userId
    // (stored as ebayUserId so ebay_webhook.js can map notifications → Wonni user).
    let ebayUsername = "eBay User";
    let ebayUserId = null;
    try {
      ({ username: ebayUsername, userId: ebayUserId } = await fetchEbayUserInfo(tokenData.access_token, isSandbox));
    } catch (err) {
      console.warn("[ebayExchangeToken] Could not fetch eBay user info:", err.message);
    }

    // ── Persist to Firestore ────────────────────────────────────────────
    const db = admin.firestore();
    const integrationRef = db
      .collection("users")
      .doc(uid)
      .collection("integrations")
      .doc("ebay");

    const expiresAt = admin.firestore.Timestamp.fromMillis(
      Date.now() + tokenData.expires_in * 1000
    );

    await integrationRef.set(
      {
        platform:           "ebay",
        isConnected:        true,
        connectedUsername:  ebayUsername,
        ebayUserId:         ebayUserId,
        connectedAt:        admin.firestore.FieldValue.serverTimestamp(),
        accessToken:        tokenData.access_token,
        refreshToken:       tokenData.refresh_token ?? null,
        tokenExpiresAt:     expiresAt,
        isSandbox:          isSandbox,
        grantedScopes:      tokenData.scope ?? null,
      },
      { merge: true }
    );

    console.log(`[ebayExchangeToken] Firestore updated for uid=${uid}, username=${ebayUsername}, ebayUserId=${ebayUserId}, scopes=${tokenData.scope}`);

    // Subscribe to ORDER_CONFIRMATION for real-time order push (production only —
    // sandbox eBay accounts don't receive Commerce Notification events).
    if (!isSandbox && NOTIFICATION_DESTINATION_ID) {
      const subscriptionId = await subscribeToOrderNotifications(
        tokenData.access_token, NOTIFICATION_DESTINATION_ID
      );
      if (subscriptionId) {
        await integrationRef.update({ orderNotificationSubscriptionId: subscriptionId });
        console.log(`[ebayExchangeToken] ORDER_CONFIRMATION subscription=${subscriptionId} for uid=${uid}`);
      }
    }

    return { success: true, username: ebayUsername };
  }
);

/**
 * Creates an ORDER_CONFIRMATION subscription for the seller using their user token.
 * Returns the subscriptionId, or null on failure.
 */
async function subscribeToOrderNotifications(accessToken, destinationId) {
  try {
    const body = JSON.stringify({
      topicId: "ORDER_CONFIRMATION",
      status: "ENABLED",
      destinationId,
      payload: { format: "JSON", schemaVersion: "1.0", deliveryProtocol: "HTTPS" },
    });
    const result = await new Promise((resolve, reject) => {
      const options = {
        hostname: "api.ebay.com",
        path: "/commerce/notification/v1/subscription",
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
        },
      };
      const req = https.request(options, (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => resolve({ statusCode: res.statusCode, body: data }));
      });
      req.on("error", reject);
      req.write(body);
      req.end();
    });

    if (result.statusCode !== 201) {
      console.warn(`[ebayExchangeToken] ORDER_CONFIRMATION subscription failed: ${result.statusCode} ${result.body}`);
      return null;
    }
    return JSON.parse(result.body).subscriptionId ?? null;
  } catch (e) {
    console.warn(`[ebayExchangeToken] ORDER_CONFIRMATION subscription error: ${e.message}`);
    return null;
  }
}

/**
 * Calls the eBay Identity API to retrieve the authenticated user's username and userId.
 * Returns { username, userId } — userId is eBay's internal identifier used in webhook payloads.
 */
function fetchEbayUserInfo(accessToken, isSandbox) {
  return new Promise((resolve, reject) => {
    const host    = isSandbox ? "apiz.sandbox.ebay.com" : "apiz.ebay.com";
    const options = {
      hostname: host,
      path:     "/commerce/identity/v1/user/",
      method:   "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type":  "application/json",
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          const parsed = JSON.parse(data);
          resolve({
            username: parsed.username ?? "eBay User",
            userId: parsed.userId ?? null,
          });
        } catch {
          reject(new Error("Could not parse eBay identity response"));
        }
      });
    });

    req.on("error", reject);
    req.end();
  });
}
