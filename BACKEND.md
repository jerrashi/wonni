# Backend contract & consolidation plan

Single reference for the Cloud Functions surface shared by the **web app**
(`web/`), the **iOS app** (`wonni/`), and the **Chrome extension**
(`extension/`) — all now in this monorepo, all on project **`wonni-app`**.

- **Monorepo since 2026-09-09** — `web/` + `extension/` folded in from the
  (now-archived) `wonni_dropship` repo. One root `firebase.json` + rules.
- **Canonical data model:** the web app's. `products/{id}` (with an inline
  `variants[]` array) is the listing record. The iOS `listings/{id}` +
  `inventory/{unitId}` collections are being retired — see
  [§ Data-model migration](#data-model-migration). (`listings/{productId}` also
  serves as the Wonni **marketplace** feed via `postToWonni` — that use stays.)
- **Function tree:** `functions/` (the only one — the nested parallel backend
  was deleted, see § Deferred ports).
- **Contract source of truth:** [`functions/contracts/`](functions/contracts/)
  (zod). Run `npm run contracts:gen` to regenerate
  `functions/contracts/generated/backend-contracts.schema.json` and the Swift
  structs. CI should fail if these are stale.

---

## How the contract is used

```js
// In a function file:
const { onCall } = require("firebase-functions/v2/https");
const { validated } = require("./contracts");

exports.recordSale = onCall(validated("recordSale", async (data, request) => {
  // `data` is parsed + typed per RecordSaleRequestSchema; bad payloads already
  // rejected with HttpsError("invalid-argument", ...). `request.auth` still raw.
  const uid = request.auth?.uid;
  ...
  return { saleId, created: true, cascade };   // shape checked when CONTRACTS_STRICT=1
}));
```

iOS reads the generated `BackendContracts.swift`; the web app reads the zod
files directly (untyped calls for now, `z.infer` types available if/when
`web/` goes TypeScript).

---

## Function inventory

Status legend: **live** = deployed & has current source · **orphan** =
deployed, no source in the canonical tree · **dead** = a shipping client calls
it but it is *not deployed* · **new** = to be built during consolidation.

### Sales & cascade  → `contracts/sales.js`

| Function | Status | Notes / action |
|---|---|---|
| `recordSale` | ✅ **built** (`functions/sales.js`, wired, not deployed) | THE sale-write path. Web `LogSaleModal` migrated. iOS `SaleRepository` still to repoint. |
| `decrementAndCascade` | ✅ **built** | On `products/` model. **iOS call site still passes `{listingId}` → change to `{productId}`.** |
| `restockAndCascade` | ✅ **built** | `{productId, quantity}` (was `{listingId, quantity}`) |
| `markSoldOutAndCascade` | ✅ **built** | `{productId}` (was `{listingId}`) |
| `syncSales` | ✅ **built** (`functions/sale_poller.js`, wired, not deployed) — needs a one-time reconnect, see below | Polls eBay (`/sell/fulfillment/v1/order`) + Etsy (`/receipts`), matches SKU/listing-id → `products/{id}` (+ variant), records each via `recordSaleCore` (`source:"ebay-poll"`/`"etsy-poll"`, forward-only status). Best-effort per-order tracking + finance lookups. Returns `{imported, skipped, saleIds, errors}`. Mercari still client-scraped. |
| `getOrderTakeHome` | ✅ **built** (`functions/sale_poller.js`) | `{saleId}` → resolves the sale's platform + orderId → eBay Finances (`apiz`) or Etsy Payments → `{takeHome, fees, shippingLabelCost, provisional}`, persisted onto the sale (merge-add). Replaces iOS `ebayGetOrderTakeHome` / `etsyGetReceiptTakeHome`. |

#### `syncSales` / `getOrderTakeHome` — code done, needs deploy + reconnect

eBay order reads need `sell.fulfillment`; net payout needs `sell.finances`;
Etsy receipts need `transactions_r`. eBay's `refresh_token` grant rejects any
scope not in the original authorization, so the refresh scope list can't just
be widened. **Done in code (2026-09-09):**

