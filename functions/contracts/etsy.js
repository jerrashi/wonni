/**
 * contracts/etsy.js — Etsy listing CRUD + shop-setup helpers.
 *
 * Consolidated from the nested tree's `etsy_listing.js` (1043 L, the only real
 * Etsy impl) onto the canonical top-level `products/{id}` model and the single
 * shared Etsy keyset (no more `credentialSet: "ios" | "web"` — that param is
 * accepted-and-ignored during the web migration).
 */

const { z } = require("zod");
const { ProductIdSchema } = require("./_shared");

const EtsyIdSchema = z.union([z.string(), z.number()]).transform(String);

// ── CRUD ───────────────────────────────────────────────────────────────────

const EtsyCreateListingRequestSchema = z.object({
  productId: ProductIdSchema,
  /** Optional overrides from the web PostModal; resolved server-side otherwise. */
  taxonomyId: z.union([z.string(), z.number()]).nullish(),
  shippingProfileId: z.union([z.string(), z.number()]).nullish(),
  returnPolicyId: z.union([z.string(), z.number()]).nullish(),
  credentialSet: z.string().nullish(), // legacy, ignored
});

const EtsyCreateListingResponseSchema = z.object({
  success: z.literal(true),
  listingId: z.string(),
});

const EtsyProductRequestSchema = z.object({
  productId: ProductIdSchema,
  credentialSet: z.string().nullish(),
});

const EtsyOkResponseSchema = z.object({ success: z.literal(true) });

// ── pull-sync (drift detection + import) ───────────────────────────────────

const EtsyDriftEntrySchema = z.object({
  field: z.string(),
  wonni: z.string(),
  external: z.string(),
  key: z.enum(["title", "price", "quantity"]),
  value: z.union([z.string(), z.number()]),
});

const EtsyPullSyncResponseSchema = z.object({
  hasDrift: z.boolean(),
  diff: z.array(EtsyDriftEntrySchema),
  etsyData: z.object({
    title: z.string().nullable(),
    price: z.number().nullable(),
    quantity: z.number().nullable(),
    status: z.string(),
    listingId: z.string(),
  }),
  wonniData: z.object({
    title: z.string(),
    price: z.number(),
    quantity: z.number(),
    status: z.string(),
  }),
});

const EtsyImportPullSyncRequestSchema = z.object({
  productId: ProductIdSchema,
  fields: z.object({
    title: z.string().nullish(),
    price: z.number().nullish(),
    quantity: z.number().int().nullish(),
  }),
  credentialSet: z.string().nullish(),
});

// ── shop-setup helpers (UI) ───────────────────────────────────────────────

const EtsyAuthedRequestSchema = z.object({ credentialSet: z.string().nullish() });

const EtsyCheckShopSetupResponseSchema = z.object({
  hasShippingProfile: z.boolean(),
  hasReturnPolicy: z.boolean(),
});

const GetEtsyCategoriesResponseSchema = z.object({
  categories: z.array(z.object({ id: z.number(), name: z.string() })),
});

const SuggestEtsyCategoryRequestSchema = z.object({
  title: z.string().nullish(),
  category: z.string().nullish(),
  credentialSet: z.string().nullish(),
});

const SuggestEtsyCategoryResponseSchema = z.object({
  taxonomyId: z.number(),
  taxonomyName: z.string(),
});

const GetEtsyShippingProfilesResponseSchema = z.object({
  profiles: z.array(z.object({ id: z.union([z.string(), z.number()]), title: z.string() })),
});

const GetEtsyReturnPoliciesResponseSchema = z.object({
  policies: z.array(z.object({ id: z.union([z.string(), z.number()]), name: z.string() })),
});

module.exports = {
  contracts: [
    {
      name: "etsyCreateListing",
      summary: "Create an Etsy listing from a product/{id} (variations, images, taxonomy).",
      request: EtsyCreateListingRequestSchema,
      response: EtsyCreateListingResponseSchema,
    },
    {
      name: "etsyUpdateListing",
      summary: "Push title/description/price/quantity + inventory to an existing Etsy listing.",
      request: EtsyProductRequestSchema,
      response: EtsyOkResponseSchema,
    },
    {
      name: "etsyDeleteListing",
      summary: "Deactivate (draft) the Etsy listing and clear the cross-post pointers.",
      request: EtsyProductRequestSchema,
      response: EtsyOkResponseSchema,
    },
    {
      name: "etsyCheckShopSetup",
      summary: "Does the connected Etsy shop have a shipping profile + return policy?",
      request: EtsyAuthedRequestSchema,
      response: EtsyCheckShopSetupResponseSchema,
    },
    {
      name: "etsyPullSync",
      summary: "Read the live Etsy listing and diff title/price/quantity against the product.",
      request: EtsyProductRequestSchema,
      response: EtsyPullSyncResponseSchema,
    },
    {
      name: "etsyImportPullSync",
      summary: "Apply selected drifted Etsy fields (title/price/quantity) onto the product.",
      request: EtsyImportPullSyncRequestSchema,
      response: EtsyOkResponseSchema,
    },
    {
      name: "getEtsyCategories",
      summary: "All Etsy taxonomy leaf categories, for the category dropdown.",
      request: EtsyAuthedRequestSchema,
      response: GetEtsyCategoriesResponseSchema,
    },
    {
      name: "suggestEtsyCategory",
      summary: "Best-match Etsy taxonomy node for a title + category path (no writes).",
      request: SuggestEtsyCategoryRequestSchema,
      response: SuggestEtsyCategoryResponseSchema,
    },
    {
      name: "getEtsyShippingProfiles",
      summary: "The connected shop's shipping profiles.",
      request: EtsyAuthedRequestSchema,
      response: GetEtsyShippingProfilesResponseSchema,
    },
    {
      name: "getEtsyReturnPolicies",
      summary: "The connected shop's return policies.",
      request: EtsyAuthedRequestSchema,
      response: GetEtsyReturnPoliciesResponseSchema,
    },
  ],
  EtsyDriftEntrySchema,
};
