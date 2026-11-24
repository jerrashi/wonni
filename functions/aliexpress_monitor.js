/**
 * aliexpress_monitor.js — daily check of AliExpress-sourced products (plan § 3
 * "source monitoring"). Model A: AliExpress is where we BUY, so a change there
 * is information for restocking, never an automatic edit of our listings.
 *
 * Writes on products/{id}:
 *   sourceCheck = { checkedAt, priceWas, priceNow, outOfStock, outOfStockVariantIds, gone }
 *   sourceAlert = one readable line ("AliExpress price went up $2.10", "Out of
 *                 stock at source", …) or null when nothing worth saying changed.
 *   variants[i].sourceStock refreshed (whole-array write, never `variants.N.x`).
 * `sourcePrice` (what we paid) is left alone; `priceWas` is that cost basis.
 * A price move counts when it is at least $0.25 AND 5%.
 * At most MAX_PER_RUN products per user per run, least recently checked first.
 */

"use strict";

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { AE_SECRETS } = require("./aliexpress_auth");

const MAX_PER_RUN = 60;
const money = (n) => `$${Math.abs(n).toFixed(2)}`;

/** Stored product + fresh mapDsProduct (or null = gone) → { sourceCheck, sourceAlert, variants? }. */
function compareSource(product, fresh, nowMs) {
  if (!fresh) {
    return {
      sourceCheck: { checkedAt: nowMs, gone: true, priceWas: product.sourcePrice ?? null, priceNow: null, outOfStock: true, outOfStockVariantIds: [] },
      sourceAlert: "No longer on AliExpress",
    };
  }
  const priceWas = Number(product.sourcePrice) > 0 ? Number(product.sourcePrice) : null;
  const priceNow = fresh.price > 0 ? fresh.price : null;
  const byId = new Map(fresh.variants.map((v) => [String(v.skuId), v]));

  let variants;
  const outOfStockVariantIds = [];
  if (Array.isArray(product.variants) && product.variants.length) {
    variants = product.variants.map((v) => {
      const f = v?.sourceVariantId != null ? byId.get(String(v.sourceVariantId)) : null;
      if (!f) return v;
      if (f.stock === 0 && v.active !== false) outOfStockVariantIds.push(v.id);
      return Number.isFinite(f.stock) ? { ...v, sourceStock: f.stock } : v;
    });
  }
  const known = fresh.variants.filter((v) => Number.isFinite(v.stock));
  const outOfStock = known.length > 0 && known.every((v) => v.stock === 0);

  const alerts = [];
  if (outOfStock) alerts.push("Out of stock at source");
  else if (outOfStockVariantIds.length) alerts.push(`${outOfStockVariantIds.length} variant${outOfStockVariantIds.length > 1 ? "s" : ""} out of stock at source`);
  if (priceWas && priceNow) {
    const diff = Math.round((priceNow - priceWas) * 100) / 100;
    if (Math.abs(diff) >= 0.25 && Math.abs(diff) / priceWas >= 0.05) {
      alerts.push(`AliExpress price went ${diff > 0 ? "up" : "down"} ${money(diff)}`);
    }
  }
  return {
    sourceCheck: { checkedAt: nowMs, gone: false, priceWas, priceNow, outOfStock, outOfStockVariantIds },
    sourceAlert: alerts.length ? alerts.join(" · ") : null,
    ...(variants ? { variants } : {}),
  };
}

const lastChecked = (p) => p.sourceCheck?.checkedAt ?? 0;

async function checkAliexpressSourcesForUser(db, uid, { fetchProduct, now = Date.now, limit = MAX_PER_RUN } = {}) {
  const fetcher = fetchProduct ?? ((id, url) => require("./aliexpress_product")._internal.mapDsProductFor(id, url, uid));
  const snap = await db.collection("products").where("userId", "==", uid).get();
  const due = snap.docs
    .map((d) => ({ id: d.id, p: d.data() }))
    .filter(({ p }) => p.source === "aliexpress" && (p.aliexpressProductId || p.sourceId) && p.saleStatus !== "deleted")
    .sort((a, b) => lastChecked(a.p) - lastChecked(b.p))
    .slice(0, limit);

  let checked = 0, flagged = 0, failed = 0;
  for (const { id, p } of due) {
    let fresh;
    try {
      fresh = await fetcher(String(p.aliexpressProductId || p.sourceId), p.aliexpressUrl || p.sourceUrl || "");
    } catch (e) {
      if (e instanceof HttpsError && e.code === "not-found") fresh = null;
      else {
        // An auth failure would repeat for every product — stop this user's run.
        if (e instanceof HttpsError && e.code === "failed-precondition") throw e;
        console.warn(`[aliexpressMonitor] ${uid}/${id}: ${e.message}`);
        failed++;
        continue;
      }
    }
    const patch = compareSource(p, fresh, now());
    await db.collection("products").doc(id).update(patch);
    checked++;
    if (patch.sourceAlert) flagged++;
  }
  return { checked, flagged, failed };
}

exports.checkAliexpressSources = onSchedule(
  { schedule: "every day 05:00", secrets: AE_SECRETS, timeoutSeconds: 540 },
  async () => {
    const db = admin.firestore();
    const snaps = await db.collectionGroup("integrations").where("isConnected", "==", true).get();
    const uids = [...new Set(snaps.docs.filter((d) => d.id === "aliexpress").map((d) => d.ref.parent.parent.id))];
    for (const uid of uids) {
      try {
        const r = await checkAliexpressSourcesForUser(db, uid);
        console.log(`[checkAliexpressSources] uid=${uid} ${JSON.stringify(r)}`);
      } catch (e) {
        console.error(`[checkAliexpressSources] uid=${uid}: ${e.message}`);
      }
    }
  }
);

exports._internal = { compareSource, checkAliexpressSourcesForUser };
