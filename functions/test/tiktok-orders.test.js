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
