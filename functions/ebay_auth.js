const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const admin = require("firebase-admin");

const EBAY_CLIENT_ID = defineSecret("EBAY_CLIENT_ID");
const EBAY_CLIENT_SECRET = defineSecret("EBAY_CLIENT_SECRET");
const EBAY_RU_NAME = defineString("EBAY_RU_NAME"); // eBay "RuName" (redirect_uri value) — NOT secret, just config
const EBAY_ENV = defineString("EBAY_ENV", { default: "sandbox" }); // "sandbox" | "production"

// The scope subset EVERY connected eBay account is known to have granted —
// the safe fallback for a refresh when we don't have a recorded grant.
// commerce.identity.readonly is requested at authorize time (Settings.jsx /
// ProfileView.swift) and only needed once, at token exchange, to read the
// username — deliberately NOT listed here.
const EBAY_SCOPES = [
  "https://api.ebay.com/oauth/api_scope/sell.inventory",
  "https://api.ebay.com/oauth/api_scope/sell.account",
].join(" ");

// Everything we'd LIKE on a refreshed token. sell.fulfillment (order reads) and
// sell.finances (net-payout reads) power syncSales / getOrderTakeHome but were
// not in the web app's original authorize request. eBay's refresh_token grant
// rejects (invalid_scope) any scope not in the user's original authorization,
// so `refreshEbayToken` sends `EBAY_SCOPES_DESIRED ∩ grantedScopes` and falls
// back to EBAY_SCOPES for legacy connections with no recorded grant.
const EBAY_SCOPES_DESIRED = [
  "https://api.ebay.com/oauth/api_scope/sell.inventory",
  "https://api.ebay.com/oauth/api_scope/sell.account",
  "https://api.ebay.com/oauth/api_scope/sell.fulfillment",
  "https://api.ebay.com/oauth/api_scope/sell.finances",
];

/** Space-delimited scope string to request when refreshing this user's token. */
function refreshScopeFor(integrationData) {
  const raw = integrationData?.grantedScopes;
  const granted = typeof raw === "string" ? raw.split(/\s+/).filter(Boolean) : null;
  if (!granted) return EBAY_SCOPES; // legacy connection — unknown grant, stay safe
  const usable = EBAY_SCOPES_DESIRED.filter((s) => granted.includes(s));
  return usable.length ? usable.join(" ") : EBAY_SCOPES;
}

/** Has this user granted the scope needed for order + finance reads? */
function hasOrderReadScopes(integrationData) {
  const raw = integrationData?.grantedScopes;
  if (typeof raw !== "string") return false;
  return raw.includes("/sell.fulfillment");
}

function ebayApiHost() {
  return EBAY_ENV.value() === "production" ? "api.ebay.com" : "api.sandbox.ebay.com";
}

// The Commerce Identity API is served from a separate subdomain (apiz.*),
// NOT the api.* host used for sell/* and identity/v1/oauth2 calls.
function ebayIdentityApiHost() {
  return EBAY_ENV.value() === "production" ? "apiz.ebay.com" : "apiz.sandbox.ebay.com";
}

// Look up the authenticated seller's eBay username for display in Settings.
// Requires the commerce.identity.readonly OAuth scope on the access token.
async function fetchEbayUsername(accessToken) {
  const response = await fetch(`https://${ebayIdentityApiHost()}/commerce/identity/v1/user/`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      Accept: "application/json",
      "Accept-Language": "en-US", // see ebayRestHeaders — undici's `*` default is rejected
    },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`eBay identity API error (${response.status}): ${JSON.stringify(data)}`);
  }
  return data.username || data.userId || null;
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
exports.ebayExchangeToken = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET] },
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

    // Fetch the authenticated user's eBay username for the "Connected as" row.
    let connectedUsername = "Connected Account";
    try {
      connectedUsername =
        (await fetchEbayUsername(tokens.access_token)) || connectedUsername;
    } catch (e) {
      console.error("Failed to fetch eBay username:", e.message);
    }

    await admin.firestore().doc(`users/${uid}/integrations/ebay`).set({
      platform: "ebay",
      isConnected: true,
      connectedUsername,
      connectedAt: admin.firestore.FieldValue.serverTimestamp(),
      // Web-specific OAuth token storage (iOS doesn't need this)
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      tokenExpiresAt: Date.now() + (tokens.expires_in ?? 7200) * 1000,
      refreshTokenExpiresAt: Date.now() + (tokens.refresh_token_expires_in ?? 0) * 1000,
      // Space-delimited scopes eBay actually granted — drives refreshScopeFor()
      // and hasOrderReadScopes(). eBay echoes `scope` on the token response;
      // the client may also pass its authorize `scopes` as a fallback.
      grantedScopes: tokens.scope ?? request.data?.scopes ?? null,
      environment: EBAY_ENV.value(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true, connectedUsername, username: connectedUsername };
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
    scope: refreshScopeFor(data),
  });

  const update = {
    accessToken: tokens.access_token,
    tokenExpiresAt: Date.now() + (tokens.expires_in ?? 7200) * 1000,
  };
  // Backfill grantedScopes for connections made before we recorded it.
  if (typeof tokens.scope === "string" && tokens.scope !== data.grantedScopes) {
    update.grantedScopes = tokens.scope;
  }
  await ref.update(update);

  return tokens.access_token;
}

