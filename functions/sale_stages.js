/**
 * sale_stages.js — the user-editable kanban/spreadsheet bucket list that
 * `sale.status` now points into.
 *
 * See docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §1. Stored
 * at `users/{uid}.saleStages`; seeded lazily with BUILT_IN_SALE_STAGES on
 * first read/write for a user who's never touched it.
 *
 * The 6 built-in keys are permanent: a user can rename their `label`, add/
 * remove/reorder custom buckets around them, but never delete or repurpose
 * a built-in `key`. That's what lets `EXCLUDED_STATUSES` in sales_metrics.js
 * and the poller's `SALE_STATUS_ORDER`/`SALE_STATUS_TERMINAL` (sales.js) keep
 * matching on the literal strings without needing to know a user's config —
 * those keys are guaranteed to always exist.
 */

/**
 * Default board, seeded for every user until they customize it. Order here
 * is the default column/dropdown order.
 *
 * Keys are the LITERAL values `sale.status` already holds — `sales.js`'s
 * `SALE_STATUS_ORDER`/`SALE_STATUS_TERMINAL`, `resolveEbayStatus()` /
 * the Etsy status ternary (`sale_poller.js`), and the web `Sales.jsx` status
 * chips all write/read these exact strings today. Using different-looking
 * built-in keys (e.g. "ready_to_ship" for what's actually written as
 * "pending") would make every freshly-recorded sale land on a status that
 * doesn't match any of the user's own saleStages — caught before shipping
 * the board UI (docs/specs/2026-09-11-stage-board-and-revenue-accounting.md
 * §1/§6). Only the LABELS are free to read however's friendliest; the key
 * must stay the wire value.
 */
const BUILT_IN_SALE_STAGES = [
  { key: "pending", label: "Ready to Ship", builtIn: true },
  { key: "shipped", label: "In Transit", builtIn: true },
  { key: "delivered", label: "Delivered", builtIn: true },
  { key: "complete", label: "Completed", builtIn: true },
  { key: "cancelled", label: "Cancelled", builtIn: true },
  { key: "returned", label: "Returned", builtIn: true },
];

const BUILT_IN_KEYS = new Set(BUILT_IN_SALE_STAGES.map((s) => s.key));

/** Read a user's configured stages, falling back to the built-in defaults
 *  when they haven't customized (or don't exist yet). Never writes. */
async function loadSaleStages(db, uid) {
  const snap = await db.collection("users").doc(uid).get();
  const stored = snap.exists ? snap.data()?.saleStages : null;
  return Array.isArray(stored) && stored.length > 0 ? stored : BUILT_IN_SALE_STAGES;
}

/**
 * Validate a full replacement stage list before it's persisted. Throws a
 * plain Error with a user-facing message on any violation; callers wrap it
 * as `invalid-argument`.
 */
function validateSaleStages(stages) {
  if (!Array.isArray(stages) || stages.length === 0) {
    throw new Error("saleStages must be a non-empty array.");
  }

  const seenKeys = new Set();
  for (const stage of stages) {
    if (!stage || typeof stage.key !== "string" || !stage.key.trim()) {
      throw new Error("Every stage needs a non-empty key.");
    }
    if (typeof stage.label !== "string" || !stage.label.trim()) {
      throw new Error(`Stage "${stage.key}" needs a non-empty label.`);
    }
    if (seenKeys.has(stage.key)) {
      throw new Error(`Duplicate stage key "${stage.key}".`);
    }
    seenKeys.add(stage.key);
    if (BUILT_IN_KEYS.has(stage.key) && stage.builtIn !== true) {
      throw new Error(`"${stage.key}" is a built-in stage and must stay marked built-in.`);
    }
  }

  for (const key of BUILT_IN_KEYS) {
    if (!seenKeys.has(key)) {
      throw new Error(`Built-in stage "${key}" cannot be removed (rename its label instead).`);
    }
  }

  return true;
}

module.exports = { BUILT_IN_SALE_STAGES, BUILT_IN_KEYS, loadSaleStages, validateSaleStages };
