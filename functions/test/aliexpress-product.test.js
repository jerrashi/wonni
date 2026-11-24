/**
 * aliexpress-product.test.js — ds.product.get mapping, freight quote, doc fields.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal: A } = require("../aliexpress_product");
const { buildNewProductDoc } = require("../product_schema");

const RESULT = {
  ae_item_base_info_dto: { subject: "NCT Dream lightstick case", mobile_detail: "<p>Hard shell&nbsp;case</p><div>Fits v2</div><img src=x>", currency_code: "USD" },
  ae_multimedia_info_dto: { image_urls: Array.from({ length: 15 }, (_, i) => `https://ae01.alicdn.com/${i}.jpg`).join(";") },
  package_info_dto: { gross_weight: "0.500", package_length: 20, package_width: 10, package_height: 5 },
  ae_item_properties: { ae_item_property: [{ attr_name: "Material", attr_value: "EVA" }, { attr_name: "Material", attr_value: "dup" }, { attr_name: "Brand Name", attr_value: "NONE" }] },
  ae_item_sku_info_dtos: { ae_item_sku_info_d_t_o: [
    { sku_id: "1", sku_attr: "14:1#Color:Black", sku_price: "9.99", offer_sale_price: "7.50", sku_available_stock: 120, currency_code: "USD" },
    { sku_id: "2", sku_attr: "14:2#Color:Pink", sku_price: "9.99", sku_available_stock: 0 },
  ] },
};

test("regression: import keeps up to 12 photos, the sale price, description, package, specifics, stock", () => {
  const m = A.mapDsProduct(RESULT, "100", "https://www.aliexpress.com/item/100.html");
  assert.equal(m.images.length, 12);
  assert.equal(m.price, 7.5, "offer_sale_price is what we'd pay now");
  assert.equal(m.description, "Hard shell case\nFits v2");
  assert.deepEqual(m.package, { weightLbs: 1, weightOz: 1.6, lengthIn: 7.9, widthIn: 3.9, heightIn: 2 });
  assert.deepEqual(m.itemSpecifics, { Material: "EVA", "Brand Name": "NONE" });
  assert.deepEqual(m.variants.map((v) => [v.price, v.stock]), [[7.5, 120], [9.99, 0]]);
  assert.equal(m.currency, "USD");
});

test("supplier stock goes on the variant as sourceStock, never into our quantity", () => {
  const m = A.mapDsProduct(RESULT, "100");
  const { variants } = A.mapAliexpressVariants(m.variants, "P");
  const doc = buildNewProductDoc({ userId: "u", variants });
  assert.deepEqual(doc.variants.map((v) => [v.quantity, v.sourceStock]), [[1, 120], [1, 0]]);
});

test("cheapestFreight: cents, decimal text and free shipping; cheapest then fastest", () => {
  assert.deepEqual(A.cheapestFreight({ delivery_options: { delivery_option_d_t_o: [
    { code: "A", shipping_fee_cent: "399", min_delivery_days: 7, max_delivery_days: 12, company: "AliExpress Standard" },
    { code: "B", shipping_fee_format: "$2.10", max_delivery_days: 20 },
    { code: "C", free_shipping: true, max_delivery_days: 30, company: "Cainiao" },
    { code: "D", free_shipping: "true", max_delivery_days: 15, company: "Fast free" },
  ] } }), { cost: 0, minDays: null, maxDays: 15, carrier: "Fast free" });
  assert.equal(A.cheapestFreight({}), null);
});

test("fetchAliexpressDsProduct: quotes shipping for the cheapest SKU; a failed quote doesn't fail the import", async () => {
  const calls = [];
  const callApi = async (method, params) => {
    calls.push({ method, params });
    if (method === "aliexpress.ds.product.get") return { aliexpress_ds_product_get_response: { result: RESULT } };
    return { aliexpress_ds_freight_query_response: { result: { delivery_options: { delivery_option_d_t_o: [{ shipping_fee_cent: 250, company: "X" }] } } } };
  };
  const p = await A.fetchAliexpressDsProduct("100", "u", "uid", { callApi });
  assert.equal(p.shipping.cost, 2.5);
  const q = JSON.parse(calls[1].params.queryDeliveryReq);
  assert.deepEqual([q.productId, q.selectedSkuId, q.shipToCountry], ["100", "1", "US"]);

  const failing = async (method) => {
    if (method === "aliexpress.ds.product.get") return { aliexpress_ds_product_get_response: { result: RESULT } };
    throw new Error("freight down");
  };
  assert.equal((await A.fetchAliexpressDsProduct("100", "u", "uid", { callApi: failing })).shipping, null);
});

test("aliexpressDocFields: package, currency, specifics, shipping quote", () => {
  const m = A.mapDsProduct(RESULT, "100");
  m.shipping = { cost: 2.5, minDays: 7, maxDays: 12, carrier: "X" };
  const f = A.aliexpressDocFields(m);
  assert.equal(f.weightLbs, 1);
  assert.equal(f.sourceCurrency, "USD");
  assert.equal(f.itemSpecifics.Material, "EVA");
  assert.deepEqual(f.sourceShipping, m.shipping);
});
