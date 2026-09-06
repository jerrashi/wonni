/**
 * contracts/ebay.js — eBay read / import / drift-sync.
 *
 * Three genuinely distinct operations (the names are historically confusing —
 * two of them say "import"):
 *
 *   ebayImportListing   — fetch ANY eBay listing by its item id (Browse API,
 *                         app token, no ownership). Read-only. Used to CREATE a
 *                         product from an existing eBay listing.
 *   ebayCheckDrift      — for a product you own, compare your live eBay offer
 *                         against the product doc. Read-only. "Is it in sync?"
 *                         (currently deployed as `ebayPullSync`.)
 *   ebayApplyDrift      — write selected drifted fields from eBay back onto the
 *                         product doc. (currently `ebayImportPullSync`.)
 *
 * The `ebayPullSync` / `ebayImportPullSync` names stay as callable aliases
 * during the web-client migration, then are removed.
 */

const { z } = require("zod");
const { ProductIdSchema, MoneySchema } = require("./_shared");

// ── ebayImportListing — pull an external listing to seed a product ─────────

const EbayImportListingRequestSchema = z.object({
  /** eBay legacy item id, e.g. "204567891234". */
  itemId: z.string().min(1),
});

const EbayImportListingResponseSchema = z.object({
  title: z.string(),
  price: MoneySchema,
  description: z.string(),
  imageUrls: z.array(z.string().url()),
  condition: z.string(),        // eBay's free-text condition label
});

// ── ebayCheckDrift (aka ebayPullSync) — read-only diff ────────────────────

const EbayCheckDriftRequestSchema = z.object({
  productId: ProductIdSchema,
});

const DriftFieldSchema = z.object({
  field: z.string(),                 // display label, "Title" / "Price" / "Quantity"
  key: z.enum(["title", "price", "quantity"]),
  wonni: z.string(),                 // display string of the local value
  external: z.string(),              // display string of the eBay value
  value: z.union([z.string(), z.number()]),  // raw eBay value to apply
});

const EbayCheckDriftResponseSchema = z.object({
  hasDrift: z.boolean(),
  diff: z.array(DriftFieldSchema),
  ebayData: z.object({
    title: z.string().nullable(),
    price: z.number().nullable(),
    quantity: z.number().nullable(),
    status: z.string(),
    listingId: z.string().nullable(),
  }),
  wonniData: z.object({
    title: z.string(),
    price: z.number(),
    quantity: z.number(),
    status: z.string(),
  }),
});

// ── ebayApplyDrift (aka ebayImportPullSync) — write selected fields ───────

const EbayApplyDriftRequestSchema = z.object({
  productId: ProductIdSchema,
  fields: z.object({
    title: z.string().optional(),
    price: z.number().optional(),
    quantity: z.number().int().optional(),
  }).refine((o) => Object.keys(o).length > 0, "Pick at least one field to apply."),
});

module.exports = {
  contracts: [
    {
      name: "ebayImportListing",
      summary: "Fetch any eBay listing by item id (Browse API) to seed a new product. Read-only, no ownership needed.",
      request: EbayImportListingRequestSchema,
      response: EbayImportListingResponseSchema,
    },
    {
      name: "ebayCheckDrift",
      summary: "Compare a product's live eBay offer against its doc. Read-only. (deployed today as ebayPullSync)",
      request: EbayCheckDriftRequestSchema,
      response: EbayCheckDriftResponseSchema,
    },
    {
      name: "ebayApplyDrift",
      summary: "Write selected drifted fields from eBay onto the product doc. (deployed today as ebayImportPullSync)",
      request: EbayApplyDriftRequestSchema,
      response: z.object({ ok: z.literal(true), applied: z.array(z.string()) }),
    },
  ],
};
