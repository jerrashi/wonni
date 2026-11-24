/**
 * tiktok-orders.test.js — TikTok orders → sales/ via recordSaleCore.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal: O } = require("../tiktok_orders");
const { variantSkuFor } = require("../ebay_listing");

const UID = "u1";
const docs = (map) => Object.entries(map).map(([id, data]) => ({ id, data: () => data }));

const PRODUCTS = {
  plain: { userId: UID, title: "Jaemin card", tiktokProductId: "TP1", tiktokSkuId: "TS1", quantity: 2 },
  tee: { userId: UID, title: "Tee", hasVariants: true, variants: [{ id: "vS", sku: "S", tiktokSkuId: "TS2" }, { id: "vM", sku: "M" }] },
};
const maps = () => O.buildTiktokMatchMaps(docs(PRODUCTS), variantSkuFor);

const line = (over) => ({ id: `li${Math.random()}`, product_id: "TP1", sku_id: "TS1", product_name: "Jaemin card", sale_price: "15.00", ...over });

test("match: TikTok SKU id, then seller SKU, then product id (plain products only)", () => {
  const m = maps();
  assert.deepEqual(O.matchLineItem({ sku_id: "TS2" }, m), { productId: "tee", variantSku: "S" });
  assert.deepEqual(O.matchLineItem({ seller_sku: variantSkuFor("tee", PRODUCTS.tee.variants[1], 1) }, m), { productId: "tee", variantSku: "M" });
  assert.deepEqual(O.matchLineItem({ product_id: "TP1" }, m), { productId: "plain", variantSku: null });
  assert.equal(O.matchLineItem({ sku_id: "nope" }, m), null);
});

test("regression: every line item counts — units of one SKU group into one sale with quantity N", () => {
  const order = { id: "O1", status: "AWAITING_SHIPMENT", create_time: 1700000000, line_items: [line(), line()], payment: { shipping_fee: "4.99" } };
  const [s] = O.tiktokOrderToSales(order, maps());
  assert.equal(s.fields.quantity, 2);
  assert.equal(s.fields.soldPrice, 30);
  assert.equal(s.fields.platformOrderId, "O1");
  assert.equal(s.fields.shippingRevenue, 4.99);
  assert.equal(s.fields.productId, "plain");
  assert.equal(s.fields.status, "pending");
  assert.equal(s.fields.soldAt, 1700000000000);
});

test("two SKUs in one order → two sales with stable per-SKU ids", () => {
  const order = { id: "O2", status: "IN_TRANSIT", line_items: [line(), line({ product_id: "TP9", sku_id: "TS2", sale_price: "12", tracking_number: "1Z", shipping_provider_name: "UPS" })] };
  const sales = O.tiktokOrderToSales(order, maps());
  assert.deepEqual(sales.map((s) => s.fields.platformOrderId), ["O2-TS1", "O2-TS2"]);
  assert.equal(sales[1].fields.variantSku, "S");
  assert.equal(sales[1].fields.trackingNumber, "1Z");
  assert.equal(sales[1].fields.status, "shipped");
  assert.equal(sales[0].fields.shippingRevenue, null, "order shipping is not split across sales");
});

test("unpaid / on-hold orders are skipped; cancelled ones are cancel-only", () => {
  assert.deepEqual(O.tiktokOrderToSales({ id: "O", status: "UNPAID", line_items: [line()] }, maps()), []);
  assert.deepEqual(O.tiktokOrderToSales({ id: "O", status: "ON_HOLD", line_items: [line()] }, maps()), []);
  const [c] = O.tiktokOrderToSales({ id: "O", status: "CANCELLED", line_items: [line()] }, maps());
  assert.equal(c.cancelOnly, true);
  assert.equal(c.fields.status, "cancelled");
});

test("buyer address reads TikTok's district levels", () => {
  const a = O.tiktokBuyerAddress({ recipient_address: {
    name: "Kim", address_line1: "1 Main", postal_code: "90001", region_code: "US",
    district_info: [{ address_level_name: "Country", address_name: "US" }, { address_level_name: "State", address_name: "CA" },
      { address_level_name: "County", address_name: "LA" }, { address_level_name: "City", address_name: "Los Angeles" }],
  } });
  assert.deepEqual(a, { name: "Kim", line1: "1 Main", line2: null, city: "Los Angeles", state: "CA", zip: "90001", country: "US" });
});

test("windowStart: first poll looks back 7 days; later polls overlap 2 h by update time", () => {
  assert.equal(O.windowStart(0, 1_000_000), 1_000_000 - 7 * 86400);
  assert.equal(O.windowStart(1_000_000_000, 0), 1_000_000 - 7200);
});

test("syncTiktokOrdersForUser: records through recordSaleCore, paginates, never creates a cancelled sale", async () => {
  const db = new FakeFirestore({ products: PRODUCTS });
  await db.doc(`users/${UID}/integrations/tiktok`).set({ isConnected: true });
  const pages = [
    { orders: [{ id: "A", status: "AWAITING_SHIPMENT", line_items: [line()] }], next_page_token: "p2" },
    { orders: [{ id: "B", status: "CANCELLED", line_items: [line()] }], next_page_token: "" },
  ];
  const client = { calls: [], async request(m, p, o) { this.calls.push(o); return pages.shift(); } };
  const recorded = [];
  const recordSale = async (_db, uid, fields, product) => {
    recorded.push({ uid, fields, hasProduct: !!product });
    return { saleId: `tiktok_${fields.platformOrderId}`, created: true };
  };
  const r = await O.syncTiktokOrdersForUser(db, UID, { client, recordSale, now: () => 1_700_000_000_000 });
  assert.deepEqual(r, { imported: 1, updated: 0, skipped: 1, saleIds: ["tiktok_A"] });
  assert.equal(recorded.length, 1);
  assert.equal(recorded[0].fields.platform, "tiktok");
  assert.equal(recorded[0].hasProduct, true);
  assert.equal(client.calls[1].query.page_token, "p2");
  assert.equal((await db.doc(`users/${UID}/integrations/tiktok`).get()).data().lastOrdersPollAt, 1_700_000_000_000);
});

test("end to end with the real recordSaleCore: a TikTok sale decrements stock and is deduped on re-poll", async () => {
  const db = new FakeFirestore({ products: { plain: { ...PRODUCTS.plain, crossPostStatus: { tiktok: "active" } } } });
  await db.doc(`users/${UID}/integrations/tiktok`).set({ isConnected: true });
  const order = { id: "Z", status: "AWAITING_SHIPMENT", line_items: [line()] };
  const client = { async request() { return { orders: [order] }; } };
  const first = await O.syncTiktokOrdersForUser(db, UID, { client });
  assert.equal(first.imported, 1);
  assert.equal(db.peek("products", "plain").quantity, 1);
  assert.equal(db.peek("sales", "tiktok_Z").platform, "tiktok");
  const again = await O.syncTiktokOrdersForUser(db, UID, { client });
  assert.deepEqual([again.imported, again.updated], [0, 1]);
  assert.equal(db.peek("products", "plain").quantity, 1, "re-poll does not decrement twice");
});

// ── fulfillment ─────────────────────────────────────────────────────────────

test("shipBy: TikTok's own deadline, else 2 business days (a Friday order is due Tuesday)", () => {
  assert.equal(O.shipByFor({ tts_sla_time: 100, rts_sla_time: 50 }), 100_000);
  assert.equal(O.shipByFor({ rts_sla_time: 50 }), 50_000);
  const fri = Date.UTC(2026, 10, 20, 15) / 1000; // Fri 2026-11-20
  assert.equal(new Date(O.shipByFor({ create_time: fri })).getUTCDay(), 2);
});

test("sync writes shipBy + the tiktok block the ship screen needs", async () => {
  const db = new FakeFirestore({ products: PRODUCTS });
  await db.doc(`users/${UID}/integrations/tiktok`).set({ isConnected: true });
  const order = { id: "Q", status: "AWAITING_SHIPMENT", rts_sla_time: 1_800_000_000, delivery_option_id: 77, shipping_type: "SELLER", line_items: [line({ id: "L1" }), line({ id: "L2" })] };
  await O.syncTiktokOrdersForUser(db, UID, { client: { async request() { return { orders: [order] }; } } });
  const s = db.peek("sales", "tiktok_Q");
  assert.equal(s.shipBy, 1_800_000_000_000);
  assert.deepEqual(s.tiktok, { orderId: "Q", lineItemIds: ["L1", "L2"], deliveryOptionId: "77", shippingType: "SELLER", packageId: null, piiExpiresAt: null });
});

test("buyer data: expires 30 days after delivery and is not written back by a later poll", () => {
  const delivered = { id: "D", status: "DELIVERED", delivery_time: 1_000, recipient_address: { name: "Kim" }, line_items: [line()] };
  const [fresh] = O.tiktokOrderToSales(delivered, maps(), 1_000_000 + 1000);
  assert.equal(fresh.tiktok.piiExpiresAt, 1_000_000 + 30 * 86400_000);
  assert.equal(fresh.fields.buyerName, "Kim");
  const [late] = O.tiktokOrderToSales(delivered, maps(), 1_000_000 + 31 * 86400_000);
  assert.equal(late.fields.buyerName, null);
  assert.equal(late.fields.buyerAddress, null);
  const [open] = O.tiktokOrderToSales({ ...delivered, status: "AWAITING_SHIPMENT" }, maps());
  assert.equal(open.tiktok.piiExpiresAt, null);
});

test("purgeTiktokBuyerDataCore: clears only expired TikTok sales", async () => {
  const db = new FakeFirestore({ sales: {
    a: { platform: "tiktok", buyerName: "Kim", buyerAddress: { zip: "1" }, tiktok: { piiExpiresAt: 10 } },
    b: { platform: "tiktok", buyerName: "Lee", tiktok: { piiExpiresAt: 999 } },
    c: { platform: "tiktok", buyerName: "Park", tiktok: { piiExpiresAt: null } },
    d: { platform: "ebay", buyerName: "Choi", tiktok: { piiExpiresAt: 1 } },
  } });
  assert.deepEqual(await O.purgeTiktokBuyerDataCore(db, 100), { cleared: 1 });
  assert.equal(db.peek("sales", "a").buyerName, null);
  assert.equal(db.peek("sales", "a").buyerAddress, null);
  assert.equal(db.peek("sales", "b").buyerName, "Lee");
  assert.equal(db.peek("sales", "d").buyerName, "Choi");
});

function shipDb(tiktok = {}) {
  return new FakeFirestore({ sales: {
    S: { userId: UID, platform: "tiktok", status: "pending", tiktok: { orderId: "O9", lineItemIds: ["L1"], deliveryOptionId: "77", shippingType: "SELLER", packageId: null, ...tiktok } },
    E: { userId: UID, platform: "ebay" },
  } });
}
const rec = (resp = {}) => ({ calls: [], async request(m, p, o) { this.calls.push({ m, p, o }); return resp; } });

test("shippingProvidersCore: carriers for the order's delivery option, sorted", async () => {
  const c = rec({ shipping_providers: [{ id: 2, name: "USPS" }, { id: 1, name: "FedEx" }] });
  const r = await O.shippingProvidersCore(shipDb(), UID, c, { saleId: "S" });
  assert.equal(c.calls[0].p, "/logistics/202309/delivery_options/77/shipping_providers");
  assert.deepEqual(r.providers, [{ id: "1", name: "FedEx" }, { id: "2", name: "USPS" }]);
});

test("markShippedCore: first time creates the package; again updates its tracking", async () => {
  const db = shipDb();
  const c = rec({ package_id: "PK1" });
  const r = await O.markShippedCore(db, UID, c, { saleId: "S", trackingNumber: " 9400 ", shippingProviderId: "2", shippingProviderName: "USPS" });
  assert.deepEqual(r, { success: true, packageId: "PK1" });
  assert.equal(c.calls[0].p, "/fulfillment/202309/orders/O9/packages");
  assert.deepEqual(c.calls[0].o.body, { tracking_number: "9400", shipping_provider_id: "2", order_line_item_ids: ["L1"] });
  const s = db.peek("sales", "S");
  assert.deepEqual([s.trackingNumber, s.carrier, s.status, s.tiktok.packageId], ["9400", "USPS", "shipped", "PK1"]);

  const c2 = rec({});
  await O.markShippedCore(db, UID, c2, { saleId: "S", trackingNumber: "9401", shippingProviderId: "2" });
  assert.equal(c2.calls[0].p, "/fulfillment/202309/packages/PK1/shipping_info/update");
});

test("markShippedCore: refuses TikTok Shipping orders, other platforms, other users, blank input", async () => {
  const c = rec();
  await assert.rejects(O.markShippedCore(shipDb({ shippingType: "TIKTOK" }), UID, c, { saleId: "S", trackingNumber: "1", shippingProviderId: "2" }), /TikTok Shipping/);
  await assert.rejects(O.markShippedCore(shipDb(), UID, c, { saleId: "E", trackingNumber: "1", shippingProviderId: "2" }), /isn't a TikTok order/);
  await assert.rejects(O.markShippedCore(shipDb(), "intruder", c, { saleId: "S", trackingNumber: "1", shippingProviderId: "2" }), (e) => e.code === "not-found");
  await assert.rejects(O.markShippedCore(shipDb(), UID, c, { saleId: "S", trackingNumber: " ", shippingProviderId: "2" }), /tracking number/);
  assert.equal(c.calls.length, 0);
});
