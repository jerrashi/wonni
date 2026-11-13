/**
 * ebay_webhook.js — eBay push notifications (github #26).
 *
 * One HTTPS endpoint, `ebayWebhook`, serves two eBay features:
 *
 *  1. Marketplace account deletion (eBay compliance). Every production keyset
 *     must name an endpoint that answers eBay's GET challenge and accepts
 *     MARKETPLACE_ACCOUNT_DELETION posts, or eBay may disable the keyset. The
 *     endpoint is set by hand in developer.ebay.com > Alerts & Notifications, with
 *     the same verification token as the EBAY_VERIFICATION_TOKEN secret.
 *  2. ORDER_CONFIRMATION (Notification API): sent to a seller when a buyer
 *     completes checkout and payment clears. We do not trust or parse the order
 *     from the push; it only says "poll this seller's eBay orders now", through the
 *     same `syncSalesForUser` path the 30-minute schedule uses (which dedupes).
 *     The 30-minute poll stays as the backstop for missed pushes.
 *
 * Subscriptions are per seller and need a USER token carrying
 * `commerce.notification.subscription`, so `ensureEbayOrderSubscription` runs
 * right after a (re)connect. The destination (our endpoint URL) is one per app;
 * it is created on first use and remembered in `system/ebayNotifications`.
 *
 * Every POST is signature-checked (X-EBAY-SIGNATURE: base64 JSON {alg, kid,
 * signature, digest}; ECDSA over the message with eBay's public key `kid`). A
 * bad signature gets 412, which eBay documents as the "rejected" answer.
 *
 * Retired: the 2026-08 version (deleted in 3a13f55, never deployed) parsed the
 * order and wrote the sale itself through a second code path.
 */

"use strict";

const crypto = require("crypto");
const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, ebayApiHost, refreshEbayToken, ebayRestHeaders } = require("./ebay_auth");

const { EBAY_VERIFICATION_TOKEN, EBAY_WEBHOOK_URL } = require("./ebay_webhook_params");

const NOTIFICATION_SCOPE = "https://api.ebay.com/oauth/api_scope/commerce.notification.subscription";
const ORDER_TOPIC = "ORDER_CONFIRMATION";
const DELETION_TOPICS = new Set(["MARKETPLACE_ACCOUNT_DELETION"]);
/** How far back a push-triggered poll reads. The push is for one fresh order. */
const PUSH_LOOKBACK_MS = 2 * 24 * 60 * 60 * 1000;

// ── challenge ──────────────────────────────────────────────────────────────

/** eBay's GET challenge answer: hex SHA-256 of code + token + endpoint URL. */
function challengeResponse(challengeCode, verificationToken, endpointUrl) {
  return crypto.createHash("sha256")
    .update(challengeCode).update(verificationToken).update(endpointUrl)
    .digest("hex");
}

// ── signature ──────────────────────────────────────────────────────────────

/** X-EBAY-SIGNATURE → {alg, kid, signature, digest}, or null if unreadable. */
function parseSignatureHeader(header) {
  if (typeof header !== "string" || !header) return null;
  try {
    const parsed = JSON.parse(Buffer.from(header, "base64").toString("utf8"));
    return parsed?.kid && parsed?.signature ? parsed : null;
  } catch {
    return null;
  }
}

/** eBay returns the key as one line with BEGIN/END markers glued on; PEM needs newlines. */
function formatPublicKey(key) {
  const body = String(key)
    .replace(/-----BEGIN PUBLIC KEY-----/, "")
    .replace(/-----END PUBLIC KEY-----/, "")
    .replace(/\s+/g, "");
  return `-----BEGIN PUBLIC KEY-----\n${body.match(/.{1,64}/g).join("\n")}\n-----END PUBLIC KEY-----`;
}

/**
 * True when the notification is signed by eBay. Checks the raw body first and
 * then the re-serialized JSON (eBay's own SDK verifies JSON.stringify(body)).
 * `getPublicKey(kid)` → {key, digest}; injected so tests need no network.
 */
async function verifySignature({ header, rawBody, body, getPublicKey }) {
  const sig = parseSignatureHeader(header);
  if (!sig) return false;
  let pk;
  try {
    pk = await getPublicKey(sig.kid);
  } catch (e) {
    console.error(`[ebayWebhook] public key ${sig.kid}: ${e.message}`);
    return false;
  }
  if (!pk?.key) return false;
  const pem = formatPublicKey(pk.key);
  const digest = String(pk.digest || sig.digest || "SHA1").toLowerCase().replace("-", "");
  const candidates = [];
  if (rawBody) candidates.push(Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(String(rawBody)));
  if (body !== undefined) candidates.push(Buffer.from(JSON.stringify(body)));
  return candidates.some((data) => {
    try {
      return crypto.createVerify(digest).update(data).verify(pem, sig.signature, "base64");
    } catch {
      return false;
    }
  });
}

// ── user lookup ────────────────────────────────────────────────────────────

