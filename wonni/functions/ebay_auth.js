/**
 * ebay_auth.js
 *
 * Firebase Cloud Function: ebayExchangeToken
 * Called by the iOS app after the user completes eBay OAuth.
 * Exchanges the short-lived authorization code for access + refresh tokens
 * using the eBay token endpoint, then persists them to Firestore.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const ebayClientId  = defineSecret("EBAY_CLIENT_ID");
const ebayCertId    = defineSecret("EBAY_CERT_ID");

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
 *   { code: string, ruName: string, isSandbox: boolean }
 *
 * The caller must be authenticated (Firebase Auth UID is used to scope the write).
 */
exports.ebayExchangeToken = onCall(
  { secrets: [ebayClientId, ebayCertId] },
  async (request) => {
    // ── Auth guard ──────────────────────────────────────────────────────
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;

    const { code, ruName, isSandbox = false } = request.data;
    if (!code || !ruName) {
      throw new HttpsError("invalid-argument", "code and ruName are required.");
    }

    console.log(`[ebayExchangeToken] Exchanging code for uid=${uid}, sandbox=${isSandbox}`);

    // ── Token exchange ──────────────────────────────────────────────────
    let tokenData;
    try {
      tokenData = await exchangeCodeForToken(
        ebayClientId.value(),
        ebayCertId.value(),
        ruName,
        code,
        isSandbox
      );
    } catch (err) {
      console.error("[ebayExchangeToken] Token exchange failed:", err.message);
      throw new HttpsError("internal", `eBay token exchange failed: ${err.message}`);
    }

    console.log(`[ebayExchangeToken] Token exchange succeeded for uid=${uid}`);

    // ── Fetch eBay username ─────────────────────────────────────────────
    // Use the access token to look up the user's eBay username so we can
    // display it in the "Linked as: …" row in Settings.
    let ebayUsername = "eBay User";
    try {
      ebayUsername = await fetchEbayUsername(tokenData.access_token, isSandbox);
    } catch (err) {
      console.warn("[ebayExchangeToken] Could not fetch eBay username:", err.message);
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
        connectedAt:        admin.firestore.FieldValue.serverTimestamp(),
        accessToken:        tokenData.access_token,
        refreshToken:       tokenData.refresh_token ?? null,
        tokenExpiresAt:     expiresAt,
        isSandbox:          isSandbox,
        grantedScopes:      tokenData.scope ?? null,
      },
      { merge: true }
    );

    console.log(`[ebayExchangeToken] Firestore updated for uid=${uid}, username=${ebayUsername}, scopes=${tokenData.scope}`);

    return { success: true, username: ebayUsername };
  }
);

/**
 * Calls the eBay Identity API to retrieve the authenticated user's username.
 */
function fetchEbayUsername(accessToken, isSandbox) {
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
          resolve(parsed.username ?? parsed.userId ?? "eBay User");
        } catch {
          reject(new Error("Could not parse eBay identity response"));
        }
      });
    });

    req.on("error", reject);
    req.end();
  });
}
