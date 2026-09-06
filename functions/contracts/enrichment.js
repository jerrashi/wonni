/**
 * contracts/enrichment.js — AI listing-field enrichment.
 *
 * ONE function, `enrichListing`, replaces both:
 *   - iOS `identifyItem`  ({ images, hints } → all fields, writes nothing)
 *   - web  `aiAutofillListing` ({ productId } → fills blank fields, persists)
 *
 * Same Gemini call, same output shape, two entry modes. `mode` discriminates:
 *   - "draft"   : photos + optional hints, no product doc yet. Returns
 *                 suggestions for every field; persists nothing.
 *   - "product" : an existing products/{id}. Fills blank fields (and optionally
 *                 persists them), plus append-style title/description proposals.
 */

const { z } = require("zod");
const { ProductIdSchema, ConditionSchema, PositiveMoneySchema } = require("./_shared");

// ── The standardized field bundle — every enrichment path emits this shape ──
// All keys optional: "draft" mode tends to fill all, "product" mode only the
// ones that were blank.

const ListingFieldsSchema = z.object({
  title: z.string().max(140).optional(),
  /** eBay-safe listing title, <= 80 chars. */
  shortTitle: z.string().max(80).optional(),
  description: z.string().max(2000).optional(),
  brand: z.string().max(60).optional(),
  /** Human-readable category path hint, NOT a platform id, e.g.
   *  "Collectibles > K-pop > Photocards". Each platform's create fn resolves
   *  it to a real id (user input > platform taxonomy API > this hint). */
  category: z.string().max(200).optional(),
  condition: ConditionSchema.optional(),
  tags: z.array(z.string()).max(8).optional(),
  suggestedPrice: PositiveMoneySchema.optional(),
  /** Shipping estimates, whole units. */
  weightOz: z.number().positive().optional(),
  lengthIn: z.number().positive().optional(),
  widthIn: z.number().positive().optional(),
  heightIn: z.number().positive().optional(),
  /** Attributes buyers filter on, e.g. {"Type":"Photo Card","Character":"Jungkook"}. */
  itemSpecifics: z.record(z.string(), z.string()).optional(),
  confidence: z.number().min(0).max(1).optional(),
});

// ── Request ────────────────────────────────────────────────────────────────

const DraftModeRequestSchema = z.object({
  mode: z.literal("draft"),
  /** base64-encoded JPEGs or https image URLs, 1–8. */
  images: z.array(z.string().min(1)).min(1).max(8),
  hints: z.object({
    title: z.string().optional(),
    price: z.number().optional(),
    description: z.string().optional(),
  }).optional(),
});

const ProductModeRequestSchema = z.object({
  mode: z.literal("product"),
  productId: ProductIdSchema,
  /** Only touch fields that are currently blank (default). false = also
   *  produce append-style proposals for filled title/description. */
  fillBlanksOnly: z.boolean().default(true),
  /** Persist the blank-field writes to the doc (default). false = return
   *  them for the client to apply after user review. */
  persist: z.boolean().default(true),
});

const EnrichListingRequestSchema = z.discriminatedUnion("mode", [
  DraftModeRequestSchema,
  ProductModeRequestSchema,
]);

// ── Response ───────────────────────────────────────────────────────────────

const EnrichListingResponseSchema = z.object({
  /** Full field bundle the model produced. In "draft" mode this is the whole
   *  answer; the client builds the product doc from it. */
  suggested: ListingFieldsSchema,
  /** Subset safe to persist as-is to blank fields ("product" mode). */
  writes: ListingFieldsSchema.partial(),
  /** Append-style proposals needing user consent (staged as aiSuggested* ). */
  proposals: z.object({
    title: z.string().optional(),
    description: z.string().optional(),
  }),
  /** Field names actually written to the doc (empty unless mode=product && persist). */
  applied: z.array(z.string()),
  aiModel: z.string(),
  aiPromptVersion: z.string(),
});

module.exports = {
  ListingFieldsSchema,
  contracts: [
    {
      name: "enrichListing",
      summary: "AI-fill listing fields from photos (draft) or gap-fill an existing product. Replaces identifyItem + aiAutofillListing.",
      request: EnrichListingRequestSchema,
      response: EnrichListingResponseSchema,
    },
  ],
};
