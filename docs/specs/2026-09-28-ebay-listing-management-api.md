# eBay listing-management API — building blocks (2026-09-28)

## Goal

Before this: `ebayCreateListing` always posts `FIXED_PRICE`, `GTC` (Good-Til-
Cancelled), first-in-list business policies. This spec adds four standalone
Cloud Functions that each wrap **one** eBay Sell-API capability, callable
independently of the create flow, so the UI can call them directly and we can
compose/restyle the actual selling *flow* later without touching this layer.

Per the user's direction: build the raw API building blocks first (typed
in/out, tested against eBay directly), defer UI/UX customization (suggested
auctions, copy, flows) to a later pass. Each function does the simplest
correct thing eBay's API allows — no heuristics or opinionated defaults baked
in beyond what's needed to make a valid API call.

## Function 1 — `ebaySetListingFormat` (draft/publish-time format choice)

**Confirmed 2026-09-28: this is a draft/publish-stage setting, not a live
toggle on a published offer** — eBay doesn't support converting a published
offer between `FIXED_PRICE` and `AUCTION` in place anyway (`updateOffer` on a
live offer 400s if `format` differs from how it was created), so this lines
up with how eBay's API actually works. The function sets the format at
create/re-publish time:

- On first publish: `createOffer` is called with the chosen `format` directly
  — no withdraw/recreate dance needed, it's just an input to the existing
  publish path.
- On re-publish of something already withdrawn (e.g. relist after ended): same
  as above, since there's no live offer to conflict with.
- If somehow called against a **currently-live** offer with a different
  format than what's live, the function throws `failed-precondition` with a
  clear message ("withdraw the listing first") rather than attempting a
  silent withdraw+recreate — that's a bigger, riskier operation that belongs
  in a deliberate re-list flow, not hidden inside a format setter.

Still true and still enforced:

- `AUCTION` requires `listingDuration` ∈ `DAYS_1,3,5,7,10` (not `GTC`).
  `FIXED_PRICE` requires `GTC` (what we already send). The function rejects
  `AUCTION` with no duration.
- Auction pricing lives in `pricingSummary.auctionStartPrice` (required) and
  optionally `auctionReservePrice`; `pricingSummary.price` becomes the
  **Buy-It-Now** price when set alongside an auction.
- **Multi-variant items cannot run as auctions at all** (eBay auctions are
  single-quantity, single-SKU only) — the function rejects with
  `failed-precondition` up front for any product with `ebayHasVariations`.
  This is the one hard blocker worth surfacing early in the draft UI later,
  since it's not obvious from eBay's docs until you hit the 400.

```js
// functions/ebay_listing.js
exports.ebaySetListingFormat = onCall({ timeoutSeconds: 60 }, async (request) => {
  // in:  { productId, format: "AUCTION" | "FIXED_PRICE",
  //        listingDuration?: "DAYS_1"|"DAYS_3"|"DAYS_5"|"DAYS_7"|"DAYS_10",
  //        auctionStartPrice?: number, auctionReservePrice?: number,
  //        buyItNowPrice?: number }
  // out: { listingId, format, offerId }
});
```

## Function 2 — `ebayRetrieveComps` (active-listing comps, no recommendation math)

**(a) Confirmed: eBay has no "recommended price" endpoint**, general-access
or otherwise. The Sell APIs (Inventory/Account/Fulfillment) have nothing
price-suggestion-shaped, and the only sold-price data eBay exposes at all is
the `Marketplace Insights API` (`/buy/marketplace_insights/v1_beta/...`) —
which is **limited-release**, gated by an explicit application to eBay's
developer program that most accounts (ours, unconfirmed) don't have. That
approval status can only be checked by logging into the eBay Developer
Portal's API Access page — not something checkable from code/CLI, so that's
a genuine "your input needed" item if we ever want sold comps specifically.
Not a blocker for this function, which only needs the generally-available
Browse API.

**(b) `ebayRetrieveComps(listing)`** — per your direction, this function does
retrieval only, no ranking/scoring/recommendation logic. It searches eBay's
**Browse API** (`/buy/browse/v1/item_summary/search`) by the listing's title
and returns the raw array of matching active listings. Sorting ("by price",
"by date"), filtering, and how it's displayed are explicitly deferred to the
later UI pass.

- Browse API uses an **application access token** (`client_credentials`
  grant), not the seller's own OAuth token — it's public marketplace data,
  not account-scoped. This means comps can be fetched even for a
  product/listing that hasn't been connected to eBay yet. `ebay_auth.js` has
  no client-credentials helper yet — one small addition
  (`getAppAccessToken()`, cached until `expires_in`, using the same
  `basicAuthHeader()` already there) is the only new auth plumbing needed.
- `q` = the listing's title verbatim (Browse API does its own relevance
  matching — no need to pre-parse keywords). Optional pass-through filters:
  `category_ids`, `filter=conditions:{...}` when the product has a resolved
  eBay category/condition already, so results stay on-topic. Both optional —
  title-only search is a valid call.
- Returns each result close to Browse API's own shape (title, price,
  condition, itemWebUrl, image, itemId) rather than remapping into a new
  schema — keeps this function a thin passthrough, easiest to keep correct as
  the UI's actual needs get defined later.

```js
// functions/ebay_listing.js (or a new functions/ebay_comps.js if this grows)
exports.ebayRetrieveComps = onCall({ timeoutSeconds: 30 }, async (request) => {
  // in:  { title: string, categoryId?: string, condition?: string, limit?: number /* default 25 */ }
  // out: { comps: [{ itemId, title, price: number, currency, condition, itemWebUrl, imageUrl }] }
});
```

## Function 3 — `ebaySetShippingRule` (named, reusable fulfillment policies)

