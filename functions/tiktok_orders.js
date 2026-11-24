/**
 * tiktok_orders.js — TikTok Shop orders → sales/ through recordSaleCore.
 *
 * Before 2026-11-23 this wrote to the orphan `orders/` collection (nothing read
 * it), read only the first line item and the removed `sourceCost` field, so a
 * TikTok sale never decremented stock or cascaded. Now it follows sale_poller.js:
 * pure mapping (`tiktokOrderToSales`) + a thin loop.
 *
 * 202309 orders list one line item PER UNIT, so line items are grouped by SKU:
 * one sale per (order, SKU) with quantity = units. Dedupe id: the order id when
 * the order has one SKU, else `<order>-<sku id>` (stable for an order's life).
 *
 * The window is by UPDATE time with an overlap, so status changes (shipped,
 * delivered, cancelled) come back around and advance the stored sale.
 * UNPAID / ON_HOLD orders are skipped (TikTok says not to ship an on-hold order;
 * it comes back once released). A cancelled order is recorded only when its sale
 * already exists — never created, or it would decrement stock for nothing.
 *
 * Fulfillment (model A: the seller ships). Each TikTok sale also carries
 *   sales/{id}.shipBy  — ms; TikTok's own deadline (tts_sla_time, else
 *                        rts_sla_time), else 2 business days after the order.
 *   sales/{id}.tiktok  — {orderId, lineItemIds, deliveryOptionId, shippingType,
 *                        packageId, piiExpiresAt}; written after recordSaleCore,
 *                        which keeps a fixed field list.
 * `tiktokShippingProviders {saleId}` lists the carriers TikTok accepts for the
 * order; `tiktokMarkShipped {saleId, trackingNumber, shippingProviderId}` sends
 * the tracking. TikTok Shipping orders (shipping_type TIKTOK) get their label in
 * Seller Center, so marking them is refused with that reason.
 * Buyer data: TikTok's data policy limits keeping buyer PII, so name + address
 * are cleared 30 days after delivery / cancellation (`purgeTiktokBuyerData`,
 * daily), and a re-poll past that date doesn't write them back.
 */

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { tiktokClientFor, TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");
const { _internal: salesInternal, EBAY_SECRETS } = require("./sales");

const SECRETS = [...new Set([...EBAY_SECRETS, TT_APP_KEY, TT_APP_SECRET])];
const FIRST_LOOKBACK_S = 7 * 24 * 3600;
const OVERLAP_S = 2 * 3600;
const PAGE_SIZE = 50;
const MAX_PAGES = 20;

const SKIP_STATUSES = new Set(["UNPAID", "ON_HOLD"]);
const PII_KEEP_MS = 30 * 24 * 3600 * 1000;
const DAY_MS = 24 * 3600 * 1000;

/** `days` business days (Mon–Fri, UTC) after `ms`. */
function addBusinessDays(ms, days) {
  let t = ms;
  let left = days;
  while (left > 0) {
    t += DAY_MS;
    const d = new Date(t).getUTCDay();
    if (d !== 0 && d !== 6) left--;
  }
  return t;
}

const secToMs = (s) => (Number(s) > 0 ? Number(s) * 1000 : null);

/** Ship-by for an order (ms). */
function shipByFor(order) {
  return secToMs(order.tts_sla_time) ?? secToMs(order.rts_sla_time)
    ?? addBusinessDays(secToMs(order.create_time) ?? Date.now(), 2);
}

/** When the buyer's name + address must be gone (ms), or null while the order is open. */
function piiExpiresAtFor(order, saleStatus) {
  if (!["delivered", "complete", "cancelled"].includes(saleStatus)) return null;
  const ended = secToMs(order.delivery_time) ?? secToMs(order.cancel_time) ?? secToMs(order.update_time) ?? Date.now();
  return ended + PII_KEEP_MS;
}

function saleStatusFor(tiktokStatus) {
  switch (tiktokStatus) {
    case "IN_TRANSIT": return "shipped";
    case "DELIVERED": return "delivered";
    case "COMPLETED": return "complete";
    case "CANCELLED": return "cancelled";
    default: return "pending"; // AWAITING_SHIPMENT, PARTIALLY_SHIPPING, AWAITING_COLLECTION
  }
}

const num = (v) => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : 0;
};
const round2 = (n) => Math.round(n * 100) / 100;

/**
 * Lookup tables for matching a line item to a product:
 *   bySkuId:     TikTok SKU id   → {productId, variantSku}   (written at post time)
 *   bySellerSku: seller SKU       → same (productId, or the eBay-style variant SKU)
 *   byProductId: TikTok product id → same, only for products without variants
 */
