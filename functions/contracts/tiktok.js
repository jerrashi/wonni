/**
 * contracts/tiktok.js — TikTok Shop callables (functions/tiktok_listing.js).
 * Category choice: the request's categoryId, else the product's remembered
 * tiktokCategoryId, else TikTok's recommendation from the title.
 */

const { z } = require("zod");
const { ProductIdSchema } = require("./_shared");

const TiktokCategorySchema = z.object({ id: z.string(), name: z.string() });

const TiktokCreateListingRequestSchema = z.object({
  productId: ProductIdSchema,
  /** Leaf category id; omit to use the remembered or recommended one. */
  categoryId: z.string().nullish(),
  /** Listing title override (the product doc keeps its own title). */
  title: z.string().max(255).nullish(),
});

const TiktokCreateListingResponseSchema = z.object({
  tiktokProductId: z.string(),
  categoryId: z.string().nullish(),
  alreadyListed: z.boolean().nullish(),
});

const TiktokSuggestCategoryRequestSchema = z.object({
  productId: ProductIdSchema,
  categoryId: z.string().nullish(),
});

const TiktokSuggestCategoryResponseSchema = z.object({
  categoryId: z.string(),
  /** "A > B > C" when TikTok recommended it; null for a picked/remembered id. */
  path: z.string().nullable(),
  recommended: z.boolean(),
  filledAttributes: z.number().int(),
  /** Required fields nothing on the product can fill. */
  missing: z.array(z.string()),
  /** Category rules Wonni can't meet (certification, size chart). */
  unmet: z.array(z.string()),
  /** One readable sentence when the post would fail, else null. */
  problem: z.string().nullable(),
});

module.exports = {
  contracts: [
    {
      name: "getTiktokCategories",
      summary: "Every leaf TikTok Shop category as {id, name: 'A > B > C'}.",
      request: z.object({}).passthrough(),
      response: z.object({ categories: z.array(TiktokCategorySchema) }),
    },
    {
      name: "tiktokSuggestCategory",
      summary: "Preview the category a TikTok post would use and whether its required fields can be filled.",
      request: TiktokSuggestCategoryRequestSchema,
      response: TiktokSuggestCategoryResponseSchema,
    },
    {
      name: "tiktokCreateListing",
      summary: "Post a products/{id} doc to TikTok Shop (one SKU per active variant, category fields filled).",
      request: TiktokCreateListingRequestSchema,
      response: TiktokCreateListingResponseSchema,
    },
    {
      name: "tiktokShippingProviders",
      summary: "Carriers TikTok accepts for a synced TikTok sale (seller-shipped orders only).",
      request: z.object({ saleId: z.string().min(1) }),
      response: z.object({ providers: z.array(z.object({ id: z.string(), name: z.string() })) }),
    },
    {
      name: "tiktokMarkShipped",
      summary: "Send tracking for a TikTok sale (creates the package, or updates its tracking).",
      request: z.object({
        saleId: z.string().min(1),
        trackingNumber: z.string().min(1),
        shippingProviderId: z.string().min(1),
        shippingProviderName: z.string().nullish(),
      }),
      response: z.object({ success: z.literal(true), packageId: z.string().nullable() }),
    },
    {
      name: "tiktokDeleteListing",
      summary: "Delete the TikTok product and clear every TikTok field on the doc.",
      request: z.object({ productId: ProductIdSchema }),
      response: z.object({ success: z.literal(true) }),
    },
  ],
};
