/**
 * contracts/bulk_drafts.js — "paste a list, get N ready-to-list drafts".
 *
 * `bulkDraftsFromText` takes ANY unstructured text (list, paragraph, message,
 * pasted table) such as
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
 * live eBay comps where possible, carries the best comp's eBay category /
 * condition / item specifics ("sell similar"), and has photo URLs from the
 * comp (eBay sellers' photos) or Google image search. No AI-generated
 * photos here — the client asks the user first, then calls
 * `generateListingPhoto` per photo-less listing. Persists nothing.
 */

const { z } = require("zod");
const { ConditionSchema, PositiveMoneySchema } = require("./_shared");

const BulkDraftsFromTextRequestSchema = z.object({
  text: z.string().min(1).max(20000),
  /** Cap on listings produced (default 40). */
  maxItems: z.number().int().min(1).max(60).default(40),
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
  /** "user" = a price the user wrote in the text (always wins); "comps" =
   *  median of live eBay asking prices; "ai" = model estimate. */
  priceSource: z.enum(["user", "comps", "ai", "none"]),
  /** Only with priceSource "user": what comps (or the model) would have
   *  suggested, so the review UI can show it next to the user's price. */
  marketPrice: PositiveMoneySchema.optional(),
  marketPriceSource: z.enum(["comps", "ai"]).optional(),
  /** https photo URLs, first = cover. */
  imageUrls: z.array(z.string()),
  /** "ebay" = the best comp's own photos; "google" = image search. The
   *  server never emits "generated" — the client sets it after the user has
   *  consented and `generateListingPhoto` returned a URL, so the review list
   *  and the draft can label the photo honestly. */
  imageSource: z.enum(["ebay", "google", "generated", "none"]),
  /** The comps the price came from (top few, for the review UI). */
  comps: z.array(CompSummarySchema),
  /** "Sell similar": the eBay item whose details were copied, and what came
   *  off it. The eBay create path prefers `ebayCategoryId` over a taxonomy
   *  suggestion and merges `itemSpecifics` into the offer's aspects. */
  similarItemId: z.string().optional(),
  ebayCategoryId: z.string().optional(),
  ebayConditionId: z.string().optional(),
  epid: z.string().optional(),
  itemSpecifics: z.record(z.string(), z.string()).optional(),
  /** The snippet of the input this proposal was parsed from, for review. */
  sourceText: z.string(),
});

const BulkDraftsFromTextResponseSchema = z.object({
  /** Shared context the parser pulled from header lines, e.g. "Nintendo Wii games, complete in box". */
  context: z.string(),
  drafts: z.array(DraftProposalSchema),
  aiModel: z.string(),
  aiPromptVersion: z.string(),
});

const GenerateListingPhotoRequestSchema = z.object({
  title: z.string().min(1).max(140),
  bundleItems: z.array(z.string()).default([]),
  condition: ConditionSchema.default("good"),
});

const GenerateListingPhotoResponseSchema = z.object({
  /** Public storage.googleapis.com URL under users/{uid}/generated/, or null
   *  when the model returned no image. */
  url: z.string().nullable(),
});

module.exports = {
  DraftProposalSchema,
  contracts: [
    {
      name: "bulkDraftsFromText",
      summary: "Parse a pasted list of items/bundles into fully-filled draft proposals with comp pricing, sell-similar details and stock photos. Persists nothing.",
      request: BulkDraftsFromTextRequestSchema,
      response: BulkDraftsFromTextResponseSchema,
    },
    {
      name: "generateListingPhoto",
      summary: "AI-generate one product photo for a listing (consent-gated on the client); saved public under users/{uid}/generated/.",
      request: GenerateListingPhotoRequestSchema,
      response: GenerateListingPhotoResponseSchema,
    },
  ],
};
