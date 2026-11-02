/**
 * cascade_delete.js — `deleteProductEverywhere`.
 *
 * Wonni is the master listing (CLAUDE.md, "eBay listing lifecycle"): deleting
 * the product means "stop selling this item everywhere". Leaving a platform
 * live would get Wonni silently re-created the next time any platform is
 * posted (postToWonni is always the first cross-post).
 *
 * Until now web orchestrated this client-side (web/src/lib/deleteProduct.js),
 * which (a) died with the browser tab, (b) could not be reused by iOS, and
 * (c) decided "is it live?" from `product.tiktokStatus`, a field the live flow
 * never writes — so TikTok listings were silently left behind. This puts the
 * decision and the orchestration in one server-side place.
 *
 * Rules:
 *   - eBay / Etsy / TikTok deletes run in parallel (allSettled).
 *   - ANY failure keeps the products/{id} doc, so a retry finds the same
 *     pointers; the response names what failed and what was removed.
 *   - Mercari has no delete automation: reported in `manualRemoval`, never
 *     blocks the delete (the client confirms that with the user first).
 *   - Each platform's own delete function does the platform-specific work
 *     (offer withdraw, Etsy deactivate/delete, TikTok product delete). They are
 *     invoked in-process via `.run()` with the caller's uid, so ownership is
 *     checked twice (here and there).
 */

"use strict";

const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { validated } = require("./contracts");

const LIVE_STATES = new Set(["active", "posted"]);
const hasVariantMercari = (product) =>
  (product.variants ?? []).some((v) => v?.crossPostListingIds?.mercari || v?.mercariListingId);

/**
 * Which platforms still have a live listing for this product.
 *   api    — platforms Wonni can delete itself, in a fixed order
 *   manual — platforms the user has to remove by hand
 * A listing id with no status still counts as live (the id is cleared on delete).
 */
function livePlatforms(product) {
  const st = product?.crossPostStatus ?? {};
  const ids = product?.crossPostListingIds ?? {};
  const api = [];
  if (LIVE_STATES.has(st.ebay) || ids.ebay || product?.ebayStatus === "active") api.push("ebay");
  if (LIVE_STATES.has(st.etsy) || ids.etsy || product?.etsyStatus === "active") api.push("etsy");
  if (LIVE_STATES.has(st.tiktok) || product?.tiktokStatus === "active") api.push("tiktok");
  const manual = [];
  if (LIVE_STATES.has(st.mercari) || ids.mercari || product?.mercariListingId || hasVariantMercari(product ?? {})) manual.push("mercari");
  return { api, manual };
}

async function deleteProductEverywhereCore({ db, uid, productId, deleters }) {
  const ref = db.collection("products").doc(productId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

  const { api, manual } = livePlatforms(product);
  const results = await Promise.allSettled(api.map((p) => deleters[p](productId)));

  const removedFrom = [];
  const failed = [];
  results.forEach((r, i) => {
    if (r.status === "fulfilled") removedFrom.push(api[i]);
    else {
      const error = r.reason?.message ?? String(r.reason);
      console.error(`[deleteProductEverywhere] ${api[i]} failed for ${productId}: ${error}`);
      failed.push({ platform: api[i], error });
    }
  });

  if (failed.length) return { deleted: false, removedFrom, failed, manualRemoval: manual };
  await ref.delete();
  return { deleted: true, removedFrom, failed: [], manualRemoval: manual };
}

// Required lazily: these modules register their own onCall functions at load.
function realDeleters(uid) {
  const run = (fn) => (productId) => fn.run({ auth: { uid }, data: { productId } });
  return {
    ebay: run(require("./ebay_listing").ebayDeleteListing),
    etsy: run(require("./etsy_listing").etsyDeleteListing),
    tiktok: run(require("./tiktok_listing").tiktokDeleteListing),
  };
}

const { EBAY_CLIENT_ID, EBAY_CLIENT_SECRET } = require("./ebay_auth");
const { TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");

exports.deleteProductEverywhere = onCall(
  // The platform handlers run in THIS function's process, so it must bind the
  // secrets they read (Etsy reads Secret Manager directly and needs none).
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, TT_APP_KEY, TT_APP_SECRET], timeoutSeconds: 120, memory: "256MiB" },
  validated("deleteProductEverywhere", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return deleteProductEverywhereCore({
      db: admin.firestore(), uid, productId: data.productId, deleters: realDeleters(uid),
    });
  }),
);

exports._internal = { livePlatforms, deleteProductEverywhereCore };
