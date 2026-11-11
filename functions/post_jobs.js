"use strict";

/**
 * Background posting jobs — a big product (hundreds of variants, split across
 * several eBay / Etsy listings) can outlast one callable, so it runs here:
 *
 *   client → startPostJob {productId, platform} → postJobs/{id} (queued)
 *     → onPostJobCreated trigger runs the platform's create core with a time
 *       budget, writing progress to the job doc after every listing
 *     → out of budget with listings left → job "partial" + a continuation job
 *       that skips the listings already live (chained, capped)
 *     → done | failed (error kept; "retry" = start a new job, which resumes
 *       from the product's saved pointers).
 *
 * The runner is plain functions over an injected db + runners, so it is tested
 * without the network (test/post-jobs.test.js).
 */

const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { validated } = require("./contracts");

const JOB_PLATFORMS = ["ebay", "etsy"];
const TRIGGER_TIMEOUT_S = 540;       // 2nd-gen event functions cap at 9 minutes
const BUDGET_MS = 400 * 1000;        // stop starting new listings after this
const MAX_CHAIN = 20;                // continuations per original job
// "partial" is a finished parent whose continuation job carries on — only the
// queued/running job counts as in flight. A "running" job untouched for longer
// than the trigger's timeout died with its instance, so it no longer blocks.
const ACTIVE = ["queued", "running"];
const STALE_MS = (TRIGGER_TIMEOUT_S + 120) * 1000;
const tsMs = (t) => (t?.toMillis ? t.toMillis() : t instanceof Date ? t.getTime() : 0);

const nowTs = () => admin.firestore.FieldValue.serverTimestamp();

/** Create (or return the in-flight) job for product+platform. */
async function enqueuePostJob({ db, uid, productId, platform, clock = Date.now }) {
  if (!JOB_PLATFORMS.includes(platform)) throw new HttpsError("invalid-argument", `Unsupported platform "${platform}".`);
  const pSnap = await db.collection("products").doc(productId).get();
  if (!pSnap.exists) throw new HttpsError("not-found", "Product not found.");
  if (pSnap.data().userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

  const existing = await db.collection("postJobs")
    .where("userId", "==", uid).where("productId", "==", productId).where("platform", "==", platform).get();
  const inFlight = existing.docs.find((d) => {
    const j = d.data();
    if (!ACTIVE.includes(j.status)) return false;
    return !(j.status === "running" && clock() - tsMs(j.updatedAt) > STALE_MS);
  });
  if (inFlight) return { jobId: inFlight.id, alreadyRunning: true };

  const ref = db.collection("postJobs").doc();
  await ref.set({
    userId: uid, productId, platform, status: "queued", chain: 0, doneGroupKeys: [],
    groupsTotal: null, groupsDone: 0, groups: [], error: null,
    createdAt: nowTs(), updatedAt: nowTs(),
  });
  return { jobId: ref.id, alreadyRunning: false };
}

/**
 * Run one job to completion, partial, or failure. `runners[platform]` is
 * `(uid, productId, {onProgress, shouldStop, skipGroupKeys}) → result`.
 */
async function runPostJob({ db, jobId, runners, clock = Date.now, budgetMs = BUDGET_MS }) {
  const ref = db.collection("postJobs").doc(jobId);
  const snap = await ref.get();
  if (!snap.exists) return { status: "missing" };
  const job = snap.data();
  if (job.status !== "queued") return { status: job.status, skipped: true }; // a retry of the trigger

  const started = clock();
  await ref.set({ status: "running", startedAt: nowTs(), updatedAt: nowTs() }, { merge: true });

  const runner = runners[job.platform];
  if (!runner) {
    await ref.set({ status: "failed", error: `No runner for ${job.platform}`, updatedAt: nowTs() }, { merge: true });
    return { status: "failed" };
  }

  const progress = async ({ groupCount, groups }) => {
    await ref.set({
      groupsTotal: groupCount, groupsDone: groups.length, groups,
      doneGroupKeys: groups.map((g) => g.groupKey), updatedAt: nowTs(),
    }, { merge: true });
  };

  try {
    const result = await runner(job.userId, job.productId, {
      onProgress: progress,
      shouldStop: () => clock() - started > budgetMs,
      skipGroupKeys: job.doneGroupKeys || [],
    });

    if (result?.partial) {
      const done = (result.groups || result.listings || []).map((g) => g.groupKey);
      if ((job.chain || 0) >= MAX_CHAIN) {
        await ref.set({ status: "failed", error: "Too many continuations — retry to resume.", updatedAt: nowTs() }, { merge: true });
        return { status: "failed" };
      }
      const next = db.collection("postJobs").doc();
      await next.set({
        userId: job.userId, productId: job.productId, platform: job.platform, status: "queued",
        chain: (job.chain || 0) + 1, continues: jobId, doneGroupKeys: done,
        groupsTotal: result.groupCount ?? job.groupsTotal ?? null, groupsDone: done.length,
        groups: result.groups || result.listings || [], error: null,
        createdAt: nowTs(), updatedAt: nowTs(),
      });
      await ref.set({ status: "partial", continuedBy: next.id, updatedAt: nowTs() }, { merge: true });
      return { status: "partial", continuedBy: next.id };
    }

    await ref.set({
      status: "done", error: null,
      listingId: result?.listingId ?? null,
      finishedAt: nowTs(), updatedAt: nowTs(),
    }, { merge: true });
    return { status: "done" };
  } catch (e) {
    console.error(`[postJob ${jobId}] ${job.platform} ${job.productId}: ${e.message}`);
    await ref.set({ status: "failed", error: String(e.message || e).slice(0, 500), updatedAt: nowTs() }, { merge: true });
    return { status: "failed", error: e.message };
  }
}

function realRunners() {
  return {
    ebay: (uid, productId, opts) => require("./ebay_listing")._internal.ebayCreateListingCore(uid, productId, opts),
    etsy: (uid, productId, opts) => require("./etsy_listing")._internal.etsyCreateListingCore(uid, { productId, ...opts }),
  };
}

exports.startPostJob = onCall(
  { timeoutSeconds: 30 },
  validated("startPostJob", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return enqueuePostJob({ db: admin.firestore(), uid, productId: data.productId, platform: data.platform });
  }),
);

// The worker. Secrets: eBay posting needs the eBay keyset + Gemini (the inline
// field-fill); Etsy reads Secret Manager directly.
exports.onPostJobCreated = onDocumentCreated(
  {
    document: "postJobs/{jobId}",
    secrets: [
      require("./ebay_auth").EBAY_CLIENT_ID,
      require("./ebay_auth").EBAY_CLIENT_SECRET,
      require("./listing_fields").geminiApiKey,
    ],
    timeoutSeconds: TRIGGER_TIMEOUT_S,
    memory: "512MiB",
  },
  async (event) => runPostJob({ db: admin.firestore(), jobId: event.params.jobId, runners: realRunners() }),
);

exports._internal = { enqueuePostJob, runPostJob, JOB_PLATFORMS, ACTIVE };
