/**
 * contracts/mercari.js — Mercari sale import + listing drift sync.
 *
 * Mercari has no API, so scraping stays client-side (the Chrome extension's
 * content scripts, the iOS WKWebView). But parsing / dedupe / recording is
 * ONE server implementation: the client sends the raw scraped rows, the
 * function interprets them. This kills the duplicate parsers
 * (extension/mercari_sold_content.js ↔ iOS MercariSaleParsing.swift).
 */

const { z } = require("zod");
const { ProductIdSchema, MoneySchema, TimestampInputSchema } = require("./_shared");

// ── One scraped Mercari sale ────────────────────────────────────────────────
// Mercari has no API, so the client (extension / iOS WKWebView) does the DOM
// scrape *and* the order-status page fetch — only it has the logged-in session.
// It parses the $-strings and dates where it can (that's where the DOM is) and
// passes raw text through where it can't. The SERVER owns everything after
// that: product-matching, dedupe, canonical sale-doc shape, quantity cascade.

const MercariScrapeItemSchema = z.object({
  /** Mercari item id, e.g. "m12345678901". Required. */
  mercariItemId: z.string().min(1),
  /** Mercari order/transaction id — the dedupe key when the client has it. */
  mercariOrderId: z.string().nullish(),
  title: z.string().nullish(),
  thumbnailUrl: z.string().url().nullish(),

  /** Item price the buyer paid, parsed by the client from the sold page. */
  priceSoldFor: z.number().positive(),
  /** Net payout after Mercari fees + shipping, if the client scraped it. */
  takeHome: z.number().nullish(),
  shippingRevenue: z.number().nullish(),

  /** Sale time — ISO/epoch if the client parsed it, else raw text for the
   *  server to best-effort parse, else neither (server falls back to now).
   *  `soldDate` is the current extension's field name — accepted as an alias. */
  soldAt: TimestampInputSchema.nullish(),
  soldDateText: z.string().nullish(),
  soldDate: z.string().nullish(),

  buyerName: z.string().nullish(),
  trackingNumber: z.string().nullish(),
});

// Envelope is validated loosely so one malformed scrape row can't 400 a batch
// of 50 — the function re-checks each row against MercariScrapeItemSchema and
// reports "parse-failed" per row.
const MercariRowLooseSchema = z.object({ mercariItemId: z.string().min(1) }).passthrough();

/** The user's answer for a row that matched no product: "this is that product". */
const MercariLinkSchema = z.object({
  productId: ProductIdSchema,
  /** The variant sold, when the product has variants. */
  variantSku: z.string().nullish(),
});

const RecordMercariSalesBatchRequestSchema = z.object({
  /** Accepts `items` (current extension field) or `rawItems` — same shape. */
  items: z.array(MercariRowLooseSchema).max(200).optional(),
  rawItems: z.array(MercariRowLooseSchema).max(200).optional(),
  /** Review-list "Link to product…" answers, keyed by mercariItemId. The pointer
   *  is written back onto the product (only where empty) so the next scan
   *  matches it without asking. */
  links: z.record(z.string(), MercariLinkSchema).optional(),
}).refine(
  (o) => (o.items?.length || 0) + (o.rawItems?.length || 0) > 0,
  "Provide at least one item in `items` or `rawItems`.",
);

const MercariBatchResultSchema = z.object({
  mercariItemId: z.string(),
  outcome: z.enum(["recorded", "duplicate", "no-match", "parse-failed"]),
  saleId: z.string().nullish(),
  productId: ProductIdSchema.nullish(),
  warning: z.string().nullish(),
  /** true = a user link wrote the Mercari id onto the product this call. */
  pointerWritten: z.boolean().nullish(),
});

const RecordMercariSalesBatchResponseSchema = z.object({
  results: z.array(MercariBatchResultSchema),
  recorded: z.number().int(),
  duplicates: z.number().int(),
  unmatched: z.number().int(),
});

// ── Refresh review: classify scraped rows before anything is recorded ───────

const ReviewMercariSalesRequestSchema = z.object({
  /** Scraped rows, NEWEST FIRST, exactly as the scraper found them. */
  items: z.array(MercariRowLooseSchema).min(1).max(200),
});

const MercariReviewRowSchema = z.object({
  mercariItemId: z.string(),
  /** "new" = not recorded yet; "recorded" = already a sale; "discarded" = the
   *  user chose Never import; "invalid" = the row can't be recorded. */
  // Named reviewState, not state: quicktype turns the key into a top-level Swift
  // `enum State`, which would shadow SwiftUI's @State across the whole app.
  reviewState: z.enum(["new", "recorded", "discarded", "invalid"]),
  /** Matched product (by the Mercari id on a product or variant), if any. */
  productId: ProductIdSchema.nullish(),
  variantSku: z.string().nullish(),
  productTitle: z.string().nullish(),
  /** Why a row is "invalid". */
  warning: z.string().nullish(),
});

