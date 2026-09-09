# wonni_dropship — current state

Dropshipping/reselling ops app: imports products from AliExpress/Weverse,
lists them on eBay / TikTok Shop / Mercari / Etsy, tracks orders. React web
app (`web/`), Chrome extension (`extension/`) for sites without a usable API
(Weverse scraping, Mercari posting/automation).

A separate iOS app "wonni" (`~/Documents/GitHub/wonni/wonni/`) is the same
product on a second platform — stripped-down native client, same backend.
Design reference: local memory `wonni-ios-design-reference` (port design, not
data).

## Backend / deploy topology

- **Firebase project: `wonni-app`** (survivor of the wonni_dropship→wonni-app
  merge). `web/src/firebase.js` points here.
- **Deployed Cloud Functions: `~/Documents/GitHub/wonni/functions/`** — this
  is the dir `firebase.json` deploys (`"source": "functions"`). Confirm with
  `firebase functions:list --project wonni-app`.
- **Landmine:** `~/Documents/GitHub/wonni/` also contains a *nested*
  `wonni/functions/` (~40 files, its own `index.js`, a 2255-line
  `ebay_listing.js` with eBay item-aspect auto-fill) that is NOT deployed by
  this repo. Easy to edit the wrong file. See memory
  `wonni-repo-two-ebay-backends`.
- Web dashboard is served at `wonni-app.web.app/web` (Vite `base` + Router
  `basename` + Hosting rewrite). OAuth callback static pages live at
  `/oauth/{ebay,aliexpress,tiktok,etsy}` and are only loaded from *deployed*
  hosting — editing `public/oauth/*/index.html` does nothing until
  `firebase deploy --only hosting`.
- One eBay keyset for everything: `EBAY_CLIENT_ID` / `EBAY_CLIENT_SECRET` /
  `EBAY_RU_NAME` secrets on `wonni-app`. Web + iOS call the same clean-named
  functions — `ebayCreateListing`, `ebayExchangeToken`, `ebayGetListing`, … .
  The old `dropshipEbay*` names/aliases were removed 2026-09-02; the orphaned
  `dropshipEbayCreateListing` / `dropshipEbayExchangeToken` deployments need
  `firebase functions:delete`.

## Roadmap (user priority order)

1. **Product variations / listing details** — Phase 1 shipped.
2. **Cross-posting** (eBay / Mercari / Etsy / TikTok) — in flight. eBay
   posting works as of 2026-09-02 (see below).
3. **Unified sales/orders dashboard** — not started. Spec:
   `~/.claude/plans/sales-dashboard-spec.md`. `orders/{orderId}` already
   carries `userId`; web + iOS should share one implementation, not build
   parallel ones.
   - **Stretch goal:** email-triggered Mercari sale import (parse Mercari's
     "item sold" emails → `recordMercariSalesBatch`) so the manual extension
     scrape becomes optional, plus sale-alert push/email on any platform sale.
     Tracked in `~/Documents/GitHub/wonni/BACKEND.md` § Stretch goals.

## eBay posting — current model (2026-09-02, works)

Cloud Function `ebayCreateListing` in
`wonni/functions/ebay_listing.js`. Uses the Inventory API:

- **Price model (2026-09-03):**
  - `product.listingPrice` — the ONE required cross-platform list price
    (eBay / TikTok / Mercari / Etsy / Wonni). No price ⇒ nothing posts.
  - `variant.price` — optional per-variant override; blank/null ⇒ follows
    `listingPrice`. Cleared inputs now write `null`, not a copy of the price.
  - `product.sourcePrice` — the ONE optional cost field. `sourceCost` and
    product-level `aliexpressPrice` are gone — `functions/scripts/
    backfill_source_price.js` renamed them on every doc 2026-09-04 (verified:
    0 docs left with the old keys) and both the read (`web/src/lib/
    pricing.js productCost()`) and write (`product_schema.buildNewProductDoc`)
    paths were simplified to `sourcePrice` only, no fallback chain. Cost
    tracking + the suggested-price chip only; **never** a fallback for
    `listingPrice`. Order-level `orders/{id}.aliexpressPrice` is a separate
    per-order snapshot, untouched. (The standalone, not-deployed
    `migrate_product_schema.js` — an old-schema→new-schema bridge, unrelated
    to live traffic — still reads all 3 legacy keys; that's its actual job,
    not a leftover.)
  - Helpers: `functions/platform_adapters.js` — `resolveListingPrice(product)`
    (throws `failed-precondition` if ≤0) + `variantPriceOr(variant, base)`;
    mirrored in `web/src/lib/pricing.js` (`resolveListingPrice`,
    `variantPrice`, `productCost`, `suggestedListingPrice`). If we ever add
    per-platform markup it goes in a wrapper on `resolveListingPrice`, one
    place.
  - `tiktokCreateListing` no longer takes a `sellPrice` arg — it reads
    `product.listingPrice`. Web callers pass nothing; Dashboard ListModal
    writes `listingPrice` to the doc before calling.
  - Suggested chip: `suggestedListingPrice(product)` = `round((2 × sourcePrice)
    / 0.9)`, null once a price is set. Shown as `✨ suggested: $X [Use]` above
    the Listing-price input (ProductDetail + Dashboard ListModal) and as the
    prefill in the extension's AliExpress panel.
  - Required-field UX: red `*` on the label, `📤 Post` / submit buttons greyed
    when unset, click ⇒ "Required field: Price is empty" + scroll/focus the
    input.
