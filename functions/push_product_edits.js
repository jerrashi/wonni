/**
 * push_product_edits.js — `pushProductEdits {productId}`.
 *
 * After products/{id} changes (web or iOS bulk edit, 2026-11-24 user request:
 * "etsy and tiktok listings should be updated; same on ios"), push the product's
 * current fields to every platform where it is live. Same shape as
 * cascade_delete.js: one server-side decision of "where is it live", each
 * platform's own update handler run in-process with the caller's uid.
 *
 *   - eBay / Etsy / TikTok updates run in parallel; one failing never stops the rest.
 *   - Mercari has no edit automation: reported in `manualUpdate`.
 *   - The doc is never written here; each platform handler records its own sync.
 */

"use strict";

const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { validated } = require("./contracts");
const { livePlatforms } = require("./cascade_delete")._internal;

async function pushProductEditsCore({ db, uid, productId, updaters }) {
  const snap = await db.collection("products").doc(productId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

  const { api, manual } = livePlatforms(product);
  const results = await Promise.allSettled(api.map((p) => updaters[p](productId)));
  const updated = [];
  const failed = [];
  results.forEach((r, i) => {
    if (r.status === "fulfilled") updated.push(api[i]);
    else {
      const error = r.reason?.message ?? String(r.reason);
      console.error(`[pushProductEdits] ${api[i]} failed for ${productId}: ${error}`);
      failed.push({ platform: api[i], error });
    }
  });
  return { updated, failed, manualUpdate: manual };
}

// Required lazily: these modules register their own onCall functions at load.
function realUpdaters(uid) {
  const run = (fn) => (productId) => fn.run({ auth: { uid }, data: { productId } });
  return {
    ebay: run(require("./ebay_listing").ebayUpdateListing),
    etsy: run(require("./etsy_listing").etsyUpdateListing),
    tiktok: run(require("./tiktok_listing").tiktokUpdateListing),
  };
}

const { EBAY_CLIENT_ID, EBAY_CLIENT_SECRET } = require("./ebay_auth");
const { TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");

exports.pushProductEdits = onCall(
  // The platform handlers run in THIS process, so bind the secrets they read
  // (Etsy reads Secret Manager directly and needs none).
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, TT_APP_KEY, TT_APP_SECRET], timeoutSeconds: 300, memory: "256MiB" },
  validated("pushProductEdits", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return pushProductEditsCore({ db: admin.firestore(), uid, productId: data.productId, updaters: realUpdaters(uid) });
  }),
);

exports._internal = { pushProductEditsCore };
