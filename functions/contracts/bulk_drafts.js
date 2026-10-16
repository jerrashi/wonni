/**
 * contracts/bulk_drafts.js — "paste text or links, get N ready-to-list drafts".
 *
 * `textToListings` (2026-10-15; `bulkDraftsFromText` is the same function under
 * its first name, kept for iOS builds in the field) takes ANY unstructured
 * text (list, paragraph, message, pasted table, product links) such as
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

/**
 * A listing the parser found but has not priced / photographed yet. Returned
 * in `remaining` and sent back verbatim in the next request's `pendingItems`, so a
 * long list is enriched 40 at a time without re-reading the text. Same shape
 * the model emits — the server re-validates every field on the way back in.
 */
/** What physically comes with a listing — see functions/comp_match.js. */
const IncludedSchema = z.enum(["complete", "partial", "loose", "sealed", "packaging", "unknown"]);
/** Shapes the client's placeholder card: a disc, a cartridge or a plain card. */
const MediaSchema = z.enum(["disc", "cartridge", "other"]);

/** Where a pasted link pointed. "web" = any other page, read via Open Graph. */
const LinkSourceSchema = z.enum(["weverse", "aliexpress", "amazon", "ebay", "web"]);

/**
 * The product page behind a pasted link, as source_links.js read it. Rides on
 * a pending item so the decision / batching round trips keep it, and the
 * enriched proposal carries its URL, id, cost and photos.
 */
const SourceProductSchema = z.object({
  url: z.string(),
  source: LinkSourceSchema,
  /** ASIN, eBay item number, AliExpress item id, Weverse sale id. */
  sourceId: z.string().optional(),
  /** "ok" = the page was read; "partial" = only what the URL itself said
   *  (an Amazon bot check); "failed" = nothing usable. */
  status: z.enum(["ok", "partial", "failed"]),
  title: z.string().optional(),
  description: z.string().optional(),
  imageUrls: z.array(z.string()),
  /** What the item sells for on that page — the seller's COST, never the
   *  resale price. */
  price: PositiveMoneySchema.optional(),
  /** eBay links only: sell-similar details straight off the listing. */
  ebayCategoryId: z.string().optional(),
  ebayConditionId: z.string().optional(),
  epid: z.string().optional(),
  aspects: z.record(z.string(), z.string()).optional(),
});

/** One distinct thing inside a multi-item entry ("issues 211-215"). */
const MemberSchema = z.object({
  title: z.string().max(140),
  searchQuery: z.string().max(200),
});

const PendingItemSchema = z.object({
  title: z.string().max(140),
  shortTitle: z.string().max(80),
  description: z.string().max(2000),
  brand: z.string().max(60).optional(),
  category: z.string().max(200).optional(),
  condition: ConditionSchema,
  tags: z.array(z.string()).max(8),
  isBundle: z.boolean(),
  bundleItems: z.array(z.string()),
  quantity: z.number().int().min(1),
  sourceText: z.string(),
  included: IncludedSchema.optional(),
  media: MediaSchema.optional(),
  searchQuery: z.string().max(200),
  componentQueries: z.array(z.string()),
  /** The model's own price estimate. */
  suggestedPrice: PositiveMoneySchema.optional(),
  /** A price the user wrote in the text. */
  userPrice: PositiveMoneySchema.optional(),
  weightOz: z.number().positive().optional(),
  lengthIn: z.number().positive().optional(),
  widthIn: z.number().positive().optional(),
  heightIn: z.number().positive().optional(),
  /** `[link N]` tokens this listing carries (numbers). */
  links: z.array(z.number().int().positive()).optional(),
  /** Set only on an entry that covers several distinct things; the server
   *  returns such an entry in `needsDecision` instead of enriching it. */
  members: z.array(MemberSchema).optional(),
  source: SourceProductSchema.optional(),
});