- **Cross-backend caveat:** `tiktokCreateListing` / `ebayCreateListing` deploy
  from top-level `functions/`. `etsyCreateListing` / `postToWonni` run from an
  older deploy whose source is the *nested* `wonni/wonni/functions/` — the
  price fixes there (`etsy_listing.js`, `wonni_listing.js`, `tiktok_listing.js`)
  need that codebase redeployed. Nested 2255-line `ebay_listing.js` pull-sync
  still has a `listing.price || 0` fallback — untouched (not deployed).
- **Single-variant:** `PUT /inventory_item/{productId}` → offer → `publishOffer`.
- **Multi-variant:** one `inventory_item` per active variant (SKU
  `${productId}::${variantId}`) → `inventory_item_group` with
  `variesBy.specifications` from `product.options` → one offer per variant →
  `publish_by_inventory_item_group` → **one** listing with N variations.
- **Package weight:** `ebayPackageWeightAndSize()` from `weightLbs`/`weightOz`
  (or fractional lbs), falling back to the app's 6 oz default; dimensions
  when all three present.
- **Field model on the `products` doc:**
  - `crossPostStatus.ebay` = `"active"` ⟺ live listing. Primary posted/not
    signal. Written + cleared together with the next field.
  - `crossPostListingIds.ebay` = numeric eBay **listingId**. Present ⟺ live.
    `platformLinks.js` already expects a numeric id here.
  - `ebayOfferId` (single) / `ebayInventoryItemGroupKey` +
    `variants[i].ebayOfferId` (multi) = **stable** offer pointers. Survive
    withdraw; only cleared when eBay 404/25713s them. Checked before any
    offer op (reuse vs create).
  - `ebayListingId` / `ebayListingUrl` = mirrors of `crossPostListingIds.ebay`.
- **Delete** (`ebayDeleteListing`): `withdrawOffer` /
  `withdraw_by_inventory_item_group` → clear the live-listing fields, KEEP
  the offer pointers so a re-post reuses the same offer(s).
- The Cloud Function owns all eBay fields on the doc — `PostModal.jsx` /
  `BulkPostModal.jsx` don't write them after the call.
- `resolveEbayOffer` = migration/recovery bridge only (12-digit listingId via
  `bulk_migrate_listing`, hex offerId, SKU/group search); backfills
  `ebayOfferId`.

**Aspect + condition + value fill (2026-09-02, deployed + posting verified):** the create
path proactively fills eBay category-required item aspects
(`getCategoryAspects` + `buildProductAspects` + `resolveBrand`/`KNOWN_BRANDS`),
resolves a category-valid condition (`getAllowedConditionIds` +
`resolveCondition`, was hardcoded `"NEW"`), and normalizes variation values
against the category's live value list (`normalizeVariationValue` —
"XXL"→"2XL" for apparel Size, which is FREE_TEXT but publish-enforced).
`publishWithRecovery` retries missing-aspect / rejected-condition errors.
Pre-flight fails cleanly for off-list `SELECTION_ONLY` values.

**Shared field-fill pipeline (2026-09-02, deployed):**
`functions/listing_fields.js` — `resolveListingFields(product)` makes ONE
`gemini-flash-lite` call to fill blank shared fields (description, brand,
tags, condition, category hint, itemSpecifics), persisted to the doc.
`aiAutofillListing` callable = the "✨ AI autofill" button on ProductDetail;
`fillBlankFieldsInline` = post-time gap-fill inside `ebayCreateListing`.
Import-time auto Gemini call removed (now opt-in). Canonical `product.condition`
field added to ProductDetail (mirrors `mercariCondition`). Plan:
`~/.claude/plans/ebay-listing-field-pipeline.md`. Left: iOS onto the shared
`ebayCreateListing` + autofill button (deferred).

