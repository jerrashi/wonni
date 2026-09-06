/**
 * contracts/sales.js — sale recording, sync, and quantity cascade.
 *
 * The `sales/{saleId}` collection is the one model both apps already share.
 * Today they write it with different field names (web: salePrice/productId,
 * iOS: priceSoldFor/listingId); this contract is the single canonical shape
 * that the `recordSale` callable writes and both apps read.
 */

const { z } = require("zod");
const {
  UidSchema,
  ProductIdSchema,
  MoneySchema,
  PositiveMoneySchema,
  TimestampInputSchema,
  TimestampReadSchema,
  PlatformSchema,
  SaleStatusSchema,
  SaleAddressSchema,
  CarrierSchema,
} = require("./_shared");

// ── The canonical sales/{saleId} document ───────────────────────────────────

const SaleDocSchema = z.object({
  userId: UidSchema,

  /** Canonical listing reference. Null for a manual sale with no catalog item. */
  productId: ProductIdSchema.nullable(),
  /** SKU of the specific variant sold, when the product has variants. */
  variantSku: z.string().nullish(),
  /** Option values of the sold variant, e.g. { Size: "M", Color: "Black" }. */
  variantOptionValues: z.record(z.string(), z.string()).nullish(),

  /** Snapshots taken at sale time so the row survives the product being edited/deleted. */
  listingTitle: z.string().nullish(),
  thumbnailUrl: z.string().url().nullish(),   // platform CDN image — preferred, no Storage cost
  coverPhotoPath: z.string().nullish(),       // Firebase Storage path — fallback

  platform: PlatformSchema,
  /** Platform order / transaction id. The dedupe key for auto-imported sales. */
  platformOrderId: z.string().nullish(),
  /** Platform's item/listing id on that platform (Mercari item id, eBay item id). */
  platformItemId: z.string().nullish(),

  priceSoldFor: PositiveMoneySchema,     // item price only
  shippingRevenue: MoneySchema.nullish(), // shipping charged to buyer
  shippingLabelCost: MoneySchema.nullish(),
  takeHome: z.number().nullish(),         // net after fees + label; may be provisional
  quantity: z.number().int().positive().default(1),

  buyerName: z.string().nullish(),
  buyerAddress: SaleAddressSchema.nullish(),
  trackingNumber: z.string().nullish(),
  carrier: CarrierSchema.nullish(),

  status: SaleStatusSchema,
  soldAt: TimestampReadSchema,
  shippedAt: TimestampReadSchema.nullish(),
  createdAt: TimestampReadSchema,
  updatedAt: TimestampReadSchema,

  /** Free-text note (web "log a sale" flow). */
  notes: z.string().nullish(),
  /** Link to the sale on the platform, when there's no structured order id. */
  externalUrl: z.string().url().nullish(),

  /** Soft-delete — hidden from the dashboard, kept so the platformOrderId
   *  stays in the dedupe set. Hard delete removes it from the set entirely. */
  isDeleted: z.boolean().nullish(),
  deletedAt: TimestampReadSchema.nullish(),

  /** Provenance: which flow created this row. */
  source: z.enum(["manual", "mercari-scan", "ebay-poll", "etsy-poll", "cross-post-drift"]).nullish(),
});

// ── recordSale — the ONE write path ─────────────────────────────────────────
// Replaces: web LogSaleModal's bare addDoc(), iOS SaleRepository.addSale()/
// recordSale(). Server stamps userId/createdAt/updatedAt and fires the cascade
// in the same invocation so there is no client round-trip and no double-decrement.

const RecordSaleRequestSchema = z.object({
  platform: PlatformSchema,
  productId: ProductIdSchema.nullish(),
  variantSku: z.string().nullish(),

  soldPrice: PositiveMoneySchema,
  shippingRevenue: MoneySchema.nullish(),
  shippingLabelCost: MoneySchema.nullish(),
  takeHome: z.number().nullish(),
  quantity: z.number().int().positive().default(1),

  soldAt: TimestampInputSchema.nullish(), // defaults to now server-side
  platformOrderId: z.string().nullish(),
  platformItemId: z.string().nullish(),

  buyerName: z.string().nullish(),
  buyerAddress: SaleAddressSchema.nullish(),
  trackingNumber: z.string().nullish(),
  carrier: CarrierSchema.nullish(),

  notes: z.string().nullish(),
  externalUrl: z.string().url().nullish(),

  /** When false, skip the quantity cascade (caller already handled stock). */
  cascade: z.boolean().default(true),
});