function buildTiktokMatchMaps(productDocs, variantSkuFor) {
  const bySkuId = new Map();
  const bySellerSku = new Map();
  const byProductId = new Map();
  for (const doc of productDocs) {
    const p = doc.data();
    const variants = Array.isArray(p.variants) ? p.variants : [];
    if (variants.length) {
      variants.forEach((v, i) => {
        if (!v) return;
        const m = { productId: doc.id, variantSku: v.sku ?? null };
        if (v.tiktokSkuId) bySkuId.set(String(v.tiktokSkuId), m);
        bySellerSku.set(variantSkuFor(doc.id, v, i), m);
      });
    } else {
      const m = { productId: doc.id, variantSku: null };
      if (p.tiktokSkuId) bySkuId.set(String(p.tiktokSkuId), m);
      bySellerSku.set(doc.id, m);
      if (p.tiktokProductId) byProductId.set(String(p.tiktokProductId), m);
    }
  }
  return { bySkuId, bySellerSku, byProductId };
}

function matchLineItem(li, maps) {
  return maps.bySkuId.get(String(li.sku_id ?? ""))
    ?? maps.bySellerSku.get(String(li.seller_sku ?? ""))
    ?? maps.byProductId.get(String(li.product_id ?? ""))
    ?? null;
}

/** recipient_address → the sale's buyerAddress shape (district_info names the levels). */
function tiktokBuyerAddress(order) {
  const a = order.recipient_address;
  if (!a) return null;
  const level = (re) => (a.district_info ?? []).find((d) => re.test(d.address_level_name ?? ""))?.address_name ?? null;
  return {
    name: a.name ?? null,
    line1: a.address_line1 ?? null,
    line2: [a.address_line2, a.address_line3, a.address_line4].filter(Boolean).join(", ") || null,
    city: level(/city/i),
    state: level(/state|province/i),
    zip: a.postal_code ?? null,
    country: a.region_code ?? "US",
  };
}

/**
 * One order → [{fields, cancelOnly}] for recordSaleCore. Unmatched line items are
 * still recorded (productId null, no stock change) so the dashboard shows every
 * TikTok sale. `cancelOnly` = record only if the sale already exists.
 */
function tiktokOrderToSales(order, maps, nowMs = Date.now()) {
  if (!order?.id || SKIP_STATUSES.has(order.status)) return [];
  const groups = new Map();
  for (const li of order.line_items ?? []) {
    if (li.is_gift) continue;
    const key = String(li.sku_id ?? li.seller_sku ?? li.product_id ?? li.id);
    const g = groups.get(key) ?? { key, items: [] };
    g.items.push(li);
    groups.set(key, g);
  }
  const status = saleStatusFor(order.status);
  const single = groups.size === 1;
  const out = [];
  for (const g of groups.values()) {
    const li = g.items[0];
    const match = matchLineItem(li, maps);
    const tracking = g.items.find((x) => x.tracking_number);
    // A line item cancelled on its own (partial cancel) cancels that sale.
    const st = g.items.every((x) => x.display_status === "CANCELLED") ? "cancelled" : status;
    const piiExpiresAt = piiExpiresAtFor(order, st);
    const piiGone = piiExpiresAt != null && piiExpiresAt <= nowMs;
    out.push({
      cancelOnly: st === "cancelled",
      shipBy: shipByFor(order),
      tiktok: {
        orderId: String(order.id),
        lineItemIds: g.items.map((x) => String(x.id)),
        deliveryOptionId: order.delivery_option_id != null ? String(order.delivery_option_id) : null,
        shippingType: order.shipping_type ?? null,
        packageId: g.items.find((x) => x.package_id)?.package_id ?? order.packages?.[0]?.id ?? null,
        piiExpiresAt,
      },
      fields: {
        platform: "tiktok",
        productId: match?.productId ?? null,
        variantSku: match?.variantSku ?? null,
        soldPrice: round2(g.items.reduce((s, x) => s + num(x.sale_price), 0)),
        shippingRevenue: single && order.payment?.shipping_fee != null ? num(order.payment.shipping_fee) || null : null,
        quantity: g.items.length,
        soldAt: (Number(order.create_time) || Math.floor(Date.now() / 1000)) * 1000,
        platformOrderId: single ? String(order.id) : `${order.id}-${g.key}`,
        platformItemId: li.product_id != null ? String(li.product_id) : null,
        buyerName: piiGone ? null : order.recipient_address?.name ?? null,
        buyerAddress: piiGone ? null : tiktokBuyerAddress(order),
        trackingNumber: tracking?.tracking_number ?? null,
        carrier: tracking?.shipping_provider_name ?? null,
        listingTitle: li.product_name ?? null,
        thumbnailUrl: li.sku_image ?? null,
        status: st,
        source: "tiktok-poll",
        cascade: true,
      },
    });
  }
  return out;
}

