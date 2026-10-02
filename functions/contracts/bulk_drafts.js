/**
 * contracts/bulk_drafts.js — "paste a list, get N ready-to-list drafts".
 *
 * `bulkDraftsFromText` takes free-form text like
 *
 *     wii games (CIB):
 *     bundle 1: just dance 4, just dance 2015, just dance 2014.
 *     super smash bros brawl
 *     link's crossbow training (in cardboard sleeve)
 *
 * and returns one draft proposal per listing (a "bundle N:" line is ONE
 * listing containing several items; header lines like "wii games (CIB):"
 * are context that applies to everything under them). Each proposal is
 * fully filled (title, description, condition, category, tags), priced from
 * live eBay comps where possible, and carries photo URLs — a stock photo
 * pulled from an eBay comp, or an AI-generated product shot when no comp
 * had one. Persists nothing: the client reviews and creates the drafts.
 */

const { z } = require("zod");
const { ConditionSchema, PositiveMoneySchema } = require("./_shared");

const PhotoSourceSchema = z.enum(["ebay", "generate", "none"]);

const BulkDraftsFromTextRequestSchema = z.object({
  text: z.string().min(1).max(8000),
  /** Cap on listings produced (default 40). */
  maxItems: z.number().int().min(1).max(60).default(40),
  /** Where photos come from. "ebay" (default) = stock photo from a comp,
   *  falling back to "generate" when no comp had an image; "generate" =
   *  always AI-generate; "none" = skip photos. */
  photoSource: PhotoSourceSchema.default("ebay"),
});

const CompSummarySchema = z.object({
  title: z.string(),
  price: z.number().nullable(),
  itemWebUrl: z.string().nullable(),
});

const DraftProposalSchema = z.object({
  title: z.string().max(140),
  /** eBay-safe title, <= 80 chars. */
  shortTitle: z.string().max(80),
  description: z.string().max(2000),
  brand: z.string().max(60).optional(),
  category: z.string().max(200).optional(),
  condition: ConditionSchema,
  tags: z.array(z.string()).max(8),
  /** True when the line described several items sold together. */
  isBundle: z.boolean(),
  /** The individual items in a bundle (empty for single-item listings). */
  bundleItems: z.array(z.string()),
  quantity: z.number().int().min(1),
  suggestedPrice: PositiveMoneySchema.optional(),
  /** "comps" = median of live eBay asking prices; "ai" = model estimate. */
  priceSource: z.enum(["comps", "ai", "none"]),
  /** https photo URLs, first = cover. */
  imageUrls: z.array(z.string()),
  imageSource: z.enum(["ebay", "generated", "none"]),
  /** The comps the price came from (top few, for the review UI). */
  comps: z.array(CompSummarySchema),
  /** The source line(s) this proposal was parsed from, for review. */
  sourceText: z.string(),
});

const BulkDraftsFromTextResponseSchema = z.object({
  /** Shared context the parser pulled from header lines, e.g. "Nintendo Wii games, complete in box". */
  context: z.string(),
  drafts: z.array(DraftProposalSchema),
  aiModel: z.string(),
  aiPromptVersion: z.string(),
});

module.exports = {
  DraftProposalSchema,
  contracts: [
    {
      name: "bulkDraftsFromText",
      summary: "Parse a pasted list of items/bundles into fully-filled draft proposals with comp pricing and stock/generated photos. Persists nothing.",
      request: BulkDraftsFromTextRequestSchema,
      response: BulkDraftsFromTextResponseSchema,
    },
  ],
};
