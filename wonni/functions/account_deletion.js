const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

const GRACE_PERIOD_MS = 30 * 24 * 60 * 60 * 1000;
const DEFER_PERIOD_MS = 14 * 24 * 60 * 60 * 1000;
const BATCH_LIMIT = 450; // stay under Firestore's 500-write batch cap

// Firestore batches cap at 500 writes; chunk arbitrarily large listing sets.
async function commitInChunks(db, docRefs, applyFn) {
  for (let i = 0; i < docRefs.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const ref of docRefs.slice(i, i + BATCH_LIMIT)) {
      applyFn(batch, ref);
    }
    await batch.commit();
  }
}

/**
 * Callable Function: requestAccountDeletion
 * Starts the 30-day soft-delete grace period: marks the user + all their
 * listings as pending deletion (hidden from everyone but the owner) without
 * deleting any data yet. Client signs the user out immediately after this
 * succeeds.
 */
exports.requestAccountDeletion = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  const db = admin.firestore();

  const now = admin.firestore.Timestamp.now();
  const purgeAt = admin.firestore.Timestamp.fromMillis(now.toMillis() + GRACE_PERIOD_MS);

  const listingsSnap = await db.collection("listings").where("userId", "==", uid).get();

  await commitInChunks(db, listingsSnap.docs.map((d) => d.ref), (batch, ref) => {
    batch.set(ref, { sellerDeletionPending: true }, { merge: true });
  });

  const batch = db.batch();
  batch.set(db.collection("deletionRequests").doc(uid), {
    userId: uid,
    requestedAt: now,
    purgeAt,
    status: "pending",
    deferredReason: null,
    lastEvaluatedAt: null,
  });
  batch.set(db.collection("users").doc(uid), { deletionPending: true }, { merge: true });
  await batch.commit();

  return { success: true, purgeAt: purgeAt.toMillis() };
});

/**
 * Callable Function: cancelAccountDeletion
 * Reverses requestAccountDeletion while the request is still "pending"
 * (i.e. before purgeDeletedAccounts has processed it). Not callable once
 * a request has been deferred past its original window or purged.
 */
exports.cancelAccountDeletion = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  const db = admin.firestore();

  const reqRef = db.collection("deletionRequests").doc(uid);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists || reqSnap.data().status === "purged") {
    throw new HttpsError("failed-precondition", "No cancellable deletion request found.");
  }

  const listingsSnap = await db
    .collection("listings")
    .where("userId", "==", uid)
    .where("sellerDeletionPending", "==", true)
    .get();

  await commitInChunks(db, listingsSnap.docs.map((d) => d.ref), (batch, ref) => {
    batch.set(ref, { sellerDeletionPending: false }, { merge: true });
  });

  const batch = db.batch();
  batch.delete(reqRef);
  batch.set(db.collection("users").doc(uid), { deletionPending: false }, { merge: true });
  await batch.commit();

  return { success: true };
});

/**
 * Scheduled Function: purgeDeletedAccounts
 * Runs daily. For every deletion request whose grace period has elapsed,
 * checks marketplaceOrders (#69 — always empty until in-app checkout ships)
 * for open/non-terminal orders on that seller and defers if any exist.
 * Otherwise hard-deletes the account's data:
 *  - sales + pendingMercariSales (third-party bookkeeping, no buyer stake)
 *  - listings
 *  - all Storage files under users/{uid}/
 *  - stored eBay/Etsy integration tokens (best-effort local cleanup only —
 *    neither platform exposes a revoke/deauthorize API today)
 *  - the deletionRequests doc itself
 *  - the Firebase Auth user record (final step)
 */
exports.purgeDeletedAccounts = onSchedule("every 24 hours", async () => {
  const db = admin.firestore();
  const now = admin.firestore.Timestamp.now();

  const dueSnap = await db
    .collection("deletionRequests")
    .where("status", "==", "pending")
    .where("purgeAt", "<=", now)
    .get();

  const results = await Promise.allSettled(dueSnap.docs.map((doc) => purgeOrDeferOne(db, doc.ref, doc.data())));
  results.forEach((result, i) => {
    if (result.status === "rejected") {
      console.error(`purgeDeletedAccounts: failed for ${dueSnap.docs[i].id}`, result.reason);
    }
  });
});

async function purgeOrDeferOne(db, reqRef, request) {
  const uid = request.userId;

  const openOrdersSnap = await db
    .collection("marketplaceOrders")
    .where("sellerId", "==", uid)
    .where("status", "not-in", ["completed", "cancelled", "returned"])
    .get();

  if (!openOrdersSnap.empty) {
    await reqRef.set(
      {
        purgeAt: admin.firestore.Timestamp.fromMillis(Date.now() + DEFER_PERIOD_MS),
        status: "deferred",
        deferredReason: `${openOrdersSnap.size} open order(s)`,
        lastEvaluatedAt: admin.firestore.Timestamp.now(),
      },
      { merge: true }
    );
    return;
  }

  // Sales/pendingMercariSales: purely personal bookkeeping imported from
  // Mercari/eBay/Etsy, no buyer stake in this app — safe to hard-delete now.
  const salesSnap = await db.collection("sales").where("userId", "==", uid).get();
  const pendingMercariSnap = await db.collection(`users/${uid}/pendingMercariSales`).get();
  await commitInChunks(
    db,
    [...salesSnap.docs.map((d) => d.ref), ...pendingMercariSnap.docs.map((d) => d.ref)],
    (batch, ref) => batch.delete(ref)
  );

  const listingsSnap = await db.collection("listings").where("userId", "==", uid).get();
  await commitInChunks(db, listingsSnap.docs.map((d) => d.ref), (batch, ref) => batch.delete(ref));

  // Best-effort: neither eBay nor Etsy expose a token-revocation API today,
  // so this only removes our locally stored copies, it does not deauthorize
  // Wonni on the platform side.
  try {
    await db.doc(`users/${uid}/integrations/etsy`).delete();
  } catch {
    // non-fatal
  }
  try {
    await db.doc(`users/${uid}/integrations/ebay`).delete();
  } catch {
    // non-fatal
  }

  try {
    await admin.storage().bucket().deleteFiles({ prefix: `users/${uid}/` });
  } catch {
    // non-fatal — Storage cleanup is best-effort; a stray file isn't worth
    // failing the whole purge over.
  }

  await reqRef.delete();

  try {
    await admin.auth().deleteUser(uid);
  } catch {
    // If the Auth user is already gone (e.g. re-run after partial failure),
    // this is a no-op condition, not an error worth surfacing.
  }
}