const CascadeResultSchema = z.object({
  productId: ProductIdSchema.nullable(),
  previousQuantity: z.number().int().nullable(),
  newQuantity: z.number().int().nullable(),
  soldOut: z.boolean(),
  /** Per-platform push outcome from the cascade. */
  platforms: z.record(
    z.string(),
    z.enum(["updated", "skipped", "failed", "pending-manual"])
  ),
});

const RecordSaleResponseSchema = z.object({
  saleId: z.string(),
  /** Absent when the sale was a duplicate (platformOrderId already recorded). */
  created: z.boolean(),
  cascade: CascadeResultSchema.nullable(),
});

// ── decrementAndCascade / restockAndCascade / markSoldOutAndCascade ─────────
// Kept as standalone callables for the drift-correction flows (a listing
// found sold on a platform without a corresponding sale row yet).

const CascadeRequestSchema = z.object({
  productId: ProductIdSchema,
  platform: PlatformSchema,
});

const RestockRequestSchema = z.object({
  productId: ProductIdSchema,
  quantity: z.number().int().positive(),
});

// ── syncSales — on-demand poll of eBay + Etsy for new orders ────────────────

const SyncSalesRequestSchema = z.object({
  /** Limit the poll to one platform; omit for all connected platforms. */
  platform: z.enum(["ebay", "etsy"]).nullish(),
  /** Don't look back past this point. Defaults to 30 days server-side. */
  since: TimestampInputSchema.nullish(),
});

const SyncSalesResponseSchema = z.object({
  imported: z.number().int(),
  skipped: z.number().int(),
  saleIds: z.array(z.string()),
  errors: z.array(z.object({ platform: z.string(), message: z.string() })),
});

// ── take-home fetch (net payout) ───────────────────────────────────────────

const GetOrderTakeHomeRequestSchema = z.object({
  saleId: z.string(),
});

const GetOrderTakeHomeResponseSchema = z.object({
  takeHome: z.number().nullable(),
  fees: z.number().nullable(),
  shippingLabelCost: z.number().nullable(),
  provisional: z.boolean(),
});

module.exports = {
  SaleDocSchema,
  contracts: [
    {
      name: "recordSale",
      summary: "The single sale-write path: writes sales/{id} + fires the quantity cascade.",
      request: RecordSaleRequestSchema,
      response: RecordSaleResponseSchema,
    },
    {
      name: "decrementAndCascade",
      summary: "Drift fix: decrement a product's quantity and push to every connected platform.",
      request: CascadeRequestSchema,
      response: z.object({ success: z.literal(true), cascade: CascadeResultSchema }),
    },
    {
      name: "restockAndCascade",
      summary: "Set a sold-out product back in stock and re-activate/push to platforms.",
      request: RestockRequestSchema,
      response: z.object({ success: z.literal(true) }),
    },
    {
      name: "markSoldOutAndCascade",
      summary: "Force quantity 0 + status sold, cascade deactivation everywhere.",
      request: z.object({ productId: ProductIdSchema }),
      response: z.object({ success: z.literal(true) }),
    },
    {
      name: "syncSales",
      summary: "Poll eBay + Etsy for orders not yet in sales/, import each via recordSale.",
      request: SyncSalesRequestSchema,
      response: SyncSalesResponseSchema,
    },
    {
      name: "getOrderTakeHome",
      summary: "Fetch the platform's net payout for a recorded sale (eBay/Etsy).",
      request: GetOrderTakeHomeRequestSchema,
      response: GetOrderTakeHomeResponseSchema,
    },
  ],
};
