"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal } = require("../post_jobs");
const { enqueuePostJob, runPostJob } = _internal;

const seed = () => new FakeFirestore({ products: { p1: { userId: "u1", title: "Comic" } } });
const jobs = (db) => [...db.collections.get("postJobs").entries()].map(([id, d]) => ({ id, ...(d.data ?? d) }));

test("enqueue creates a queued job; a second call returns the in-flight one instead of starting another", async () => {
  const db = seed();
  const a = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  assert.equal(a.alreadyRunning, false);
  const b = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  assert.deepEqual(b, { jobId: a.jobId, alreadyRunning: true });
  const c = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "etsy" });
  assert.notEqual(c.jobId, a.jobId, "a different platform is its own job");
});

test("enqueue enforces ownership, existence and platform", async () => {
  const db = seed();
  await assert.rejects(enqueuePostJob({ db, uid: "other", productId: "p1", platform: "ebay" }), /Not your product/);
  await assert.rejects(enqueuePostJob({ db, uid: "u1", productId: "nope", platform: "ebay" }), /not found/i);
  await assert.rejects(enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "mercari" }), /Unsupported platform/);
});

test("a run writes progress after each listing and ends done", async () => {
  const db = seed();
  const { jobId } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  const runners = {
    ebay: async (uid, productId, opts) => {
      await opts.onProgress({ groupCount: 3, groups: [{ groupKey: "p1", listingId: "L1" }] });
      await opts.onProgress({ groupCount: 3, groups: [{ groupKey: "p1", listingId: "L1" }, { groupKey: "p1g2", listingId: "L2" }] });
      return { listingId: "L1" };
    },
  };
  assert.deepEqual(await runPostJob({ db, jobId, runners }), { status: "done" });
  const j = db.peek("postJobs", jobId);
  assert.equal(j.status, "done");
  assert.equal(j.groupsTotal, 3);
  assert.equal(j.groupsDone, 2);
  assert.deepEqual(j.doneGroupKeys, ["p1", "p1g2"]);
  assert.equal(j.listingId, "L1");
});

test("out of time budget → job 'partial' + a queued continuation carrying the finished listings", async () => {
  const db = seed();
  const { jobId } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "etsy" });
  let t = 0;
  const runners = {
    etsy: async (uid, productId, opts) => {
      t += 10_000;                       // pretend a listing took 10 s
      assert.equal(opts.shouldStop(), true, "budget is 5 s in this test");
      return { partial: true, groupCount: 3, groups: [{ groupKey: "p1", listingId: "E1" }] };
    },
  };
  const res = await runPostJob({ db, jobId, runners, clock: () => t, budgetMs: 5_000 });
  assert.equal(res.status, "partial");
  assert.equal(db.peek("postJobs", jobId).status, "partial");
  const next = db.peek("postJobs", res.continuedBy);
  assert.equal(next.status, "queued");
  assert.equal(next.chain, 1);
  assert.deepEqual(next.doneGroupKeys, ["p1"]);
  assert.equal(next.continues, jobId);
});

test("the continuation hands the already-finished listings to the runner so it skips them", async () => {
  const db = seed();
  const { jobId } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  let seenSkip;
  const first = await runPostJob({ db, jobId, runners: { ebay: async () => ({ partial: true, groupCount: 2, groups: [{ groupKey: "p1", listingId: "L1" }] }) } });
  await runPostJob({ db, jobId: first.continuedBy, runners: { ebay: async (u, p, opts) => { seenSkip = opts.skipGroupKeys; return { listingId: "L1" }; } } });
  assert.deepEqual(seenSkip, ["p1"]);
  assert.equal(db.peek("postJobs", first.continuedBy).status, "done");
});

test("a failing run is recorded with its error; the finished listings stay in doneGroupKeys", async () => {
  const db = seed();
  const { jobId } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  const res = await runPostJob({ db, jobId, runners: { ebay: async (u, p, opts) => {
    await opts.onProgress({ groupCount: 2, groups: [{ groupKey: "p1", listingId: "L1" }] });
    throw new Error("eBay 25002 bad aspect");
  } } });
  assert.equal(res.status, "failed");
  const j = db.peek("postJobs", jobId);
  assert.equal(j.status, "failed");
  assert.match(j.error, /25002/);
  assert.deepEqual(j.doneGroupKeys, ["p1"]);
  // after a failure a new job is allowed (resume = start again)
  const again = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  assert.equal(again.alreadyRunning, false);
});

test("a trigger redelivery never runs a finished job twice, and a chain is capped", async () => {
  const db = seed();
  const { jobId } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  let runs = 0;
  const runners = { ebay: async () => { runs++; return { listingId: "L" }; } };
  await runPostJob({ db, jobId, runners });
  const again = await runPostJob({ db, jobId, runners });
  assert.equal(runs, 1);
  assert.equal(again.skipped, true);

  const { jobId: j2 } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "etsy" });
  await db.collection("postJobs").doc(j2).set({ chain: 20 }, { merge: true });
  const capped = await runPostJob({ db, jobId: j2, runners: { etsy: async () => ({ partial: true, groupCount: 9, groups: [] }) } });
  assert.equal(capped.status, "failed");
});

test("a finished 'partial' parent does not block a later job, and a dead 'running' job goes stale", async () => {
  const db = seed();
  const { jobId } = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  const res = await runPostJob({ db, jobId, runners: { ebay: async () => ({ partial: true, groupCount: 2, groups: [{ groupKey: "p1", listingId: "L1" }] }) } });
  await runPostJob({ db, jobId: res.continuedBy, runners: { ebay: async () => ({ listingId: "L1" }) } });
  const fresh = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  assert.equal(fresh.alreadyRunning, false, "chain finished → new job allowed");

  await db.collection("postJobs").doc(fresh.jobId).set({ status: "running" }, { merge: true });
  const later = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay", clock: () => Date.now() + 20 * 60 * 1000 });
  assert.equal(later.alreadyRunning, false, "a 'running' job 20 min stale is ignored");
  const soon = await enqueuePostJob({ db, uid: "u1", productId: "p1", platform: "ebay" });
  assert.equal(soon.alreadyRunning, true);
});