/**
 * Which Wonni user is this eBay account? By subscription id first (exact), then
 * by eBay user id, then by username. eBay started sending an immutable user id in
 * place of the username for some US users (2025-09), hence both.
 * Returns integration doc refs (several Wonni users may have linked one eBay account).
 */
async function findEbayIntegrations(db, { subscriptionId, userId, username }) {
  const group = db.collectionGroup("integrations");
  if (subscriptionId) {
    const s = await group.where("orderNotificationSubscriptionId", "==", subscriptionId).get();
    if (!s.empty) return s.docs;
  }
  for (const [field, value] of [["ebayUserId", userId], ["connectedUsername", username], ["connectedUsername", userId]]) {
    if (!value) continue;
    const s = await group.where(field, "==", value).get();
    const hits = s.docs.filter((d) => d.id === "ebay");
    if (hits.length) return hits;
  }
  return [];
}

// ── topic handlers ─────────────────────────────────────────────────────────

/**
 * An eBay user deleted their account: forget their tokens and identity. Their
 * Wonni products and sales stay (they are the Wonni user's records), but the
 * eBay connection, which holds the eBay user's personal data, is removed.
 */
async function handleAccountDeletion(db, data) {
  const docs = await findEbayIntegrations(db, { userId: data?.userId, username: data?.username });
  for (const d of docs) {
    await d.ref.delete();
  }
  return { unlinked: docs.length };
}

/** A seller got an order: poll that seller's eBay orders now. */
async function handleOrderConfirmation(db, data, metadata, { syncUser }) {
  const docs = await findEbayIntegrations(db, {
    subscriptionId: metadata?.subscriptionId,
    userId: data?.user?.userId ?? data?.seller?.userId,
    username: data?.user?.username ?? data?.seller?.username,
  });
  const uids = [...new Set(docs.filter((d) => d.data()?.isConnected).map((d) => d.ref.parent.parent.id))];
  let imported = 0;
  for (const uid of uids) {
    const r = await syncUser(uid);
    imported += r?.imported ?? 0;
  }
  return { users: uids.length, imported };
}

/**
 * Routes one verified notification. Never throws: an application error must not
 * turn into a non-2xx, which would make eBay retry the same message for days.
 */
async function handleNotification(db, body, deps) {
  const topic = body?.metadata?.topic;
  const data = body?.notification?.data;
  try {
    if (DELETION_TOPICS.has(topic)) return { topic, ...(await handleAccountDeletion(db, data)) };
    if (topic === ORDER_TOPIC) return { topic, ...(await handleOrderConfirmation(db, data, body.metadata, deps)) };
    return { topic, ignored: true };
  } catch (e) {
    console.error(`[ebayWebhook] ${topic}: ${e.message}`);
    return { topic, error: e.message };
  }
}

// ── subscription setup ─────────────────────────────────────────────────────

/** Does this connection's grant allow creating notification subscriptions? */
function hasNotificationScope(integrationData) {
  const raw = integrationData?.grantedScopes;
  return typeof raw === "string" && raw.split(/\s+/).includes(NOTIFICATION_SCOPE);
}

/**
 * Makes sure this seller is subscribed to ORDER_CONFIRMATION. Best effort: a
 * failure is logged and returned, never thrown, so a connect still succeeds and
 * the 30-minute poll keeps working. `call(method, path, body)` is an eBay REST
 * call with the user's token (injected for tests).
 */
async function ensureEbayOrderSubscription(db, uid, { call, webhookUrl, verificationToken }) {
  const ref = db.doc(`users/${uid}/integrations/ebay`);
  const integration = (await ref.get()).data();
  if (!integration?.isConnected) return { status: "not-connected" };
  if (!hasNotificationScope(integration)) return { status: "needs-reconnect" };
  if (integration.orderNotificationSubscriptionId) return { status: "exists", subscriptionId: integration.orderNotificationSubscriptionId };

  try {
    const destinationId = await ensureDestination(db, { call, webhookUrl, verificationToken });
    let subscriptionId = null;
    try {
      const res = await call("POST", "/commerce/notification/v1/subscription", {
        topicId: ORDER_TOPIC,
        status: "ENABLED",
        destinationId,
        payload: { format: "JSON", schemaVersion: "1.0", deliveryProtocol: "HTTPS" },
      });
      subscriptionId = res?.subscriptionId ?? null;
    } catch (e) {
      if (e.status !== 409) throw e;
      // Already subscribed (e.g. the doc lost its id): find the existing one.
      const list = await call("GET", "/commerce/notification/v1/subscription?limit=100");
      subscriptionId = (list?.subscriptions ?? []).find((s) => s.topicId === ORDER_TOPIC)?.subscriptionId ?? null;
    }
    if (!subscriptionId) return { status: "failed", message: "eBay returned no subscription id" };
    await ref.set({ orderNotificationSubscriptionId: subscriptionId }, { merge: true });
    return { status: "created", subscriptionId };
  } catch (e) {
    console.error(`[ebayWebhook] subscribe uid=${uid}: ${e.message}`);
    return { status: "failed", message: e.message };
  }
}

