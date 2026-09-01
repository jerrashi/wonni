const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { tiktokRequest } = require("./tiktok_listing");
const { TT_APP_KEY, TT_APP_SECRET } = require("./tiktok_auth");

// Poll TikTok Shop for new orders — called by web app or on schedule
exports.syncTiktokOrders = onCall(
  { secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return syncOrdersForUser(uid);
  }
);

// Scheduled sync every 15 minutes for all connected users
exports.syncTiktokOrdersScheduled = onSchedule(
  { schedule: "every 15 minutes", secrets: [TT_APP_KEY, TT_APP_SECRET] },
  async () => {
    const db = admin.firestore();
    // Find all users with a connected TikTok integration
    const snaps = await db.collectionGroup("integrations")
      .where("isConnected", "==", true)
      .get();
    const uids = [...new Set(snaps.docs.filter((d) => d.id === "tiktok").map((d) => d.ref.parent.parent.id))];
    await Promise.allSettled(uids.map(syncOrdersForUser));
  }
);

async function syncOrdersForUser(uid) {
  const db = admin.firestore();
  const userRef = db.doc(`users/${uid}`);
  const userSnap = await userRef.get();
  const lastPollAt = userSnap.data()?.lastTiktokPollAt ?? 0;
  const now = Math.floor(Date.now() / 1000);
  const fromTime = lastPollAt > 0 ? Math.floor(lastPollAt / 1000) : now - 48 * 3600;

  let cursor = "";
  let newOrders = 0;

  do {
    const body = {
      order_status: "AWAITING_SHIPMENT",
      create_time_ge: fromTime,
      create_time_lt: now,
      page_size: 50,
      ...(cursor ? { cursor } : {}),
    };

    const response = await tiktokRequest("POST", "/api/orders/202309/orders/search", body, uid);
    if (response.code !== 0) break;

    const orders = response.data?.orders ?? [];
    cursor = response.data?.next_cursor ?? "";

    for (const order of orders) {
      const orderId = order.id;

      // Dedup
      const existing = await db.collection("orders")
        .where("userId", "==", uid)
        .where("tiktokOrderId", "==", orderId)
        .limit(1)
        .get();
      if (!existing.empty) continue;

      // Match to a product
      const lineItem = order.line_items?.[0];
      const tiktokProductId = lineItem?.product_id;
      let productId = null;
      let aliexpressProductId = null;
      let productTitle = lineItem?.product_name ?? "";
      let aliexpressPrice = 0;

      if (tiktokProductId) {
        const pSnap = await db.collection("products")
          .where("userId", "==", uid)
          .where("tiktokProductId", "==", tiktokProductId)
          .limit(1)
          .get();
        if (!pSnap.empty) {
          const p = pSnap.docs[0];
          productId = p.id;
          aliexpressProductId = p.data().aliexpressProductId;
          productTitle = p.data().title;
          aliexpressPrice = p.data().sourceCost ?? 0;
        }
      }

      const buyerAddress = order.recipient_address ?? {};
      const salePrice = parseFloat(lineItem?.sale_price ?? "0");

      await db.collection("orders").add({
        userId: uid,
        tiktokOrderId: orderId,
        productId,
        aliexpressProductId,
        productTitle,
        aliexpressPrice,
        buyerName: buyerAddress.name ?? "",
        buyerAddress: {
          name: buyerAddress.name ?? "",
          phone: buyerAddress.phone_number ?? "",
          address: buyerAddress.address_line1 ?? "",
          city: buyerAddress.city ?? "",
          state: buyerAddress.state ?? "",
          zip: buyerAddress.zipcode ?? "",
          country: buyerAddress.country_code ?? "US",
        },
        quantity: lineItem?.quantity ?? 1,
        salePrice,
        status: "pending",
        createdAt: admin.firestore.Timestamp.fromDate(new Date(order.create_time * 1000)),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      newOrders++;
    }
  } while (cursor);

  await userRef.set({ lastTiktokPollAt: Date.now() }, { merge: true });
  return { newOrders };
}
