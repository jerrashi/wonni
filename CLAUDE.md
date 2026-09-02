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
  `EBAY_RU_NAME` secrets on `wonni-app`. Web + iOS use the same one. (The
  `dropshipEbay*` function-name prefix and its `ebayCreateListing` alias are
  legacy naming, not a second credential set.)

## Roadmap (user priority order)

1. **Product variations / listing details** — Phase 1 shipped.
2. **Cross-posting** (eBay / Mercari / Etsy / TikTok) — in flight. eBay
   posting works as of 2026-09-02 (see below).
3. **Unified sales/orders dashboard** — not started. Spec:
   `~/.claude/plans/sales-dashboard-spec.md`. `orders/{orderId}` already
   carries `userId`; web + iOS should share one implementation, not build
   parallel ones.

## eBay posting — current model (2026-09-02, works)

Cloud Function `ebayCreateListing` (= `dropshipEbayCreateListing`) in
`wonni/functions/ebay_listing.js`. Uses the Inventory API:

- **Price:** `product.listingPrice` is the single cross-platform price.
  `resolveListingPrice()` blocks with `failed-precondition` if it's
  missing/≤0 — no invented prices, no `sourceCost` in pricing (that's
  reserved for future profit tracking).
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
`fillBlankFieldsInline` = post-time gap-fill inside `dropshipEbayCreateListing`.
Import-time auto Gemini call removed (now opt-in). Canonical `product.condition`
field added to ProductDetail (mirrors `mercariCondition`). Plan:
`~/.claude/plans/ebay-listing-field-pipeline.md`. Left: iOS onto the shared
`ebayCreateListing` + autofill button (deferred).

**Deferred:** `ebayUpdateListing` / `ebaySyncListing` (the "apply edits" /
drift-sync path) still use the old malformed multi-variant `variations`
payload — separately broken pre-existing, single-variant edit is fine.

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
