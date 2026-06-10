/**
 * ebay_webhook.js
 *
 * HTTP endpoint for eBay Commerce Notifications:
 *   GET  — challenge verification (required for endpoint registration with eBay)
 *   POST — incoming event notifications (account deletion, order completed)
 *
 * Also exports setupEbayNotifications (callable) for one-time webhook registration.
 *
 * Setup:
 *   1. Add EBAY_VERIFICATION_TOKEN to Firebase Secret Manager:
 *        firebase functions:secrets:set EBAY_VERIFICATION_TOKEN
 *      Use any random string (e.g. `openssl rand -hex 32`). Never change it after registering.
 *   2. Deploy: firebase deploy --only functions:ebayWebhook,functions:setupEbayNotifications,firestore:indexes
 *   3. Grant yourself the admin custom claim once (run in Node.js with service account creds):
 *        admin.auth().setCustomUserClaims("<your-uid>", { admin: true })
 *   4. Sign in as that admin user and call setupEbayNotifications:
 *        { webhookUrl: "https://us-central1-<project>.cloudfunctions.net/ebayWebhook" }
 *      This creates a destination + MARKETPLACE_ORDER_COMPLETED subscription on eBay.
 *   5. eBay validates the endpoint by sending a GET challenge. No action needed — the
 *      challenge handler below responds automatically.
 */

const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const crypto = require("crypto");
const { processSingleEbayOrder, getEbayAccessToken, makeRequest } = require("./sale_poller");

if (admin.apps.length === 0) admin.initializeApp();

const ebayClientId          = defineSecret("EBAY_CLIENT_ID");
const ebayCertId            = defineSecret("EBAY_CERT_ID");
const etsyClientId          = defineSecret("ETSY_CLIENT_ID");
const ebayVerificationToken = defineSecret("EBAY_VERIFICATION_TOKEN");

// ─────────────────────────────────────────────────────────────
// Webhook endpoint
// ─────────────────────────────────────────────────────────────

exports.ebayWebhook = onRequest(
  { secrets: [ebayClientId, ebayCertId, etsyClientId, ebayVerificationToken], cors: false },
  async (req, res) => {
    // ── GET: challenge verification ────────────────────────────────────────
    // eBay sends this when registering a new endpoint. Respond with the
    // SHA-256 hash of challengeCode + verificationToken + endpointUrl.
    if (req.method === "GET") {
      const challengeCode = req.query.challenge_code;
      if (!challengeCode) return res.status(400).send("Missing challenge_code");

      // Firebase's cloudfunctions.net proxy rewrites the Host header, so we cannot
      // derive the URL from request headers. Use the stable Cloud Run URL directly —
      // this must exactly match the URL registered with eBay's Notifications API.
      const endpointUrl = "https://ebaywebhook-dynv7fggca-uc.a.run.app";
      const hash = crypto.createHash("sha256")
        .update(challengeCode)
        .update(ebayVerificationToken.value())
        .update(endpointUrl)
        .digest("hex");

      console.log(`[ebayWebhook] Challenge verified for: ${endpointUrl}`);
      return res.status(200).json({ challengeResponse: hash });
    }

    if (req.method !== "POST") {
      res.setHeader("Allow", "GET, POST");
      return res.status(405).send("Method Not Allowed");
    }

    // ── POST: notification ────────────────────────────────────────────────
    const notification = req.body;
    const topic    = notification?.metadata?.topic;
    const data     = notification?.notification?.data;
    const metadata = notification?.metadata;
    console.log(`[ebayWebhook] topic=${topic} orderId=${data?.orderId ?? "—"}`);

    try {
      if (topic === "MARKETPLACE_ACCOUNT_DELETION" || topic === "MARKETPLACE_ACCOUNT_CANCELLATION") {
        await handleAccountDeletion(data);
      } else if (topic === "ORDER_CONFIRMATION") {
        await handleOrderConfirmation(data, metadata);
      } else if (topic === "MARKETPLACE_ORDER_COMPLETED" || topic === "MARKETPLACE_ORDER_PAID") {
        // Legacy topic — kept for any in-flight events during migration
        await handleOrderCompleted(data);
      } else {
        console.log(`[ebayWebhook] Unhandled topic: ${topic}`);
      }
    } catch (e) {
      // Always return 200 — a non-200 response causes eBay to retry, which is only
      // appropriate for transient infrastructure failures, not application errors.
      console.error(`[ebayWebhook] Error processing ${topic}: ${e.message}`, e.stack);
    }

    return res.status(200).send("OK");
  }
);

