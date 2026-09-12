// Mirrors functions/sale_stages.js's BUILT_IN_SALE_STAGES — kept in sync by
// hand (this is UI-default data, not a wire contract, so it isn't codegen'd).
// Keys are the LITERAL `sale.status` values written elsewhere (sales.js
// SALE_STATUS_ORDER/SALE_STATUS_TERMINAL, resolveEbayStatus()/the Etsy status
// ternary in sale_poller.js) — only the labels are free to read however's
// friendliest. See docs/specs/2026-09-11-stage-board-and-revenue-accounting.md.
export const BUILT_IN_SALE_STAGES = [
  { key: "pending", label: "Ready to Ship", builtIn: true },
  { key: "shipped", label: "In Transit", builtIn: true },
  { key: "delivered", label: "Delivered", builtIn: true },
  { key: "complete", label: "Completed", builtIn: true },
  { key: "cancelled", label: "Cancelled", builtIn: true },
  { key: "returned", label: "Returned", builtIn: true },
];

/** Chip color class per built-in key — matches Sales.jsx's old STATUS_LABELS.
 *  Any custom bucket key not listed here falls back to "chip-draft". */
export const BUILT_IN_CHIP_CLASS = {
  pending: "chip-pending",
  shipped: "chip-fulfilling",
  delivered: "chip-fulfilling",
  complete: "chip-primary",
  cancelled: "chip-draft",
  returned: "chip-draft",
};

/** Sale statuses excluded from revenue by default — mirrors
 *  functions/sales_metrics.js EXCLUDED_STATUSES / web/src/lib/salesMetrics.js. */
export const EXCLUDED_STATUS_KEYS = new Set(["cancelled", "returned"]);