**Deferred:** `ebayUpdateListing` / `ebaySyncListing` (the "apply edits" /
drift-sync path). Single-variant in-place edit works (price now via
`resolveListingPrice`). Multi-variant now throws `unimplemented` ("delete and
re-post") instead of firing the old malformed single-offer `variations` /
`minimumAdvertisedPrice` payload — the real fix is porting these to the
item-group flow `postMultiVariant` uses.

Offer-lifecycle design detail: `~/.claude/plans/ebay-offer-lifecycle-redesign.md`.

## Open work

- [ ] **iOS onto the shared eBay/field-fill backend** (Step 5 of
  `~/.claude/plans/ebay-listing-field-pipeline.md`; web + backend steps 1–4
  done + deployed 2026-09-02). To do:
  - point the iOS eBay-create call at the shared `ebayCreateListing` Cloud
    Function (call sites not yet traced — start in
    `~/Documents/GitHub/wonni/wonni/wonni/Data/`).
  - add an "✨ AI autofill" button that calls `aiAutofillListing`.
  - ensure iOS writes the canonical `product.condition` (it has
    `ItemCondition`; make sure the field name/values line up with web's
    `new|likenew|good|fair|poor` and `productConditionToEbayEnum`).
  - delete the now-dead `importTimeGeminiFields` in
    `wonni/functions/gemini_identify.js` (and its still-imported
    `geminiApiKey` refs in the 3 import fns) once nothing needs it.
- [ ] **`postToWonni` skip when a live Wonni listing exists.** Server-side
  early-return in `wonni/wonni/functions/wonni_listing.js` when
  `listings/{productId}` is `status:"active"` (keep the first-post-only
  `isDraft:false` write); client-side, wrap the Step-1 `postToWonni` call in
  `PostModal.handleSubmit` in `if (!isPlatformAlreadyPosted("wonni", product))`.
- [ ] **Phase B backend-merge blockers** (need manual action / go-ahead):
  - AliExpress Open Platform + TikTok Shop Partner Center registered
    `redirect_uri` → `https://wonni-app.web.app/web/oauth/*`.
  - Firestore/Storage rules not emulator-validated (no Java here) — use the
    Console Rules Playground or a test deploy. Guidance:
    `FIRESTORE_RULES_VALIDATION.md`, `FIRESTORE_RULES_TEST_CASES.md`.
  - Data migration from the old `wonni-dropship` project (`auth:import`,
    Firestore/Storage copy) — unstarted, waits on explicit go-ahead.
- [ ] `ProductDetail.jsx` read/write migration off `products` onto `listings`
  (20+ scattered `updateDoc` sites) — deferred.
- [ ] `refreshSourceData` Cloud Function — refetch source images/variants
  on-demand from ProductDetail's expandable Images/Variants sections, 24h
  cooldown per section, timestamp under `products.sourceRefresh.{section}`.
- [ ] Phase 3 sales/orders dashboard (spec above).

## eBay READ + gotchas (2026-09-02)

- `ebayGetListing({ productId })` (`functions/ebay_listing.js`, registered,
  NOT UI-wired) — live READ from the Inventory API via the doc's stable
  pointers. Single: `getOffer(ebayOfferId)` + `getInventoryItem(productId)`.
  Multi: `getInventoryItemGroup` + per-variant `getOffer(variants[i].ebayOfferId)`
  + `getInventoryItem(variants[i].ebayVariantSku)`. Returns
  listingId/status, group (title/variesBy/variantSKUs), per-variant
  offer+item, totalSold. Tested against live listing 147545353525.
- **NEVER `docRef.update({ "variants.0.x": y })`** — a dotted numeric field
  path clobbers the `variants` ARRAY into a MAP and drops every other field
  on each variant. Always read-modify-write the whole `variants` array.
  (Corrupted two live products this way on 2026-09-02; recovered from eBay.)
- eBay SKUs must be **alphanumeric, <= 50 chars** (err 25707). Variant SKU is
  `${productId}${strippedVariantId}` (was `${productId}::${id}` — the `::`
  also 400s the `?inventory_item_group_key=` offer query, so multi-variant
  offer discovery uses the stored `variants[i].ebayOfferId` instead).
- Variant `price` blank ⇒ follows the listing price; set ⇒ overrides. The
  importers no longer seed it with the source cost (`sourcePrice` keeps that).

## Phase 1 notes (variations)

- `MAX_VARIATION_DIMENSIONS` in `ProductDetail.jsx` caps variation structure
  at 2 dimensions (primary + sub), matching Etsy's UI. Not generalized to N.
- AliExpress paste-a-URL import uses the real AliExpress API
  (`aliexpress_auth.js` `callAliexpressApi`) for structured `sku_attr`; the
  extension's DOM-scraping fallback for AliExpress is deprioritized.

## Gemini / AI enrichment (current)

- `importTimeGeminiFields` (`gemini_identify.js`) — runs automatically at
  import (AliExpress/Weverse/bulk), writes `geminiDescription`/
  `geminiCategory`/`geminiTags`. **Slated to become opt-in** per the
  field-pipeline plan.
- `generateProductDescription` (`generate_description.js`) — the "✨ AI
  Suggest" button, description from title + one image. To be generalized to
  fill all blank fields in one call.
