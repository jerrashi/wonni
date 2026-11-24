const test = require("node:test");
const assert = require("node:assert/strict");
const { pushProductEditsCore } = require("../push_product_edits.js")._internal;
const { tiktokEditBodies } = require("../tiktok_listing.js")._internal;

const dbWith = (product) => ({
  collection: () => ({ doc: () => ({ get: async () => ({ exists: !!product, data: () => product }) }) }),
});
const recorder = (failOn = []) => {
  const calls = [];
  const fn = (p) => async (id) => { calls.push(`${p}:${id}`); if (failOn.includes(p)) throw new Error(`${p} said no`); };
  return { calls, updaters: { ebay: fn("ebay"), etsy: fn("etsy"), tiktok: fn("tiktok") } };
};

test("pushes to every live platform; Mercari is reported, not pushed", async () => {
  const { calls, updaters } = recorder();
  const product = { userId: "u", crossPostStatus: { ebay: "active", etsy: "active", tiktok: "active", mercari: "active" } };
  const r = await pushProductEditsCore({ db: dbWith(product), uid: "u", productId: "p1", updaters });
  assert.deepEqual(r, { updated: ["ebay", "etsy", "tiktok"], failed: [], manualUpdate: ["mercari"] });
  assert.deepEqual(calls, ["ebay:p1", "etsy:p1", "tiktok:p1"]);
});

test("a product live nowhere makes no platform calls", async () => {
  const { calls, updaters } = recorder();
  const r = await pushProductEditsCore({ db: dbWith({ userId: "u" }), uid: "u", productId: "p1", updaters });
  assert.deepEqual(r, { updated: [], failed: [], manualUpdate: [] });
  assert.equal(calls.length, 0);
});

test("one platform failing still updates the others", async () => {
  const { updaters } = recorder(["etsy"]);
  const product = { userId: "u", crossPostStatus: { ebay: "active", etsy: "active" } };
  const r = await pushProductEditsCore({ db: dbWith(product), uid: "u", productId: "p1", updaters });
  assert.deepEqual(r.updated, ["ebay"]);
  assert.deepEqual(r.failed, [{ platform: "etsy", error: "etsy said no" }]);
});

test("someone else's product is refused", async () => {
  const { updaters } = recorder();
  await assert.rejects(
    pushProductEditsCore({ db: dbWith({ userId: "other" }), uid: "u", productId: "p1", updaters }),
    /Not your product/,
  );
});

test("tiktokEditBodies: text + package, prices only for SKUs with a TikTok id", () => {
  const plain = tiktokEditBodies({ title: "Scarf", description: "Wool", listingPrice: 45, tiktokSkuId: "sku9", weightLbs: 1 });
  assert.equal(plain.edit.title, "Scarf");
  assert.equal(plain.edit.package_weight.unit, "POUND");
  assert.deepEqual(plain.prices, { skus: [{ id: "sku9", price: { amount: "45.00", currency: "USD" } }] });

  const multi = tiktokEditBodies({
    title: "Tee", listingPrice: 30, hasVariants: true, options: [{ name: "Size" }],
    variants: [{ tiktokSkuId: "a", price: 35 }, { tiktokSkuId: "b" }, { price: 99 }, { tiktokSkuId: "c", active: false }],
  });
  assert.deepEqual(multi.prices.skus.map((s) => [s.id, s.price.amount]), [["a", "35.00"], ["b", "30.00"]]);

  assert.equal(tiktokEditBodies({ title: "x", listingPrice: 5 }).prices, null);
});