1. ✅ `ebay_auth.js` — `grantedScopes` recorded on `users/{uid}/integrations/ebay`
   at exchange (+ backfilled on refresh); `refreshScopeFor()` sends
   `EBAY_SCOPES_DESIRED ∩ grantedScopes`, falls back to the safe base subset
   for legacy connections. `hasOrderReadScopes()` gates the poll.
2. ✅ `ebayRequest(uid, m, p, b, { host:"apiz", marketplaceId })` — Finances host.
3. ✅ web `Settings.jsx` — eBay authorize adds `sell.fulfillment` +
   `sell.finances`; Etsy adds `transactions_r`; passes `scopes` to
   `ebayExchangeToken`. iOS `ProfileView.swift` already requested all of these.

**Still needs a human:**

- Deploy `functions/` + `firebase deploy --only hosting` from `wonni_dropship`.
- The 2–3 existing users **reconnect eBay + Etsy once** (their stored
  `grantedScopes` won't include the new scopes until they re-authorize).
  `syncSales` returns a friendly `errors:[{platform:"ebay", message:"…reconnect…"}]`
  until then — nothing breaks.
- Canonical `etsy_auth.js` has **no refresh-token path** (throws "reconnect"
  on expiry). Pre-existing gap; the Etsy poll inherits it. Port
  `refreshEtsyToken` from the nested tree when doing Etsy CRUD.

Until deployed: sales still land via `recordSale` + `recordMercariSalesBatch`.

**Cascade coverage today:** eBay (via `bulk_update_price_quantity` on the stored
offer pointer), Etsy (`listings` PATCH), Mercari (`pendingMercari*` flags).
TikTok is stubbed `pending-manual` until `tiktokUpdateListing` consolidation.

#### Quantity model (confirmed 2026-09-09)

Only two quantity operations matter:

- **`quantity = quantity - 1`** — the normal case. A sale on *any* platform
  decrements the sold bucket (the specific variant when the product has
  variants), then the cascade pushes the new number to every *other* connected
  API platform. eBay/Etsy/TikTok get the literal new quantity.
- **`quantity = 0`** — rare, and **only** when the user marks the item out of
  stock from the Wonni GUI (iOS/web) → `markSoldOutAndCascade`. This is the
  only path that force-zeros API listings.

**Mercari is binary, not numeric.** A Mercari listing is just *active* (in
stock) or *inactive* (out). The cascade never pushes a number to Mercari; it
sets a `pending*` flag for the client-side headless flow to action:

| Situation | Flag | Client action |
|---|---|---|
| decrement leaves qty **> 0**, sale was **on Mercari** | `pendingMercariRelist` | Mercari auto-ended the listing on sale → re-list it |
| decrement leaves qty **= 0** (any platform) | `pendingMercariDeactivation` | end / deactivate the listing |
| user marks out of stock, product is on Mercari | `pendingMercariDeactivation` | deactivate **every associated listing, including the per-variation ones** |
| restock | flags cleared | re-list |

decrement leaving qty > 0 from a *non-Mercari* sale needs **no** Mercari action
(still "in stock" → still active).

**Known gap (2026-09-09):** `cascade()` writes `pendingMercari*` at the
**product** level only. When variants map to separate Mercari listings
(`variants[i].crossPostListingIds.mercari`), a single variant selling out — or
a GUI mark-out-of-stock on a variant product — needs the flag on
`variants[i]`, not just the product. TODO before the Mercari headless flow
ships: per-variant flags + have `markSoldOutAndCascade`/`decrementAndCascade`
set them for each affected variant.

#### Re-record field policy (2026-09-09)

`recordSaleCore` merge-writes on a duplicate `platform_orderId`. **Lifecycle
fields** (`status`, `createdAt`, `source`) are written only on first insert —
a poller re-seeing an order can't reset `status:"shipped"` → `"pending"`.
Every **other** field the caller leaves blank *is* overwritten (e.g. a
re-record with no `trackingNumber` nulls an existing one). Pinned by
`test/sales.test.js` "regression: re-recording a sale…". If pollers become a
source of truth for tracking/buyer data, widen the guarded set.

### Mercari  → `contracts/mercari.js`

| Function | Status | Notes / action |
|---|---|---|
| `recordMercariSalesBatch` | ✅ **built + deployed** (`functions/mercari_sales.js`) | Client scrapes + sends rows (`items` or `rawItems`); server matches `mercariItemId`→`products/{id}` (+ variant, current + legacy keys), dedupes, writes canonical sale + cascade via shared `recordSaleCore`. Loose envelope + per-row `safeParse` → one bad scrape row = `parse-failed`, not a 400. Accepts the current extension shape (`soldDate` alias). Extension response-handling updated. Still TODO: iOS side. |
| `recordSaleCore` (internal) | ✅ | Extracted from `recordSale`; shared write+cascade path. |
| `detectMercariPullSyncDiff` | **dead** (web calls it) | Port from nested `mercari_pull_sync.js` onto `products/`. |
| `importMercariPullSync` | **dead** (web) | same |
| `updateMercariListingStatus` | **live** | Reconcile the two impls: top-level uses `crossPostStatus.mercari`; nested adds per-variant + `listings.variations[]` mirror. Keep top-level namespace, keep the per-variant handling, drop the `listings` mirror. |
| `ensureMercariListingDetails` | **live** | top-level only. Keep. |
| `recordMercariSale` (singular) | **dead** | Fold into `recordMercariSalesBatch` (batch of 1). Remove. |

### eBay listings  → `contracts/listings.js`

| Function | Status | Notes / action |
|---|---|---|
| `ebayCreateListing` | **live** | Keep top-level impl. **iOS call site changes:** `{ listingId }` → `{ productId }`. |
| `ebayDeleteListing` | **live** | keep top-level |
| `ebayGetListing` / `ebayGetListingDetails` | **live** | keep top-level; UI-wire `ebayGetListing` |
| `ebayUpdateListing` / `ebaySyncListing` | **live** | keep top-level (multi-variant still `unimplemented`) |
| `ebayPullSync` / `ebayImportPullSync` | **live** | keep top-level |
| `recoverEbayOfferIds` | **live** | keep |
| `ebayImportListing` | **dead** (iOS) | **Distinct** from the drift functions — fetches ANY eBay listing by item id (Browse API, app token, no ownership) to seed a new product. Keep. Port `ebay_import.js` onto the shared keyset. |
| `ebayCheckDrift` (today `ebayPullSync`) | **live** | Read-only: compare a product's live eBay offer to its doc. Rename for clarity; keep `ebayPullSync` as an alias through the web migration. Rebase off `listings`/`wonni_` SKU/`credentialSet`. |
| `ebayApplyDrift` (today `ebayImportPullSync`) | **live** | Write selected drifted fields onto the product. Rename; alias kept. Drop the dual `listings` write. |
| `ebayExchangeToken` | **live** | **Keep top-level.** Shared app keyset (`EBAY_CLIENT_ID` / `EBAY_CLIENT_SECRET` / `EBAY_RU_NAME` + `EBAY_ENV`). Per-user data isolation is via `userId` + Firestore rules — unaffected. Drop the nested per-user `isSandbox` token model. |

### Etsy  → `contracts/etsy.js`

**✅ Ported 2026-09-09** — `functions/etsy_listing.js` rewritten from the nested
1043 L impl onto the canonical top-level `products/{id}` model + the single
shared Etsy keyset + `validated()`. 10 callables wired in `index.js`. 13 tests
(`test/etsy.test.js`) cover the pure layer (taxonomy match, inventory + create
payloads, drift diff, field import); the Etsy HTTP layer needs an emulator /
manual smoke.

| Function | Status | Notes |
|---|---|---|
| `etsyCreateListing` | ✅ built, not deployed | `{productId, taxonomyId?, shippingProfileId?, returnPolicyId?}`. `resolveListingPrice` + `listingImagesFor` from `platform_adapters`. Variant products (>1) push an `inventory` payload. Writes `crossPostStatus.etsy:"active"` + `crossPostListingIds.etsy` + `etsyListingId`. |
| `etsyUpdateListing` / `etsyDeleteListing` / `etsyCheckShopSetup` | ✅ built | `{productId}`. Delete = set Etsy state `inactive` + clear pointers. |
| `getEtsyCategories` / `getEtsyReturnPolicies` / `getEtsyShippingProfiles` / `suggestEtsyCategory` | ✅ built | Fixes the broken web Etsy category UI (they were dead — no canonical impl). |
| `etsyPullSync` / `etsyImportPullSync` | ✅ built — **replaced the broken stub** | The old canonical stub read `users/{uid}/products/{id}` (wrong path — that collection doesn't exist). Now top-level `products/`, product-only diff (no `listings/` write). |
| `etsyExchangeToken` | ✅ **fixed** | Now stores `refresh_token` (it didn't — web Etsy tokens died after 1h with no recovery). New `getActiveEtsyToken(uid)` refreshes + recovers `shopId`. **Existing web Etsy connections must reconnect once** to get a stored refresh token. `sale_poller.syncEtsy` + `getOrderTakeHome` now use it too. |
| `dropshipEtsyCreateListing` | **orphan** | still to `firebase functions:delete` once web is confirmed off it |

**Web cleanup (optional, non-blocking):** `PostModal.jsx` / `BulkPostModal.jsx` /
`ProductDetail.jsx` pass `credentialSet: "web"` — the schema accepts & ignores
it. Remove on the next web pass.

### TikTok  → `contracts/tiktok.js` *(to add)*

| Function | Status | Notes / action |
|---|---|---|
| `tiktokCreateListing` / `Update` / `Delete` | **live** | keep top-level; nested uses `tiktokStatus` field vs canonical `crossPostStatus.tiktok` |
| `getTiktokCategories` | **live** | keep |
| `syncTiktokOrders` / `syncTiktokOrdersScheduled` | **live** | keep |
| `tiktokExchangeToken` | **live** | keep top-level |

### Products / import / media

| Function | Status | Notes / action |
|---|---|---|
| `aliexpressImportProduct` / `weverseImportProduct` / `weverseBulkImportProducts` | **live** | keep top-level (opt-in Gemini path). |
| `identifyProductsInImage` | **live** | keep |
| `enrichListing` | ✅ **built** (`functions/enrichment.js`, wired, not deployed) | Merges `identifyItem` + `aiAutofillListing`. `mode:"draft"` `{images[], hints?}` → `identifyDraft` (base64 / data: / https images, `DRAFT_SYSTEM_PROMPT`), persists nothing. `mode:"product"` `{productId, fillBlanksOnly, persist}` → wraps the existing `resolveListingFields()`; writes blank fields when `persist`. Response: `{suggested, writes, proposals, applied, aiModel, aiPromptVersion}` (contract shape — `geminiCategory`→`category`, `weightLbs`→`weightOz`, iOS 7-value condition → canonical 5 via `normalizeCondition`). 7 tests. |
| `identifyItem` | **dead** (iOS) | Superseded by `enrichListing` mode:"draft". iOS `GeminiService.swift` still calls it — repoint in step 9. |
| `aiAutofillListing` | **live** | Kept as-is (web "✨ AI autofill" button) until web migrates to `enrichListing` mode:"product". Both now route through the same `resolveListingFields()` core. |
| `generateProductDescription` | **live** | keep (single-purpose "✨ AI Suggest" description button) |
| `splitProductImage` | **live** | keep |
| `publishStorageObject` | ✅ **built** (`functions/publish_storage_object.js`, wired, not deployed) | Copied verbatim from nested. Deploy unblocks web image uploads. |
| `refreshSourceData` | **orphan** (web uses it, works) | move source into canonical tree |
| `onProductDeleted` | **live** | keep |
| `postToWonni` | ✅ **built** (`functions/wonni_listing.js` + `listing_shape.js`, wired) | Publishes `products/{id}` → the Wonni **marketplace** feed `listings/{id}` (`UserListing` shape, `status:"active"`). Now has the roadmap guard: if a live `listings/{id}` (`status:"active"`) exists it only syncs the product's published flags and returns `skipped:true` instead of re-mapping/clobbering. 8 tests. **This was the ONLY deployed function still coming from the nested tree** — deleted 2026-09-09. |

### Auth / settings / account

| Function | Status | Notes / action |
|---|---|---|
| `generateOAuthState` | **live** | add `"etsy"` to the platform allowlist (nested has it) |
| `disconnectPlatform` / `updateSettings` | **live** | add `"etsy"` to allowlists |
| `aliexpressExchangeToken` / `tiktokExchangeToken` | **live** | reconcile integration-doc field shape (`platform`, `connectedAt` vs token-only) |
| `requestAccountDeletion` / `cancelAccountDeletion` / `purgeDeletedAccounts` | **not deployed** — deferred port | see below |
| `notifySavedSearchMatches` | **not deployed** — deferred port | see below |
| `ebayWebhook` / `setupEbayNotifications` | **not deployed** — deferred port | see below |
| `placeAliexpressOrder` / `confirmTiktokShipment` / `pollAliexpressTracking` | **live** | keep |

---

## Deferred ports (nested tree deleted 2026-09-09)

The nested `wonni/functions/` tree (a full parallel backend, ~40 files) was
**deleted at commit `3a13f55`**. Verified first that only `postToWonni` was
actually deployed from it — everything below was dead code (not deployed
anywhere), so deleting it is not a regression. Retrieve any file with
`git show 3a13f55:wonni/functions/<file>`.

These are genuine features that need a proper port onto `products/` + the
shared keysets + `validated()` when picked up — they are **not** blockers for
the consolidation:

| Feature | Source (at `3a13f55`) | Notes |
|---|---|---|
| `ebayImportListing` | `ebay_import.js` | Fetch ANY eBay listing by item id (Browse API, app token, no ownership) to seed a new product. Distinct from drift-sync. iOS calls it. |
| `ebayWebhook` + `setupEbayNotifications` | `ebay_webhook.js` (346 L) | eBay marketplace-account-deletion notification endpoint (eBay compliance) + order push. Was never deployed → **eBay compliance gap predates this work.** |
| `requestAccountDeletion` / `cancelAccountDeletion` / `purgeDeletedAccounts` | `account_deletion.js` (191 L) | App Store account-deletion requirement (iOS #62). Never deployed → also a pre-existing gap. |
| `notifySavedSearchMatches` | `saved_search_notify.js` | Wonni marketplace saved-search alerts. |
| `ebayRedirect` (onRequest) | `index.js` L174 | `?code=` → `wonni://oauth/ebay?code=` deep link for the iOS eBay OAuth flow. Port if/when iOS eBay OAuth is re-enabled. |
| `identifyItem` | `index.js` L13 | superseded by `enrichListing` mode:"draft"; iOS repoint = step 9. |
| `ebayGetOrderTakeHome` / `etsyGetReceiptTakeHome` | `sale_fetch.js` | superseded by `getOrderTakeHome({saleId})`; iOS repoint = step 9. |

---

## Data-model migration

`listings/{id}` + `inventory/{unitId}`  →  `products/{id}` (+ inline `variants[]`).

| iOS today | Canonical |
|---|---|
| `listings/{id}.quantity` | `products/{id}.variants[i].quantity` (or a top-level `quantity` for no-variant products) |
| `listings/{id}.status` (`active`/`sold`/`draft`) | `products/{id}.crossPostStatus.*` + a `soldOut` flag |
| `listings/{id}.crossPostListingIds.ebay` | same key on `products/{id}` |
| eBay SKU `wonni_${listingId}` | `${productId}` (single) / `${productId}${variantId}` (multi) |
| `crossPostStatus.ebay === "posted"` | `=== "active"` |
| `Sale.listingId` | `Sale.productId` |
| SwiftData local drafts | keep (local only); publish writes `products/` |

**Scope:** only 2–3 real iOS users have `listings` docs. A one-shot script
(`functions/scripts/migrate_listings_to_products.js`) converts them; no
zero-downtime dance needed.

**Swift surface that changes:** `ListingRepository` (467 L), `ProductRepository`,
`SaleRepository`, `Sale.swift`, the draft model, and ~10 `httpsCallable` call
sites (names + payloads).

#### Per-variation Mercari flags — client contract (spec for the iOS repoint)

`product.variants[]` is the inline array on `products/{id}`. Each entry is one
purchasable variation and carries: `id`, `sku`, `quantity`, `active`,
`optionValues` (`{Size:"M"}`), an optional `price` override, and per-platform
listing pointers — including `crossPostListingIds.mercari` (**that variation's
own Mercari listing id**, because a Mercari listing is one item / one size).

The `cascade()` in `functions/sales.js` cannot touch Mercari (no API). It
leaves a flag for the client's headless WKWebView / extension flow to action,
then clear:

| Flag location | Set when | Client does |
|---|---|---|
| `product.pendingMercariDeactivation` (no-variant product) | qty → 0 | end the Mercari listing, then `FieldValue.delete()` the flag |
| `product.pendingMercariRelist` (no-variant) | Mercari-origin sale, qty still > 0 | re-list, clear flag |
| `product.variants[i].pendingMercariDeactivation` | that variant's qty → 0, **or** a GUI mark-out-of-stock | end `variants[i].crossPostListingIds.mercari`; clear via whole-array RMW (never `variants.i.x`) |
| `product.variants[i].pendingMercariRelist` | Mercari-origin sale of that variant, qty > 0 | re-list that variant's listing; clear |

**iOS work (part of step 9):** `CrossPostWebView.swift`'s deactivate/relist
queue reads `UserListing.pendingMercari*` off `listings/`. Repoint it to
`products/`: flatten each flagged variant into its own actionable row (one per
Mercari listing), act on `variants[i].crossPostListingIds.mercari`, clear the
flag with a whole-`variants`-array `setData(merge:)` — **not** a
`"variants.\(i).x"` field path (corrupts the array). `ProfileView` badge count
must sum product-level + per-variant flags.

**Extension:** has **no** Mercari deactivation/relist consumer today — it only
posts to Mercari and scrapes sold items. Sold-out Mercari listings are
currently endable only from iOS. Adding an extension deactivation queue is a
new feature, tracked in § Stretch goals, not part of consolidation.

---

## Sequenced work

1. ✅ **Contract scaffold** — `functions/contracts/` (sales, mercari, listings,
   ebay, etsy, enrichment).
2. ✅ **Port the dead-but-needed functions** onto the canonical tree + schema:
   `publishStorageObject`, `recordSale` + cascade family, `recordMercariSalesBatch`,
   `syncSales` + `getOrderTakeHome`, Etsy CRUD (10), `enrichListing`, `postToWonni`.
   Deferred (dead, not blockers): eBay webhook, account deletion, `ebayImportListing`,
   saved-search notify — see § Deferred ports.
3. ✅ **Deployed** the canonical `functions/` tree (2026-09-09). Verified new
   functions ACTIVE; contract layer enforcing in prod.
4. ✅ **Nested tree deleted** (`3a13f55`) — was a full parallel backend; only
   `postToWonni` was live from it, now ported. `dropshipEtsyCreateListing`
   orphan already gone.
5. **Wire `validated(...)`** into the remaining pre-existing shared functions
   (ebay_listing, tiktok_listing, user_settings, imports) — incremental.
6. ✅ **Monorepo** (`12c906a`, 2026-09-09) — `web/` + `extension/` subtree-merged
   into this repo (history preserved). One root `firebase.json` (hosting from
   wonni_dropship + functions from here), `firestore.rules` / `storage.rules` /
   `firestore.indexes.json` moved up from `wonni/`. `wonni_dropship` is now a
   read-only archive. **Left:** `firebase deploy --only storage` needs Console
   Playground validation first (storage.rules has an undeployed "dropship
   images" block); `firestore.rules` already matches live.
7. ✅ **Migrated** `listings/` → `products/` (2026-09-09). 72 of 73 `listings/`
   docs got a `products/{sameId}` doc (`migratedFromListing:true`); 1 was
   already web-published. `listings/` left in place (marketplace feed +
   old-ref compat). Idempotent re-run = 0 creates. Script:
   `functions/scripts/migrate_listings_to_products.js` (+ census). Reversal:
   delete `products/` where `migratedFromListing == true`.
8. **Repoint iOS** — 🔄 in progress.
   - ✅ **Done** (iOS `** BUILD SUCCEEDED **`): 22 callable payloads
     `{listingId}`→`{productId}`; `identifyItem`→`enrichListing` mode:"draft"
     (GeminiService, same public signature); `ebayGetOrderTakeHome`/
     `etsyGetReceiptTakeHome`→`getOrderTakeHome` (RecordSaleSheet — contract
     widened to also accept `{platform, platformOrderId}` for the pre-save
     fetch). `BackendContracts.swift` already in the Xcode target.
   - **Left (needs a design pass, not mechanical):**
     - `ListingRepository` (467 L) reads/writes `listings/{uuid}` — but it
       mixes the seller's draft CRUD with the buyer-facing **marketplace feed**
       (`fetchFeedPage`, `fetchSuggestedListings` across all users). Only the
       seller side moves to `products/` (via `postToWonni` to publish);
       `listings/` stays the marketplace. `ProductRepository` already does the
       cross-client draft half.
     - `CrossPostWebView` per-variation Mercari flags — read
       `products/{id}.variants[i].pendingMercari*` (spec § Data-model migration).
     - ✅ `Sale` — added `productId` (canonical) alongside legacy `listingId`,
       `linkedProductId` accessor, init mirrors the two; `SaleRepository`
       writes + queries `productId`. Backfilled prod (`backfill_sale_product_id.js`
       — 8 of 18 `sales/` docs). Full `listingId` removal deferred.
9. **Deploy**; smoke-test web + iOS + extension.
10. **Wire `validated(...)`** into the remaining pre-existing shared functions
    (ebay_listing, tiktok_listing, user_settings, imports) — incremental,
    non-blocking.

## Backfill — not needed

Queried prod `sales` on 2026-09-08: all ~19 docs are iOS-written and already
use the canonical field names (`priceSoldFor` / `listingTitle` / `thumbnailUrl`
/ `status` / `isDeleted`). There are **zero** old web-format docs — the web
`LogSaleModal` was never used in production. The `Sales.jsx` compat mapping
shipped in `sales-shared-backend` actually *fixes* the web Sales page, which
had been rendering $0 / no title for every iOS sale.

Remaining gap: old docs carry `listingId` (an iOS `listings/{uuid}` ref), not
`productId`. That is resolved by the listings→products migration (step 8), not
a separate sales backfill.

---

---

## Contract surface

<!-- AUTOGEN:contract-surface -->

<!-- Generated by `npm run contracts:gen` from functions/contracts/*.js — do not edit by hand. -->

**31 callables** validated by `validated(name, handler)`. Request payloads are
parsed against these schemas before the handler runs; bad payloads are rejected
with `HttpsError("invalid-argument", ...)`. Swift types: `contracts/generated/`.

### `sales`

| Callable | Summary |
|---|---|
| `decrementAndCascade` | Drift fix: decrement a product's quantity and push to every connected platform. |
| `getOrderTakeHome` | Fetch the platform's net payout for a recorded sale (eBay/Etsy). |
| `markSoldOutAndCascade` | Force quantity 0 + status sold, cascade deactivation everywhere. |
| `recordSale` | The single sale-write path: writes sales/{id} + fires the quantity cascade. |
| `restockAndCascade` | Set a sold-out product back in stock and re-activate/push to platforms. |
| `syncSales` | Poll eBay + Etsy for orders not yet in sales/, import each via recordSale. |
| `updateSaleStatus` | Move one sale to a stage-board bucket (kanban drag / spreadsheet dropdown). |

### `mercari`

| Callable | Summary |
|---|---|
| `detectMercariPullSyncDiff` | Compare a scraped live Mercari listing against the product doc. |
| `importMercariPullSync` | Pull selected drifted fields from Mercari onto the product doc. |
| `recordMercariSalesBatch` | Take raw scraped Mercari rows → parse + dedupe + recordSale + cascade, server-side. |
| `updateMercariListingStatus` | Extension reports the outcome of a Mercari post/edit attempt. |

### `listings`

| Callable | Summary |
|---|---|
| `ebayCreateListing` | Create or re-publish an eBay listing from a products/{id} doc (single or multi-variant). |
| `ebayDeleteListing` | Withdraw the eBay offer(s); keep the stable offer pointers for a later re-post. |
| `ebayGetListing` | Live READ from the eBay Inventory API via the doc's stable pointers. |
| `ebayUpdateListing` | Apply product-doc edits to the live eBay listing (single-variant only for now). |
| `postToWonni` | Publish a products/{id} to the Wonni marketplace feed (listings/{id}, status:active). Skips a re-write when a live listing already exists. |

### `ebay`

| Callable | Summary |
|---|---|
| `ebayApplyDrift` | Write selected drifted fields from eBay onto the product doc. (deployed today as ebayImportPullSync) |
| `ebayCheckDrift` | Compare a product's live eBay offer against its doc. Read-only. (deployed today as ebayPullSync) |
| `ebayImportListing` | Fetch any eBay listing by item id (Browse API) to seed a new product. Read-only, no ownership needed. |

### `etsy`

| Callable | Summary |
|---|---|
| `etsyCheckShopSetup` | Does the connected Etsy shop have a shipping profile + return policy? |
| `etsyCreateListing` | Create an Etsy listing from a product/{id} (variations, images, taxonomy). |
| `etsyDeleteListing` | Deactivate (draft) the Etsy listing and clear the cross-post pointers. |
| `etsyImportPullSync` | Apply selected drifted Etsy fields (title/price/quantity) onto the product. |
| `etsyPullSync` | Read the live Etsy listing and diff title/price/quantity against the product. |
| `etsyUpdateListing` | Push title/description/price/quantity + inventory to an existing Etsy listing. |
| `getEtsyCategories` | All Etsy taxonomy leaf categories, for the category dropdown. |
| `getEtsyReturnPolicies` | The connected shop's return policies. |
| `getEtsyShippingProfiles` | The connected shop's shipping profiles. |
| `suggestEtsyCategory` | Best-match Etsy taxonomy node for a title + category path (no writes). |

### `enrichment`

| Callable | Summary |
|---|---|
| `enrichListing` | AI-fill listing fields from photos (draft) or gap-fill an existing product. Replaces identifyItem + aiAutofillListing. |

### `settings`

| Callable | Summary |
|---|---|
| `updateSaleStages` | Replace the user's sale-stage board/dropdown bucket list (kanban columns). |

<!-- /AUTOGEN:contract-surface -->


## Stretch goals

- **Email-triggered Mercari sale import.** Manual HTML scraping via the
  extension is tedious. A Cloud Function (Gmail push / `mail` collection /
  forwarding address) parses Mercari's "Your item sold" / shipping-label
  emails into `MercariScrapeItem` rows and calls `recordMercariSalesBatch`.
  Dedupe already handles overlap with a later extension scrape. Non-blocking
  for consolidation; do it after `syncSales`.
- **Sale-alert notifications.** Push/email to the user when any platform sale
  lands (eBay/Etsy poll, Mercari email/scrape), off the same ingest path.
- **Extension Mercari deactivation/relist queue.** The extension can post to
  Mercari and scrape sold items but can't *end* or *re-list* a listing — only
  iOS `CrossPostWebView` does that (reading `pendingMercari*`). A web/extension
  user's sold-out Mercari listings stay live until they open iOS. Add a
  background queue in the extension that watches `products/` for
  `pendingMercari*` (product- and variant-level) and runs the headless flow.

## Settled

- **eBay token model** — shared app keyset (`EBAY_CLIENT_ID`/`SECRET`/`RU_NAME`
  + `EBAY_ENV`). Per-user isolation is `userId` + rules, unaffected.
- **`ebayImportListing`** is its own thing (fetch-external-to-seed), kept
  separate from `ebayCheckDrift` / `ebayApplyDrift` (own-listing drift sync).
- **`identifyItem` + `aiAutofillListing`** → one `enrichListing` with a
  `mode` discriminator and the shared `ListingFields` output shape.

## Open decisions

- **quicktype enum naming** — generated Swift names shared enums after the
  first struct that used them (`DecrementAndCascadeRequestPlatform`).
  Acceptable for now; fix later with a post-process pass or hand-written shims.
- **`enrichListing` draft-mode images** — base64 (simple, size-limited) vs
  Storage URLs (needs upload first). Leaning: accept both, prefer URLs.