// ─────────────────────────────────────────────────────────────
// Notification handlers
// ─────────────────────────────────────────────────────────────

async function handleAccountDeletion(data) {
  const ebayUserId = data?.userId ?? data?.username;
  if (!ebayUserId) return;

  const db = admin.firestore();
  const snap = await db.collectionGroup("integrations")
    .where("platform", "==", "ebay")
    .where("connectedUsername", "==", ebayUserId)
    .get();

  if (snap.empty) {
    console.log(`[ebayWebhook] No Wonni user found for deleted eBay account: ${ebayUserId}`);
    return;
  }

  const batch = db.batch();
  for (const doc of snap.docs) {
    console.log(`[ebayWebhook] Unlinking eBay for Wonni uid: ${doc.ref.parent.parent.id}`);
    batch.delete(doc.ref);
  }
  await batch.commit();
}

async function handleOrderConfirmation(data, metadata) {
  const orderId = data?.orderId;
  if (!orderId) {
    console.error("[ebayWebhook] ORDER_CONFIRMATION missing orderId. Raw data:", JSON.stringify(data));
    return;
  }

  const db = admin.firestore();
  let uid = null;

  // Primary lookup: subscriptionId stored in the user's integration doc when they connected.
  // eBay includes the subscriptionId in notification metadata for USER-scoped topics.
  const subscriptionId = metadata?.subscriptionId;
  if (subscriptionId) {
    const snap = await db.collectionGroup("integrations")
      .where("orderNotificationSubscriptionId", "==", subscriptionId)
      .limit(1).get();
    if (!snap.empty) uid = snap.docs[0].ref.parent.parent.id;
  }

  // Fallback: match by seller username/userId from notification payload.
  // Handles orders for users who connected before subscription IDs were stored.
  if (!uid) {
    const sellerUsername =
      data?.seller?.username ?? data?.sellerId ?? data?.userId ?? data?.username;
    if (sellerUsername) {
      const snap = await db.collectionGroup("integrations")
        .where("platform", "==", "ebay")
        .where("connectedUsername", "==", sellerUsername)
        .where("isConnected", "==", true)
        .limit(1).get();
      if (!snap.empty) uid = snap.docs[0].ref.parent.parent.id;
    }
  }

  if (!uid) {
    console.log(`[ebayWebhook] ORDER_CONFIRMATION: no user found for orderId=${orderId}. metadata:`, JSON.stringify(metadata));
    return;
  }

  const tokenInfo = await getEbayAccessToken(uid, ebayClientId.value(), ebayCertId.value(), db);
  if (!tokenInfo) {
    console.error(`[ebayWebhook] ORDER_CONFIRMATION: no token for uid=${uid}`);
    return;
  }
  const { accessToken, isSandbox } = tokenInfo;

  const orderRes = await makeRequest({
    hostname: isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com",
    path: `/sell/fulfillment/v1/order/${encodeURIComponent(orderId)}`,
    method: "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
    },
  });

  if (orderRes.statusCode !== 200) {
    console.error(`[ebayWebhook] ORDER_CONFIRMATION: fetch order ${orderId} failed ${orderRes.statusCode}: ${orderRes.body.slice(0, 200)}`);
    return;
  }

  const order = JSON.parse(orderRes.body);
  await processSingleEbayOrder(
    order, uid, accessToken, isSandbox, db,
    ebayClientId.value(), ebayCertId.value(), etsyClientId.value()
  );
  console.log(`[ebayWebhook] ORDER_CONFIRMATION: order ${orderId} processed for uid=${uid}`);
}

