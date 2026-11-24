/**
 * tiktok-listing.test.js — payload builders, create/delete cores with a fake
 * client, and the sale cascade's stock push.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal: L } = require("../tiktok_listing");
const { variantSkuFor } = require("../ebay_listing");

const UID = "u1";

function fakeClient(responses = {}) {
  const calls = [];
  return {
    calls,
    async request(method, path, opts = {}) {
      calls.push({ method, path, opts });
      const key = Object.keys(responses).find((k) => path === k || path.startsWith(k));
      const r = key ? responses[key] : {};
      return typeof r === "function" ? r(opts) : r;
    },
  };
}

const imageFetch = async () => ({ buffer: Buffer.from([1, 2, 3, 4]), contentType: "image/png" });

test("buildCategoryList: leaves only, with full breadcrumb names", () => {
  const list = L.buildCategoryList([
    { id: 1, parent_id: 0, local_name: "Collectibles", is_leaf: false },
    { id: 2, parent_id: 1, local_name: "K-pop", is_leaf: false },
    { id: 3, parent_id: 2, local_name: "Photocards", is_leaf: true },
    { id: 4, parent_id: 0, local_name: "Toys", is_leaf: true },
  ]);
  assert.deepEqual(list, [
    { id: "3", name: "Collectibles > K-pop > Photocards" },
    { id: "4", name: "Toys" },
  ]);
});

test("pickWarehouse: default enabled sales warehouse; none → readable error", () => {
  assert.equal(L.pickWarehouse([
    { id: "r1", type: "RETURN_WAREHOUSE", is_default: true },
    { id: "s1", type: "SALES_WAREHOUSE" },
    { id: "s2", type: "SALES_WAREHOUSE", is_default: true },
  ]), "s2");
  assert.throws(() => L.pickWarehouse([]), /no sales warehouse/);
});

test("regression: package uses the product's weight/dims, not a hardcoded 0.5 kg", () => {
  assert.deepEqual(L.tiktokPackage({ weightLbs: 1, weightOz: 8, lengthIn: 10, widthIn: 7, heightIn: 3 }), {
    package_weight: { value: "1.5", unit: "POUND" },
    package_dimensions: { length: "10", width: "7", height: "3", unit: "INCH" },
  });
  assert.equal(L.tiktokPackage({}).package_weight.value, "0.38"); // 6 oz default
});

test("regression: a plain product posts its own quantity, not 999", () => {
  assert.equal(L.skuQuantity({ quantity: 1 }, null), 1);
  assert.equal(L.skuQuantity({}, null), 1);
  assert.equal(L.skuQuantity({ quantity: 0 }, null), 0);
});

test("buildTiktokSkus: one SKU per active variant, eBay-style seller SKU, variant price override, shared pool", () => {
  const product = {
    listingPrice: 20, hasVariants: true, quantity: 3, // shared pool (unset flag + variants)
    options: [{ name: "Member" }],
    variants: [
      { id: "vA", sku: "A", optionValues: { Member: "Jaemin" }, quantity: 9 },
      { id: "vB", sku: "B", optionValues: { Member: "Mark" }, price: 25 },
      { id: "vC", sku: "C", optionValues: { Member: "Haechan" }, active: false },
    ],
  };
  const skus = L.buildTiktokSkus(product, "P1", { warehouseId: "W" });
  assert.equal(skus.length, 2);
  assert.equal(skus[0].seller_sku, variantSkuFor("P1", product.variants[0], 0));
  assert.deepEqual(skus[0].sales_attributes, [{ name: "Member", value_name: "Jaemin" }]);
  assert.deepEqual(skus[0].price, { amount: "20.00", currency: "USD" });
  assert.deepEqual(skus[1].price, { amount: "25.00", currency: "USD" });
  assert.deepEqual(skus.map((s) => s.inventory[0]), [{ warehouse_id: "W", quantity: 3 }, { warehouse_id: "W", quantity: 3 }]);
});

test("buildTiktokSkus: per-variant stock uses each variant's own number", () => {
  const product = {
    listingPrice: 10, hasVariants: true, quantityVariesByVariant: true, options: [{ name: "Size" }],
    variants: [{ id: "s", sku: "S", optionValues: { Size: "S" }, quantity: 2 }, { id: "m", sku: "M", optionValues: { Size: "M" }, quantity: 0 }],
  };
  assert.deepEqual(L.buildTiktokSkus(product, "P", { warehouseId: "W" }).map((s) => s.inventory[0].quantity), [2, 0]);
});

test("createTiktokListingCore: uploads photos, picks + caches the warehouse, writes ids back", async () => {
  const db = new FakeFirestore();
  await db.doc(`users/${UID}/integrations/tiktok`).set({ isConnected: true });
  await db.collection("products").doc("P1").set({
    userId: UID, title: "Jaemin card", description: "d", listingPrice: 15, quantity: 1,
    images: ["https://x/a.jpg", "https://x/b.jpg"],
  });
  const client = fakeClient({
    "/product/202309/images/upload": () => ({ uri: `tos-${Math.random()}` }),
    "/logistics/202309/warehouses": { warehouses: [{ id: "W1", type: "SALES_WAREHOUSE", is_default: true }] },
    "/product/202309/products": { product_id: "TT1", skus: [{ id: "SKU1", seller_sku: "P1" }] },
  });
  const r = await L.createTiktokListingCore(db, UID, client, { productId: "P1", categoryId: "600001" }, { fetchBytesImpl: imageFetch });
  assert.deepEqual(r, { tiktokProductId: "TT1", categoryId: "600001" });

  const create = client.calls.find((c) => c.path === "/product/202309/products");
  const body = create.opts.body;
  assert.equal(body.category_id, "600001");
  assert.equal(body.main_images.length, 2);
  assert.equal(body.skus[0].inventory[0].warehouse_id, "W1");
  assert.equal(body.skus[0].seller_sku, "P1");
  assert.equal("attributes" in body, false);

  const p = db.peek("products", "P1");
  assert.equal(p.crossPostStatus.tiktok, "active");
  assert.equal(p.crossPostListingIds.tiktok, "TT1");
  assert.equal(p.tiktokSkuId, "SKU1");
  assert.equal(p.tiktokWarehouseId, "W1");
  assert.equal((await db.doc(`users/${UID}/integrations/tiktok`).get()).data().warehouseId, "W1");
});

test("createTiktokListingCore: variant SKU ids go back on the variants array (no dotted paths)", async () => {
  const db = new FakeFirestore();
  await db.doc(`users/${UID}/integrations/tiktok`).set({ isConnected: true, warehouseId: "W" });
  const variants = [{ id: "vA", sku: "A", optionValues: { Size: "S" } }, { id: "vB", sku: "B", optionValues: { Size: "M" } }];
  await db.collection("products").doc("P2").set({
    userId: UID, title: "Tee", listingPrice: 10, hasVariants: true, options: [{ name: "Size" }], variants, images: ["https://x/a.jpg"],
  });
  const client = fakeClient({
    "/product/202309/images/upload": { uri: "u" },
    "/product/202309/products": {
      product_id: "TT2",
      skus: [{ id: "S1", seller_sku: variantSkuFor("P2", variants[0], 0) }, { id: "S2", seller_sku: variantSkuFor("P2", variants[1], 1) }],
    },
  });
  await L.createTiktokListingCore(db, UID, client, { productId: "P2", categoryId: "1" }, { fetchBytesImpl: imageFetch });
  const p = db.peek("products", "P2");
  assert.ok(Array.isArray(p.variants));
  assert.deepEqual(p.variants.map((v) => v.tiktokSkuId), ["S1", "S2"]);
  assert.equal(p.variants[0].optionValues.Size, "S");
  assert.equal(client.calls.some((c) => c.path.startsWith("/logistics")), false, "cached warehouse reused");
});

test("createTiktokListingCore: no price fails before any upload; other users' products are refused", async () => {
  const db = new FakeFirestore();
  await db.collection("products").doc("P3").set({ userId: UID, title: "x", images: ["https://x/a.jpg"] });
  await db.collection("products").doc("P4").set({ userId: "other", listingPrice: 5 });
  const client = fakeClient();
  await assert.rejects(L.createTiktokListingCore(db, UID, client, { productId: "P3", categoryId: "1" }), /listing price/);
  assert.equal(client.calls.length, 0);
  await assert.rejects(L.createTiktokListingCore(db, UID, client, { productId: "P4", categoryId: "1" }), (e) => e.code === "permission-denied");
});

test("inventoryUpdateBody: shared pool → every SKU; per-variant → sold SKU; plain → its SKU", () => {
  const shared = {
    tiktokWarehouseId: "W", hasVariants: true, options: [{ name: "M" }],
    variants: [{ sku: "A", tiktokSkuId: "1" }, { sku: "B", tiktokSkuId: "2" }],
  };
  assert.deepEqual(L.inventoryUpdateBody(shared, { variantSku: "A", newQuantity: 4 }).skus.map((s) => [s.id, s.inventory[0].quantity]), [["1", 4], ["2", 4]]);
  const per = { ...shared, quantityVariesByVariant: true };
  assert.deepEqual(L.inventoryUpdateBody(per, { variantSku: "B", newQuantity: 0 }).skus.map((s) => s.id), ["2"]);
  assert.deepEqual(L.inventoryUpdateBody({ tiktokWarehouseId: "W", tiktokSkuId: "9" }, { newQuantity: 1 }),
    { skus: [{ id: "9", inventory: [{ warehouse_id: "W", quantity: 1 }] }] });
  assert.equal(L.inventoryUpdateBody({ tiktokSkuId: "9" }, { newQuantity: 1 }), null, "no warehouse → nothing to push");
});

test("pushTiktokQuantity: posts to the product's inventory endpoint; skips when nothing is mapped", async () => {
  const client = fakeClient();
  const r = await L.pushTiktokQuantity("u", { tiktokProductId: "TT", tiktokWarehouseId: "W", tiktokSkuId: "S" }, { newQuantity: 0 }, { client });
  assert.equal(r, "updated");
  assert.equal(client.calls[0].path, "/product/202309/products/TT/inventory/update");
  assert.equal(await L.pushTiktokQuantity("u", { tiktokProductId: "TT" }, { newQuantity: 0 }, { client }), "skipped");
});

test("deleteTiktokListingCore: deletes on TikTok and clears every TikTok field", async () => {
  const db = new FakeFirestore();
  await db.collection("products").doc("P").set({
    userId: UID, tiktokProductId: "TT", tiktokSkuId: "S", crossPostStatus: { tiktok: "active", ebay: "active" },
    crossPostListingIds: { tiktok: "TT" }, variants: [{ sku: "A", tiktokSkuId: "1" }],
  });
  const client = fakeClient();
  await L.deleteTiktokListingCore(db, UID, client, "P");
  assert.deepEqual(client.calls[0].opts.body, { product_ids: ["TT"] });
  const p = db.peek("products", "P");
  assert.equal(p.crossPostStatus.tiktok, undefined);
  assert.equal(p.crossPostStatus.ebay, "active");
  assert.equal(p.tiktokProductId, undefined);
  assert.equal(p.variants[0].tiktokSkuId, undefined);
});

test("security: photo downloads go through the SSRF-guarded fetchBytes and refuse non-images", async () => {
  const { fetchBytes } = require("../source_links");
  await assert.rejects(fetchBytes("http://169.254.169.254/computeMetadata/v1/"), /https|public|not allowed|blocked/i);
  await assert.rejects(fetchBytes("https://127.0.0.1/x.png"), /public|private|not allowed|blocked|loopback/i);
  const client = fakeClient({ "/product/202309/images/upload": { uri: "u" } });
  await assert.rejects(L.uploadImage(client, "https://x/a", async () => ({ buffer: Buffer.from("x"), contentType: "text/html" })), /not an image/);
  assert.equal(client.calls.length, 0);
});
