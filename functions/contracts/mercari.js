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

// ── Raw scrape row — exactly what a client pulls out of Mercari's
//    __NEXT_DATA__ / DOM, with no interpretation applied ────────────────────

const MercariScrapeItemSchema = z.object({
  /** Mercari item id, e.g. "m12345678901". Required — it's the dedupe key. */
  mercariItemId: z.string().min(1),
  /** Mercari order/transaction id when the sold page exposes it. */
  mercariOrderId: z.string().nullish(),
  title: z.string().nullish(),
  /** Raw price string as shown ("$24", "¥2400") — server parses. */
  priceText: z.string().nullish(),
  /** Numeric price if the client already has it cleanly. */
  priceValue: z.number().nullish(),
  statusText: z.string().nullish(),   // "Sold", "Shipped", "In progress" …
  soldDateText: z.string().nullish(),
  thumbnailUrl: z.string().url().nullish(),
  /** Anything else the scrape saw, as a JSON string — passed through for
   *  server-side heuristics without widening the typed contract. */
  rawJson: z.string().nullish(),
});

const RecordMercariSalesBatchRequestSchema = z.object({
  rawItems: z.array(MercariScrapeItemSchema).min(1).max(200),
  /** Stop importing once an item older than this is hit (incremental sync). */
  stopBefore: TimestampInputSchema.nullish(),
});

const MercariBatchResultSchema = z.object({
  mercariItemId: z.string(),
  outcome: z.enum(["recorded", "duplicate", "no-match", "parse-failed"]),
  saleId: z.string().nullish(),
  productId: ProductIdSchema.nullish(),
  warning: z.string().nullish(),
});

const RecordMercariSalesBatchResponseSchema = z.object({
  results: z.array(MercariBatchResultSchema),
  recorded: z.number().int(),
  duplicates: z.number().int(),
  unmatched: z.number().int(),
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
  contracts: [
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
