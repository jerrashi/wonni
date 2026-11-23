/**
 * tiktok-client.test.js — signing, token parsing, error mapping and the
 * refresh/shop-cipher flow of tiktok_client.js, with a fake fetch.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");

const { FakeFirestore } = require("./helpers/fake-firestore");
const tt = require("../tiktok_client");

const SECRET = "sec123";
const KEY = "key456";

test("signRequest: secret-wrapped HMAC over path + sorted params (minus sign/access_token) + body", () => {
  const sig = tt.signRequest(SECRET, "/product/202309/products", {
    timestamp: 1700000000, app_key: KEY, shop_cipher: "ROW_x", sign: "ignored", access_token: "ignored",
  }, '{"a":1}');
  const plain = `${SECRET}/product/202309/productsapp_key${KEY}shop_cipherROW_xtimestamp1700000000{"a":1}${SECRET}`;
  assert.equal(sig, crypto.createHmac("sha256", SECRET).update(plain).digest("hex"));
});

test("regression: matches the public tiktok-shop SDK's signatureByAppSecret on the same input", () => {
  // Re-implementation of tiktok-shop@2.0.0 dist/common/common.js signatureByAppSecret,
  // inlined so the test needs no extra dependency.
  function sdkSign(params, path, appSecret, body) {
    const keys = Object.keys(params).filter((k) => !["app_secret", "token", "access_token", "sign"].includes(k))
      .sort((a, b) => a.localeCompare(b));
    let input = path + keys.map((k) => k + String(params[k])).join("");
    if (Object.keys(body).length) input += JSON.stringify(body);
    return crypto.createHmac("sha256", appSecret).update(appSecret + input + appSecret).digest("hex");
  }
  const params = { app_key: KEY, timestamp: 1700000000, shop_cipher: "ROW_x", page_size: 50 };
  const body = { order_status: "AWAITING_SHIPMENT" };
  assert.equal(
    tt.signRequest(SECRET, "/order/202309/orders/search", params, JSON.stringify(body)),
    sdkSign(params, "/order/202309/orders/search", SECRET, body),
  );
});

test("buildSignedRequest: 202309 host, signing params in the QUERY, token in x-tts-access-token", () => {
  const { url, init } = tt.buildSignedRequest({
    appKey: KEY, appSecret: SECRET, accessToken: "AT", method: "POST",
    path: "/order/202309/orders/search", query: { page_size: 50 }, body: { x: 1 },
    shopCipher: "ROW_c", nowSec: 1700000000,
  });
  const u = new URL(url);
  assert.equal(u.origin, "https://open-api.tiktokglobalshop.com");
  assert.equal(u.pathname, "/order/202309/orders/search");
  assert.equal(u.searchParams.get("app_key"), KEY);
  assert.equal(u.searchParams.get("timestamp"), "1700000000");
  assert.equal(u.searchParams.get("shop_cipher"), "ROW_c");
  assert.equal(u.searchParams.get("page_size"), "50");
  assert.equal(u.searchParams.get("sign"), tt.signRequest(SECRET, u.pathname,
    { page_size: 50, app_key: KEY, timestamp: 1700000000, shop_cipher: "ROW_c" }, '{"x":1}'));
  assert.equal(u.searchParams.has("access_token"), false);
  assert.equal(init.headers["x-tts-access-token"], "AT");
  assert.equal(init.body, '{"x":1}');
});

test("buildSignedRequest: multipart body is not signed and keeps no JSON content-type", () => {
  const form = { fake: "form" };
  const { url, init } = tt.buildSignedRequest({
    appKey: KEY, appSecret: SECRET, accessToken: "AT", method: "POST",
    path: "/product/202309/images/upload", body: form, multipart: true, shopCipher: "c", nowSec: 1,
  });
  const u = new URL(url);
  assert.equal(u.searchParams.get("sign"),
    tt.signRequest(SECRET, u.pathname, { app_key: KEY, timestamp: 1, shop_cipher: "c" }, ""));
  assert.equal(init.body, form);
  assert.equal(init.headers["Content-Type"], undefined);
});

test("tokenUrl: unsigned, app_secret in the query, right grant types", () => {
  const g = new URL(tt.tokenUrl("get", { appKey: KEY, appSecret: SECRET, code: "C" }));
  assert.equal(g.href.startsWith("https://auth.tiktok-shops.com/api/v2/token/get?"), true);
  assert.equal(g.searchParams.get("grant_type"), "authorized_code");
  assert.equal(g.searchParams.get("auth_code"), "C");
  assert.equal(g.searchParams.get("app_secret"), SECRET);
  const r = new URL(tt.tokenUrl("refresh", { appKey: KEY, appSecret: SECRET, refreshToken: "R" }));
  assert.equal(r.pathname, "/api/v2/token/refresh");
  assert.equal(r.searchParams.get("grant_type"), "refresh_token");
});

test("regression: access_token_expire_in is an absolute Unix time, not a duration", () => {
  const now = 1_700_000_000_000;
  const t = tt.parseTokenResponse({ code: 0, data: {
    access_token: "A", refresh_token: "R", access_token_expire_in: 1_700_604_800, refresh_token_expire_in: 1_731_536_000,
    seller_name: "Wonni", open_id: "o1",
  } }, now);
  assert.equal(t.tokenExpiresAt, 1_700_604_800_000);
  assert.equal(t.refreshTokenExpiresAt, 1_731_536_000_000);
  assert.equal(t.sellerName, "Wonni");
  // A duration-looking value still works.
  assert.equal(tt.expiryToMs(3600, now), now + 3_600_000);
});

test("parseTokenResponse: a failed exchange is a readable reconnect error", () => {
  assert.throws(() => tt.parseTokenResponse({ code: 36004004, message: "invalid auth code" }),
    (e) => e.code === "failed-precondition" && /invalid auth code/.test(e.message) && /Reconnect/.test(e.message));
});

test("tiktokError: auth codes say reconnect; others carry TikTok's reason + code", () => {
  const a = tt.tiktokError({ code: 105002, message: "Expired credentials", request_id: "r1" }, "Posting");
  assert.equal(a.code, "failed-precondition");
  assert.match(a.message, /Posting failed: Expired credentials\. Reconnect TikTok Shop/);
  const b = tt.tiktokError({ code: 12052048, message: "Category is invalid" }, "Posting");
  assert.match(b.message, /Category is invalid \[12052048\]/);
  assert.doesNotMatch(b.message, /Reconnect/);
});

// ── client flow ────────────────────────────────────────────────────────────

function fakeFetch(routes) {
  const calls = [];
  const impl = async (url, init = {}) => {
    calls.push({ url, init });
    const u = new URL(url);
    const handler = routes[u.pathname];
    if (!handler) throw new Error(`unexpected fetch ${u.pathname}`);
    const out = typeof handler === "function" ? handler(u, init) : handler;
    return { status: 200, text: async () => JSON.stringify(out) };
  };
  impl.calls = calls;
  return impl;
}

function seededDb(integration) {
  const db = new FakeFirestore();
  db.doc("users/u1/integrations/tiktok").set(integration);
  return db;
}

const NOW = 1_700_000_000_000;

test("client: refreshes an expiring token, stores it, then fetches + caches the shop cipher", async () => {
  const db = seededDb({ isConnected: true, accessToken: "old", refreshToken: "R", tokenExpiresAt: NOW + 60_000 });
  const fetchImpl = fakeFetch({
    "/api/v2/token/refresh": { code: 0, data: { access_token: "new", refresh_token: "R2", access_token_expire_in: NOW / 1000 + 86400 } },
    "/authorization/202309/shops": { code: 0, data: { shops: [{ id: "7", name: "Wonni", cipher: "ROW_c", region: "US" }] } },
    "/product/202309/categories": (u, init) => {
      assert.equal(u.searchParams.get("shop_cipher"), "ROW_c");
      assert.equal(init.headers["x-tts-access-token"], "new");
      return { code: 0, data: { categories: [] } };
    },
  });
  const client = tt.createTiktokClient({ db, uid: "u1", appKey: KEY, appSecret: SECRET, fetchImpl, now: () => NOW });
  assert.deepEqual(await client.request("GET", "/product/202309/categories"), { categories: [] });
  await client.request("GET", "/product/202309/categories");

  const stored = (await db.doc("users/u1/integrations/tiktok").get()).data();
  assert.equal(stored.accessToken, "new");
  assert.equal(stored.refreshToken, "R2");
  assert.equal(stored.shopCipher, "ROW_c");
  assert.equal(stored.shopId, "7");
  const paths = fetchImpl.calls.map((c) => new URL(c.url).pathname);
  assert.deepEqual(paths, ["/api/v2/token/refresh", "/authorization/202309/shops",
    "/product/202309/categories", "/product/202309/categories"]);
  // The shops call itself is not shop-scoped.
  assert.equal(new URL(fetchImpl.calls[1].url).searchParams.has("shop_cipher"), false);
});

test("client: not connected → readable failed-precondition, no network", async () => {
  const db = new FakeFirestore();
  const fetchImpl = fakeFetch({});
  const client = tt.createTiktokClient({ db, uid: "u1", appKey: KEY, appSecret: SECRET, fetchImpl, now: () => NOW });
  await assert.rejects(client.request("GET", "/product/202309/categories"),
    (e) => e.code === "failed-precondition" && /not connected/.test(e.message));
  assert.equal(fetchImpl.calls.length, 0);
});

test("client: a non-zero envelope throws with TikTok's message", async () => {
  const db = seededDb({ isConnected: true, accessToken: "a", tokenExpiresAt: NOW + 86_400_000, shopCipher: "c" });
  const fetchImpl = fakeFetch({ "/product/202309/products": { code: 12019001, message: "Missing brand" } });
  const client = tt.createTiktokClient({ db, uid: "u1", appKey: KEY, appSecret: SECRET, fetchImpl, now: () => NOW });
  await assert.rejects(client.request("POST", "/product/202309/products", { body: {}, what: "Posting to TikTok" }),
    (e) => /Posting to TikTok failed: Missing brand \[12019001\]/.test(e.message));
});