const BulkDraftsFromTextRequestSchema = z.object({
  /** The text to parse — any notes, with or without product links. Omit when
   *  sending `pendingItems`. */
  text: z.string().min(1).max(20000).optional(),
  /** Listings from a previous response's `remaining`, to enrich next. */
  pendingItems: z.array(PendingItemSchema).max(60).optional(),
  /** Shared context from an earlier part of the same text (continuing after
   *  `unparsedText`). */
  context: z.string().max(500).optional(),
  /** Listings enriched per call (default 40) — the rest come back in `remaining`. */
  maxItems: z.number().int().min(1).max(60).default(40),
});

const CompSummarySchema = z.object({
  title: z.string(),
  price: z.number().nullable(),
  itemWebUrl: z.string().nullable(),
});

/**
 * One live eBay listing the user may take photos (and sell-similar details)
 * from in the photo chooser. Every comp the search returned that has a photo
 * is a candidate — the automatic pick is just the first strong one — so a
 * listing that sits at position 30 on eBay is still reachable.
 */
const PhotoCandidateSchema = z.object({
  itemId: z.string(),
  title: z.string(),
  price: z.number().nullable(),
  /** The listing's cover photo (full size). More photos come from
   *  `draftPhotoCandidateDetail` once one is chosen. */
  imageUrl: z.string(),
  itemWebUrl: z.string().nullable(),
  /** What that listing says is included (comp_match.js); "unknown" when its
   *  title and short description are silent. */
  included: IncludedSchema,
  /** Phrases that make it a different thing to buy ("reproduction", "for
   *  parts", "graded"…). Shown as warning chips. */
  markers: z.array(z.string()),
  /** Same item, same state: an explicit same-state match, or — when our
   *  listing does not say what is included — a title that matches closely.
   *  Strong candidates are listed first; the rest follow (user decision
   *  2026-10-14: never hide the long tail, the right listing is often there). */
  strong: z.boolean(),
});

/** How sure the automatic photo pick is. The client shows a "choose photos"
 *  badge on anything but "strong". */
const PhotoMatchSchema = z.enum(["strong", "weak", "none"]);

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
  /** "source" = the pasted link's own product page; "ebay" = the best comp's
   *  own photos; "google" = image search. The server never emits "generated"
   *  — the client sets it after the user has consented and
   *  `generateListingPhoto` returned a URL, so the review list and the draft
   *  can label the photo honestly. */
  imageSource: z.enum(["source", "ebay", "google", "generated", "none"]),
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
  /** Shipping estimates (same fields as enrichListing's ListingFields), so a
   *  list-made draft needs no second AI pass. */
  weightOz: z.number().positive().optional(),
  lengthIn: z.number().positive().optional(),
  widthIn: z.number().positive().optional(),
  heightIn: z.number().positive().optional(),
  /** What comes with the listing (CIB vs cartridge only…). Comp photos are
   *  only used from eBay listings in the same state; when none is found
   *  `imageSource` is "none" and the client draws a placeholder. Optional so
   *  older servers / clients stay compatible. */
  included: IncludedSchema.optional(),
  media: MediaSchema.optional(),
  /** The snippet of the input this proposal was parsed from, for review. */
  sourceText: z.string(),
  /** The eBay search the comps came from; the photo chooser starts from it. */
  searchQuery: z.string().optional(),
  /** How sure the automatic photo pick is (see PhotoMatchSchema). Absent from
   *  older servers → the client shows no badge. */
  photoMatch: PhotoMatchSchema.optional(),
  /** Every searched listing with a photo, strong matches first, for the
   *  chooser — stored on the draft so the sheet opens with no network call. */
  photoCandidates: z.array(PhotoCandidateSchema).optional(),
  /** Provenance when the listing came from a pasted link. */
  sourceUrl: z.string().optional(),
  source: LinkSourceSchema.optional(),
  sourceId: z.string().optional(),
  /** What the seller paid / what the linked page sells it for (cost). */
  sourcePrice: PositiveMoneySchema.optional(),
});

