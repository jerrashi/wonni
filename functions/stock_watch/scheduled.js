/**
 * stock_watch/scheduled.js — scheduled poll of every watchedSources/{id} doc.
 *
 * For each watched source: watchStock() the current snapshot, diff it against
 * the last one on record (watchState/{platform}_{sourceId}), persist the new
 * snapshot, and write a notification doc for every non-empty diff. No UI /
 * push work here — a later phase reads these notification docs.
 */

"use strict";

const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const { watchStock } = require("./registry");
const { diffSnapshot } = require("./diff_snapshot");

function stateDocId(platform, sourceId) {
  return `${platform}_${sourceId}`;
}

async function pollWatchedSource(db, sourceDoc) {
  const source = sourceDoc.data();
  const { platform, url, userId } = source ?? {};
  if (!url) return;

  const current = await watchStock({ platform, url });
  const stateRef = db.collection("watchState").doc(stateDocId(current.platform, current.sourceId));
  const stateSnap = await stateRef.get();
  const previous = stateSnap.exists ? stateSnap.data() : null;

  const events = diffSnapshot(previous, current);

  await stateRef.set(current);

  if (events.length && userId) {
    const notifications = db.collection("users").doc(userId).collection("notifications");
    await Promise.all(
      events.map((event) =>
        notifications.add({
          type: event.type,
          platform: current.platform,
          sourceId: current.sourceId,
          url: current.url,
          title: current.title,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        })
      )
    );
  }
}

// Poll all watched sources every 30 minutes.
exports.watchStockSourcesScheduled = onSchedule(
  { schedule: "every 30 minutes", timeoutSeconds: 540, memory: "512MiB" },
  async () => {
    const db = admin.firestore();
    const snap = await db.collection("watchedSources").get();
    await Promise.allSettled(snap.docs.map((doc) => pollWatchedSource(db, doc)));
  }
);

module.exports.pollWatchedSource = pollWatchedSource;
module.exports.stateDocId = stateDocId;
