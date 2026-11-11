/**
 * etsy-split.test.js — one Wonni product across several Etsy listings
 * (Etsy caps a listing at 70 / 400 / 4,900 variant combinations).
 */
"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { FakeFirestore } = require("./helpers/fake-firestore");
const { planEtsyListings, etsyGroupLimit } = require("../etsy_inventory");
const { _internal } = require("../etsy_listing");
const { syncEtsyGroups, planForProduct } = _internal;

const issues = (n) => Array.from({ length: n }, (_, i) => ({ i, v: { id: `v${i}`, optionValues: { Issue: `#${i}` }, quantity: 1 } }));
const grid = (a, b, fn = () => ({})) => {
  const out = []; let i = 0;
  for (let s = 0; s < a; s++) for (let n = 0; n < b; n++) out.push({ i: i++, v: { id: `v${i}`, optionValues: { Series: `S${s}`, Issue: `#${n}` }, quantity: 1, ...fn(s, n) } });
  return out;
};

test("one variation type: 150 issues → listings of 70 / 70 / 10", () => {
  const plan = planEtsyListings(issues(150), [{ name: "Issue" }], { productId: "p1" });
  assert.deepEqual(plan.map((g) => g.items.length), [70, 70, 10]);
  assert.deepEqual(plan.map((g) => g.key), ["p1", "p1g2", "p1g3"]);
});

test("two types, shared quantity at one price: 600 combinations fit ONE listing (4,900 mode)", () => {
  const plan = planEtsyListings(grid(30, 20), [{ name: "Series" }, { name: "Issue" }], { productId: "p1", sharedQuantity: 3 });
  assert.equal(plan.length, 1);
});

test("two types where quantity differs per combination: the 400 limit splits 600 into two listings, a series staying whole", () => {
  const items = grid(30, 20, (s, n) => ({ quantity: (s + n) % 3 }));
  const plan = planEtsyListings(items, [{ name: "Series" }, { name: "Issue" }], { productId: "p1" });
  assert.deepEqual(plan.map((g) => g.items.length), [400, 200]);
  const seriesGroups = new Map();
  for (const g of plan) for (const it of g.items) seriesGroups.set(it.v.optionValues.Series, (seriesGroups.get(it.v.optionValues.Series) ?? new Set()).add(g.key));
  assert.ok([...seriesGroups.values()].every((s) => s.size === 1));
});

test("etsyGroupLimit: 70 / 400 / 4,900 by shape", () => {
  assert.equal(etsyGroupLimit(issues(3).map((x) => x.v)), 70);
  assert.equal(etsyGroupLimit(grid(2, 2).map((x) => x.v), 10, { sharedQuantity: 1 }), 4900);
  assert.equal(etsyGroupLimit(grid(2, 2, (s) => ({ price: 10 + s })).map((x) => x.v)), 400);
});

test("a legacy posted product keeps its variants on the first listing", () => {
  const items = issues(60);
  const plan = planEtsyListings(items, [{ name: "Issue" }], { productId: "p1", legacyPosted: true });
  assert.equal(plan.length, 1);
  assert.equal(plan[0].key, "p1");
});

// ── syncEtsyGroups against a fake Etsy ──────────────────────────────────────

function fakeEtsy(existing = {}) {
  const listings = new Map(Object.entries(existing));
  const log = [];
  let next = 9000;
  globalThis.fetch = async (url, opts = {}) => {
    const path = String(url).replace("https://openapi.etsy.com", "");
    const method = opts.method || "GET";
    const body = opts.body ? JSON.parse(opts.body) : undefined;
    log.push({ method, path, body });
    const json = (status, data) => ({ status, ok: status < 300, text: async () => JSON.stringify(data) });
    let m;
    if (method === "POST" && /\/shops\/S\/listings$/.test(path)) {
      const id = String(next++); listings.set(id, { state: "draft", inventory: null, ...body }); return json(201, { listing_id: id });
    }
    if ((m = path.match(/^\/v3\/application\/listings\/(\d+)\/inventory$/)) && method === "PUT") {
      listings.get(m[1]).inventory = body; return json(200, {});
    }
    if ((m = path.match(/^\/v3\/application\/listings\/(\d+)$/)) && method === "GET") {
      const l = listings.get(m[1]); return l ? json(200, { listing_id: m[1], state: l.state }) : json(404, {});
    }
    if ((m = path.match(/shops\/S\/listings\/(\d+)$/)) && method === "PATCH") {
      const l = listings.get(m[1]); if (!l) return json(404, {});
      Object.assign(l, body); return json(200, {});
    }
    return json(200, {});
  };
  return { listings, log };
}