const ReviewMercariSalesResponseSchema = z.object({
  rows: z.array(MercariReviewRowSchema),
  /** Index of the first "recorded" row — the scan's stop point for this tab —
   *  or null when every row is new (keep scrolling). */
  firstRecordedIndex: z.number().int().nullable(),
});

const SetMercariSalesDiscardedRequestSchema = z.object({
  items: z.array(z.object({
    mercariItemId: z.string().min(1),
    mercariOrderId: z.string().nullish(),
    title: z.string().nullish(),
    priceSoldFor: z.number().nullish(),
  })).min(1).max(200),
  /** true = Never import (tombstone); false = Restore. */
  discarded: z.boolean(),
});

// ── Pull-sync: detect drift between a Mercari listing and the product doc ───

const DetectMercariPullSyncDiffRequestSchema = z.object({
  productId: ProductIdSchema,
  /** Scraped current state of the live Mercari listing. */
  scraped: z.object({
    title: z.string().nullish(),
    description: z.string().nullish(),
    price: MoneySchema.nullish(),
    photoUrls: z.array(z.string().url()).nullish(),
    status: z.string().nullish(),
  }),
});

const MercariFieldDiffSchema = z.object({
  field: z.enum(["title", "description", "price", "photos", "status"]),
  productValue: z.unknown(),
  mercariValue: z.unknown(),
});

const DetectMercariPullSyncDiffResponseSchema = z.object({
  productId: ProductIdSchema,
  diffs: z.array(MercariFieldDiffSchema),
  inSync: z.boolean(),
});

const ImportMercariPullSyncRequestSchema = z.object({
  productId: ProductIdSchema,
  /** Which diffed fields to pull from Mercari onto the product doc. */
  fields: z.array(z.enum(["title", "description", "price", "photos", "status"])).min(1),
  scraped: DetectMercariPullSyncDiffRequestSchema.shape.scraped,
});

// ── updateMercariListingStatus — extension reports each post attempt ────────

const UpdateMercariListingStatusRequestSchema = z.object({
  productId: ProductIdSchema,
  variantId: z.string().nullish(),          // one Mercari listing per variant
  status: z.enum(["active", "inactive", "sold", "error", "draft"]),
  listingId: z.string().nullish(),          // Mercari item id
  url: z.string().url().nullish(),
  category: z.string().nullish(),
  error: z.string().nullish(),
  syncedTitle: z.string().nullish(),
  syncedDescription: z.string().nullish(),
  syncedPrice: z.number().nullish(),
  syncedImages: z.array(z.string().url()).nullish(),
});

module.exports = {
  MercariScrapeItemSchema,
  MercariRowLooseSchema,
  MercariBatchResultSchema,
  MercariReviewRowSchema,
  contracts: [
    {
      name: "reviewMercariSales",
      summary: "Refresh step 1: classify scraped Mercari rows as new / recorded / discarded / invalid and report where to stop scanning (first already-recorded row). Records nothing.",
      request: ReviewMercariSalesRequestSchema,
      response: ReviewMercariSalesResponseSchema,
    },
    {
      name: "setMercariSalesDiscarded",
      summary: "Refresh step 3: Never import (tombstone) or Restore Mercari rows. Server-only store users/{uid}/mercariSaleInbox.",
      request: SetMercariSalesDiscardedRequestSchema,
      response: z.object({ updated: z.number().int() }),
    },
    {
      name: "recordMercariSalesBatch",
      summary: "Take raw scraped Mercari rows → parse + dedupe + recordSale + cascade, server-side.",
      request: RecordMercariSalesBatchRequestSchema,
      response: RecordMercariSalesBatchResponseSchema,
    },
    {
      name: "detectMercariPullSyncDiff",
      summary: "Compare a scraped live Mercari listing against the product doc.",
      request: DetectMercariPullSyncDiffRequestSchema,
      response: DetectMercariPullSyncDiffResponseSchema,
    },
    {
      name: "importMercariPullSync",
      summary: "Pull selected drifted fields from Mercari onto the product doc.",
      request: ImportMercariPullSyncRequestSchema,
      response: z.object({ ok: z.literal(true), updated: z.array(z.string()) }),
    },
    {
      name: "updateMercariListingStatus",
      summary: "Extension reports the outcome of a Mercari post/edit attempt.",
      request: UpdateMercariListingStatusRequestSchema,
      response: z.object({ ok: z.literal(true) }),
    },
  ],
};