/**
 * An entry that names several distinct things ("Amazing Spider-Man issues
 * 211-215") without saying they sell together. Nothing is priced or
 * photographed until the user picks: send `asIndividual` (one pending item
 * per thing) or `asBundle` (one lot) back as `pendingItems`. One sheet per
 * run, Individual the default (user decision 2026-10-15).
 */
const DecisionSchema = z.object({
  sourceText: z.string(),
  title: z.string(),
  memberTitles: z.array(z.string()),
  asBundle: PendingItemSchema,
  asIndividual: z.array(PendingItemSchema),
});

/** What became of each pasted link, in order, for the review UI. */
const LinkResultSchema = z.object({
  url: z.string(),
  source: LinkSourceSchema,
  status: z.enum(["ok", "partial", "failed"]),
  title: z.string().optional(),
  error: z.string().optional(),
});

const DraftPhotoCandidatesRequestSchema = z.object({
  /** The (possibly edited) eBay search. */
  query: z.string().min(1).max(200),
  /** What our listing says is included — decides which candidates are strong. */
  included: IncludedSchema.default("unknown"),
});

const DraftPhotoCandidatesResponseSchema = z.object({
  candidates: z.array(PhotoCandidateSchema),
});

const DraftPhotoCandidateDetailRequestSchema = z.object({
  itemId: z.string().min(1),
  /** Drops single-item identity specifics (Game Name, UPC…) for a bundle. */
  isBundle: z.boolean().default(false),
});

/** The chosen listing's photos and sell-similar details — the same fields a
 *  proposal carries, so the client applies them the same way. */
const DraftPhotoCandidateDetailResponseSchema = z.object({
  title: z.string(),
  imageUrls: z.array(z.string()),
  ebayCategoryId: z.string().optional(),
  ebayConditionId: z.string().optional(),
  epid: z.string().optional(),
  itemSpecifics: z.record(z.string(), z.string()).optional(),
});

const BulkDraftsFromTextResponseSchema = z.object({
  /** Shared context the parser pulled from header lines, e.g. "Nintendo Wii games, complete in box". */
  context: z.string(),
  drafts: z.array(DraftProposalSchema),
  /** Parsed listings beyond this batch, in source order. Send them back as
   *  `pendingItems` (up to 60 at a time) until this is empty. */
  remaining: z.array(PendingItemSchema),
  /** Entries waiting for an individual-or-bundle answer (see DecisionSchema).
   *  Absent from older servers. */
  needsDecision: z.array(DecisionSchema).optional(),
  /** Every link found in `text`, resolved or not. Empty for `pendingItems`. */
  links: z.array(LinkResultSchema).optional(),
  /** Tail of the input the parser never reached (only when a very long text
   *  hit the model's output ceiling). Send it back as `text` to continue. */
  unparsedText: z.string(),
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
  PendingItemSchema,
  PhotoCandidateSchema,
  SourceProductSchema,
  DecisionSchema,
  contracts: [
    {
      name: "textToListings",
      summary: "ONE text-or-links → listings call: product URLs are resolved (Amazon / eBay / AliExpress / Weverse / any page), the text is parsed into listings, multi-item entries wait in needsDecision, the rest are priced and photographed. Persists nothing.",
      request: BulkDraftsFromTextRequestSchema,
      response: BulkDraftsFromTextResponseSchema,
    },
    {
      name: "draftPhotoCandidates",
      summary: "Search live eBay listings for a draft's photo chooser: every result with a photo, strong (same item, same state) matches first.",
      request: DraftPhotoCandidatesRequestSchema,
      response: DraftPhotoCandidatesResponseSchema,
    },
    {
      name: "draftPhotoCandidateDetail",
      summary: "One chosen eBay listing's full photo set and sell-similar details (category, condition, ePID, item specifics) for import onto a draft.",
      request: DraftPhotoCandidateDetailRequestSchema,
      response: DraftPhotoCandidateDetailResponseSchema,
    },
    {
      name: "bulkDraftsFromText",
      summary: "Same function as textToListings under its original name (kept for iOS builds in the field).",
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
