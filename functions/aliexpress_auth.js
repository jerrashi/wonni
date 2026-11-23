/**
 * aliexpress_auth.js — AliExpress Open Platform (IOP) tokens + business calls.
 *
 * Signing follows the official IOP SDK (`iop` python `sign()`):
 *   system call (path API, e.g. /auth/token/create) → POST api-sg.aliexpress.com/rest<path>,
 *       string = path + sorted(key+value)
 *   business call (method name, e.g. aliexpress.ds.product.get) → POST /sync,
 *       string = sorted(key+value)
 *   sign = upper-hex HMAC-SHA256(key = app_secret, string)
 * Before 2026-11-23 the token exchange posted to the old Taobao-style
 * `oauth.aliexpress.com/token` and read `expire_time` (epoch ms) as seconds
 * from now. None of it had run live (no AliExpress connection exists yet).
 */

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const crypto = require("crypto");

const AE_APP_KEY = defineSecret("ALIEXPRESS_APP_KEY");
const AE_APP_SECRET = defineSecret("ALIEXPRESS_APP_SECRET");
const AE_SECRETS = [AE_APP_KEY, AE_APP_SECRET];
const AE_GATEWAY = "https://api-sg.aliexpress.com";
const REFRESH_MARGIN_MS = 5 * 60 * 1000;

/** IOP signature. `apiPath` only for system (path-style) APIs. */
function signRequest(params, appSecret, apiPath = "") {
  const concat = Object.keys(params)
    .filter((k) => k !== "sign" && params[k] !== undefined && params[k] !== null && params[k] !== "")
    .sort()
    .map((k) => `${k}${params[k]}`)
    .join("");
  return crypto.createHmac("sha256", appSecret).update(`${apiPath}${concat}`).digest("hex").toUpperCase();
}

function signedParams(params, { appKey, appSecret, apiPath = "", nowMs = Date.now() }) {
  const all = { ...params, app_key: appKey, timestamp: String(nowMs), sign_method: "sha256" };
  for (const k of Object.keys(all)) if (all[k] === undefined || all[k] === null) delete all[k];
  all.sign = signRequest(all, appSecret, apiPath);
  return all;
}

/** epoch-ms expiry from a token response (`expire_time` ms, else `expires_in` s). */
function tokenExpiryMs(parsed, nowMs) {
  const abs = Number(parsed.expire_time);
  if (Number.isFinite(abs) && abs > 1e12) return abs;
  const rel = Number(parsed.expires_in);
  if (Number.isFinite(rel) && rel > 0) return nowMs + rel * 1000;
  return nowMs + 3600 * 1000;
}

/** /auth/token/create|refresh JSON → integration fields, or a readable error. */
function parseTokenResponse(parsed, nowMs = Date.now()) {
  if (!parsed?.access_token) {
    const why = parsed?.message || parsed?.error_description || parsed?.code || "no token returned";
    throw new HttpsError("failed-precondition", `AliExpress sign-in failed: ${why}. Reconnect AliExpress in Settings.`);
  }
  const refreshAbs = Number(parsed.refresh_token_valid_time);
  return {
    accessToken: parsed.access_token,
    refreshToken: parsed.refresh_token ?? null,
    tokenExpiresAt: tokenExpiryMs(parsed, nowMs),
    refreshTokenExpiresAt: Number.isFinite(refreshAbs) && refreshAbs > 1e12 ? refreshAbs : null,
    account: parsed.account ?? parsed.user_nick ?? "",
  };
}

async function postForm(fetchImpl, url, params) {
  const res = await fetchImpl(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded;charset=utf-8" },
    body: new URLSearchParams(params).toString(),
  });
  const text = await res.text();
  try { return JSON.parse(text); } catch {
    throw new HttpsError("unavailable", `AliExpress returned a non-JSON response (HTTP ${res.status}).`);
  }
}

async function tokenCall(apiPath, params, { appKey, appSecret, fetchImpl = fetch, now = Date.now }) {
  const body = signedParams(params, { appKey, appSecret, apiPath, nowMs: now() });
  return parseTokenResponse(await postForm(fetchImpl, `${AE_GATEWAY}/rest${apiPath}`, body), now());
}

