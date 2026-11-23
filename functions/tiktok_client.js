/**
 * tiktok_client.js — the ONE way the backend talks to TikTok Shop (API 202309).
 *
 * Replaces the hand-rolled `tiktokRequest` / `tiktokHeaders` that never ran live
 * (legacy `/api/...` paths, signing params only in `x-tts-*` headers, a plain
 * HMAC with no secret wrap). Rules, from TikTok's "Sign your API request" page as
 * implemented by the public `tiktok-shop` SDK (common.js signatureByAppSecret):
 *
 *   input = path + concat(sorted query `key+value`, excluding sign + access_token)
 *           + raw JSON body (omitted for multipart uploads)
 *   sign  = hex HMAC-SHA256(key = app_secret, msg = app_secret + input + app_secret)
 *
 * Query always carries `app_key`, `timestamp`, `sign`, plus `shop_cipher` for
 * shop-scoped calls. The access token goes in the `x-tts-access-token` header.
 *
 * Token endpoints live on a different host and are NOT signed: the app secret
 * goes in the query. `access_token_expire_in` there is an absolute Unix time
 * (seconds), not a duration — the old code added it to Date.now().
 *
 * Every piece is pure or takes its I/O as a parameter so it is unit-testable;
 * `createTiktokClient` is the stateful part (token refresh + shop cipher).
 */

"use strict";

const crypto = require("crypto");
const { HttpsError } = require("firebase-functions/v2/https");

const API_HOST = "https://open-api.tiktokglobalshop.com";
const AUTH_HOST = "https://auth.tiktok-shops.com";
const REFRESH_MARGIN_MS = 5 * 60 * 1000;

// ── signing ────────────────────────────────────────────────────────────────

function signRequest(appSecret, path, query = {}, bodyStr = "") {
  const concat = Object.keys(query)
    .filter((k) => k !== "sign" && k !== "access_token" && query[k] !== undefined && query[k] !== null)
    .sort()
    .map((k) => `${k}${query[k]}`)
    .join("");
  const plain = `${appSecret}${path}${concat}${bodyStr}${appSecret}`;
  return crypto.createHmac("sha256", appSecret).update(plain).digest("hex");
}

/**
 * Build the URL + headers + body of one signed call. `multipart` bodies are
 * left out of the signature (TikTok's rule for file uploads) and the caller
 * supplies the FormData.
 */
function buildSignedRequest({
  appKey, appSecret, accessToken, method, path, query = {}, body = null, shopCipher = null,
  multipart = false, nowSec = Math.floor(Date.now() / 1000),
}) {
  const q = { ...query, app_key: appKey, timestamp: nowSec };
  if (shopCipher) q.shop_cipher = shopCipher;
  const bodyStr = !multipart && body != null ? JSON.stringify(body) : "";
  q.sign = signRequest(appSecret, path, q, bodyStr);
  const qs = new URLSearchParams(Object.entries(q).map(([k, v]) => [k, String(v)])).toString();
  const headers = { "x-tts-access-token": accessToken };
  if (!multipart) headers["Content-Type"] = "application/json";
  return {
    url: `${API_HOST}${path}?${qs}`,
    init: { method, headers, body: multipart ? body : (bodyStr || undefined) },
  };
}

// ── tokens ─────────────────────────────────────────────────────────────────

function tokenUrl(kind, { appKey, appSecret, code, refreshToken }) {
  const params = kind === "get"
    ? { app_key: appKey, app_secret: appSecret, auth_code: code, grant_type: "authorized_code" }
    : { app_key: appKey, app_secret: appSecret, refresh_token: refreshToken, grant_type: "refresh_token" };
  return `${AUTH_HOST}/api/v2/token/${kind}?${new URLSearchParams(params).toString()}`;
}

/** `*_expire_in` → epoch ms. Absolute Unix seconds per the docs; a small number is
 *  read as a duration so a doc change can't make every token look expired. */
function expiryToMs(v, nowMs) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return nowMs + 3600 * 1000;
  return n > 1e9 ? n * 1000 : nowMs + n * 1000;
}

/** Token endpoint JSON → the fields stored on users/{uid}/integrations/tiktok. */
function parseTokenResponse(parsed, nowMs = Date.now()) {
  if (!parsed || parsed.code !== 0 || !parsed.data?.access_token) {
    throw new HttpsError(
      "failed-precondition",
      `TikTok sign-in failed: ${parsed?.message || "no token returned"}. Reconnect TikTok Shop in Settings.`,
    );
  }
  const d = parsed.data;
  return {
    accessToken: d.access_token,
    refreshToken: d.refresh_token ?? null,
    tokenExpiresAt: expiryToMs(d.access_token_expire_in, nowMs),
    refreshTokenExpiresAt: d.refresh_token_expire_in ? expiryToMs(d.refresh_token_expire_in, nowMs) : null,
    sellerName: d.seller_name ?? null,
    openId: d.open_id ?? null,
  };
}

