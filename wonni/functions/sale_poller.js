/**
 * sale_poller.js
 *
 * syncSales — on-demand callable (triggered by the iOS "Sync Sales" button).
 * Checks the authenticated user's connected eBay and Etsy accounts for new
 * orders/receipts, creates Sale documents, and calls decrementAndCascade.
 *
 * Matching logic:
 *   eBay  — SKU format is "wonni_{listingId}", set by ebayCreateListing
 *   Etsy  — query listings where crossPostListingIds.etsy == etsyListingId
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const { refreshEtsyToken } = require("./etsy_auth");
const { decrementAndCascadeInternal } = require("./sale_sync");

if (admin.apps.length === 0) admin.initializeApp();

const ebayClientId = defineSecret("EBAY_CLIENT_ID");
const ebayCertId   = defineSecret("EBAY_CERT_ID");
const etsyClientId = defineSecret("ETSY_CLIENT_ID");

// ─────────────────────────────────────────────────────────────
// HTTP helper
// ─────────────────────────────────────────────────────────────

function makeRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => resolve({ statusCode: res.statusCode, body: data }));
    });
    req.on("error", reject);
    if (body) req.write(typeof body === "string" ? body : JSON.stringify(body));
    req.end();
  });
}

// ─────────────────────────────────────────────────────────────
// Token helpers
// ─────────────────────────────────────────────────────────────

async function getEbayAccessToken(uid, clientId, certId, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("ebay");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected || !doc.data().refreshToken) return null;
  const d = doc.data();
  if ((d.tokenExpiresAt?.toDate().getTime() ?? 0) > Date.now() + 300000) {
    return { accessToken: d.accessToken, isSandbox: d.isSandbox || false };
  }
  const creds = Buffer.from(`${clientId}:${certId}`).toString("base64");
  const scope = encodeURIComponent(
    "https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory " +
    "https://api.ebay.com/oauth/api_scope/sell.fulfillment https://api.ebay.com/oauth/api_scope/sell.finances"
  );
  const reqBody = `grant_type=refresh_token&refresh_token=${encodeURIComponent(d.refreshToken)}&scope=${scope}`;
  const res = await makeRequest({
    hostname: d.isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com",
    path: "/identity/v1/oauth2/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Authorization": `Basic ${creds}`,
      "Content-Length": Buffer.byteLength(reqBody),
    },
  }, reqBody);
  if (res.statusCode !== 200) {
    console.error(`[syncSales] eBay token refresh failed uid=${uid}: ${res.statusCode}`);
    return null;
  }
  const token = JSON.parse(res.body);
  await ref.update({
    accessToken: token.access_token,
    tokenExpiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + token.expires_in * 1000),
  });
  return { accessToken: token.access_token, isSandbox: d.isSandbox || false };
}

async function getEtsyAccessToken(uid, clientId, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("etsy");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected || !doc.data().refreshToken) return null;
  const d = doc.data();
  if ((d.tokenExpiresAt?.toDate().getTime() ?? 0) > Date.now() + 300000) {
    return { accessToken: d.accessToken, shopId: d.shopId };
  }
  try {
    const tokenData = await refreshEtsyToken(clientId, null, d.refreshToken);
    await ref.update({
      accessToken: tokenData.access_token,
      refreshToken: tokenData.refresh_token ?? d.refreshToken,
      tokenExpiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + tokenData.expires_in * 1000),
    });
    return { accessToken: tokenData.access_token, shopId: d.shopId };
  } catch (e) {
    console.error(`[syncSales] Etsy token refresh failed uid=${uid}: ${e.message}`);
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// Deduplication
// ─────────────────────────────────────────────────────────────

async function saleExists(db, uid, platformOrderId) {
  const snap = await db.collection("sales")
    .where("userId", "==", uid)
    .where("platformOrderId", "==", platformOrderId)
    .limit(1)
    .get();
  return !snap.empty;
}

async function findExistingSaleDoc(db, uid, platformOrderId) {
  const snap = await db.collection("sales")
    .where("userId", "==", uid)
    .where("platformOrderId", "==", platformOrderId)
    .limit(1)
    .get();
  return snap.empty ? null : snap.docs[0];
}

// ─────────────────────────────────────────────────────────────
// Take-home helpers
// ─────────────────────────────────────────────────────────────

async function ebayFetchTakeHome(orderId, accessToken, isSandbox) {
  try {
    const res = await makeRequest({
      hostname: isSandbox ? "apiz.sandbox.ebay.com" : "apiz.ebay.com",
      path: `/sell/finances/v1/transaction?orderId=${encodeURIComponent(orderId)}&transactionType=SALE`,
      method: "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
        "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
      },
    });
    if (res.statusCode !== 200) return null;
    const txs = JSON.parse(res.body).transactions ?? [];
    const sale = txs.find(t => t.transactionType === "SALE") ?? txs[0];
    if (!sale) return null;
    const gross = parseFloat(sale.amount?.value ?? "0");
    const fees  = parseFloat(sale.totalFeeAmount?.value ?? "0");
    return gross > 0 ? Math.round((gross - fees) * 100) / 100 : null;
  } catch { return null; }
}

async function ebayFetchTracking(orderId, accessToken, isSandbox) {
  try {
    const res = await makeRequest({
      hostname: isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com",
      path: `/sell/fulfillment/v1/order/${encodeURIComponent(orderId)}/shipping_fulfillment`,
      method: "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
        "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
      },
    });
    console.log(`[ebayFetchTracking] order=${orderId} status=${res.statusCode} body=${res.body.slice(0, 200)}`);
    if (res.statusCode !== 200) return null;
    const fulfillments = JSON.parse(res.body).fulfillments ?? [];
    if (!fulfillments.length) return null;
    // Use the last fulfillment as primary — when a label is voided and reissued, eBay appends
    // the new one; taking the last gives us the most recently created active label.
    const primary = fulfillments[fulfillments.length - 1];
    return {
      trackingNumber: primary.shipmentTrackingNumber ?? null,
      carrier: primary.shippingCarrierCode ?? null,
      allFulfillments: fulfillments.map(f => ({
        fulfillmentId: f.fulfillmentId ?? null,
        trackingNumber: f.shipmentTrackingNumber ?? null,
        carrier: f.shippingCarrierCode ?? null,
        shippedDate: f.shippedDate ?? null,
      })),
    };
  } catch (e) {
    console.warn(`[ebayFetchTracking] order=${orderId} error: ${e.message}`);
    return null;
  }
}

async function etsyFetchTakeHome(receiptId, accessToken, shopId, clientId) {
  try {
    const res = await makeRequest({
      hostname: "openapi.etsy.com",
      path: `/v3/application/shops/${shopId}/payments?receipt_id=${receiptId}`,
      method: "GET",
      headers: {
        "x-api-key": clientId,
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    });
    if (res.statusCode !== 200) return null;
    let net = 0;
    for (const p of JSON.parse(res.body).results ?? []) {
      if (p.amount_net) net += p.amount_net.amount / (p.amount_net.divisor || 100);
    }
    return net > 0 ? Math.round(net * 100) / 100 : null;
  } catch { return null; }
}

// ─────────────────────────────────────────────────────────────
// eBay order sync — returns count of new sales recorded
// ─────────────────────────────────────────────────────────────

async function syncEbayOrders(uid, integrationRef, clientId, certId, db, force = false) {
  const tokenInfo = await getEbayAccessToken(uid, clientId, certId, db);
  if (!tokenInfo) return 0;
  const { accessToken, isSandbox } = tokenInfo;

  const integDoc = await integrationRef.get();
  // force=true: scan 30 days back (for manual rescan); default: since last successful sync or 48h
  const defaultLookback = force ? 30 * 24 * 60 * 60 * 1000 : 48 * 60 * 60 * 1000;
  const lastPollAt = force
    ? new Date(Date.now() - defaultLookback)
    : (integDoc.data().lastEbayPollAt?.toDate() ?? new Date(Date.now() - defaultLookback));
  const from = lastPollAt.toISOString();
  const to   = new Date().toISOString();

  const res = await makeRequest({
    hostname: isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com",
    path: `/sell/fulfillment/v1/order?filter=creationdate:[${from}..${to}]&limit=50`,
    method: "GET",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
    },
  });

  if (res.statusCode === 403) {
    console.error(`[syncSales] eBay 403 uid=${uid} body=${res.body.slice(0, 300)}`);
    throw new Error("ebay_scope_missing");
  }
  if (res.statusCode !== 200) {
    console.error(`[syncSales] eBay orders error uid=${uid}: ${res.statusCode} body=${res.body.slice(0, 300)}`);
    return 0;
  }

  const orders = JSON.parse(res.body).orders ?? [];
  console.log(`[syncSales] eBay uid=${uid}: ${orders.length} orders in window [${from} .. ${to}]`);
  for (const o of orders) {
    console.log(`[syncSales]   order ${o.orderId} paymentStatus=${o.orderPaymentStatus} skus=${(o.lineItems||[]).map(i=>i.sku).join(",")}`);
  }
  let newCount = 0;

  for (const order of orders) {
    if (order.orderPaymentStatus !== "PAID") {
      console.log(`[syncSales] skipping order ${order.orderId}: paymentStatus=${order.orderPaymentStatus}`);
      continue;
    }
    const orderId = order.orderId;
    const existingDoc = await findExistingSaleDoc(db, uid, orderId);

    if (existingDoc) {
      // Backfill tracking, all fulfillments, corrected address, and registered address
      const existing = existingDoc.data();
      const updates = {};

      const tracking = await ebayFetchTracking(orderId, accessToken, isSandbox);
      if (tracking) {
        if (tracking.trackingNumber && !existing.trackingNumber) {
          updates.trackingNumber = tracking.trackingNumber;
          updates.carrier = tracking.carrier ?? null;
          updates.status = "shipped";
          console.log(`[syncSales] backfilled tracking for order ${orderId}: ${tracking.trackingNumber}`);
        }
        if (tracking.allFulfillments?.length) {
          updates.shippingFulfillments = tracking.allFulfillments;
        }
      }

      const shipStep = (order.fulfillmentStartInstructions ?? [])
        .find(i => i.fulfillmentInstructionsType === "SHIP_TO" || i.shippingStep)
        ?.shippingStep?.shipTo;
      const addr = shipStep?.contactAddress ?? order.buyer?.buyerRegistrationAddress?.contactAddress ?? {};
      const buyerName = shipStep?.fullName ?? order.buyer?.buyerRegistrationAddress?.fullName ?? null;
      const correctLine1 = addr.addressLine1 ?? null;
      if (correctLine1 && existing.buyerAddress?.line1 !== correctLine1) {
        updates.buyerAddress = {
          name: buyerName,
          line1: addr.addressLine1 ?? null,
          line2: addr.addressLine2 ?? null,
          city: addr.city ?? null,
          state: addr.stateOrProvince ?? null,
          zip: addr.postalCode ?? null,
          country: addr.countryCode ?? "US",
        };
      }
      if (!existing.buyerRegisteredAddress) {
        const regAddr = order.buyer?.buyerRegistrationAddress?.contactAddress ?? {};
        updates.buyerRegisteredAddress = {
          name: order.buyer?.buyerRegistrationAddress?.fullName ?? null,
          line1: regAddr.addressLine1 ?? null,
          line2: regAddr.addressLine2 ?? null,
          city: regAddr.city ?? null,
          state: regAddr.stateOrProvince ?? null,
          zip: regAddr.postalCode ?? null,
          country: regAddr.countryCode ?? null,
        };
      }

      if (Object.keys(updates).length > 0) {
        updates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
        await existingDoc.ref.update(updates);
      }
      continue;
    }

    for (const item of (order.lineItems ?? [])) {
      const sku = item.sku ?? "";
      if (!sku.startsWith("wonni_")) {
        console.log(`[syncSales] skipping line item: sku="${sku}" title="${item.title}" — no wonni_ prefix`);
        continue;
      }
      const listingId = sku.replace(/^wonni_/, "");

      const [listingSnap, takeHome, tracking] = await Promise.all([
        db.collection("listings").doc(listingId).get(),
        ebayFetchTakeHome(orderId, accessToken, isSandbox),
        ebayFetchTracking(orderId, accessToken, isSandbox),
      ]);
      const listing = listingSnap.exists ? listingSnap.data() : null;
      const priceSoldFor = parseFloat(order.pricingSummary?.total?.value ?? "0");

      // fulfillmentStartInstructions contains the actual ship-to address (what goes on the label).
      // buyer.buyerRegistrationAddress is the billing/account address and can differ at checkout.
      const shipStep = (order.fulfillmentStartInstructions ?? [])
        .find(i => i.fulfillmentInstructionsType === "SHIP_TO" || i.shippingStep)
        ?.shippingStep?.shipTo;
      const addr = shipStep?.contactAddress ?? order.buyer?.buyerRegistrationAddress?.contactAddress ?? {};
      const buyerName = shipStep?.fullName ?? order.buyer?.buyerRegistrationAddress?.fullName ?? null;
      const regAddr = order.buyer?.buyerRegistrationAddress?.contactAddress ?? {};

      await db.collection("sales").add({
        userId: uid,
        listingId,
        listingTitle: listing?.customTitle ?? item.title ?? null,
        coverPhotoPath: listing?.coverPhotoPath ?? null,
        platform: "ebay",
        platformOrderId: orderId,
        priceSoldFor,
        takeHome: takeHome ?? null,
        buyerAddress: {
          name: buyerName,
          line1: addr.addressLine1 ?? null,
          line2: addr.addressLine2 ?? null,
          city: addr.city ?? null,
          state: addr.stateOrProvince ?? null,
          zip: addr.postalCode ?? null,
          country: addr.countryCode ?? "US",
        },
        buyerRegisteredAddress: {
          name: order.buyer?.buyerRegistrationAddress?.fullName ?? null,
          line1: regAddr.addressLine1 ?? null,
          line2: regAddr.addressLine2 ?? null,
          city: regAddr.city ?? null,
          state: regAddr.stateOrProvince ?? null,
          zip: regAddr.postalCode ?? null,
          country: regAddr.countryCode ?? null,
        },
        trackingNumber: tracking?.trackingNumber ?? null,
        carrier: tracking?.carrier ?? null,
        shippingFulfillments: tracking?.allFulfillments ?? null,
        status: tracking?.trackingNumber ? "shipped" : "pending",
        soldAt: admin.firestore.Timestamp.fromDate(new Date(order.creationDate)),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      newCount++;
      try {
        await decrementAndCascadeInternal(listingId, "ebay", db, clientId, certId, etsyClientId.value());
      } catch (e) {
        console.error(`[syncSales] cascade failed listingId=${listingId}: ${e.message}`);
      }
    }
  }

  await integrationRef.update({ lastEbayPollAt: admin.firestore.Timestamp.now() });
  console.log(`[syncSales] eBay uid=${uid}: ${newCount} new sales from ${orders.length} orders`);
  return newCount;
}

// ─────────────────────────────────────────────────────────────
// Etsy receipt sync — returns count of new sales recorded
// ─────────────────────────────────────────────────────────────

async function syncEtsyReceipts(uid, integrationRef, clientId, db, force = false) {
  const tokenInfo = await getEtsyAccessToken(uid, clientId, db);
  if (!tokenInfo || !tokenInfo.shopId) return 0;
  const { accessToken, shopId } = tokenInfo;

  const integDoc = await integrationRef.get();
  const defaultLookback = force ? 30 * 24 * 60 * 60 * 1000 : 48 * 60 * 60 * 1000;
  const lastPollAt = force
    ? new Date(Date.now() - defaultLookback)
    : (integDoc.data().lastEtsyPollAt?.toDate() ?? new Date(Date.now() - defaultLookback));
  const minCreated = Math.floor(lastPollAt.getTime() / 1000);

  const res = await makeRequest({
    hostname: "openapi.etsy.com",
    path: `/v3/application/shops/${shopId}/receipts?was_paid=true&min_created=${minCreated}&limit=100`,
    method: "GET",
    headers: {
      "x-api-key": clientId,
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
  });

  if (res.statusCode !== 200) {
    console.error(`[syncSales] Etsy receipts error uid=${uid}: ${res.statusCode}`);
    return 0;
  }

  const receipts = JSON.parse(res.body).results ?? [];
  let newCount = 0;

  for (const receipt of receipts) {
    const receiptId = String(receipt.receipt_id);
    if (await saleExists(db, uid, receiptId)) continue;

    const firstTx = receipt.transactions?.[0];
    const etsyListingId = firstTx ? String(firstTx.listing_id) : null;
    let listingId = null, listing = null;
    if (etsyListingId) {
      const snap = await db.collection("listings")
        .where("userId", "==", uid)
        .where("crossPostListingIds.etsy", "==", etsyListingId)
        .limit(1).get();
      if (!snap.empty) { listingId = snap.docs[0].id; listing = snap.docs[0].data(); }
    }

    const priceSoldFor = (receipt.total_price?.amount ?? 0) / (receipt.total_price?.divisor ?? 100);
    const takeHome = await etsyFetchTakeHome(receipt.receipt_id, accessToken, shopId, clientId);

    await db.collection("sales").add({
      userId: uid,
      listingId,
      listingTitle: listing?.customTitle ?? firstTx?.title ?? null,
      coverPhotoPath: listing?.coverPhotoPath ?? null,
      platform: "etsy",
      platformOrderId: receiptId,
      priceSoldFor: Math.round(priceSoldFor * 100) / 100,
      takeHome: takeHome ?? null,
      buyerAddress: {
        name: receipt.name ?? null,
        line1: receipt.first_line ?? null,
        line2: receipt.second_line ?? null,
        city: receipt.city ?? null,
        state: receipt.state ?? null,
        zip: receipt.zip ?? null,
        country: receipt.country_iso ?? "US",
      },
      trackingNumber: null,
      carrier: null,
      status: "pending",
      soldAt: admin.firestore.Timestamp.fromMillis((receipt.creation_tsz ?? Date.now() / 1000) * 1000),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    newCount++;
    if (listingId) {
      try {
        await decrementAndCascadeInternal(listingId, "etsy", db, ebayClientId.value(), ebayCertId.value(), clientId);
      } catch (e) {
        console.error(`[syncSales] cascade failed listingId=${listingId}: ${e.message}`);
      }
    }
  }

  await integrationRef.update({ lastEtsyPollAt: admin.firestore.Timestamp.now() });
  console.log(`[syncSales] Etsy uid=${uid}: ${newCount} new sales from ${receipts.length} receipts`);
  return newCount;
}

// ─────────────────────────────────────────────────────────────
// Callable entry point
// ─────────────────────────────────────────────────────────────

const SYNC_COOLDOWN_MS = 5 * 60 * 1000; // 5 minutes

exports.syncSales = onCall(
  { secrets: [ebayClientId, ebayCertId, etsyClientId], timeoutSeconds: 120 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const uid = request.auth.uid;
    const db = admin.firestore();
    const force = request.data?.force === true;

    // Rate limit: reject if synced within the last 5 minutes (skip for force rescan)
    if (!force) {
      const userRef = db.collection("users").doc(uid);
      const userDoc = await userRef.get();
      const lastSync = userDoc.data()?.lastSalesSyncAt?.toDate();
      if (lastSync && Date.now() - lastSync.getTime() < SYNC_COOLDOWN_MS) {
        const nextAllowed = new Date(lastSync.getTime() + SYNC_COOLDOWN_MS);
        return { rateLimited: true, nextAllowedAt: nextAllowed.toISOString(), newSales: 0 };
      }
    }
    await db.collection("users").doc(uid).set(
      { lastSalesSyncAt: admin.firestore.FieldValue.serverTimestamp() },
      { merge: true }
    );

    const ebayRef = db.collection("users").doc(uid).collection("integrations").doc("ebay");
    const etsyRef = db.collection("users").doc(uid).collection("integrations").doc("etsy");
    const [ebayDoc, etsyDoc] = await Promise.all([ebayRef.get(), etsyRef.get()]);

    let ebayNew = 0, etsyNew = 0, ebayError = null;

    if (ebayDoc.exists && ebayDoc.data().isConnected) {
      try {
        ebayNew = await syncEbayOrders(uid, ebayRef, ebayClientId.value(), ebayCertId.value(), db, force);
      } catch (e) {
        if (e.message === "ebay_scope_missing") {
          ebayError = "reconnect_required";
        } else {
          console.error(`[syncSales] eBay sync error uid=${uid}: ${e.message}`);
        }
      }
    }
    if (etsyDoc.exists && etsyDoc.data().isConnected) {
      etsyNew = await syncEtsyReceipts(uid, etsyRef, etsyClientId.value(), db, force).catch((e) => {
        console.error(`[syncSales] Etsy sync error uid=${uid}: ${e.message}`);
        return 0;
      });
    }

    const total = ebayNew + etsyNew;
    console.log(`[syncSales] uid=${uid} complete: ${ebayNew} eBay + ${etsyNew} Etsy = ${total} new`);
    return { newSales: total, ebay: ebayNew, etsy: etsyNew, ebayError };
  }
);