async function saleExists(db, uid, platformOrderId) {
  for (const id of [`tiktok_${platformOrderId}`, `${uid}_tiktok_${platformOrderId}`]) {
    const s = await db.collection("sales").doc(id).get();
    if (s.exists && s.data()?.userId === uid) return true;
  }
  return false;
}

/** Window start (Unix s) from the last successful poll (ms). */
function windowStart(lastPollMs, nowS) {
  return lastPollMs > 0 ? Math.floor(lastPollMs / 1000) - OVERLAP_S : nowS - FIRST_LOOKBACK_S;
}

async function syncTiktokOrdersForUser(db, uid, { client, recordSale = salesInternal.recordSaleCore, now = Date.now } = {}) {
  const integRef = db.doc(`users/${uid}/integrations/tiktok`);
  const integ = (await integRef.get()).data();
  if (!integ?.isConnected) return { imported: 0, updated: 0, skipped: 0, saleIds: [] };
  const c = client ?? tiktokClientFor(uid, { db });

  const productDocs = (await db.collection("products").where("userId", "==", uid).get()).docs;
  const productById = new Map(productDocs.map((d) => [d.id, d.data()]));
  const { variantSkuFor } = require("./ebay_listing");
  const maps = buildTiktokMatchMaps(productDocs, variantSkuFor);

  const nowS = Math.floor(now() / 1000);
  const body = { update_time_ge: windowStart(integ.lastOrdersPollAt ?? 0, nowS), update_time_lt: nowS };
  let pageToken = "";
  let imported = 0, updated = 0, skipped = 0;
  const saleIds = [];

  for (let page = 0; page < MAX_PAGES; page++) {
    const query = { page_size: PAGE_SIZE, sort_field: "update_time", sort_order: "ASC", ...(pageToken ? { page_token: pageToken } : {}) };
    const data = await c.request("POST", "/order/202309/orders/search", { query, body, what: "Loading TikTok orders" });
    for (const order of data.orders ?? []) {
      for (const { fields, cancelOnly, shipBy, tiktok } of tiktokOrderToSales(order, maps, now())) {
        try {
          if (cancelOnly && !(await saleExists(db, uid, fields.platformOrderId))) { skipped++; continue; }
          const { saleId, created } = await recordSale(db, uid, fields, productById.get(fields.productId) ?? null);
          // Keep a package id we learned when marking shipped if TikTok's copy lags.
          const prev = (await db.collection("sales").doc(saleId).get()).data()?.tiktok;
          await db.collection("sales").doc(saleId).set(
            { shipBy, tiktok: { ...tiktok, packageId: tiktok.packageId ?? prev?.packageId ?? null } }, { merge: true });
          saleIds.push(saleId);
          created ? imported++ : updated++;
        } catch (e) {
          console.error(`[syncTiktokOrders] order ${order.id} uid=${uid}: ${e.message}`);
          skipped++;
        }
      }
    }
    pageToken = data.next_page_token || "";
    if (!pageToken) break;
  }

  await integRef.set({ lastOrdersPollAt: now() }, { merge: true });
  return { imported, updated, skipped, saleIds };
}

// ── fulfillment ─────────────────────────────────────────────────────────────

async function loadTiktokSale(db, uid, saleId) {
  const snap = await db.collection("sales").doc(String(saleId || "")).get();
  const sale = snap.exists ? snap.data() : null;
  if (!sale || sale.userId !== uid) throw new HttpsError("not-found", "Sale not found.");
  if (sale.platform !== "tiktok" || !sale.tiktok?.orderId) {
    throw new HttpsError("failed-precondition", "This isn't a TikTok order Wonni has synced. Refresh TikTok orders and try again.");
  }
  return sale;
}

function refuseTiktokShipping(sale) {
  if (sale.tiktok.shippingType === "TIKTOK") {
    throw new HttpsError("failed-precondition",
      "This order uses TikTok Shipping. Buy and print the label in TikTok Seller Center; tracking is added there.");
  }
}

async function shippingProvidersCore(db, uid, client, { saleId }) {
  const sale = await loadTiktokSale(db, uid, saleId);
  refuseTiktokShipping(sale);
  if (!sale.tiktok.deliveryOptionId) {
    throw new HttpsError("failed-precondition", "TikTok hasn't given this order a delivery option yet. Refresh TikTok orders and try again.");
  }
  const data = await client.request("GET", `/logistics/202309/delivery_options/${sale.tiktok.deliveryOptionId}/shipping_providers`, {
    what: "Loading TikTok carriers",
  });
  const providers = (data.shipping_providers ?? []).map((p) => ({ id: String(p.id), name: p.name ?? String(p.id) }))
    .sort((a, b) => a.name.localeCompare(b.name));
  return { providers };
}