/** The app's one destination (our endpoint), created on first use and remembered. */
async function ensureDestination(db, { call, webhookUrl, verificationToken }) {
  const cfgRef = db.doc("system/ebayNotifications");
  const cfg = (await cfgRef.get()).data();
  if (cfg?.destinationId && cfg.webhookUrl === webhookUrl) return cfg.destinationId;

  let destinationId = null;
  try {
    const res = await call("POST", "/commerce/notification/v1/destination", {
      name: "wonni",
      status: "ENABLED",
      deliveryConfig: { endpoint: webhookUrl, verificationToken },
    });
    destinationId = res?.destinationId ?? null;
  } catch (e) {
    if (e.status !== 409) throw e;
  }
  if (!destinationId) {
    const list = await call("GET", "/commerce/notification/v1/destination?limit=100");
    destinationId = (list?.destinations ?? []).find((d) => d.deliveryConfig?.endpoint === webhookUrl)?.destinationId ?? null;
  }
  if (!destinationId) throw new Error("Could not create or find the eBay notification destination");
  await cfgRef.set({ destinationId, webhookUrl, updatedAt: Date.now() }, { merge: true });
  return destinationId;
}

/** `call` for ensureEbayOrderSubscription, using this user's eBay token. */
function userEbayCall(uid) {
  return async (method, path, body) => {
    const token = await refreshEbayToken(uid);
    const hasBody = body !== undefined;
    const res = await fetch(`https://${ebayApiHost()}${path}`, {
      method,
      headers: ebayRestHeaders(`Bearer ${token}`, hasBody),
      ...(hasBody && { body: JSON.stringify(body) }),
    });
    if (res.status === 204) return null;
    // createDestination / createSubscription answer 201 with the id in Location.
    const location = res.headers.get("location") || "";
    const text = await res.text();
    if (!res.ok) {
      const err = new Error(`eBay notification API (${res.status}): ${text.slice(0, 300)}`);
      err.status = res.status;
      throw err;
    }
    const json = text ? JSON.parse(text) : {};
    const idFromLocation = location.split("/").pop() || null;
    if (path.endsWith("/destination") && !json.destinationId) json.destinationId = idFromLocation;
    if (path.endsWith("/subscription") && !json.subscriptionId) json.subscriptionId = idFromLocation;
    return json;
  };
}

// ── public key cache (app token) ───────────────────────────────────────────

const publicKeys = new Map();
async function fetchPublicKey(kid) {
  if (publicKeys.has(kid)) return publicKeys.get(kid);
  const { getEbayAppTokenCached } = require("./ebay_listing");
  const token = await getEbayAppTokenCached();
  const res = await fetch(`https://${ebayApiHost()}/commerce/notification/v1/public_key/${encodeURIComponent(kid)}`, {
    headers: ebayRestHeaders(`Bearer ${token}`, false),
  });
  if (!res.ok) throw new Error(`public_key ${res.status}`);
  const pk = await res.json();
  publicKeys.set(kid, pk);
  return pk;
}

// ── HTTP endpoint ──────────────────────────────────────────────────────────

exports.ebayWebhook = onRequest(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_VERIFICATION_TOKEN], timeoutSeconds: 120, memory: "512MiB" },
  async (req, res) => {
    if (req.method === "GET") {
      const code = req.query.challenge_code;
      if (!code) return res.status(400).send("Missing challenge_code");
      return res.status(200).json({
        challengeResponse: challengeResponse(String(code), EBAY_VERIFICATION_TOKEN.value(), EBAY_WEBHOOK_URL.value()),
      });
    }
    if (req.method !== "POST") {
      res.set("Allow", "GET, POST");
      return res.status(405).send("Method Not Allowed");
    }

    const ok = await verifySignature({
      header: req.get("x-ebay-signature"),
      rawBody: req.rawBody,
      body: req.body,
      getPublicKey: fetchPublicKey,
    });
    if (!ok) {
      console.warn("[ebayWebhook] rejected: bad or missing signature");
      return res.status(412).send("Signature check failed");
    }

    const db = admin.firestore();
    const { syncSalesForUser } = require("./sale_poller")._internal;
    const result = await handleNotification(db, req.body, {
      syncUser: (uid) => syncSalesForUser(db, uid, { only: "ebay", sinceFor: () => Date.now() - PUSH_LOOKBACK_MS }),
    });
    console.log(`[ebayWebhook] ${JSON.stringify(result)}`);
    return res.status(204).send();
  },
);

module.exports = {
  ebayWebhook: exports.ebayWebhook,
  EBAY_VERIFICATION_TOKEN,
  EBAY_WEBHOOK_URL,
  NOTIFICATION_SCOPE,
  ensureEbayOrderSubscription,
  userEbayCall,
  _internal: {
    challengeResponse,
    parseSignatureHeader,
    formatPublicKey,
    verifySignature,
    findEbayIntegrations,
    handleAccountDeletion,
    handleOrderConfirmation,
    handleNotification,
    hasNotificationScope,
    ensureEbayOrderSubscription,
    ensureDestination,
  },
};
