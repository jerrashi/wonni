/**
 * sale_sync.js
 *
 * decrementAndCascade — triggered when a sale is detected on any platform.
 * Updates quantity in Firestore, then propagates to eBay (Inventory API) and
 * Etsy (Listings API). Mercari has no API — sets flags that the iOS app surfaces
 * for manual headless-browser action.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const https = require("https");
const { refreshEtsyToken } = require("./etsy_auth");

if (admin.apps.length === 0) admin.initializeApp();

const ebayClientId = defineSecret("EBAY_CLIENT_ID");
const ebayCertId = defineSecret("EBAY_CERT_ID");
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

async function getEbayToken(uid, clientId, certId, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("ebay");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected || !doc.data().refreshToken) return null;
  const d = doc.data();
  if ((d.tokenExpiresAt?.toDate().getTime() ?? 0) > Date.now() + 300000) {
    return { accessToken: d.accessToken, isSandbox: d.isSandbox || false };
  }
  const creds = Buffer.from(`${clientId}:${certId}`).toString("base64");
  const scope = encodeURIComponent(
    "https://api.ebay.com/oauth/api_scope https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.fulfillment https://api.ebay.com/oauth/api_scope/sell.finances"
  );
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(d.refreshToken)}&scope=${scope}`;
  const res = await makeRequest({
    hostname: "api.ebay.com",
    path: "/identity/v1/oauth2/token",
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Authorization": `Basic ${creds}`,
    },
  }, body);
  if (res.statusCode !== 200) {
    console.error(`[sale_sync] eBay token refresh failed: ${res.statusCode} ${res.body}`);
    return null;
  }
  const t = JSON.parse(res.body);
  await ref.set({
    accessToken: t.access_token,
    tokenExpiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + t.expires_in * 1000),
  }, { merge: true });
  return { accessToken: t.access_token, isSandbox: d.isSandbox || false };
}

async function getEtsyToken(uid, clientId, db) {
  const ref = db.collection("users").doc(uid).collection("integrations").doc("etsy");
  const doc = await ref.get();
  if (!doc.exists || !doc.data().isConnected) return null;
  const d = doc.data();
  if (Date.now() <= (d.tokenExpiresAt?.toMillis() ?? 0) - 5 * 60 * 1000) {
    return { accessToken: d.accessToken, shopId: d.shopId };
  }
  try {
    const refreshed = await refreshEtsyToken(clientId, null, d.refreshToken);
    await ref.update({
      accessToken: refreshed.access_token,
      refreshToken: refreshed.refresh_token ?? d.refreshToken,
      tokenExpiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + refreshed.expires_in * 1000),
    });
    return { accessToken: refreshed.access_token, shopId: d.shopId };
  } catch (e) {
    console.error(`[sale_sync] Etsy token refresh failed: ${e.message}`);
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// eBay quantity update
// ─────────────────────────────────────────────────────────────

async function updateEbayQty(listingId, newQty, uid, clientId, certId, db) {
  const token = await getEbayToken(uid, clientId, certId, db);
  if (!token) { console.log(`[sale_sync] No eBay token for uid=${uid}, skipping`); return; }
  const { accessToken, isSandbox } = token;
  const host = isSandbox ? "api.sandbox.ebay.com" : "api.ebay.com";
  const sku = `wonni_${listingId}`;
  const authHeader = { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" };

  if (newQty <= 0) {
    // Withdraw active offers so the listing goes inactive
    const offersRes = await makeRequest({
      hostname: host, path: `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}`,
      method: "GET", headers: authHeader,
    });
    if (offersRes.statusCode === 200) {
      const data = JSON.parse(offersRes.body);
      for (const offer of (data.offers || [])) {
        if (offer.status === "PUBLISHED") {
          const wr = await makeRequest({
            hostname: host, path: `/sell/inventory/v1/offer/${offer.offerId}/withdraw`,
            method: "POST", headers: authHeader,
          }, {});
          console.log(`[sale_sync] eBay offer ${offer.offerId} withdrawn (qty=0): ${wr.statusCode}`);
        }
      }
    }
  } else {
    // Fetch current inventory item, update quantity, re-PUT
    const itemRes = await makeRequest({
      hostname: host, path: `/sell/inventory/v1/inventory_item/${sku}`,
      method: "GET", headers: authHeader,
    });
    if (itemRes.statusCode === 200) {
      const item = JSON.parse(itemRes.body);
      if (!item.availability) item.availability = {};
      item.availability.shipToLocationAvailability = { quantity: newQty };
      const putRes = await makeRequest({
        hostname: host, path: `/sell/inventory/v1/inventory_item/${sku}`,
        method: "PUT", headers: { ...authHeader, "Content-Language": "en-US" },
      }, item);
      console.log(`[sale_sync] eBay inventory item qty=${newQty}: ${putRes.statusCode}`);
    } else {
      console.warn(`[sale_sync] eBay inventory item GET failed: ${itemRes.statusCode}`);
    }

    // Update offer's availableQuantity too
    const offersRes = await makeRequest({
      hostname: host, path: `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}`,
      method: "GET", headers: authHeader,
    });
    if (offersRes.statusCode === 200) {
      const data = JSON.parse(offersRes.body);
      const offer = (data.offers || []).find(o => o.status === "PUBLISHED") || data.offers?.[0];
      if (offer?.offerId) {
        // Build a minimal update body preserving existing policies
        const updateBody = {
          sku,
          marketplaceId: offer.marketplaceId || "EBAY_US",
          format: "FIXED_PRICE",
          availableQuantity: newQty,
          categoryId: offer.categoryId,
          listingDescription: offer.listingDescription,
          listingPolicies: offer.listingPolicies,
          merchantLocationKey: offer.merchantLocationKey,
          pricingSummary: offer.pricingSummary,
        };
        const or = await makeRequest({
          hostname: host, path: `/sell/inventory/v1/offer/${offer.offerId}`,
          method: "PUT", headers: { ...authHeader, "Content-Language": "en-US" },
        }, updateBody);
        console.log(`[sale_sync] eBay offer ${offer.offerId} availableQty=${newQty}: ${or.statusCode}`);
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Etsy quantity update
// ─────────────────────────────────────────────────────────────

async function updateEtsyQty(listingId, newQty, etsyListingId, uid, clientId, db) {
  const token = await getEtsyToken(uid, clientId, db);
  if (!token) { console.log(`[sale_sync] No Etsy token for uid=${uid}, skipping`); return; }
  const { accessToken } = token;

  const payload = newQty <= 0
    ? JSON.stringify({ state: "inactive" })
    : JSON.stringify({ quantity: newQty });

  const res = await makeRequest({
    hostname: "openapi.etsy.com",
    path: `/v3/application/listings/${etsyListingId}`,
    method: "PATCH",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "x-api-key": clientId,
    },
  }, payload);

  console.log(`[sale_sync] Etsy listing ${etsyListingId} qty=${newQty}: ${res.statusCode}`);

  if (res.statusCode === 404) {
    await admin.firestore().collection("listings").doc(listingId).update({
      "crossPostStatus.etsy": "deleted",
    });
  }
}

// ─────────────────────────────────────────────────────────────
// Core decrement logic — exported for use from webhook handlers
// ─────────────────────────────────────────────────────────────

async function decrementAndCascadeInternal(listingId, soldOnPlatform, db, ebayId, certId, etsyId) {
  const listingRef = db.collection("listings").doc(listingId);
  const listingDoc = await listingRef.get();
  if (!listingDoc.exists) throw new Error(`Listing ${listingId} not found`);
  const listing = listingDoc.data();
  const uid = listing.userId;

  const currentQty = listing.quantity ?? 1;
  const newQty = Math.max(currentQty - 1, 0);
  const willSell = newQty <= 0;

  const update = {
    quantity: newQty,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (willSell) {
    update.status = "sold";
    update.soldAt = admin.firestore.FieldValue.serverTimestamp();
  }

  // Mercari flags — Mercari has no API; iOS handles via headless browser
  const mercariId = listing.crossPostListingIds?.mercari;
  if (mercariId) {
    if (soldOnPlatform === "mercari") {
      // Mercari sold and qty still > 0 → need to re-list on Mercari
      if (!willSell) update.pendingMercariRelist = true;
    } else if (willSell) {
      // Sold elsewhere, qty=0 → deactivate Mercari listing
      update.pendingMercariDeactivation = true;
    }
  }

  await listingRef.update(update);
  console.log(`[sale_sync] ${listingId}: qty ${currentQty}→${newQty}, soldOn=${soldOnPlatform}, willSell=${willSell}`);

  // eBay cascade (skip if the sale came from eBay — it already decremented itself)
  const ebayListingId = listing.crossPostListingIds?.ebay;
  if (ebayListingId && listing.crossPostStatus?.ebay === "posted" && soldOnPlatform !== "ebay") {
    try {
      await updateEbayQty(listingId, newQty, uid, ebayId, certId, db);
    } catch (e) {
      console.error(`[sale_sync] eBay cascade error for ${listingId}:`, e.message);
    }
  }

  // Etsy cascade (skip if the sale came from Etsy)
  const etsyListingId = listing.crossPostListingIds?.etsy;
  if (etsyListingId && listing.crossPostStatus?.etsy === "posted" && soldOnPlatform !== "etsy") {
    try {
      await updateEtsyQty(listingId, newQty, etsyListingId, uid, etsyId, db);
    } catch (e) {
      console.error(`[sale_sync] Etsy cascade error for ${listingId}:`, e.message);
    }
  }
}

exports.decrementAndCascadeInternal = decrementAndCascadeInternal;

// ─────────────────────────────────────────────────────────────
// Callable: iOS app calls this when it detects a Mercari sale
// ─────────────────────────────────────────────────────────────

exports.decrementAndCascade = onCall(
  { secrets: [ebayClientId, ebayCertId, etsyClientId] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
    const { listingId, platform } = request.data;
    if (!listingId) throw new HttpsError("invalid-argument", "listingId is required.");

    const db = admin.firestore();
    const doc = await db.collection("listings").doc(listingId).get();
    if (!doc.exists) throw new HttpsError("not-found", "Listing not found.");
    if (doc.data().userId !== request.auth.uid) throw new HttpsError("permission-denied", "Access denied.");

    try {
      await decrementAndCascadeInternal(
        listingId,
        platform || "unknown",
        db,
        ebayClientId.value(),
        ebayCertId.value(),
        etsyClientId.value()
      );
    } catch (e) {
      throw new HttpsError("internal", e.message);
    }
    return { success: true };
  }
);
