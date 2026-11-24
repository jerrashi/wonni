/**
 * tiktok-category.test.js — category recommendation, required attributes, rules.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const C = require("../tiktok_category");
const { _internal: L } = require("../tiktok_listing");

const ATTRS = [
  { id: "1", name: "Brand", type: "PRODUCT_PROPERTY", is_requried: true, is_customizable: true, values: [{ id: "b1", name: "SM Entertainment" }] },
  { id: "2", name: "Material", type: "PRODUCT_PROPERTY", is_required: true, values: [{ id: "m1", name: "Paper" }, { id: "m9", name: "Other" }] },
  { id: "3", name: "Theme", type: "PRODUCT_PROPERTY", is_requried: false, values: [{ id: "t1", name: "K-pop" }] },
  { id: "4", name: "Warranty", type: "PRODUCT_PROPERTY", is_requried: true, values: [{ id: "w1", name: "1 year" }] },
  { id: "5", name: "Color", type: "SALES_PROPERTY", is_requried: true, values: [] },
];

test("buildProductAttributes: listed match, customizable free text, neutral fallback, missing list", () => {
  const product = { brand: "SM Entertainment", itemSpecifics: { Character: "K-pop", Material: ["Cardstock"] } };
  const { attributes, missing } = C.buildProductAttributes(ATTRS, product);
  assert.deepEqual(attributes, [
    { id: "1", values: [{ id: "b1", name: "SM Entertainment" }] },
    { id: "2", values: [{ id: "m9", name: "Other" }] },          // "Cardstock" isn't listed, not customizable → Other
    { id: "3", values: [{ id: "t1", name: "K-pop" }] },           // optional, matched through the Character alias
  ]);
  assert.deepEqual(missing, ["Warranty"], "sales properties are the SKU builder's, never 'missing'");
});

test("buildProductAttributes: a customizable attribute takes the product's own words", () => {
  const { attributes } = C.buildProductAttributes([ATTRS[0]], { brand: "Pitaka" });
  assert.deepEqual(attributes, [{ id: "1", values: [{ name: "Pitaka" }] }]);
});

test("unmetRules + categoryProblem: certifications and size charts are reported in plain words", () => {
  const unmet = C.unmetRules({ product_certifications: [{ name: "CPC", is_required: true }, { name: "x", is_required: false }], size_chart: { is_required: true } });
  assert.deepEqual(unmet, ["a certification (CPC)", "a size chart"]);
  assert.match(C.categoryProblem({ missing: ["Warranty"], unmet }), /Warranty.*Item specifics.*certification \(CPC\) and a size chart/);
  assert.equal(C.categoryProblem({ missing: [], unmet: [] }), null);
});

function client(responses) {
  const calls = [];
  return {
    calls,
    async request(method, path, opts = {}) {
      calls.push({ method, path, opts });
      for (const [k, v] of Object.entries(responses)) if (path === k || path.startsWith(k)) return typeof v === "function" ? v(opts) : v;
      return {};
    },
  };
}

test("resolveTiktokCategory: pick > remembered > recommended", async () => {
  const c = client({
    "/product/202309/categories/recommend": { leaf_category_id: "900", categories: [{ name: "Collectibles" }, { name: "Photocards", is_leaf: true }] },
    "/product/202309/categories/": { attributes: [] },
  });
  assert.equal((await C.resolveTiktokCategory(c, { tiktokCategoryId: "5" }, { categoryId: "7" })).categoryId, "7");
  assert.equal((await C.resolveTiktokCategory(c, { tiktokCategoryId: "5" })).categoryId, "5");
  const r = await C.resolveTiktokCategory(c, { title: "Jaemin photocard" });
  assert.deepEqual([r.categoryId, r.path, r.recommended], ["900", "Collectibles > Photocards", true]);
  assert.equal(c.calls.find((x) => x.path.endsWith("/recommend")).opts.body.product_title, "Jaemin photocard");
});

test("createTiktokListingCore: no category → recommended one, attributes sent, category remembered", async () => {
  const db = new FakeFirestore();
  await db.doc("users/u/integrations/tiktok").set({ isConnected: true, warehouseId: "W" });
  await db.collection("products").doc("P").set({
    userId: "u", title: "Jaemin card", listingPrice: 12, quantity: 1, brand: "SM Entertainment", images: ["https://x/a.jpg"],
  });
  const c = client({
    "/product/202309/categories/recommend": { leaf_category_id: "900" },
    "/product/202309/categories/900/attributes": { attributes: [ATTRS[0]] },
    "/product/202309/images/upload": { uri: "u1" },
    "/product/202309/products": { product_id: "TT", skus: [{ id: "S", seller_sku: "P" }] },
  });
  const r = await L.createTiktokListingCore(db, "u", c, { productId: "P" },
    { fetchBytesImpl: async () => ({ buffer: Buffer.from([1]), contentType: "image/jpeg" }) });
  assert.deepEqual(r, { tiktokProductId: "TT", categoryId: "900" });
  const body = c.calls.find((x) => x.path === "/product/202309/products").opts.body;
  assert.equal(body.category_id, "900");
  assert.deepEqual(body.product_attributes, [{ id: "1", values: [{ id: "b1", name: "SM Entertainment" }] }]);
  assert.equal(db.peek("products", "P").tiktokCategoryId, "900");
});

test("createTiktokListingCore: a required field Wonni can't fill stops the post before any photo upload", async () => {
  const db = new FakeFirestore();
  await db.collection("products").doc("P").set({ userId: "u", title: "x", listingPrice: 5, images: ["https://x/a.jpg"] });
  const c = client({ "/product/202309/categories/1/attributes": { attributes: [ATTRS[3]] } });
  await assert.rejects(L.createTiktokListingCore(db, "u", c, { productId: "P", categoryId: "1" }),
    (e) => e.code === "failed-precondition" && /Warranty/.test(e.message));
  assert.equal(c.calls.some((x) => x.path.includes("images")), false);
});

test("suggestTiktokCategoryCore: preview for the picker", async () => {
  const db = new FakeFirestore({ products: { P: { userId: "u", title: "Tee" } } });
  const c = client({
    "/product/202309/categories/recommend": { leaf_category_id: "42", categories: [{ name: "Tops" }] },
    "/product/202309/categories/42/attributes": { attributes: ATTRS },
  });
  const r = await L.suggestTiktokCategoryCore(db, "u", c, { productId: "P" });
  assert.equal(r.categoryId, "42");
  assert.equal(r.recommended, true);
  assert.deepEqual(r.missing, ["Brand", "Warranty"]);
  assert.match(r.problem, /Brand, Warranty/);
  await assert.rejects(L.suggestTiktokCategoryCore(db, "intruder", c, { productId: "P" }), (e) => e.code === "not-found");
});
