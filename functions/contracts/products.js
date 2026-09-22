/**
 * contracts/products.js — the `products/{id}` doc shape, variant subset.
 *
 * NOTE: this schema currently only covers the variant-related subset of the
 * product doc (`options`, `variants`, `hasVariants`, `quantityVariesByVariant`
 * and the shapes they're built from) — NOT the full `products/{id}` document
 * (title, pricing, images, source-specific fields, etc. all live outside this
 * file for now). A future pass should extend `ProductDocSchema` to cover the
 * rest of `product_schema.js`'s `buildNewProductDoc`.
 *
 * This is the shared contract for the exact runtime shape written by
 * `functions/product_schema.js`'s `buildNewProductDoc` and read/written by
 * `functions/sales.js` / `functions/ebay_listing.js` (see the "NEVER a dotted
 * `variants.N.x` path" comments in those files — every write here replaces
 * the whole `variants` array).
 */

const { z } = require("zod");
const { CrossPostPlatformSchema } = require("./_shared");

// ── Options ──────────────────────────────────────────────────────────────

/** One variation dimension, e.g. { name: "Style", values: ["RM", "Jin"] }. */
const OptionSchema = z.object({
  id: z.string().nullish(),
  name: z.string().min(1),
  values: z.array(z.string()),
});

// ── Per-platform cross-post maps (variant-level; mirrors the product-level
//    shape already used by `product.crossPostStatus` / `crossPostListingIds`,
//    keyed by the same `CrossPostPlatformSchema` platforms) ────────────────

const CrossPostStatusSchema = z.object({
  ebay: z.string().nullish(),
  etsy: z.string().nullish(),
  mercari: z.string().nullish(),
  tiktok: z.string().nullish(),
});

const CrossPostListingIdsSchema = z.object({
  ebay: z.string().nullish(),
  etsy: z.string().nullish(),
  mercari: z.string().nullish(),
  tiktok: z.string().nullish(),
});

// ── Variant ──────────────────────────────────────────────────────────────

const VariantSchema = z.object({
  id: z.string().min(1),
  /** Dimension name → this variant's value, e.g. { Style: "RM", Size: "M" }. */
  optionValues: z.record(z.string(), z.string()),
  sku: z.string().nullish(),
  sourcePrice: z.number().nullish(),
  price: z.number().nullish(),
  quantity: z.number().int().nonnegative(),
  active: z.boolean(),
  sourceVariantId: z.string().nullish(),
  crossPostStatus: CrossPostStatusSchema,
  crossPostListingIds: CrossPostListingIdsSchema,
  mercariUrl: z.string().nullish(),
  /** Set server-side by `sales.js` `applyMercariFlags()` — a sale on another
   *  variant that shares this variant's stock pool leaves this variant's own
   *  Mercari listing stale until the client acts on the flag. */
  pendingMercariDeactivation: z.boolean().nullish(),
  pendingMercariRelist: z.boolean().nullish(),
});

// ── Product doc (variant-related subset only — see file header) ──────────

const ProductDocSchema = z.object({
  options: z.array(OptionSchema).default([]),
  variants: z.array(VariantSchema).default([]),
  hasVariants: z.boolean().default(false),
  quantityVariesByVariant: z.boolean().default(false),
});

module.exports = {
  OptionSchema,
  CrossPostStatusSchema,
  CrossPostListingIdsSchema,
  VariantSchema,
  ProductDocSchema,
  // No `contracts` array — this file defines shared doc shapes, not
  // callables, so it's exported directly (see contracts/index.js) rather
  // than aggregated via `ALL`.
};
