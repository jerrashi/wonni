/**
 * purchase_orders.js — AliExpress restock orders (plan § 3, model A: AliExpress
 * ships to the SELLER, the item becomes ordinary stock).
 *
 * purchaseOrders/{id} = { userId, productId, variantSku, sourceVariantId, quantity,
 *   unitPrice, currency, aeOrderIds[], status, trackingNumber, carrier,
 *   receivedQuantity, createdAt, updatedAt, receivedAt }
 * status: placed (unpaid — AliExpress creates orders unpaid; the seller pays in
 *   the AliExpress app) → paid → shipped → delivered (AliExpress says so) →
 *   received (the seller said so; stock added) | cancelled.
 *
 * - `aliexpressCreateRestockOrder {productId, variantSku?, quantity, address}`:
 *   re-reads the product on AliExpress for the SKU's sku_attr + current price,
 *   places one DS order to the seller's address (remembered at
 *   users/{uid}/settings/aliexpressRestock for the next order).
 * - `syncPurchaseOrdersScheduled` (every 6 h) + `syncPurchaseOrders` (button):
 *   aliexpress.trade.ds.order.get → status + tracking.
 * - `markPurchaseOrderReceived {purchaseOrderId, quantity?}`: adds the units to
 *   stock through sales.restockCore (same push to every live platform as
 *   restockAndCascade). Once per order.
 * Firestore rules: clients only READ their own purchaseOrders (see firestore.rules).
 */

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const { callAliexpressApi, AE_SECRETS } = require("./aliexpress_auth");
const { EBAY_SECRETS, _internal: salesInternal } = require("./sales");

const SECRETS = [...new Set([...AE_SECRETS, ...EBAY_SECRETS])];
const OPEN = new Set(["placed", "paid", "shipped", "delivered"]);
const MAX_QTY = 100;

/** AliExpress order_status → ours. Unknown statuses keep the current one. */
function statusFromAe(aeStatus, current) {
  switch (aeStatus) {
    case "PLACE_ORDER_SUCCESS": return "placed";
    case "WAIT_SELLER_SEND_GOODS": case "RISK_CONTROL": case "WAIT_SELLER_EXAMINE_MONEY": return "paid";
    case "SELLER_PART_SEND_GOODS": case "WAIT_BUYER_ACCEPT_GOODS": return "shipped";
    case "FUND_PROCESSING": case "FINISH": return "delivered";
    case "IN_CANCEL": return "cancelled";
    default: return current;
  }
}

function normalizeAddress(a = {}) {
  const t = (v) => String(v ?? "").trim();
  const address = {
    fullName: t(a.fullName), phone: t(a.phone).replace(/[^0-9+]/g, ""), line1: t(a.line1), line2: t(a.line2),
    city: t(a.city), state: t(a.state), zip: t(a.zip), country: t(a.country || "US").toUpperCase(),
  };
  const missing = ["fullName", "phone", "line1", "city", "state", "zip"].filter((k) => !address[k]);
  if (missing.length) throw new HttpsError("invalid-argument", `Shipping address is missing: ${missing.join(", ")}.`);
  return address;
}

/** The DS order-create params for one SKU. */
function placeOrderParams({ outOrderId, aeProductId, skuAttr, quantity, address }) {
  return {
    param_place_order_request4_open_api_d_t_o: JSON.stringify({
      out_order_id: outOrderId,
      logistics_address: {
        full_name: address.fullName, contact_person: address.fullName,
        mobile_no: address.phone.replace(/^\+?1(?=\d{10}$)/, ""), phone_country: "+1",
        address: address.line1, address2: address.line2, city: address.city,
        province: address.state, zip: address.zip, country: address.country,
      },
      product_items: [{ product_id: Number(aeProductId), product_count: quantity, sku_attr: skuAttr || "" }],
    }),
  };
}