**Confirmed on the mail-class point:** First-Class Package is the cheap
legitimate service for trading cards; Media Mail is the cheap legitimate
service for media (books/discs/etc) — two different item types, two
different services, both cheaper than Ground Advantage for their respective
category. Good to have that explicit since the rule model below is keyed
exactly on that (item type → service), not a single "cheap shipping" bucket.

eBay's own unit here is a **fulfillment policy** — `ebay_listing.js` already
creates one dynamically per handling time
(`cloneFulfillmentPolicyWithHandlingTime`), so the API shape is proven; this
function generalizes it into an explicit, named, user-driven rule instead of
an implicit clone.

**Inputs**, per your spec — 2 required, 3 optional:

- **Required: `handlingTimeDays`** (number) and **`handlingCost`** (number,
  dollars — handling cost is layered into the shipping service's price as
  eBay has no separate "handling fee" field on a fulfillment policy; it's
  folded into `shippingServices[].additionalCost`, called out explicitly in
  the naming so it stays visible).
- Optional: **`itemType`** (free-form label, e.g. `"Trading Cards"`,
  `"Media"` — used only for the rule's name and for future auto-selection
  logic, not sent to eBay, which has no such field), **`preferredCarrier`**
  (e.g. `"USPS"`), **`preferredService`** (eBay service code, e.g.
  `"USPSFirstClass"` / `"USPSMediaMail"` — when omitted, the function doesn't
  guess; it requires at least one `shippingServices` entry to be resolvable,
  same as today's fallback-to-account-default path).

**Naming convention**, matching the "X business days" pattern already used
by `cloneFulfillmentPolicyWithHandlingTime`: `"{handlingTimeDays} business
days - {itemType} - ${handlingCost} handling"`, e.g. `"2 business days -
Trading Cards - $10 handling"`. When `itemType` is omitted: `"{handlingTimeDays}
business days - ${handlingCost} handling"`. This keeps rules
self-describing in eBay's own Seller Hub UI, not just ours, and keeps the
existing dedup-by-name lookup (`get_by_policy_name`) working the same way
`cloneFulfillmentPolicyWithHandlingTime` already relies on.

**Confirm-before-posting**, per your ask — the function is a single call that
both builds the payload from these inputs and posts it (create or update by
`policyId`), returning what was actually saved so the caller can display it
back for confirmation rather than trusting its own request blindly:

```js
// functions/ebay_listing.js
exports.ebaySetShippingRule = onCall({ timeoutSeconds: 30 }, async (request) => {
  // in:  { policyId?: string /* update if present, else create-or-reuse-by-name */,
  //        handlingTimeDays: number,        // required
  //        handlingCost: number,            // required
  //        itemType?: string,               // optional, name-only + future auto-select
  //        preferredCarrier?: string,        // optional
  //        preferredService?: string,        // optional eBay shippingServices[].serviceCode
  //      }
  // out: { policyId, name, handlingTimeDays, handlingCost, shippingServices }
  //      — the saved policy, echoed back for the caller to confirm/display.
});

exports.ebayListShippingRules = onCall({ timeoutSeconds: 30 }, async (request) => {
  // in:  {}
  // out: { rules: [{ policyId, name, handlingTimeDays, handlingCost, shippingServices }] }
});
```

`ebayCreateListing` / `ebaySetListingFormat` gain an optional
`shippingPolicyId` input — when passed, skip `getListingPolicies`'s auto-pick
and use it directly (omitted ⇒ falls back to today's auto-pick, so nothing
existing breaks).

## Data model

No new product-doc fields needed for functions 2–3 (comps retrieval is
read-only and stateless; shipping rules live entirely in the eBay account,
listed live via `ebayListShippingRules` — no local mirror to drift out of
sync). Function 1 needs one new field so drafts/re-posts know the chosen
format:

- `product.ebayListingFormat`: `"FIXED_PRICE" | "AUCTION"` — mirrors what's
  actually live, written by `ebaySetListingFormat` (and by
  `ebayCreateListing`, defaulting to `"FIXED_PRICE"` for backward
  compatibility with every existing listing that predates this field).

## Testing strategy

Same pattern as the existing `functions/test/ebay-*.test.js` files: no live
eBay calls in `npm test` (node:test, no emulator/network). Each function
gets:

1. A pure-logic unit test (payload-shape tests — e.g. `AUCTION` + no
   `listingDuration` throws `failed-precondition`; multi-variant + `AUCTION`
   throws; the shipping-rule naming-convention builder is deterministic given
   fixed inputs).
2. `ebayRequest` mocked via dependency injection (check how existing ebay
   tests stub it — `ebay-import-listing.test.js` — reuse that seam) so the
   *shape* of the outgoing eBay payload is asserted without a network call.
3. A manual smoke-test checklist (run once against eBay's **sandbox**
   environment, `EBAY_ENV=sandbox`, before first real use) — same caveat the
   existing eBay functions carry: full request/response contract can't be
   emulator-verified (no Java here, see `docs/FIRESTORE_RULES_VALIDATION.md`
   for the unrelated-but-same-root-cause note), so sandbox is the actual
   verification step, not just unit tests.

## Explicit non-goals for this pass

- No UI. No sort/filter/display logic on comps, no auto-selection of a
  shipping rule by item type, no default template picked for a category —
  this spec is the raw API layer the UI will call, deferred per your
  instruction not to customize function behavior ahead of the flow being
  designed.
- No changes to the existing `ebayCreateListing` default behavior — it keeps
  posting `FIXED_PRICE`/`GTC`/auto-picked policies exactly as today unless
  new optional inputs are passed.
- No sold-comp (Marketplace Insights) integration yet — blocked on checking
  our eBay Developer Portal API access, a manual check only you can do.
