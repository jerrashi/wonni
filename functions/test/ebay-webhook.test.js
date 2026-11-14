/**
 * ebay-webhook.test.js — challenge hash, signature check, topic routing,
 * seller lookup, and the per-seller ORDER_CONFIRMATION subscription.
 * No network: eBay calls and the sales poll are injected.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");

const { _internal: wh, NOTIFICATION_SCOPE } = require("../ebay_webhook");

// ── a tiny Firestore double with collectionGroup + nested docs ─────────────

function makeDb(seed = {}) {
  const store = new Map(Object.entries(seed)); // full path → data
  const ref = (path) => {
    const parts = path.split("/");
    return {
      id: parts[parts.length - 1],
      path,
      parent: { id: parts[parts.length - 2], parent: { id: parts[parts.length - 3] } },
      async get() { const d = store.get(path); return { exists: !!d, data: () => d }; },
      async set(data, opts) { store.set(path, opts?.merge ? { ...(store.get(path) ?? {}), ...data } : data); },
      async delete() { store.delete(path); },
    };
  };
  return {
    store,
    doc: ref,
    collectionGroup(name) {
      // Immutable like real Firestore queries: where() returns a new query.
      const query = (filters) => ({
        where(f, op, v) { return query([...filters, [f, v]]); },
        async get() {
          const docs = [...store.entries()]
            .filter(([p, d]) => p.split("/").slice(-2)[0] === name && filters.every(([f, v]) => d[f] === v))
            .map(([p, d]) => ({ id: p.split("/").pop(), ref: ref(p), data: () => d }));
          return { empty: docs.length === 0, docs };
        },
      });
      return query([]);
    },
  };
}

// ── challenge ──────────────────────────────────────────────────────────────

test("challengeResponse: sha256 hex of code + token + endpoint, in that order", () => {
  const expected = crypto.createHash("sha256").update("abc" + "tok" + "https://x/y").digest("hex");
  assert.equal(wh.challengeResponse("abc", "tok", "https://x/y"), expected);
});

// ── signature ──────────────────────────────────────────────────────────────

function signedFixture(body) {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const raw = Buffer.from(JSON.stringify(body));
  const signature = crypto.createSign("sha1").update(raw).sign(privateKey, "base64");
  const header = Buffer.from(JSON.stringify({ alg: "ecdsa", kid: "k1", signature, digest: "SHA1" })).toString("base64");
  // eBay sends the PEM on one line; formatPublicKey must cope.
  const oneLine = publicKey.export({ type: "spki", format: "pem" }).replace(/\n/g, "");
  return { raw, header, getPublicKey: async (kid) => (kid === "k1" ? { key: oneLine, digest: "SHA1" } : null) };
}

test("verifySignature: accepts eBay-signed bodies (raw or re-serialized)", async () => {
  const body = { metadata: { topic: "ORDER_CONFIRMATION" }, notification: { data: { order: { orderId: "1" } } } };
  const f = signedFixture(body);
  assert.equal(await wh.verifySignature({ header: f.header, rawBody: f.raw, body, getPublicKey: f.getPublicKey }), true);
  assert.equal(await wh.verifySignature({ header: f.header, body, getPublicKey: f.getPublicKey }), true);
});

test("verifySignature: rejects tampered body, missing header, unknown key", async () => {
  const body = { metadata: { topic: "ORDER_CONFIRMATION" } };
  const f = signedFixture(body);
  const tampered = { metadata: { topic: "MARKETPLACE_ACCOUNT_DELETION" } };
  assert.equal(await wh.verifySignature({ header: f.header, body: tampered, getPublicKey: f.getPublicKey }), false);
  assert.equal(await wh.verifySignature({ header: undefined, body, getPublicKey: f.getPublicKey }), false);
  assert.equal(await wh.verifySignature({ header: "not base64 json", body, getPublicKey: f.getPublicKey }), false);
  const otherKid = Buffer.from(JSON.stringify({ kid: "nope", signature: "AAAA" })).toString("base64");
  assert.equal(await wh.verifySignature({ header: otherKid, body, getPublicKey: f.getPublicKey }), false);
  const throwing = async () => { throw new Error("eBay down"); };
  assert.equal(await wh.verifySignature({ header: f.header, body, getPublicKey: throwing }), false);
});

// ── routing ────────────────────────────────────────────────────────────────

const seed = () => ({
  "users/u1/integrations/ebay": { isConnected: true, connectedUsername: "seller_one", ebayUserId: "EBU1", orderNotificationSubscriptionId: "sub-1" },
  "users/u2/integrations/ebay": { isConnected: true, connectedUsername: "seller_two" },
  "users/u3/integrations/etsy": { isConnected: true, connectedUsername: "seller_two" }, // not eBay
});

test("ORDER_CONFIRMATION: finds the seller by subscription id and polls only them", async () => {
  const db = makeDb(seed());
  const polled = [];
  const r = await wh.handleNotification(db, {
    metadata: { topic: "ORDER_CONFIRMATION", subscriptionId: "sub-1" },
    notification: { data: { user: { username: "someone_else" }, order: { orderId: "O1" } } },
  }, { syncUser: async (uid) => { polled.push(uid); return { imported: 1 }; } });
  assert.deepEqual(polled, ["u1"]);
  assert.equal(r.imported, 1);
});

test("ORDER_CONFIRMATION: falls back to user id, then username; never matches a non-eBay integration", async () => {
  const db = makeDb(seed());
  const polled = [];
  const syncUser = async (uid) => { polled.push(uid); return { imported: 0 }; };
  await wh.handleNotification(db, { metadata: { topic: "ORDER_CONFIRMATION" }, notification: { data: { user: { userId: "EBU1" } } } }, { syncUser });
  await wh.handleNotification(db, { metadata: { topic: "ORDER_CONFIRMATION" }, notification: { data: { user: { username: "seller_two" } } } }, { syncUser });
  assert.deepEqual(polled, ["u1", "u2"]);
});

test("ORDER_CONFIRMATION: unknown seller or disconnected integration polls nobody", async () => {
  const s = seed();
  s["users/u2/integrations/ebay"].isConnected = false;
  const db = makeDb(s);
  const polled = [];
  const syncUser = async (uid) => { polled.push(uid); };
  await wh.handleNotification(db, { metadata: { topic: "ORDER_CONFIRMATION" }, notification: { data: { user: { username: "stranger" } } } }, { syncUser });
  await wh.handleNotification(db, { metadata: { topic: "ORDER_CONFIRMATION" }, notification: { data: { user: { username: "seller_two" } } } }, { syncUser });
  assert.deepEqual(polled, []);
});

test("regression: a failing poll never throws out of the handler (eBay would retry for days)", async () => {
  const db = makeDb(seed());
  const r = await wh.handleNotification(db, { metadata: { topic: "ORDER_CONFIRMATION", subscriptionId: "sub-1" }, notification: { data: {} } },
    { syncUser: async () => { throw new Error("boom"); } });
  assert.equal(r.error, "boom");
});

test("MARKETPLACE_ACCOUNT_DELETION removes that eBay account's connections only, by user id", async () => {
  const db = makeDb(seed());
  const r = await wh.handleNotification(db, { metadata: { topic: "MARKETPLACE_ACCOUNT_DELETION" }, notification: { data: { username: "whatever", userId: "EBU1" } } }, {});
  assert.equal(r.unlinked, 1);
  assert.equal(db.store.has("users/u1/integrations/ebay"), false);
  assert.equal(db.store.has("users/u2/integrations/ebay"), true);
  assert.equal(db.store.has("users/u3/integrations/etsy"), true);
});

test("regression: account deletion never matches by username (usernames are reused after a rename)", async () => {
  const db = makeDb(seed());
  // u2 has no ebayUserId; a deletion carrying their (possibly recycled) username must not touch it.
  const r = await wh.handleNotification(db, { metadata: { topic: "MARKETPLACE_ACCOUNT_DELETION" }, notification: { data: { username: "seller_two", userId: "someone-new" } } }, {});
  assert.equal(r.unlinked, 0);
  assert.equal(db.store.has("users/u2/integrations/ebay"), true);
});

test("regression: a user id is never compared against connectedUsername", async () => {
  const s = seed();
  s["users/u2/integrations/ebay"].connectedUsername = "EBU9"; // legacy doc that stored an id as the name
  const db = makeDb(s);
  const polled = [];
  await wh.handleNotification(db, { metadata: { topic: "ORDER_CONFIRMATION" }, notification: { data: { user: { userId: "EBU9" } } } },
    { syncUser: async (uid) => { polled.push(uid); } });
  assert.deepEqual(polled, []);
});

test("unknown topics are ignored", async () => {
  const r = await wh.handleNotification(makeDb(), { metadata: { topic: "ITEM_AVAILABILITY" } }, {});
  assert.equal(r.ignored, true);
});

// ── subscription ───────────────────────────────────────────────────────────

const opts = (call, appCall = call) => ({ call, appCall, webhookUrl: "https://hook", verificationToken: "tok" });

test("ensureEbayOrderSubscription: needs the notification scope (old grants must reconnect)", async () => {
  const db = makeDb({ "users/u/integrations/ebay": { isConnected: true, grantedScopes: "https://api.ebay.com/oauth/api_scope/sell.fulfillment" } });
  const r = await wh.ensureEbayOrderSubscription(db, "u", opts(async () => { throw new Error("should not call"); }));
  assert.equal(r.status, "needs-reconnect");
});

test("ensureEbayOrderSubscription: creates destination once, then the subscription, and stores both ids", async () => {
  const db = makeDb({
    "users/a/integrations/ebay": { isConnected: true, grantedScopes: `x ${NOTIFICATION_SCOPE}` },
    "users/b/integrations/ebay": { isConnected: true, grantedScopes: NOTIFICATION_SCOPE },
  });
  const calls = [];
  let n = 0;
  const call = async (method, path, body) => {
    calls.push(`${method} ${path}`);
    if (path.endsWith("/destination")) return { destinationId: "D1" };
    if (path.endsWith("/subscription")) { assert.equal(body.topicId, "ORDER_CONFIRMATION"); assert.equal(body.destinationId, "D1"); return { subscriptionId: `S${++n}` }; }
  };
  assert.equal((await wh.ensureEbayOrderSubscription(db, "a", opts(call))).subscriptionId, "S1");
  assert.equal((await wh.ensureEbayOrderSubscription(db, "b", opts(call))).subscriptionId, "S2");
  assert.equal(calls.filter((c) => c.endsWith("/destination")).length, 1);
  assert.equal(db.store.get("users/a/integrations/ebay").orderNotificationSubscriptionId, "S1");
  assert.equal(db.store.get("system/ebayNotifications").destinationId, "D1");
  // second run for the same user is a no-op
  assert.equal((await wh.ensureEbayOrderSubscription(db, "a", opts(call))).status, "exists");
});

test("ensureEbayOrderSubscription: 409s fall back to finding the existing destination / subscription", async () => {
  const db = makeDb({ "users/a/integrations/ebay": { isConnected: true, grantedScopes: NOTIFICATION_SCOPE } });
  const conflict = () => Object.assign(new Error("409"), { status: 409 });
  const call = async (method, path) => {
    if (method === "POST") throw conflict();
    if (path.includes("/destination")) return { destinations: [{ destinationId: "OLD", deliveryConfig: { endpoint: "https://other" } }, { destinationId: "D9", deliveryConfig: { endpoint: "https://hook" } }] };
    return { subscriptions: [{ topicId: "ITEM_AVAILABILITY", subscriptionId: "nope" }, { topicId: "ORDER_CONFIRMATION", subscriptionId: "S9" }] };
  };
  const r = await wh.ensureEbayOrderSubscription(db, "a", opts(call));
  assert.equal(r.subscriptionId, "S9");
  assert.equal(db.store.get("system/ebayNotifications").destinationId, "D9");
});

test("regression: the destination uses the app token, the subscription the user token (user token 403s on /destination)", async () => {
  const db = makeDb({ "users/a/integrations/ebay": { isConnected: true, grantedScopes: NOTIFICATION_SCOPE } });
  const userPaths = [], appPaths = [];
  const call = async (method, path) => {
    userPaths.push(path);
    if (path.includes("/destination")) throw Object.assign(new Error("403 Access denied"), { status: 403 });
    return { subscriptionId: "S1" };
  };
  const appCall = async (method, path) => { appPaths.push(path); return { destinationId: "D1" }; };
  const r = await wh.ensureEbayOrderSubscription(db, "a", opts(call, appCall));
  assert.equal(r.status, "created");
  assert.deepEqual(appPaths, ["/commerce/notification/v1/destination"]);
  assert.deepEqual(userPaths, ["/commerce/notification/v1/subscription"]);
});

test("ensureEbayOrderSubscription: an eBay error is returned, not thrown (connect must still succeed)", async () => {
  const db = makeDb({ "users/a/integrations/ebay": { isConnected: true, grantedScopes: NOTIFICATION_SCOPE } });
  const r = await wh.ensureEbayOrderSubscription(db, "a", opts(async () => { throw Object.assign(new Error("403 insufficient scope"), { status: 403 }); }));
  assert.equal(r.status, "failed");
});
