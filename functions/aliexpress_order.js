const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { callAliexpressApi } = require("./aliexpress_auth");
const { tiktokRequest } = require("./tiktok_listing");
const { TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");

// Place a dropship order on AliExpress for a given TikTok order
exports.placeAliexpressOrder = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { orderId } = request.data;
    if (!orderId) throw new HttpsError("invalid-argument", "Missing orderId.");

    const db = admin.firestore();
    const orderRef = db.collection("orders").doc(orderId);
    const orderSnap = await orderRef.get();
    if (!orderSnap.exists) throw new HttpsError("not-found", "Order not found.");

    const order = orderSnap.data();
    if (order.userId !== uid) throw new HttpsError("permission-denied", "Not your order.");
    if (order.status !== "pending") throw new HttpsError("failed-precondition", `Order is already ${order.status}.`);

    // Load product for variant info
    let skuAttr = "";
    if (order.productId) {
      const pSnap = await db.collection("products").doc(order.productId).get();
      if (pSnap.exists) skuAttr = pSnap.data().selectedVariant ?? "";
    }

    const addr = order.buyerAddress;
    const response = await callAliexpressApi("aliexpress.ds.order.create", {
      product_id: order.aliexpressProductId,
      product_count: order.quantity ?? 1,
      sku_attr: skuAttr || undefined,
      logistics_address: JSON.stringify({
        contact_person: addr.name,
        mobile_no: addr.phone,
        address: addr.address,
        city: addr.city,
        province: addr.state,
        zip: addr.zip,
        country: addr.country ?? "US",
      }),
      order_memo: orderId,
    }, uid);

    const aeOrder = response?.aliexpress_ds_order_create_response?.result;
    if (aeOrder?.is_success === false || !aeOrder?.order_id) {
      throw new HttpsError("internal", `AliExpress order failed: ${aeOrder?.error_msg ?? JSON.stringify(response)}`);
    }

    await orderRef.update({
      aliexpressOrderId: String(aeOrder.order_id),
      status: "fulfilling",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { aliexpressOrderId: String(aeOrder.order_id) };
  }
);

// Confirm shipment on TikTok once tracking is available
exports.confirmTiktokShipment = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { orderId, trackingNumber, carrier } = request.data;
    const db = admin.firestore();
    const orderRef = db.collection("orders").doc(orderId);
    const snap = await orderRef.get();
    if (!snap.exists || snap.data().userId !== uid) throw new HttpsError("not-found", "Order not found.");

    const order = snap.data();
    const response = await tiktokRequest(
      "POST",
      `/api/fulfillment/202309/orders/${order.tiktokOrderId}/packages/ship`,
      { tracking_number: trackingNumber, shipping_provider_id: carrier ?? "OTHER" },
      uid
    );

    if (response.code !== 0) {
      throw new HttpsError("internal", `TikTok ship confirmation failed: ${response.message}`);
    }

    await orderRef.update({
      trackingNumber,
      carrier: carrier ?? "OTHER",
      status: "shipped",
      shippedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);

// Poll AliExpress tracking for all "fulfilling" orders every 2 hours
exports.pollAliexpressTracking = onSchedule(
  { schedule: "every 2 hours" },
  async () => {
    const db = admin.firestore();
    const snap = await db.collection("orders").where("status", "==", "fulfilling").get();

    await Promise.allSettled(
      snap.docs.map(async (doc) => {
        const order = doc.data();
        try {
          const response = await callAliexpressApi("aliexpress.ds.tracking.info.query", {
            out_ref: order.aliexpressOrderId,
          }, order.userId);

          const trackingInfo = response?.aliexpress_ds_tracking_info_query_response?.result;
          const tracking = trackingInfo?.logistics_info_list?.aeop_order_tracking_info?.[0];
          if (!tracking?.tracking_website_name) return;

          // Tracking available — confirm shipment on TikTok
          await admin.firestore().collection("orders").doc(doc.id).update({
            trackingNumber: tracking.carrier_code ?? tracking.tracking_website_name,
            status: "shipped",
            shippedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          // Also notify TikTok
          if (order.tiktokOrderId) {
            await tiktokRequest(
              "POST",
              `/api/fulfillment/202309/orders/${order.tiktokOrderId}/packages/ship`,
              {
                tracking_number: tracking.carrier_code ?? "UNKNOWN",
                shipping_provider_id: "OTHER",
              },
              order.userId
            ).catch(() => {}); // best-effort
          }
        } catch {
          // Silently skip — will retry next poll
        }
      })
    );
  }
);
