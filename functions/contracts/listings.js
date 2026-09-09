/**
 * contracts/listings.js — cross-post create / delete / sync.
 *
 * Scope for now: the eBay path, which is the confirmed shared surface (both
 * apps call `ebayCreateListing`). TikTok / Etsy / Wonni follow the same
 * `{ productId }`-in shape and get added here as their functions are folded
 * into the consolidated codebase (BACKEND.md §Consolidation).
 *
 * KEY CHANGE from the iOS backend: the request key is `productId`, not
 * `listingId`. iOS currently calls `ebayCreateListing({ listingId })` — that
 * call site changes as part of the migration.
 */

const { z } = require("zod");
const { ProductIdSchema, CrossPostPlatformSchema } = require("./_shared");

/** Every cross-post create/delete/sync callable takes at least this. */
const ProductRefRequestSchema = z.object({
  productId: ProductIdSchema,
});

const EbayCreateListingRequestSchema = ProductRefRequestSchema.extend({
  /** Override the listing title without editing the product doc. */
  titleOverride: z.string().max(80).nullish(),
  /** Skip the AI gap-fill of blank shared fields for this call. */
  skipAutofill: z.boolean().default(false),
});

const EbayCreateListingResponseSchema = z.object({
  listingId: z.string(),                    // numeric eBay listingId, as a string
  /** Single-variant listing. */
  offerId: z.string().nullish(),
  /** Multi-variant listing. */
  inventoryItemGroupKey: z.string().nullish(),
  variantOfferIds: z.record(z.string(), z.string()).nullish(),
  listingUrl: z.string().url(),
});

const EbayGetListingResponseSchema = z.object({
  productId: ProductIdSchema,
  listingId: z.string().nullable(),
  status: z.string(),
  totalSold: z.number().int(),
  group: z.object({
    title: z.string().nullish(),
    variesBy: z.array(z.string()).nullish(),
    variantSkus: z.array(z.string()).nullish(),
  }).nullish(),
});

const CrossPostStatusResponseSchema = z.object({
  productId: ProductIdSchema,
  platform: CrossPostPlatformSchema,
  status: z.enum(["active", "inactive", "sold", "error", "none"]),
  listingId: z.string().nullish(),
});

module.exports = {
  ProductRefRequestSchema,
  contracts: [
    {
      name: "ebayCreateListing",
      summary: "Create or re-publish an eBay listing from a products/{id} doc (single or multi-variant).",
      request: EbayCreateListingRequestSchema,
      response: EbayCreateListingResponseSchema,
    },
    {
      name: "ebayDeleteListing",
      summary: "Withdraw the eBay offer(s); keep the stable offer pointers for a later re-post.",
      request: ProductRefRequestSchema,
      response: z.object({ ok: z.literal(true) }),
    },
    {
      name: "ebayGetListing",
      summary: "Live READ from the eBay Inventory API via the doc's stable pointers.",
      request: ProductRefRequestSchema,
      response: EbayGetListingResponseSchema,
    },
    {
      name: "ebayUpdateListing",
      summary: "Apply product-doc edits to the live eBay listing (single-variant only for now).",
      request: ProductRefRequestSchema,
      response: CrossPostStatusResponseSchema,
    },
    {
      name: "postToWonni",
      summary: "Publish a products/{id} to the Wonni marketplace feed (listings/{id}, status:active). Skips a re-write when a live listing already exists.",
      request: ProductRefRequestSchema,
      response: z.object({
        listingId: z.string(),
        alreadyPosted: z.boolean(),
        /** true = a live listing already existed; only the product flags were synced. */
        skipped: z.boolean().optional(),
      }),
    },
  ],
};