// Header set for every eBay REST call. One place to reason about eBay's
// picky header validation:
//   - Node's built-in fetch (undici) injects `Accept-Language: *` when we
//     don't set it. eBay's Inventory API rejects that with error 25709
//     ("Invalid value for header Accept-Language.") — pin it to en-US.
//   - Content-Language is only valid alongside a request body; eBay returns
//     25709 if it's sent on GET/DELETE.
function ebayRestHeaders(authValue, hasBody, extra) {
  return {
    Authorization: authValue,
    Accept: "application/json",
    "Accept-Language": "en-US",
    "Content-Type": "application/json",
    ...(hasBody ? { "Content-Language": "en-US" } : {}),
    ...extra,
  };
}

// The Finances API lives on apiz.* (same split as the Identity API), not the
// api.* host that serves sell/inventory, sell/account, sell/fulfillment.
function ebayApiZHost() {
  return EBAY_ENV.value() === "production" ? "apiz.ebay.com" : "apiz.sandbox.ebay.com";
}

// Authenticated eBay REST call. Returns parsed JSON (or null for 204).
//   opts.host: "apiz" for the Finances API (default: the api.* host)
//   opts.marketplaceId: adds X-EBAY-C-MARKETPLACE-ID (order/finance reads want it)
async function ebayRequest(uid, method, path, body, opts = {}) {
  const accessToken = await refreshEbayToken(uid);
  const hasBody = body !== undefined && body !== null;
  const host = opts.host === "apiz" ? ebayApiZHost() : ebayApiHost();
  const extraHeaders = opts.marketplaceId ? { "X-EBAY-C-MARKETPLACE-ID": opts.marketplaceId } : undefined;
  const response = await fetch(`https://${host}${path}`, {
    method,
    headers: ebayRestHeaders(`Bearer ${accessToken}`, hasBody, extraHeaders),
    ...(hasBody && { body: JSON.stringify(body) }),
  });

  if (response.status === 204) return null;
  if (!response.ok) {
    const text = await response.text();
    const err = new Error(`eBay API error (${response.status}): ${text}`);
    err.status = response.status;
    // eBay returns { "errors": [{ errorId, message, ... }] }. Callers rely on
    // err.ebayErrors to recognise specific conditions (e.g. 25002 "offer
    // already exists") and recover instead of failing the whole request.
    try {
      const parsed = JSON.parse(text);
      if (Array.isArray(parsed?.errors)) err.ebayErrors = parsed.errors;
    } catch {
      /* non-JSON error body — leave err.ebayErrors undefined */
    }
    throw err;
  }
  return response.json();
}

module.exports = {
  ebayExchangeToken: exports.ebayExchangeToken,
  refreshEbayToken,
  ebayRequest,
  ebayRestHeaders,
  ebayApiHost,
  ebayApiZHost,
  refreshScopeFor,
  hasOrderReadScopes,
  EBAY_SCOPES,
  EBAY_SCOPES_DESIRED,
  EBAY_CLIENT_ID,
  EBAY_CLIENT_SECRET,
  EBAY_RU_NAME,
  EBAY_ENV,
};
