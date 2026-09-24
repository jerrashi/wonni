/**
 * weverse_order_tasks.js — the "re-buy this on Weverse to fulfill the sale"
 * backbone.
 *
 * ── What this is ────────────────────────────────────────────────────────
 * When a product sourced from Weverse (`product.source === "weverse"`)
 * sells on eBay/Etsy/Mercari/whatever, the user still has to go manually
 * re-purchase that same item on Weverse to actually fulfill the buyer's
 * order — Weverse has no seller/ordering API, so there is no automated way
 * to place that order. `createWeverseOrderTaskIfNeeded` is called from
 * `sales.js`'s `recordSaleCore` (best-effort, mirroring the cascade's
 * per-platform try/catch — see that file) and drops a
 * `weverseOrderTasks/{id}` doc that the extension polls
 * (`listWeverseOrderTasksCore`) and surfaces as a deep-link + manual
 * "mark as ordered" confirmation (`recordWeverseOrderPlacedCore`).
 *
 * ── What this is NOT ────────────────────────────────────────────────────
 * This module never touches Weverse itself — no add-to-cart, no checkout,
 * no payment. It only tracks the human's own re-order (order number + what
 * they paid) after the fact. See `extension/weverse_order_fill.js` for the
 * explicit, deliberately-unimplemented stub for a future cart-fill pass and
 * why that's out of scope here.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { validated } = require("./contracts");

/**
 * Best-effort: create a `weverseOrderTasks/{id}` doc when a Weverse-sourced
 * product just sold. Called from `sales.js` `recordSaleCore` inside a
 * try/catch — a failure here must never block or roll back the sale write.
 *
 * `product` is the pre-sale product doc (same one `recordSaleCore` already
 * fetched/ownership-checked). Returns the created task id, or null if this
 * product isn't Weverse-sourced (the common case — most sales skip this).
 */
async function createWeverseOrderTaskIfNeeded(db, uid, { product, productId, saleId, variantSku }) {
  if (!product || product.source !== "weverse") return null;

  const ref = db.collection("weverseOrderTasks").doc();
  await ref.set({
    userId: uid,
    productId,
    variantId: variantSku ?? null,
    saleId,
    weverseSaleId: product.weverseSaleId ?? null,
    weverseUrl: product.sourceUrl ?? null,
    listingTitle: product.title ?? null,
    thumbnailUrl: (Array.isArray(product.images) && product.images[0]) || null,
    status: "pending",
    orderNumber: null,
    costPaid: null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    orderedAt: null,
  });
  return ref.id;
}

/**
 * `recordWeverseOrderPlaced` core: the human confirms they manually placed
 * the re-order on Weverse. Verifies ownership, marks the task `ordered`, and
 * merges `costPaid` onto the linked `sales/{saleId}` doc as `actualCostPaid`
 * (see contracts/sales.js) so margin tracking has the real figure instead of
 * only the estimated `product.sourcePrice`.
 */
async function recordWeverseOrderPlacedCore(db, uid, { taskId, orderNumber, costPaid }) {
  const taskRef = db.collection("weverseOrderTasks").doc(taskId);
  const snap = await taskRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Weverse order task not found.");
  const task = snap.data();
  if (task.userId !== uid) throw new HttpsError("permission-denied", "Not your task.");

  const now = admin.firestore.FieldValue.serverTimestamp();
  await taskRef.set({
    status: "ordered",
    orderNumber,
    costPaid,
    orderedAt: now,
  }, { merge: true });

  // Best-effort mirror onto the sale doc — a missing/already-deleted sale
  // shouldn't fail the task update the user is actively confirming.
  if (task.saleId) {
    try {
      const saleRef = db.collection("sales").doc(task.saleId);
      const saleSnap = await saleRef.get();
      if (saleSnap.exists && saleSnap.data().userId === uid) {
        await saleRef.set({ actualCostPaid: costPaid, updatedAt: now }, { merge: true });
      }
    } catch (e) {
      console.error(`[recordWeverseOrderPlaced] failed to mirror costPaid onto sale ${task.saleId}:`, e.message);
    }
  }

  return { success: true };
}

/**
 * `listWeverseOrderTasks` core: this user's tasks, most-recent-first,
 * filtered to `status` (default "pending" — the extension's normal poll).
 *
 * Deliberately simple pagination: fetches this user's matching tasks
 * (`where` only — no `orderBy`, since sort happens here) up to a generous
 * internal cap, sorts by `createdAt` descending in JS, then windows by
 * `cursor` (a task id) + `limit`. Fine at the scale one user's outstanding
 * re-order tasks actually reach; a heavier user would want a real
 * `orderBy(createdAt).startAfter(cursor)` Firestore query + composite index
 * instead.
 */
async function listWeverseOrderTasksCore(db, uid, { status, limit, cursor }) {
  const effectiveStatus = status ?? "pending";
  const effectiveLimit = limit ?? 50;

  const snap = await db.collection("weverseOrderTasks")
    .where("userId", "==", uid)
    .where("status", "==", effectiveStatus)
    .limit(500)
    .get();

  const all = snap.docs
    .map((d) => ({ id: d.id, ...d.data() }))
    .sort((a, b) => tsMillis(b.createdAt) - tsMillis(a.createdAt));

  let startIndex = 0;
  if (cursor) {
    const idx = all.findIndex((t) => t.id === cursor);
    startIndex = idx === -1 ? 0 : idx + 1;
  }

  const page = all.slice(startIndex, startIndex + effectiveLimit);
  const nextCursor = startIndex + effectiveLimit < all.length ? page[page.length - 1]?.id ?? null : null;

  return { tasks: page, nextCursor };
}

/** Sortable millis from either a real Firestore Timestamp, a fake-firestore
 *  plain Date (see test/helpers/fake-firestore.js), or a missing value. */
function tsMillis(v) {
  if (!v) return 0;
  if (typeof v.toMillis === "function") return v.toMillis();
  if (v instanceof Date) return v.getTime();
  if (typeof v._seconds === "number") return v._seconds * 1000;
  return 0;
}

// ── Callables ────────────────────────────────────────────────────────────

exports.recordWeverseOrderPlaced = onCall(validated("recordWeverseOrderPlaced", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return recordWeverseOrderPlacedCore(admin.firestore(), uid, data);
}));

exports.listWeverseOrderTasks = onCall(validated("listWeverseOrderTasks", async (data, request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
  return listWeverseOrderTasksCore(admin.firestore(), uid, data);
}));

// Consumed directly by sales.js's recordSaleCore (best-effort, own try/catch there).
exports.createWeverseOrderTaskIfNeeded = createWeverseOrderTaskIfNeeded;

exports._internal = {
  createWeverseOrderTaskIfNeeded,
  recordWeverseOrderPlacedCore,
  listWeverseOrderTasksCore,
};
