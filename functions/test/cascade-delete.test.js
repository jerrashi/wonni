"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal } = require("../cascade_delete");
const { livePlatforms, deleteProductEverywhereCore } = _internal;

const seed = (data) => {
  const db = new FakeFirestore({ products: { p1: { userId: "u1", title: "T", ...data } } });
  return db;
};
const recorder = (fail = {}) => {
  const calls = [];
  const mk = (name) => async (productId) => {
    calls.push(name);
    if (fail[name]) throw new Error(fail[name]);
  };
  return { calls, deleters: { ebay: mk("ebay"), etsy: mk("etsy"), tiktok: mk("tiktok") } };
};
const exists = async (db) => (await db.collection("products").doc("p1").get()).exists;

test("livePlatforms: reads crossPostStatus for every platform", () => {
  assert.deepEqual(livePlatforms({ crossPostStatus: { ebay: "active", etsy: "posted", tiktok: "active" } }).api.sort(), ["ebay", "etsy", "tiktok"]);
  assert.deepEqual(livePlatforms({ crossPostStatus: { ebay: "inactive", etsy: "", tiktok: "inactive" } }).api, []);
});

test("regression: a TikTok listing is live when crossPostStatus.tiktok is 'active' (web only checked the never-written tiktokStatus)", () => {
  assert.deepEqual(livePlatforms({ crossPostStatus: { tiktok: "active" } }).api, ["tiktok"]);
});

test("livePlatforms: a listing id with no status still counts; Mercari goes to manual", () => {
  const r = livePlatforms({ crossPostListingIds: { ebay: "123" }, crossPostStatus: { mercari: "active" } });
  assert.deepEqual(r.api, ["ebay"]);
  assert.deepEqual(r.manual, ["mercari"]);
  assert.deepEqual(livePlatforms({ variants: [{ mercariListingId: "m1" }] }).manual, ["mercari"]);
});

test("happy path: deletes every live platform, then the doc", async () => {
  const db = seed({ crossPostStatus: { ebay: "active", etsy: "active" } });
  const { calls, deleters } = recorder();
  const r = await deleteProductEverywhereCore({ db, uid: "u1", productId: "p1", deleters });
  assert.deepEqual(calls.sort(), ["ebay", "etsy"]);
  assert.deepEqual(r, { deleted: true, removedFrom: ["ebay", "etsy"], failed: [], manualRemoval: [] });
  assert.equal(await exists(db), false);
});

test("no live platforms: just deletes the doc", async () => {
  const db = seed({});
  const { calls, deleters } = recorder();
  const r = await deleteProductEverywhereCore({ db, uid: "u1", productId: "p1", deleters });
  assert.equal(calls.length, 0);
  assert.equal(r.deleted, true);
});

test("regression: a failing platform keeps the doc, reports the failure, and still removes the others", async () => {
  const db = seed({ crossPostStatus: { ebay: "active", etsy: "active", tiktok: "active" } });
  const { calls, deleters } = recorder({ etsy: "Etsy down" });
  const r = await deleteProductEverywhereCore({ db, uid: "u1", productId: "p1", deleters });
  assert.equal(calls.length, 3); // parallel: one failure doesn't stop the rest
  assert.equal(r.deleted, false);
  assert.deepEqual(r.removedFrom.sort(), ["ebay", "tiktok"]);
  assert.deepEqual(r.failed, [{ platform: "etsy", error: "Etsy down" }]);
  assert.equal(await exists(db), true);
});

test("Mercari is reported for manual removal and does not block the delete", async () => {
  const db = seed({ crossPostStatus: { mercari: "active" } });
  const { deleters } = recorder();
  const r = await deleteProductEverywhereCore({ db, uid: "u1", productId: "p1", deleters });
  assert.deepEqual(r.manualRemoval, ["mercari"]);
  assert.equal(r.deleted, true);
});

test("ownership: another user's product is permission-denied and untouched", async () => {
  const db = seed({ crossPostStatus: { ebay: "active" } });
  const { calls, deleters } = recorder();
  await assert.rejects(deleteProductEverywhereCore({ db, uid: "intruder", productId: "p1", deleters }), { code: "permission-denied" });
  assert.equal(calls.length, 0);
  assert.equal(await exists(db), true);
});

test("missing product is not-found", async () => {
  const db = new FakeFirestore({});
  const { deleters } = recorder();
  await assert.rejects(deleteProductEverywhereCore({ db, uid: "u1", productId: "nope", deleters }), { code: "not-found" });
});
