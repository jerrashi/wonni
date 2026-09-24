/**
 * contracts/weverse_order_tasks.js — the `weverseOrderTasks/{id}` doc shape
 * and the callables built on top of it.
 *
 * Background (see BACKEND.md "Weverse re-order tasks" section): when a
 * product sourced from Weverse (`product.source === "weverse"`) sells on
 * any resale platform, `sales.js`'s `recordSaleCore` best-effort creates one
 * of these — a reminder + deep-link that the extension surfaces so the user
 * can go re-buy the item on Weverse to fulfill the order. Weverse has no
 * ordering API, so nothing here places or automates the actual purchase —
 * a human always does the real add-to-cart/checkout/payment; see
 * `extension/weverse_order_fill.js` for the explicit non-automation stub.
 */

const { z } = require("zod");
const {
  UidSchema,
  ProductIdSchema,
  MoneySchema,
  PositiveMoneySchema,
  TimestampReadSchema,
} = require("./_shared");

// ── The canonical weverseOrderTasks/{id} document ───────────────────────────

const WeverseOrderTaskStatusSchema = z.enum(["pending", "ordered", "cancelled"]);

const WeverseOrderTaskDocSchema = z.object({
  userId: UidSchema,
  productId: ProductIdSchema,
  /** Sku of the specific variant that sold, when the product has variants.
   *  Named `variantId` (not `variantSku`) to match the field name this spec
   *  was requested under; it holds the same `product.variants[i].sku` value
   *  `sales.js` already uses as its variant identifier everywhere else. */
  variantId: z.string().nullish(),
  /** The `sales/{id}` doc this task was created for. */
  saleId: z.string().min(1),
  /** `product.weverseSaleId` at task-creation time — the Weverse "sale" (drop)
   *  id, snapshotted so the task survives the product being edited/deleted. */
  weverseSaleId: z.string().nullish(),
  /** `product.sourceUrl` at task-creation time — deep-links the extension's
   *  "open on Weverse" action straight to the original listing. */
  weverseUrl: z.string().url().nullish(),

  /** Snapshots of the product's title/photo at task-creation time, purely
   *  for the extension popup's list — same rationale as `sales.js`'s own
   *  sale-doc snapshot fields (survive the product being edited/deleted). */
  listingTitle: z.string().nullish(),
  thumbnailUrl: z.string().url().nullish(),

  status: WeverseOrderTaskStatusSchema,
  /** Set once `recordWeverseOrderPlaced` marks this ordered. */
  orderNumber: z.string().nullish(),
  /** What the user actually paid on Weverse to fulfill this sale — mirrored
   *  onto `sales/{saleId}.actualCostPaid` for margin tracking (see
   *  contracts/sales.js's `SaleDocSchema.actualCostPaid`). */
  costPaid: MoneySchema.nullish(),

  createdAt: TimestampReadSchema,
  orderedAt: TimestampReadSchema.nullish(),
});

// ── recordWeverseOrderPlaced — human confirms they placed the Weverse order ─
// Called from the extension popup after the user manually completes checkout
// on Weverse and clicks "Mark as ordered". Never triggered automatically.

const RecordWeverseOrderPlacedRequestSchema = z.object({
  taskId: z.string().min(1),
  orderNumber: z.string().min(1).max(200),
  costPaid: PositiveMoneySchema,
});

const RecordWeverseOrderPlacedResponseSchema = z.object({
  success: z.literal(true),
});

// ── listWeverseOrderTasks — extension polls this for the badge/list ────────

const ListWeverseOrderTasksRequestSchema = z.object({
  /** Defaults to "pending" server-side — the extension only wants the ones
   *  still needing action, unless it explicitly asks for another status. */
  status: WeverseOrderTaskStatusSchema.nullish(),
  limit: z.number().int().positive().max(100).nullish(),
  /** Opaque cursor from a previous response's `nextCursor` — paginates by
   *  task doc id (`createdAt` isn't guaranteed unique). */
  cursor: z.string().nullish(),
});

const WeverseOrderTaskWithIdSchema = WeverseOrderTaskDocSchema.extend({ id: z.string() });

const ListWeverseOrderTasksResponseSchema = z.object({
  tasks: z.array(WeverseOrderTaskWithIdSchema),
  nextCursor: z.string().nullable(),
});

module.exports = {
  WeverseOrderTaskDocSchema,
  WeverseOrderTaskWithIdSchema,
  WeverseOrderTaskStatusSchema,
  contracts: [
    {
      name: "recordWeverseOrderPlaced",
      summary: "Human confirms they manually placed the re-order on Weverse — marks the task ordered + records cost paid onto the linked sale.",
      request: RecordWeverseOrderPlacedRequestSchema,
      response: RecordWeverseOrderPlacedResponseSchema,
    },
    {
      name: "listWeverseOrderTasks",
      summary: "List this user's pending (or filtered) Weverse re-order tasks, for the extension to poll.",
      request: ListWeverseOrderTasksRequestSchema,
      response: ListWeverseOrderTasksResponseSchema,
    },
  ],
};