exports.aliexpressExchangeToken = onCall({ secrets: AE_SECRETS }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  const { code, state } = request.data ?? {};
  if (!code) throw new HttpsError("invalid-argument", "Missing code.");

  const db = admin.firestore();
  const stateRef = db.doc(`users/${uid}/oauthStates/aliexpress`);
  const stored = (await stateRef.get()).data();
  if (!stored?.nonce || stored.nonce !== state) throw new HttpsError("invalid-argument", "Invalid OAuth state.");
  await stateRef.delete();
  if (Date.now() - stored.createdAt.toMillis() > 10 * 60 * 1000) {
    throw new HttpsError("deadline-exceeded", "OAuth state expired.");
  }

  const t = await tokenCall("/auth/token/create", { code }, { appKey: AE_APP_KEY.value(), appSecret: AE_APP_SECRET.value() });
  await db.doc(`users/${uid}/integrations/aliexpress`).set({
    platform: "aliexpress",
    isConnected: true,
    connectedUsername: t.account,
    connectedAt: admin.firestore.FieldValue.serverTimestamp(),
    accessToken: t.accessToken,
    refreshToken: t.refreshToken,
    tokenExpiresAt: t.tokenExpiresAt,
    refreshTokenExpiresAt: t.refreshTokenExpiresAt,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  return { success: true };
});

/** A valid access token for `uid`, refreshing within 5 min of expiry. */
async function refreshAliexpressToken(uid, { db = admin.firestore(), appKey, appSecret, fetchImpl = fetch, now = Date.now } = {}) {
  const ref = db.doc(`users/${uid}/integrations/aliexpress`);
  const data = (await ref.get()).data();
  if (!data?.isConnected || !data.accessToken) {
    throw new HttpsError("failed-precondition", "AliExpress is not connected. Connect it in Settings.");
  }
  if (data.tokenExpiresAt - now() > REFRESH_MARGIN_MS) return data.accessToken;
  if (!data.refreshToken) throw new HttpsError("failed-precondition", "AliExpress session expired. Reconnect AliExpress in Settings.");

  const t = await tokenCall("/auth/token/refresh", { refresh_token: data.refreshToken }, {
    appKey: appKey ?? AE_APP_KEY.value(), appSecret: appSecret ?? AE_APP_SECRET.value(), fetchImpl, now,
  });
  const patch = { accessToken: t.accessToken, refreshToken: t.refreshToken ?? data.refreshToken, tokenExpiresAt: t.tokenExpiresAt };
  if (t.refreshTokenExpiresAt) patch.refreshTokenExpiresAt = t.refreshTokenExpiresAt;
  await ref.set(patch, { merge: true });
  return t.accessToken;
}

/**
 * Business API call (POST /sync). Returns the parsed body; an `error_response`
 * envelope becomes a readable HttpsError instead of a silent undefined result.
 * Callers must bind AE_SECRETS.
 */
async function callAliexpressApi(method, params, uid, deps = {}) {
  const appKey = deps.appKey ?? AE_APP_KEY.value();
  const appSecret = deps.appSecret ?? AE_APP_SECRET.value();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const accessToken = await refreshAliexpressToken(uid, { ...deps, appKey, appSecret, fetchImpl });
  const body = signedParams({ ...params, method, access_token: accessToken, format: "json", v: "2.0" }, {
    appKey, appSecret, nowMs: (deps.now ?? Date.now)(),
  });
  const parsed = await postForm(fetchImpl, `${AE_GATEWAY}/sync`, body);
  if (parsed?.error_response) {
    const e = parsed.error_response;
    const auth = /token|session|auth/i.test(`${e.code} ${e.msg ?? e.message ?? ""}`);
    throw new HttpsError("failed-precondition",
      `AliExpress ${method} failed: ${e.msg ?? e.message ?? e.code}${auth ? ". Reconnect AliExpress in Settings." : ""}`,
      { aliexpressCode: e.code });
  }
  return parsed;
}

module.exports = {
  aliexpressExchangeToken: exports.aliexpressExchangeToken,
  refreshAliexpressToken,
  callAliexpressApi,
  signRequest,
  AE_APP_KEY, AE_APP_SECRET, AE_SECRETS,
  _internal: { signedParams, tokenExpiryMs, parseTokenResponse },
};
