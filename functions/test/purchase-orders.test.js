/**
 * purchase-orders.test.js — AliExpress restock orders.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal: P } = require("../purchase_orders");
const { _internal: S } = require("../sales");

const ADDRESS = { fullName: "Jerry S", phone: "+1 (555) 123-4567", line1: "1 Main St", city: "LA", state: "CA", zip: "90001" };
const FRESH = { price: 7.5, currency: "USD", variants: [
  { skuId: "11", skuAttr: "14:1#Color:Black", price: 7.5, stock: 50 },
  { skuId: "12", skuAttr: "14:2#Color:Pink", price: 8, stock: 0 },
] };

function db0(extra = {}) {
  return new FakeFirestore({ products: {
    plain: { userId: "u", source: "aliexpress", aliexpressProductId: "100", quantity: 2 },
    tee: { userId: "u", source: "aliexpress", aliexpressProductId: "100", hasVariants: true, quantityVariesByVariant: true,
      variants: [{ id: "a", sku: "A", sourceVariantId: "11", quantity: 1 }, { id: "b", sku: "B", sourceVariantId: "12", quantity: 0 }] },
    weverse: { userId: "u", source: "weverse", sourceId: "9" },
    ...extra,
  } });
}

const api = (result = { is_success: true, order_list: { number: [8001] } }) => {
  const calls = [];
  const fn = async (method, params) => { calls.push({ method, params }); return { aliexpress_ds_order_create_response: { result } }; };
  fn.calls = calls;
  return fn;
};

test("createRestockOrderCore: places one order for the variant's AliExpress SKU to the seller's address", async () => {
  const db = db0();
  const callApi = api();
  const r = await P.createRestockOrderCore(db, "u", { productId: "tee", variantSku: "A", quantity: 3, address: ADDRESS },
    { callApi, fetchProduct: async () => FRESH, now: () => 1000 });
  assert.deepEqual(r.aeOrderIds, ["8001"]);
  assert.equal(callApi.calls[0].method, "aliexpress.ds.order.create");
  const dto = JSON.parse(callApi.calls[0].params.param_place_order_request4_open_api_d_t_o);
  assert.deepEqual(dto.product_items, [{ product_id: 100, product_count: 3, sku_attr: "14:1#Color:Black" }]);
  assert.equal(dto.logistics_address.mobile_no, "5551234567");
  assert.equal(dto.out_order_id, r.purchaseOrderId);
  const po = db.peek("purchaseOrders", r.purchaseOrderId);
  assert.deepEqual([po.status, po.quantity, po.unitPrice, po.variantSku, po.sourceVariantId], ["placed", 3, 7.5, "A", "11"]);
  assert.equal(db.peek("users/u/settings", "aliexpressRestock").address.zip, "90001");
});

test("createRestockOrderCore: refuses bad input before calling AliExpress", async () => {
  const callApi = api();
  const deps = { callApi, fetchProduct: async () => FRESH };
  const run = (req) => P.createRestockOrderCore(db0(), "u", { productId: "tee", variantSku: "A", quantity: 1, address: ADDRESS, ...req }, deps);
  await assert.rejects(run({ quantity: 0 }), /Quantity/);
  await assert.rejects(run({ address: { ...ADDRESS, zip: "" } }), /missing: zip/);
  await assert.rejects(run({ productId: "weverse" }), /wasn't imported from AliExpress/);
  await assert.rejects(run({ variantSku: null }), /Pick which variant/);
  await assert.rejects(run({ variantSku: "B" }), /Out of stock on AliExpress/);
  await assert.rejects(P.createRestockOrderCore(db0(), "intruder", { productId: "tee", variantSku: "A", quantity: 1, address: ADDRESS }, deps), (e) => e.code === "not-found");
  assert.equal(callApi.calls.length, 0);
});

test("createRestockOrderCore: AliExpress's refusal is readable and nothing is saved", async () => {
  const db = db0();
  await assert.rejects(P.createRestockOrderCore(db, "u", { productId: "plain", quantity: 1, address: ADDRESS },
    { callApi: api({ is_success: false, error_msg: "SKU_NOT_AVAILABLE" }), fetchProduct: async () => FRESH }), /SKU_NOT_AVAILABLE/);
  assert.equal((await db.collection("purchaseOrders").where("userId", "==", "u").get()).docs.length, 0);
});

test("syncPurchaseOrdersForUser: status + tracking from trade.ds.order.get; closed orders skipped", async () => {
  const db = new FakeFirestore({ purchaseOrders: {
    p1: { userId: "u", status: "placed", aeOrderIds: ["1"] },
    p2: { userId: "u", status: "received", aeOrderIds: ["2"] },
  } });
  const calls = [];
  const callApi = async (method, params) => {
    calls.push(JSON.parse(params.single_order_query).order_id);
    return { aliexpress_trade_ds_order_get_response: { result: { order_status: "WAIT_BUYER_ACCEPT_GOODS",
      logistics_info_list: { aeop_order_logistics_info: [{ logistics_no: "LP123", logistics_service: "CAINIAO_STANDARD" }] } } } };
  };
  assert.deepEqual(await P.syncPurchaseOrdersForUser(db, "u", { callApi, now: () => 5 }), { updated: 1, failed: 0 });
  assert.deepEqual(calls, ["1"]);
  const po = db.peek("purchaseOrders", "p1");
  assert.deepEqual([po.status, po.trackingNumber, po.carrier], ["shipped", "LP123", "CAINIAO_STANDARD"]);
});

test("markReceivedCore: adds the units to stock once, through the restock path", async () => {
  const db = db0({});
  await db.collection("purchaseOrders").doc("po").set({ userId: "u", productId: "plain", variantSku: null, quantity: 3, status: "delivered" });
  const r = await P.markReceivedCore(db, "u", { purchaseOrderId: "po" }, { restock: (d, uid, args) => S.restockCore(d, uid, args) });
  assert.deepEqual(r, { success: true, added: 3, newQuantity: 5 });
  assert.equal(db.peek("products", "plain").quantity, 5);
  assert.equal(db.peek("purchaseOrders", "po").status, "received");
  await assert.rejects(P.markReceivedCore(db, "u", { purchaseOrderId: "po" }), /Already marked received/);
  assert.equal(db.peek("products", "plain").quantity, 5);
});

test("markReceivedCore: fewer arrived → that many; a failed restock puts the order back", async () => {
  const db = db0();
  await db.collection("purchaseOrders").doc("po").set({ userId: "u", productId: "tee", variantSku: "B", quantity: 4, status: "shipped" });
  await P.markReceivedCore(db, "u", { purchaseOrderId: "po", quantity: 2 }, { restock: (d, uid, args) => S.restockCore(d, uid, args) });
  assert.equal(db.peek("products", "tee").variants[1].quantity, 2, "per-variant stock: the ordered variant");

  await db.collection("purchaseOrders").doc("po2").set({ userId: "u", productId: "plain", quantity: 1, status: "shipped" });
  await assert.rejects(P.markReceivedCore(db, "u", { purchaseOrderId: "po2" }, { restock: async () => { throw new Error("eBay down"); } }), /eBay down/);
  assert.equal(db.peek("purchaseOrders", "po2").status, "shipped");
});