/** The product's AliExpress SKU for a variant (or the cheapest / only one). */
function pickSourceSku(product, fresh, variantSku) {
  const variants = Array.isArray(product.variants) ? product.variants : [];
  if (variants.length) {
    const v = variants.find((x) => x?.sku === variantSku);
    if (!v) throw new HttpsError("invalid-argument", "Pick which variant to reorder.");
    const sku = fresh.variants.find((s) => String(s.skuId) === String(v.sourceVariantId));
    if (!sku) throw new HttpsError("failed-precondition", "That variant isn't sold on AliExpress any more.");
    return { variant: v, sku };
  }
  const sku = [...fresh.variants].sort((a, b) => (a.price || Infinity) - (b.price || Infinity))[0];
  return { variant: null, sku: sku ?? null };
}

async function createRestockOrderCore(db, uid, req, { callApi = callAliexpressApi, fetchProduct, now = Date.now } = {}) {
  const quantity = Math.floor(Number(req.quantity));
  if (!(quantity >= 1 && quantity <= MAX_QTY)) throw new HttpsError("invalid-argument", `Quantity must be 1 to ${MAX_QTY}.`);
  const address = normalizeAddress(req.address);

  const snap = await db.collection("products").doc(String(req.productId || "")).get();
  const product = snap.exists ? snap.data() : null;
  if (!product || product.userId !== uid) throw new HttpsError("not-found", "Product not found.");
  const aeProductId = product.aliexpressProductId || (product.source === "aliexpress" ? product.sourceId : null);
  if (!aeProductId) throw new HttpsError("failed-precondition", "This product wasn't imported from AliExpress.");

  const fetcher = fetchProduct ?? ((id, url) => require("./aliexpress_product")._internal.mapDsProductFor(id, url, uid, { callApi }));
  const fresh = await fetcher(String(aeProductId), product.aliexpressUrl || product.sourceUrl || "");
  const { variant, sku } = pickSourceSku(product, fresh, req.variantSku ?? null);
  if (sku && sku.stock === 0) throw new HttpsError("failed-precondition", "Out of stock on AliExpress right now.");

  const ref = db.collection("purchaseOrders").doc();
  const response = await callApi("aliexpress.ds.order.create",
    placeOrderParams({ outOrderId: ref.id, aeProductId, skuAttr: sku?.skuAttr, quantity, address }), uid);
  const result = response?.aliexpress_ds_order_create_response?.result;
  const ids = result?.order_list?.number ?? result?.order_list ?? [];
  const aeOrderIds = (Array.isArray(ids) ? ids : [ids]).filter((x) => x != null && x !== "").map(String);
  if (!(result?.is_success === true || result?.is_success === "true") || !aeOrderIds.length) {
    const why = result?.error_msg || result?.error_code || "no order number came back";
    throw new HttpsError("failed-precondition", `AliExpress didn't place the order: ${why}.`);
  }

  const ts = now();
  const order = {
    userId: uid, productId: String(req.productId), variantSku: variant?.sku ?? null,
    sourceVariantId: sku?.skuId != null ? String(sku.skuId) : null, quantity,
    unitPrice: sku?.price ?? fresh.price ?? null, currency: fresh.currency ?? "USD",
    aeOrderIds, status: "placed", trackingNumber: null, carrier: null,
    receivedQuantity: null, createdAt: ts, updatedAt: ts, receivedAt: null,
  };
  await ref.set(order);
  await db.doc(`users/${uid}/settings/aliexpressRestock`).set({ address, updatedAt: ts }, { merge: true });
  return { purchaseOrderId: ref.id, aeOrderIds, status: "placed" };
}

/** trade.ds.order.get `result` → {status, trackingNumber, carrier}. */
function orderUpdateFromAe(result, current) {
  const logistics = result?.logistics_info_list?.aeop_order_logistics_info ?? result?.logistics_info_list ?? [];
  const first = (Array.isArray(logistics) ? logistics : []).find((l) => l?.logistics_no);
  return {
    status: statusFromAe(result?.order_status, current.status),
    trackingNumber: first?.logistics_no ?? current.trackingNumber ?? null,
    carrier: first?.logistics_service ?? current.carrier ?? null,
  };
}

