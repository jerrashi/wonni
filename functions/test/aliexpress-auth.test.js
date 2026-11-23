/**
 * aliexpress-auth.test.js — IOP signing, token parsing and the business-call
 * error envelope, with a fake fetch.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");

const { FakeFirestore } = require("./helpers/fake-firestore");
const ae = require("../aliexpress_auth");

const SECRET = "s3cret";
const hmac = (s) => crypto.createHmac("sha256", SECRET).update(s).digest("hex").toUpperCase();

test("signRequest: system APIs prefix the path; business APIs don't (official IOP SDK rule)", () => {
  const params = { b: "2", a: "1", sign: "x" };
  assert.equal(ae.signRequest(params, SECRET, "/auth/token/create"), hmac("/auth/token/createa1b2"));
  assert.equal(ae.signRequest(params, SECRET), hmac("a1b2"));
});

test("regression: expire_time is epoch ms, not seconds from now", () => {
  const now = 1_700_000_000_000;
  const t = ae._internal.parseTokenResponse({
    access_token: "A", refresh_token: "R", expire_time: 1_700_086_400_000, refresh_token_valid_time: 1_702_000_000_000, account: "me",
  }, now);
  assert.equal(t.tokenExpiresAt, 1_700_086_400_000);
  assert.equal(t.refreshTokenExpiresAt, 1_702_000_000_000);
  assert.equal(ae._internal.tokenExpiryMs({ expires_in: 60 }, now), now + 60_000);
});

test("parseTokenResponse: no token → readable reconnect error", () => {
  assert.throws(() => ae._internal.parseTokenResponse({ code: "IncompleteSignature", message: "bad sign" }),
    (e) => e.code === "failed-precondition" && /bad sign/.test(e.message));
});

function fetchRecorder(byPath) {
  const calls = [];
  const impl = async (url, init) => {
    const u = new URL(url);
    calls.push({ path: u.pathname, params: Object.fromEntries(new URLSearchParams(init.body)) });
    return { status: 200, text: async () => JSON.stringify(byPath[u.pathname]) };
  };
  impl.calls = calls;
  return impl;
}

test("callAliexpressApi: refreshes an expiring token via /rest/auth/token/refresh, then signs the /sync call", async () => {
  const db = new FakeFirestore();
  const now = 1_700_000_000_000;
  await db.doc("users/u/integrations/aliexpress").set({ isConnected: true, accessToken: "old", refreshToken: "R", tokenExpiresAt: now + 1000 });
  const fetchImpl = fetchRecorder({
    "/rest/auth/token/refresh": { access_token: "new", refresh_token: "R2", expire_time: now + 86_400_000 },
    "/sync": { aliexpress_ds_product_get_response: { result: { ok: 1 } } },
  });
  const r = await ae.callAliexpressApi("aliexpress.ds.product.get", { product_id: "1" }, "u",
    { db, appKey: "K", appSecret: SECRET, fetchImpl, now: () => now });
  assert.deepEqual(r, { aliexpress_ds_product_get_response: { result: { ok: 1 } } });

  const [refresh, call] = fetchImpl.calls;
  assert.equal(refresh.path, "/rest/auth/token/refresh");
  const { sign: rs, ...rp } = refresh.params;
  assert.equal(rs, ae.signRequest(rp, SECRET, "/auth/token/refresh"));
  assert.equal(call.params.access_token, "new");
  assert.equal(call.params.method, "aliexpress.ds.product.get");
  const { sign: cs, ...cp } = call.params;
  assert.equal(cs, ae.signRequest(cp, SECRET));
  assert.equal((await db.doc("users/u/integrations/aliexpress").get()).data().refreshToken, "R2");
});

test("callAliexpressApi: error_response is thrown with AliExpress's message, not returned silently", async () => {
  const db = new FakeFirestore();
  await db.doc("users/u/integrations/aliexpress").set({ isConnected: true, accessToken: "a", tokenExpiresAt: Date.now() + 86_400_000 });
  const fetchImpl = fetchRecorder({ "/sync": { error_response: { code: "IllegalAccessToken", msg: "The specified access token is invalid" } } });
  await assert.rejects(ae.callAliexpressApi("aliexpress.ds.product.get", {}, "u", { db, appKey: "K", appSecret: SECRET, fetchImpl }),
    (e) => e.code === "failed-precondition" && /access token is invalid\. Reconnect AliExpress/.test(e.message));
});

test("callAliexpressApi: not connected → readable error, no network", async () => {
  const fetchImpl = fetchRecorder({});
  await assert.rejects(ae.callAliexpressApi("x", {}, "u", { db: new FakeFirestore(), appKey: "K", appSecret: SECRET, fetchImpl }),
    /not connected/);
  assert.equal(fetchImpl.calls.length, 0);
});