async function handleOrderCompleted(data) {
  const orderId = data?.orderId;
  // eBay may use username, sellerId, or userId depending on the notification schema version
  const sellerUsername = data?.username ?? data?.sellerId ?? data?.userId;

  if (!orderId || !sellerUsername) {
    console.error("[ebayWebhook] Missing orderId or seller in order notification:", JSON.stringify(data));
    return;
  }

  const db = admin.firestore();

  // Find the Wonni user who owns this eBay seller account
  const snap = await db.collectionGroup("integrations")
    .where("platform", "==", "ebay")
    .where("connectedUsername", "==", sellerUsername)
    .where("isConnected", "==", true)
    .limit(1)
    .get();

  if (snap.empty) {
    console.log(`[ebayWebhook] No connected Wonni user for eBay seller: ${sellerUsername}`);
    return;
  }

  const uid = snap.docs[0].ref.parent.parent.id;

  const tokenInfo = await getEbayAccessToken(uid, ebayClientId.value(), ebayCertId.value(), db);
  if (!tokenInfo) {
    console.error(`[ebayWebhook] Could not get eBay access token for uid=${uid}`);
    return;
  }
  const { accessToken, isSandbox } = tokenInfo;

  // Fetch full order details from eBay Fulfillment API
  const orderRes = await makeRequest({
    hostname: isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com",
    path: `/sell/fulfillment/v1/order/${encodeURIComponent(orderId)}`,
    method: "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
    },
  });

  if (orderRes.statusCode !== 200) {
    console.error(`[ebayWebhook] Failed to fetch order ${orderId}: ${orderRes.statusCode} ${orderRes.body.slice(0, 200)}`);
    return;
  }

  const order = JSON.parse(orderRes.body);
  await processSingleEbayOrder(
    order, uid, accessToken, isSandbox, db,
    ebayClientId.value(), ebayCertId.value(), etsyClientId.value()
  );
  console.log(`[ebayWebhook] Order ${orderId} processed for uid=${uid}`);
}

// ─────────────────────────────────────────────────────────────
// One-time setup: register destination + subscription with eBay
// ─────────────────────────────────────────────────────────────

exports.setupEbayNotifications = onCall(
  { secrets: [ebayClientId, ebayCertId, ebayVerificationToken] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    // Admin custom claim required — only the app owner should be able to register
    // or re-point the eBay webhook endpoint.
    // Grant it once: admin.auth().setCustomUserClaims(uid, { admin: true })
    if (request.auth.token?.admin !== true) {
      throw new HttpsError("permission-denied", "Admin only.");
    }

    const { webhookUrl } = request.data;
    if (!webhookUrl) throw new HttpsError("invalid-argument", "webhookUrl is required.");

    // Application-level (client credentials) token for the Notifications API
    const creds = Buffer.from(`${ebayClientId.value()}:${ebayCertId.value()}`).toString("base64");
    const tokenBody = `grant_type=client_credentials&scope=${encodeURIComponent("https://api.ebay.com/oauth/api_scope")}`;
    const tokenRes = await makeRequest({
      hostname: "api.ebay.com",
      path: "/identity/v1/oauth2/token",
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": `Basic ${creds}`,
        "Content-Length": Buffer.byteLength(tokenBody),
      },
    }, tokenBody);

    if (tokenRes.statusCode !== 200) {
      throw new HttpsError("internal", `eBay app token failed (${tokenRes.statusCode}): ${tokenRes.body}`);
    }
    const appToken = JSON.parse(tokenRes.body).access_token;

    // Create notification destination
    const destBody = JSON.stringify({
      deliveryConfig: {
        url: webhookUrl,
        verificationToken: ebayVerificationToken.value(),
      },
      schemaVersion: "1.0",
      status: "ENABLED",
    });
    const destRes = await makeRequest({
      hostname: "api.ebay.com",
      path: "/commerce/notification/v1/destination",
      method: "POST",
      headers: {
        "Authorization": `Bearer ${appToken}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(destBody),
      },
    }, destBody);

    console.log(`[setupEbayNotifications] destination: ${destRes.statusCode} ${destRes.body}`);
    const destData = JSON.parse(destRes.body);
    const destinationId = destData.destinationId;
    if (!destinationId) {
      throw new HttpsError("internal", `eBay destination creation failed: ${destRes.body}`);
    }

    // Subscribe to MARKETPLACE_ORDER_COMPLETED
    const subBody = JSON.stringify({
      destinationId,
      status: "ENABLED",
      topicId: "MARKETPLACE_ORDER_COMPLETED",
      payload: { format: "JSON", schemaVersion: "1.0", deliveryProtocol: "HTTPS" },
    });
    const subRes = await makeRequest({
      hostname: "api.ebay.com",
      path: "/commerce/notification/v1/subscription",
      method: "POST",
      headers: {
        "Authorization": `Bearer ${appToken}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(subBody),
      },
    }, subBody);

    console.log(`[setupEbayNotifications] subscription: ${subRes.statusCode} ${subRes.body}`);
    const subData = JSON.parse(subRes.body);

    return {
      destinationId,
      subscriptionId: subData.subscriptionId ?? null,
      status: subData.status ?? "unknown",
    };
  }
);