async function syncPurchaseOrdersForUser(db, uid, { callApi = callAliexpressApi, now = Date.now } = {}) {
  const snap = await db.collection("purchaseOrders").where("userId", "==", uid).get();
  let updated = 0, failed = 0;
  for (const d of snap.docs) {
    const po = d.data();
    if (!OPEN.has(po.status) || po.status === "delivered" && po.trackingNumber) continue;
    try {
      const r = await callApi("aliexpress.trade.ds.order.get",
        { single_order_query: JSON.stringify({ order_id: po.aeOrderIds?.[0] }) }, uid);
      const next = orderUpdateFromAe(r?.aliexpress_trade_ds_order_get_response?.result, po);
      if (next.status !== po.status || next.trackingNumber !== po.trackingNumber || next.carrier !== po.carrier) {
        await db.collection("purchaseOrders").doc(d.id).update({ ...next, updatedAt: now() });
        updated++;
      }
    } catch (e) {
      if (e instanceof HttpsError && e.code === "failed-precondition") throw e; // auth: stop this user
      console.warn(`[syncPurchaseOrders] ${uid}/${d.id}: ${e.message}`);
      failed++;
    }
  }
  return { updated, failed };
}

async function markReceivedCore(db, uid, { purchaseOrderId, quantity }, { restock = salesInternal.restockCore, now = Date.now } = {}) {
  const ref = db.collection("purchaseOrders").doc(String(purchaseOrderId || ""));
  const snap = await ref.get();
  const po = snap.exists ? snap.data() : null;
  if (!po || po.userId !== uid) throw new HttpsError("not-found", "Order not found.");
  if (po.status === "received") throw new HttpsError("failed-precondition", "Already marked received; stock was added then.");
  if (po.status === "cancelled") throw new HttpsError("failed-precondition", "This order was cancelled.");
  const qty = quantity == null ? po.quantity : Math.floor(Number(quantity));
  if (!(qty >= 0 && qty <= MAX_QTY)) throw new HttpsError("invalid-argument", "Enter how many arrived.");
  // Status first, so a retry after a cascade failure can't add the stock twice.
  await ref.update({ status: "received", receivedQuantity: qty, receivedAt: now(), updatedAt: now() });
  let r = { newQuantity: null };
  try {
    if (qty > 0) r = await restock(db, uid, { productId: po.productId, variantSku: po.variantSku, delta: qty });
  } catch (e) {
    // Stock wasn't added: put the order back so "Mark received" can be retried.
    await ref.update({ status: po.status, receivedQuantity: null, receivedAt: null, updatedAt: now() });
    throw e;
  }
  return { success: true, added: qty, newQuantity: r.newQuantity ?? null };
}

function requireUid(request) {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return uid;
}

exports.aliexpressCreateRestockOrder = onCall({ secrets: AE_SECRETS, timeoutSeconds: 60 }, async (request) =>
  createRestockOrderCore(admin.firestore(), requireUid(request), request.data ?? {}));

exports.syncPurchaseOrders = onCall({ secrets: AE_SECRETS, timeoutSeconds: 120 }, async (request) =>
  syncPurchaseOrdersForUser(admin.firestore(), requireUid(request)));

exports.markPurchaseOrderReceived = onCall({ secrets: SECRETS, timeoutSeconds: 120 }, async (request) =>
  markReceivedCore(admin.firestore(), requireUid(request), request.data ?? {}));

exports.syncPurchaseOrdersScheduled = onSchedule(
  { schedule: "every 6 hours", secrets: AE_SECRETS, timeoutSeconds: 540 },
  async () => {
    const db = admin.firestore();
    const snaps = await db.collectionGroup("integrations").where("isConnected", "==", true).get();
    const uids = [...new Set(snaps.docs.filter((d) => d.id === "aliexpress").map((d) => d.ref.parent.parent.id))];
    for (const uid of uids) {
      try {
        const r = await syncPurchaseOrdersForUser(db, uid);
        if (r.updated || r.failed) console.log(`[syncPurchaseOrdersScheduled] uid=${uid} ${JSON.stringify(r)}`);
      } catch (e) {
        console.error(`[syncPurchaseOrdersScheduled] uid=${uid}: ${e.message}`);
      }
    }
  }
);

exports._internal = {
  statusFromAe, normalizeAddress, placeOrderParams, pickSourceSku, createRestockOrderCore,
  orderUpdateFromAe, syncPurchaseOrdersForUser, markReceivedCore,
};