async function markShippedCore(db, uid, client, { saleId, trackingNumber, shippingProviderId, shippingProviderName }) {
  const tracking = String(trackingNumber || "").trim();
  if (!tracking) throw new HttpsError("invalid-argument", "Enter a tracking number.");
  if (!shippingProviderId) throw new HttpsError("invalid-argument", "Pick a carrier.");
  const sale = await loadTiktokSale(db, uid, saleId);
  refuseTiktokShipping(sale);
  const body = { tracking_number: tracking, shipping_provider_id: String(shippingProviderId) };
  let packageId = sale.tiktok.packageId;
  if (packageId) {
    // Already a package (re-send / correction): update its tracking.
    await client.request("POST", `/fulfillment/202309/packages/${packageId}/shipping_info/update`, { body, what: "Updating TikTok tracking" });
  } else {
    const data = await client.request("POST", `/fulfillment/202309/orders/${sale.tiktok.orderId}/packages`, {
      body: { ...body, order_line_item_ids: sale.tiktok.lineItemIds }, what: "Marking the TikTok order shipped",
    });
    packageId = data?.package_id != null ? String(data.package_id) : null;
  }
  await db.collection("sales").doc(String(saleId)).update({
    trackingNumber: tracking,
    carrier: shippingProviderName || null,
    status: sale.status === "pending" || !sale.status ? "shipped" : sale.status,
    "tiktok.packageId": packageId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return { success: true, packageId };
}

/** Clear buyer name + address on TikTok sales past their piiExpiresAt. */
async function purgeTiktokBuyerDataCore(db, nowMs = Date.now()) {
  const snap = await db.collection("sales").where("platform", "==", "tiktok").get();
  let cleared = 0;
  for (const d of snap.docs) {
    const s = d.data();
    const exp = s.tiktok?.piiExpiresAt;
    if (exp == null || exp > nowMs || (s.buyerName == null && s.buyerAddress == null)) continue;
    await db.collection("sales").doc(d.id).update({ buyerName: null, buyerAddress: null });
    cleared++;
  }
  return { cleared };
}

function requireUid(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return uid;
}

const TT_ONLY = [TT_APP_KEY, TT_APP_SECRET];

exports.tiktokShippingProviders = onCall({ secrets: TT_ONLY }, async (request) => {
  const uid = requireUid(request);
  const db = admin.firestore();
  return shippingProvidersCore(db, uid, tiktokClientFor(uid, { db }), request.data ?? {});
});

exports.tiktokMarkShipped = onCall({ secrets: TT_ONLY }, async (request) => {
  const uid = requireUid(request);
  const db = admin.firestore();
  return markShippedCore(db, uid, tiktokClientFor(uid, { db }), request.data ?? {});
});

exports.purgeTiktokBuyerData = onSchedule({ schedule: "every day 04:00", timeoutSeconds: 300 }, async () => {
  const { cleared } = await purgeTiktokBuyerDataCore(admin.firestore());
  console.log(`[purgeTiktokBuyerData] cleared ${cleared} sale(s)`);
});

exports.syncTiktokOrders = onCall({ secrets: SECRETS, timeoutSeconds: 300 }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return syncTiktokOrdersForUser(admin.firestore(), uid);
});

exports.syncTiktokOrdersScheduled = onSchedule(
  { schedule: "every 15 minutes", secrets: SECRETS, timeoutSeconds: 540 },
  async () => {
    const db = admin.firestore();
    // Needs the integrations.isConnected collection-group field override
    // (firestore.indexes.json, added 2026-11-23).
    const snaps = await db.collectionGroup("integrations").where("isConnected", "==", true).get();
    const uids = [...new Set(snaps.docs.filter((d) => d.id === "tiktok").map((d) => d.ref.parent.parent.id))];
    const results = await Promise.allSettled(uids.map((uid) => syncTiktokOrdersForUser(db, uid)));
    results.forEach((r, i) => {
      if (r.status === "rejected") console.error(`[syncTiktokOrdersScheduled] uid=${uids[i]}: ${r.reason?.message ?? r.reason}`);
    });
  }
);

exports._internal = {
  saleStatusFor, buildTiktokMatchMaps, matchLineItem, tiktokBuyerAddress, tiktokOrderToSales,
  windowStart, syncTiktokOrdersForUser, addBusinessDays, shipByFor, piiExpiresAtFor,
  shippingProvidersCore, markShippedCore, purgeTiktokBuyerDataCore,
};