const AUTH = { shopId: "S", accessToken: "t", clientId: "c" };
const DATA = { shippingProfileId: 1, returnPolicyId: 2, taxonomyId: 3, whenMade: "2020_2026", whoMade: "someone_else", isSupply: true };

function bigProduct(extra = {}) {
  const variants = issues(150).map((x) => x.v);
  return { userId: "u", title: "Comic Run", listingPrice: 5, options: [{ name: "Issue" }], variants, quantityVariesByVariant: true, images: ["x"], ...extra };
}

test("creates one Etsy listing per group, titles 'Part N of M', every variant tagged with its listing, doc written", async () => {
  const etsy = fakeEtsy();
  const db = new FakeFirestore({ products: { p1: bigProduct() } });
  const ref = db.collection("products").doc("p1");
  const product = db.peek("products", "p1");
  const plan = planForProduct(product, "p1", 5);
  assert.equal(plan.length, 3);

  const listings = await syncEtsyGroups(
    { ref, product, productId: "p1", plan, auth: AUTH, price: 5, readinessStateId: null, data: DATA },
    { upload: async () => 1 },
  );
  assert.equal(listings.length, 3);
  const doc = db.peek("products", "p1");
  assert.equal(doc.etsyListingId, listings[0].listingId);
  assert.equal(doc.etsyListings.length, 3);
  assert.equal(doc.crossPostStatus.etsy, "active");
  assert.equal(doc.variants.filter((v) => v.etsyGroupKey === "p1").length, 70);
  assert.equal(doc.variants.filter((v) => v.etsyGroupKey === "p1g3").length, 10);
  const titles = [...etsy.listings.values()].map((l) => l.title);
  assert.deepEqual(titles, ["Comic Run - Part 1 of 3", "Comic Run - Part 2 of 3", "Comic Run - Part 3 of 3"]);
  assert.ok([...etsy.listings.values()].every((l) => l.state === "active"));
  assert.deepEqual([...etsy.listings.values()].map((l) => l.inventory.products.length), [70, 70, 10]);
});

test("a second run updates the existing listings in place (no new listings) and creates one for a newly added overflow variant", async () => {
  const etsy = fakeEtsy();
  const db = new FakeFirestore({ products: { p1: bigProduct() } });
  const ref = db.collection("products").doc("p1");
  let product = db.peek("products", "p1");
  await syncEtsyGroups({ ref, product, productId: "p1", plan: planForProduct(product, "p1", 5), auth: AUTH, price: 5, readinessStateId: null, data: DATA }, { upload: async () => 1 });
  assert.equal(etsy.listings.size, 3);

  product = db.peek("products", "p1");
  product.variants = [...product.variants, ...Array.from({ length: 61 }, (_, k) => ({ id: `n${k}`, optionValues: { Issue: `#new${k}` }, quantity: 1 }))];
  const plan = planForProduct(product, "p1", 5);
  await syncEtsyGroups({ ref, product, productId: "p1", plan, auth: AUTH, price: 5, readinessStateId: null, data: DATA }, { upload: async () => 1 });
  assert.equal(etsy.listings.size, 4, "10 + 61 > 70 → exactly one new listing");
  assert.equal(db.peek("products", "p1").etsyListings.length, 4);
});

test("a small product is not split (single listing path stays as it was)", () => {
  const p = bigProduct({ variants: issues(5).map((x) => x.v) });
  assert.equal(planForProduct(p, "p1", 5), null);
});
