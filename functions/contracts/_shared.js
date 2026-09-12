/**
 * contracts/_shared.js
 *
 * Primitive + shared-shape zod schemas used across more than one callable
 * contract. Everything here is plain CommonJS so the Cloud Functions runtime
 * (`require`) and the Swift codegen script both read the same source.
 *
 * Convention: schema consts are PascalCase and end in `Schema`. Request /
 * response schemas live in the per-domain files (sales.js, listings.js, …)
 * and are aggregated by contracts/index.js.
 */

const { z } = require("zod");

// ── Primitives ──────────────────────────────────────────────────────────────

/** Firebase Auth uid. Never trusted from `request.data` — always taken from
 *  `request.auth.uid` server-side — but appears in doc schemas. */
const UidSchema = z.string().min(1);

/** A `products/{id}` document id. This is the canonical listing reference key
 *  across both apps (the iOS `listings/{id}` collection is being retired — see
 *  BACKEND.md §Data model). */
const ProductIdSchema = z.string().min(1);

/** USD amount, item price only (never includes shipping). Non-negative. */
const MoneySchema = z.number().nonnegative();

/** USD amount that must be a real charge (listing price, sale price). */
const PositiveMoneySchema = z.number().positive();

/** Timestamp as accepted in a request payload: ISO-8601 string or epoch ms.
 *  Functions normalize this to a Firestore Timestamp before writing. */
const TimestampInputSchema = z.union([
  z.string().datetime({ offset: true }),
  z.number().int().positive(),
]);

/** Timestamp as it appears when a doc is read back to a client (Firestore
 *  serializes to `{ _seconds, _nanoseconds }` over the callable transport). */
const TimestampReadSchema = z.object({
  _seconds: z.number().int(),
  _nanoseconds: z.number().int(),
});

// ── Enumerations (single source of truth — mirror these in Swift via codegen,
//    not by hand) ───────────────────────────────────────────────────────────

/** Every channel a sale or listing can belong to. `manual` = in-person/other,
 *  `wonni` = the first-party marketplace. */
const PlatformSchema = z.enum([
  "ebay",
  "mercari",
  "etsy",
  "tiktok",
  "wonni",
  "manual",
]);

/** Channels that have a real cross-post integration (excludes manual). */
const CrossPostPlatformSchema = z.enum(["ebay", "mercari", "etsy", "tiktok", "wonni"]);

/** Lifecycle of a sale after it lands. Was a fixed 6-value enum (ported from
 *  iOS `SaleStatus`); loosened 2026-09-11 (docs/specs/2026-09-11-stage-board-
 *  and-revenue-accounting.md) to an open string — `status` is now a
 *  per-user-editable kanban/spreadsheet bucket key (`users/{uid}.saleStages`,
 *  see `sale_stages.js`), not a fixed set. The 6 built-in keys below are
 *  still what the eBay/Etsy pollers write directly (`sale_stages.js`
 *  `BUILT_IN_SALE_STAGES`) and are permanent — a user can rename their
 *  labels but never delete or repurpose the keys — so code that only ever
 *  needs to recognize those 6 (poller re-record ordering, revenue exclusion)
 *  keeps matching on the literal strings unchanged. Only a manual board/
 *  dropdown move can produce any other value. */
const SaleStatusSchema = z.string().min(1).max(40);

/** Canonical product condition. Matches web `product.condition`
 *  (`new|likenew|good|fair|poor`) — iOS `ItemCondition` maps onto this. */
const ConditionSchema = z.enum(["new", "likenew", "good", "fair", "poor"]);

// ── Shared object shapes ────────────────────────────────────────────────────

const SaleAddressSchema = z.object({
  name: z.string().nullish(),
  line1: z.string().nullish(),
  line2: z.string().nullish(),
  city: z.string().nullish(),
  state: z.string().nullish(),
  zip: z.string().nullish(),
  country: z.string().nullish(),
});

const CarrierSchema = z.enum(["USPS", "UPS", "FedEx", "DHL", "other"]);

/** Standard success envelope for callables that don't return data. */
const OkResponseSchema = z.object({ ok: z.literal(true) });

module.exports = {
  UidSchema,
  ProductIdSchema,
  MoneySchema,
  PositiveMoneySchema,
  TimestampInputSchema,
  TimestampReadSchema,
  PlatformSchema,
  CrossPostPlatformSchema,
  SaleStatusSchema,
  ConditionSchema,
  SaleAddressSchema,
  CarrierSchema,
  OkResponseSchema,
};