/** GET /authorization/202309/shops → the first shop (Wonni supports one per account). */
function pickShop(parsed) {
  const shop = parsed?.data?.shops?.[0];
  if (!shop?.cipher) {
    throw new HttpsError("failed-precondition", "This TikTok account has no authorized shop. Reconnect TikTok Shop in Settings.");
  }
  return { shopId: String(shop.id ?? ""), shopCipher: shop.cipher, shopName: shop.name ?? null, shopRegion: shop.region ?? null };
}

// ── errors ─────────────────────────────────────────────────────────────────

// 105xxx = auth/token problems (expired, revoked, wrong app); 106xxx = app or
// seller lacks the scope/permission. Both mean "reconnect", not "retry".
function isAuthError(code) {
  const c = Number(code);
  return (c >= 105000 && c < 107000) || c === 36004004;
}

/** A non-zero TikTok envelope → readable HttpsError carrying TikTok's own reason. */
function tiktokError(parsed, what = "TikTok request", httpStatus = null) {
  const code = parsed?.code;
  const msg = parsed?.message || (httpStatus ? `HTTP ${httpStatus}` : "unknown error");
  const reqId = parsed?.request_id ? ` (request ${parsed.request_id})` : "";
  if (isAuthError(code) || httpStatus === 401) {
    return new HttpsError("failed-precondition", `${what} failed: ${msg}. Reconnect TikTok Shop in Settings.${reqId}`, { tiktokCode: code });
  }
  return new HttpsError("failed-precondition", `${what} failed: ${msg} [${code ?? httpStatus}]${reqId}`, { tiktokCode: code });
}

async function readJson(res) {
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { code: -1, message: `Non-JSON response (HTTP ${res.status}): ${text.slice(0, 200)}` }; }
}

// ── client ─────────────────────────────────────────────────────────────────

/**
 * One user's TikTok Shop client.
 *   deps: { db, uid, appKey, appSecret, fetchImpl = fetch, now = Date.now }
 * `request(method, path, { query, body, shopScoped = true, what })` returns
 * `data` from the envelope or throws a readable HttpsError.
 */
function createTiktokClient({ db, uid, appKey, appSecret, fetchImpl = fetch, now = Date.now }) {
  const ref = db.doc(`users/${uid}/integrations/tiktok`);
  let cached = null;

  async function credentials() {
    if (cached && cached.tokenExpiresAt - now() > REFRESH_MARGIN_MS) return cached;
    const snap = await ref.get();
    const data = snap.exists ? snap.data() : null;
    if (!data?.isConnected || !data.accessToken) {
      throw new HttpsError("failed-precondition", "TikTok Shop is not connected. Connect it in Settings.");
    }
    let creds = { ...data };
    if (!(data.tokenExpiresAt - now() > REFRESH_MARGIN_MS)) {
      if (!data.refreshToken) throw new HttpsError("failed-precondition", "TikTok session expired. Reconnect TikTok Shop in Settings.");
      const res = await fetchImpl(tokenUrl("refresh", { appKey, appSecret, refreshToken: data.refreshToken }), { method: "GET" });
      const t = parseTokenResponse(await readJson(res), now());
      const patch = {
        accessToken: t.accessToken,
        refreshToken: t.refreshToken ?? data.refreshToken,
        tokenExpiresAt: t.tokenExpiresAt,
      };
      if (t.refreshTokenExpiresAt) patch.refreshTokenExpiresAt = t.refreshTokenExpiresAt;
      await ref.set(patch, { merge: true });
      creds = { ...creds, ...patch };
    }
    cached = creds;
    return creds;
  }

  async function send(method, path, { query = {}, body = null, shopCipher = null, multipart = false, what } = {}) {
    const creds = await credentials();
    const { url, init } = buildSignedRequest({
      appKey, appSecret, accessToken: creds.accessToken, method, path, query, body, shopCipher, multipart,
      nowSec: Math.floor(now() / 1000),
    });
    const res = await fetchImpl(url, init);
    const parsed = await readJson(res);
    if (parsed.code !== 0) throw tiktokError(parsed, what || `TikTok ${method} ${path}`, res.status);
    return parsed.data ?? {};
  }

  async function shopCipher() {
    const creds = await credentials();
    if (creds.shopCipher) return creds.shopCipher;
    const data = await send("GET", "/authorization/202309/shops", { what: "Loading your TikTok shop" });
    const shop = pickShop({ data });
    await ref.set(shop, { merge: true });
    cached = { ...cached, ...shop };
    return shop.shopCipher;
  }

  return {
    async request(method, path, { query, body, shopScoped = true, multipart = false, what } = {}) {
      const cipher = shopScoped ? await shopCipher() : null;
      return send(method, path, { query, body, shopCipher: cipher, multipart, what });
    },
    credentials,
    shopCipher,
  };
}

module.exports = {
  API_HOST, AUTH_HOST,
  signRequest, buildSignedRequest, tokenUrl, expiryToMs, parseTokenResponse, pickShop,
  isAuthError, tiktokError, createTiktokClient,
};
