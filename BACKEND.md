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
| `decrementAndCascade` | ✅ **built** | On `products/` model. All iOS call sites already pass `{productId}` (verified 2026-09-12 across `SaleRepository`/`RecordSaleSheet`/`CrossPostWebView`/`MainView` — some still hold the value in a locally-named `listingId` variable, but the payload key is correct). |
| `restockAndCascade` | ✅ **built** | `{productId, quantity}` (was `{listingId, quantity}`) |
| `markSoldOutAndCascade` | ✅ **built** | `{productId}` (was `{listingId}`) |
| `syncSales` | ✅ **built** (`functions/sale_poller.js`, wired, not deployed) — needs a one-time reconnect, see below | Polls eBay (`/sell/fulfillment/v1/order`) + Etsy (`/receipts`), matches SKU/listing-id → `products/{id}` (+ variant), records each via `recordSaleCore` (`source:"ebay-poll"`/`"etsy-poll"`, forward-only status). Best-effort per-order tracking + finance lookups. Returns `{imported, skipped, saleIds, errors}`. Mercari still client-scraped. **`syncSalesScheduled` (2026-11-12, not deployed):** every 30 min, polls each connected eBay/Etsy user since their own `lastSalesPollAt` minus a 1 h overlap (30-day cap; `recordSaleCore` dedupes), via the shared `syncSalesForUser`. The manual button is unchanged. |
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
| `ebayWebhook` | **ported 2026-11-13, not deployed** (`functions/ebay_webhook.js`) | `setupEbayNotifications` retired: subscribing happens per seller on connect |
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

**48 callables** validated by `validated(name, handler)`. Request payloads are
parsed against these schemas before the handler runs; bad payloads are rejected
with `HttpsError("invalid-argument", ...)`. Swift types: `contracts/generated/`.

### `sales`

| Callable | Summary |
|---|---|
| `decrementAndCascade` | Drift fix: decrement a product's quantity and push to every connected platform. |
| `getOrderTakeHome` | Fetch the platform's net payout for a recorded sale (eBay/Etsy). |
| `markSoldOutAndCascade` | Force quantity 0 + status sold, cascade deactivation everywhere. |
| `pushEbayQuantityUpdate` | Manual Wonni quantity edit → push the new quantity to eBay only (Etsy/TikTok not wired yet). |
| `reassignSaleStage` | Bulk-move every sale in one stage-board bucket to another (used when deleting a custom bucket). |
| `recordSale` | The single sale-write path: writes sales/{id} + fires the quantity cascade. |
| `restockAndCascade` | Set a sold-out product back in stock and re-activate/push to platforms. |
| `syncSales` | Poll eBay + Etsy for orders not yet in sales/, import each via recordSale. |
| `updateSaleStatus` | Move one sale to a stage-board bucket (kanban drag / spreadsheet dropdown). |

### `mercari`

| Callable | Summary |
|---|---|
| `detectMercariPullSyncDiff` | Compare a scraped live Mercari listing against the product doc. |
| `importMercariPullSync` | Pull selected drifted fields from Mercari onto the product doc. |
| `listMercariSaleInbox` | Mercari sales waiting for review (pending) and hidden ones (discarded), for the banner + review list without a scan. |
| `recordMercariSalesBatch` | Take raw scraped Mercari rows → parse + dedupe + recordSale + cascade, server-side. |
| `reviewMercariSales` | Refresh step 1: classify scraped Mercari rows as new / recorded / discarded / invalid and report where to stop scanning (first already-recorded row). With autoImport: records id-matched complete rows, saves the rest to the review inbox, returns the inbox. |
| `setMercariSalesDiscarded` | Refresh step 3: Never import (tombstone) or Restore Mercari rows. Server-only store users/{uid}/mercariSaleInbox. |
| `undoMercariAutoImport` | Undo for auto-imported Mercari sales: delete the sale, restore stock (eBay/Etsy pushed back up), put the row back in review. |
| `updateMercariListingStatus` | Extension reports the outcome of a Mercari post/edit attempt. |

### `listings`

| Callable | Summary |
|---|---|
| `deleteProductEverywhere` | Stop selling a product everywhere: delete its live eBay / Etsy / TikTok listings in parallel, then the products/{id} doc. If any platform delete fails the doc is KEPT (retry-safe) and the failures are returned. Mercari has no delete automation, so it is reported in manualRemoval. |
| `ebayCreateListing` | Create or re-publish an eBay listing from a products/{id} doc (single or multi-variant). |
| `ebayDeleteListing` | Withdraw the eBay offer(s); keep the stable offer pointers for a later re-post. |
| `ebayGetListing` | Live READ from the eBay Inventory API via the doc's stable pointers. |
| `ebayUpdateListing` | Apply product-doc edits to the live eBay listing (single-variant only for now). |
| `postToWonni` | Publish a products/{id} to the Wonni marketplace feed (listings/{id}, status:active). Skips a re-write when a live listing already exists. |
| `startPostJob` | Post a product to eBay or Etsy as a BACKGROUND job (for products split across several listings). Returns a job id at once; progress is on postJobs/{jobId} (status queued|running|partial|done|failed, groupsDone/groupsTotal, groups[]). An unfinished job for the same product+platform is returned instead of starting a second. |

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

### `crossPostRules`

| Callable | Summary |
|---|---|
| `applyCrossPostRules` | Run a user's ordered cross-post rules against a product; on the first match, compute the listing price + shipping estimates and trigger cross-posting to the matched platforms. |

### `weverseOrderTasks`

| Callable | Summary |
|---|---|
| `listWeverseOrderTasks` | List this user's pending (or filtered) Weverse re-order tasks, for the extension to poll. |
| `recordWeverseOrderPlaced` | Human confirms they manually placed the re-order on Weverse — marks the task ordered + records cost paid onto the linked sale. |

### `bulkDrafts`

| Callable | Summary |
|---|---|
| `bulkDraftsFromText` | Same function as textToListings under its original name (kept for iOS builds in the field). |
| `commitListingProposals` | Web commit step for textToListings: reviewed proposals become products/{id} draft docs with their photos re-hosted into our bucket. |
| `draftPhotoCandidateDetail` | One chosen eBay listing's full photo set and sell-similar details (category, condition, ePID, item specifics) for import onto a draft. |
| `draftPhotoCandidates` | Search live eBay listings for a draft's photo chooser: every result with a photo, strong (same item, same state) matches first. |
| `generateListingPhoto` | AI-generate one product photo for a listing (consent-gated on the client); saved public under users/{uid}/generated/. |
| `textToListings` | ONE text-or-links → listings call: product URLs are resolved (Amazon / eBay / AliExpress / Weverse / any page), the text is parsed into listings, multi-item entries wait in needsDecision, the rest are priced and photographed. Persists nothing. |

<!-- /AUTOGEN:contract-surface -->


## Sold-out + sales tracking — product decisions (2026-10-24)

Agreed with the user 2026-10-24. These supersede the older notes where they
differ; the "reconciled" lines say what changed. Nothing here is built yet.

### 1. "Mark as sold out" is a queued job, like posting
- Selecting one or more listings and choosing Mark as sold out enqueues ONE
  job per listing on the same queue publishing and cross-posting use (iOS
  `AppTaskQueue` + `CrossPostRunStore` persistence, so it survives leaving the
  app and shows the "interrupted" banner on return). The pill reads
  "Marking sold out · 1 of 4"; tapping it opens the full-screen progress list,
  and a Mercari row opens that listing's web view (see 2).
- Per listing the job is: `markSoldOutAndCascade({productId})` (zeroes every
  active variant, cascades qty 0 to eBay/Etsy/TikTok, sets `pendingMercari*`)
  → then, if the product is on Mercari, the Mercari step below. The job is
  `ended` only when both finished; a Mercari failure leaves the flag so the
  pending-actions screen still shows it.
- **Reconciled:** replaces the foreground confirm + spinner in
  `ProfileView.markAsSoldOut` and `BulkEditSheet.markSelectedOutOfStock`
  (3 silent retries). Closes #36's gap properly. The web "Mark as out of
  stock" `"..."` action noted under the eBay lifecycle work calls the same
  callable; web has no pill, and its Mercari step is the extension queue (§
  Stretch goals) — unchanged.

### 2. Mercari sold-out runs in a minimized web view, deactivate OR delete
- The Mercari step is a `CrossPostWebView`-style job: minimized by default,
  openable from the pill/progress list to watch or fix a login, never a fully
  hidden headless run. `MercariListingStateAutomator` (My Listings page,
  checkbox, Deactivate/Activate button; #17/#35, never device-verified) is the
  starting point for the script, re-hosted in that visible-on-demand view.
- **New user setting** `mercariSoldOutAction: "deactivate" | "delete"`,
  default **deactivate**, next to the other Mercari prefs
  (`settings/mercariShipping`, same surface as `keepSmartPricing`; web
  Settings gets it too). Deactivate keeps `crossPostListingIds.mercari` so a
  restock re-activates (#17); delete clears the id and the Mercari status,
  and a restock re-posts from scratch — the setting's help text must say so.
- **Reconciled:** the cascade's `pendingMercariDeactivation` flag name stays
  (BACKEND.md "Mercari is binary" table); the client reads the setting to pick
  the action. The `variants[i].pendingMercari*` gap still applies.
- **Mock approved 2026-10-29** (https://claude.ai/artifact/FMeSfkN9c7PBsfT9NDA7wo)
  with these answers: the progress list groups **by listing** (one row per
  listing, one chip per platform); a job leaves the queue only once every
  platform confirmed, and when all rows are done the pill and list close by
  themselves — no Done tap; a platform step that has not confirmed after
  **60 s times out and auto-retries once**, and a listing that still fails is
  marked **back in stock** and shown in a "not marked sold out" list at the
  end (same shape as the publish screen's failed-platform list); the
  Deactivate | Delete choice is **account-wide only** (no per-listing choice —
  the one edge case, deactivate pending-pickup items but delete sold ones, is
  not worth a per-run control), and a run under Delete asks once per run:
  "Delete out-of-stock listings on Mercari?".

- **Built 2026-11-02 (iOS; device run pending).** `Data/SoldOutRun.swift` (rules +
  `SoldOutRunStore`, tests `SoldOutPlanTests`), `Data/SoldOutRunner.swift` (the
  loop: `markSoldOutAndCascade` → `MercariListingStateAutomator` with 60 s timeout
  × 2 attempts; a Mercari failure restores stock via `restockListing` +
  `restockAndCascade`), `Views/SoldOutProgressView.swift` (list + `SoldOutMercariWebView`
  cover), `Views/MercariSettingsView.swift` (replaces `MercariShippingPreferencesView`;
  `soldOutAction` added to `settings/mercariShipping`, AppStorage
  `mercariSoldOutAction`). Entry points rewired: ProfileView row alert,
  EditListingSheet "Mark as Sold Out", BulkEditSheet "Mark as Out of Stock".
  MainView presents the sheet and the "interrupted" Resume alert. **Unverified:**
  the automator's `.delete` pass (inactive tab → `DeleteAllButton` or a button
  reading "Delete" → confirm dialog) is a guess at Mercari's markup; a miss opens
  the web view for the user to finish, never a silent success. The Deactivate pass
  reuses the 2026-07 selectors that were themselves never run on a device.

### 2b. Mercari Smart Pricing is set at three levels (2026-11-02, mock approved, built on iOS)
- Account default (today's `keepSmartPricing`), a per-posting toggle shown
  indented under the Mercari checkbox in `CrossPostSheet` while Mercari is on,
  and a per-listing Off/On control (in the sheet's "N listings" expander and
  on the listing/draft edit sheet). **Most recent choice wins**, encoded
  without timestamps: touching the posting toggle resets every listing's
  override to match; a listing control touched afterwards wins for that
  listing. Under $10 stays forced off (`mustDisableSmartPricing`). Resolution
  = one pure, tested `resolveSmartPricing(price, account, posting, listing)`
  used by the iOS poster, the edit flow and the extension payload. Listing
  field `mercariSmartPricing: true | false` (nil = follow). Editing it after
  posting re-runs the Mercari edit flow to flip the switch there.
- **Built 2026-11-02 (iOS; device run pending).** `MercariFormJS.resolveSmartPricing`
  (tests in `MercariFormJSTests`); `CrossPostJob.smartPricing` /
  `PersistedCrossPostJob.smartPricing` (nil = account); `CrossPostSheet` returns
  `CrossPostOptions` next to the platform set, shows the indented toggle while
  Mercari is on (starts at the account value), the "N Listings ⌄" heading and the
  plain Wonni footer line; the Mercari row has no caption. Per listing:
  `Item.mercariSmartPricing` (draft pencil sheet, "Mercari" section) and
  `UserListing.mercariSmartPricing` (EditListingSheet toggle under the Mercari row;
  changing it writes the field and opens `MercariAutoEditSheet(smartPricing:)`, whose
  `MercariAutoEditState` now resolves with that value instead of the account default;
  greyed under $10). Jobs: `UploadManager.pendingMercariSmartPricing` carries the
  Post menu value into the post-publish job build, `ProfileView.bulkPostListings`
  takes `CrossPostOptions`; both prefer the listing's own value. The poster passes
  `job.smartPricing ?? account` into `ShippingPreferences.keepSmartPricing`.
  **Not done:** web (no Smart Pricing control at all) and the extension payload still
  send only the account value.

### 3. Mercari sales: Refresh → review → record → link → cascade
- A **Refresh** button (iOS Sales dashboard, web Sales page) scans Mercari's
  `in_progress` then `complete` tabs newest-first (`sortBy=7`) and stops at
  the **first row already recorded** on each tab (match by Mercari item/order
  id against existing sales). This is what iOS `scanForNewSales` already does
  for `in_progress`; the plan's "both tabs" scope stands.
  Caveat to keep in mind: a sale can sit behind a known row if an earlier scan
  skipped it (login wall, timeout) — the Refresh menu keeps a "Full rescan"
  option that ignores the stop rule; dedupe makes it safe.
- **Review step, opt-out model (user choice):** every new row is listed,
  checked by default; the user unchecks what not to import. Rows whose Mercari
  id matches a product (`crossPostListingIds.mercari`, product or variant) show
  the linked product; unmatched rows show "Link to product…" (pick product +
  variant / SKU). Import records each checked row via `recordSaleCore`
  (dedupe by `platformOrderId` query), writes the product pointer back where
  it was empty (so the next scan auto-matches), decrements the sold bucket and
  fires the cascade — qty 0 ⇒ the sold-out queue in §1 handles the other
  platforms. Unchecked rows are left; "Never import" sends a row to the inbox
  as `discarded` (tombstone + Restore).
- **Reconciled against the 2026-10-12 plan (Part B):** the plan auto-imported
  matched rows and only sent unmatched ones to the inbox. Now ALL new rows
  pass through the review list first; the `mercariSaleInbox` collection keeps
  its three states but becomes the "decided later / discarded" store rather
  than the main UI. `importMercariSales`, the shared scraper
  (`MercariScanJS`), the Match-writes-pointer rule and the email-ingest idea are
  unchanged. iOS `pendingMercariSales` is still the inbox's ancestor.

- **Backend built 2026-11-12 (not deployed; no client yet):** `reviewMercariSales
  {items}` classifies scraped rows (newest first) as `reviewState` new / recorded /
  discarded / invalid, with the matched product + title and `firstRecordedIndex`
  (the stop point); it records nothing. `recordMercariSalesBatch` gained `links
  {mercariItemId: {productId, variantSku}}` for "Link to product…" answers — the
  Mercari id is written onto the product/variant only where empty (whole-array
  variants rebuild). `setMercariSalesDiscarded {items, discarded}` writes/removes
  `users/{uid}/mercariSaleInbox/{mercari_<order|item id>}` (server-only, no rules
  change). Field is `reviewState`, not `state`: quicktype made a top-level Swift
  `enum State` that shadows SwiftUI's `@State`. **iOS review UI built 2026-11-12**
  (`Data/MercariRefresh.swift` plan + service, `Views/MercariRefreshReviewSheet.swift`,
  tests `MercariRefreshPlanTests`): `SalesDashboardView.syncWebPlatforms` now enriches what
  `scanForNewSales` found, calls `reviewMercariSales`, and shows the opt-out review list
  (uncheck / Link to product… / swipe Never import); Import calls
  `recordMercariSalesBatch`. It replaces the old auto-import + `pendingMercariSales`
  branches (the `mercariAutoImport` setting and the "+" modal are now unused by Refresh).
  **Scan (2026-11-13):** Refresh now reads `in_progress` then `complete` (`MercariSaleTab`)
  and stops at the first already-recorded sale in each list (`stopAtKnown`); the sync
  button's long-press menu has "Full rescan of Mercari" (no stop; rows the user hid with
  "Never import" come back in a "Never import" section with Restore). The `complete` URL
  (`/mypage/listings/complete/?sortBy=7`) and its DOM are assumed to match `in_progress`;
  unverified on a real account. **Not done:** a standing "Discarded (N)" menu entry (restore
  works only from a Full rescan), the Chrome extension and web review step (mock first), and
  nothing here has run against a real Mercari account.

- **Amended 2026-11-14 (user; mock https://claude.ai/artifact/3N5S6mWWBA36jptkxDtygP
  v4) — linked sales import on their own; built on web, extension and iOS, deploy
  pending.** Supersedes the "ALL new rows pass through review" rule above.
  - `reviewMercariSales {items, autoImport: true, recordLinked}`: a row matched by a
    Mercari id already on a product AND carrying title + price > 0 + sold date is
    recorded right there (`reviewState: "autoRecorded"`, sale gets `autoImported:
    true`, inbox doc `state: "autoRecorded"` keeps the scrape + `saleId`). Every other
    new row is written to `users/{uid}/mercariSaleInbox` as `pending` with the scraped
    item, so it survives stop-at-known refreshes and other devices. A title-only match
    (≥60% of the sale's words, unique) comes back as `suggestedProductId` and is only
    ever recorded when the user imports the row. `recordLinked: false` = the app's
    "Auto-import linked Mercari sales" switch is off (everything waits). Without
    `autoImport` the call still only classifies (older iOS builds).
  - `listMercariSaleInbox` → `{pending, discarded}` rows `{item, inboxState, productId,
    variantSku, productTitle, suggestedProductId, suggestedProductTitle, missing}`
    (field is `inboxState`, not `state`, for the same quicktype `enum State` reason).
  - `undoMercariAutoImport {items}`: only inbox rows in `autoRecorded` whose sale has
    `autoImported: true` — deletes the sale, `applyQuantityDelta(+qty)` + `cascade`
    with `soldOnPlatform: null` (pushes eBay/Etsy back up, sets no Mercari flag), row
    back to `pending`. A Weverse re-order task the sale created is left in place.
  - `recordMercariSalesBatch {allowUnlinked: true}` records a row with no product and
    no stock change ("Not linked"); `quantity` per row; recorded rows leave the inbox.
  - Never import keeps the scraped row on the tombstone, so Restore puts it straight
    back in `pending` (older tombstones without one are deleted, as before).
  - **Clients.** Web Sales: ↻ Refresh = `syncSales` + the extension's
    `SCAN_MERCARI_SALES` (`mercari_sold_content.js` no longer auto-records; it answers
    the dashboard bridge only, internal message from a dashboard tab), banner + review
    modal + edit form (`components/MercariReview.jsx`); the per-product "Check Mercari
    for sold items" entry is gone. Edits in the review form are not saved until Import
    (Cancel keeps the scraped row, not the edits). iOS: toolbar is ↻ and + only (Full
    rescan moved to Settings › Mercari › "Rescan all Mercari sales", which flags the
    next refresh), floating banner instead of the auto-opened sheet, review sections
    Needs info / Ready / Never import, `MercariSaleEditSheet` per row. Extension
    enrichment fetches the item page (`__NEXT_DATA__` price in cents, photo) and the
    order-status page (take-home, sold date) by `fetch`; whether those pages carry the
    data without client rendering is unverified, so expect "Needs info" rows until a
    real run says otherwise.

### 4. eBay (and Etsy) sales import is automatic
- `syncSales` (`sale_poller.js`: eBay Fulfillment orders + Etsy receipts) is
  manual today — web Sales button, iOS pull-to-refresh. Decision: run it on a
  schedule for every user with a connected eBay/Etsy integration (pattern:
  `syncTiktokOrdersScheduled`), keep the manual button for "now". Default
  lookback stays; a per-user `salesSyncedAt` cursor replaces the fixed window
  once scheduled.
- **eBay webhook (#26), ported 2026-11-13, not deployed.** `functions/ebay_webhook.js`
  `ebayWebhook` (HTTPS): GET answers eBay's challenge (sha256 of code + the
  `EBAY_VERIFICATION_TOKEN` secret + the `EBAY_WEBHOOK_URL` param); POST checks
  `X-EBAY-SIGNATURE` (ECDSA, eBay public key by `kid`, app token) and answers 412
  on a bad one, then routes: `ORDER_CONFIRMATION` (seller found by
  `orderNotificationSubscriptionId`, then `ebayUserId`, then `connectedUsername`)
  (username last, sale pushes only) runs `syncSalesForUser(only: "ebay", 2-day lookback)`, the same path as the
  30-minute poll, which stays as the backstop; `MARKETPLACE_ACCOUNT_DELETION`
  deletes that eBay account's `integrations/ebay` docs, matched ONLY by `ebayUserId` (the compliance endpoint
  eBay requires, possibly why the keyset was refused 2026-10-16). Always 204,
  never a retry loop on our own errors. Subscribing: `ebayExchangeToken` stores
  `ebayUserId` and calls `ensureEbayOrderSubscription` (best effort; destination
  created once and kept in `system/ebayNotifications`). Needs the new
  `commerce.notification.subscription` scope (added to web Settings + iOS
  authorize URLs and `EBAY_SCOPES_DESIRED`), so every seller reconnects once.
  Unverified live: eBay's acceptance of the scope on our keyset, the exact
  ORDER_CONFIRMATION payload, and destination creation with a user token.
  Collection-group indexes for `ebayUserId` / `connectedUsername` are in
  `firestore.indexes.json`. Tests: `test/ebay-webhook.test.js`.

## Scale + multiple eBay accounts — product decisions (2026-11-11, user)

**Why:** eBay caps free (no-fee) listings at about 250 per account for most
sellers. Two levers, both deliberate product direction:

1. **Pro option: several eBay accounts per user, grouped by what they sell.**
   E.g. 240 listings on an anime-collectibles account, 213 on a trading-cards
   account, 180 on a vintage-fashion account. Ties into the earlier "products
   grouped" design and into the multiple-storefront idea (CLAUDE.md § Backlog):
   integrations are one-per-platform per user today
   (`users/{uid}/integrations/ebay`), so this needs integrations keyed by an
   account id, an account (or group) on each product, and routing through
   `crossPostRules`. Touches every eBay create/update/sync/delete path and the
   sales cascade — needs its own plan before code. Check eBay's policy on
   multiple seller accounts per person first (business reason, linked-account
   risk).
2. **Pack many items into ONE listing with variations, up to eBay's maximum.**
   Example: a large comic collection sold as a single listing so it costs one
   of the 250 slots. Realistic shape: 30+ series, 20+ options each (600+
   variants).

**Rules for every future decision (don't limit more than the platforms do):**
- Never cap variation count/dimensions below the platform's own API limit. The
  web editor's 2-dimension cap (`MAX_VARIATION_DIMENSIONS`) mirrors Etsy; it
  is not a count cap — keep it that way, and do not add one.
- **eBay limits — VERIFIED 2026-11-11** ([Trading API variations guide](https://developer.ebay.com/api-docs/user-guides/static/trading-user-guide/variations.html)):
  max **250 variations per listing**, max **5 specifics per variation**, max
  **30 values per specific name** (so one "Series" dimension can't hold 30+
  series in one listing either). The Inventory API reference states no limits
  of its own; the 250 figure also matches the "too many variations" error
  third-party integrations report. Etsy's limits still need the same check.
- **Etsy limits — VERIFIED 2026-11-11** (Etsy developer docs: [Listings tutorial](https://developers.etsy.com/documentation/tutorials/listings/),
  [Third Variation tutorial](https://developers.etsy.com/documentation/tutorials/third-variation/),
  [seller help](https://help.etsy.com/hc/en-us/articles/115015664047-How-to-Add-Variations-to-Your-Listings)):
  max products (variant combinations) per listing = **70** with one variation
  type, **4,900** with two, **2,500** with three — BUT only **400** when price,
  quantity, SKU or readiness state varies by ALL variation properties
  (`*_on_property` covers every property) on a 2- or 3-variation listing.
  No documented cap on options per type. Three types need
  `max_variations_supported=3` on the inventory PUT (developer preview from
  2026-08-17, no GA date given); the web editor's 2-type cap is therefore still
  right for Etsy, don't raise it yet. Comics: one "Issue" type holds at most
  70 per Etsy listing; Series x Issue holds 4,900 only if price/qty/SKU do not
  vary per combination, else 400 — so Etsy needs the same auto-split idea as
  eBay (not built), with a smaller group size (70 / 400 / 4,900 by shape).
  **Payload fixed 2026-11-11 (unit-tested only, NOT live-verified):**
  `buildEtsyInventoryPayload` now sends custom property ids (513, 514) with
  `property_name`, lists ALL property ids in `price_on_property` /
  `quantity_on_property` / `sku_on_property` when that field differs across
  variants (empty when uniform — e.g. shared pool at one price), stops
  inventing `SKU_n`, and refuses a listing over Etsy's 70 / 400 / 4,900 limit
  or with more than 2 types with a readable error. The docs don't show the
  custom-property JSON; the shape used (`property_id` 513/514 + name + `values`,
  empty `value_ids`) is from Etsy's API conventions — confirm with one real
  draft after re-linking Etsy. 
  **Etsy auto-split — built 2026-11-11 (fake-Etsy tests only, not live):**
  `etsy_inventory.js` (payload + `planEtsyListings`, same engine as eBay's
  planner) splits a product into one Etsy listing per 70 / 400 / 4,900
  combinations by shape, a series kept whole. Doc: `etsyListings:
  [{groupKey, listingId}]` (only when split; first mirrored in
  `etsyListingId` / `crossPostListingIds.etsy`) + `variants[i].etsyGroupKey`.
  `syncEtsyGroups` (create AND update) creates missing listings (draft → photos →
  inventory → publish), PATCHes + replaces inventory on existing ones,
  deactivates listings whose variants all moved away, and writes the doc after
  every listing. Delete deactivates all; pull-sync sums quantity across
  listings and strips " - Part N of M"; the shared-pool sale push now uses the
  same payload builder and updates every listing (the old copy in `sales.js`
  had the empty-`*_on_property` bug). Gaps: a per-variant sale on a
  NON-shared split product doesn't push to Etsy (same as the unsplit case
  today); Etsy listings cost $0.20 each, so a split costs more per product.
- **eBay variation limits — reference copy** (verbatim figures from the
  [Trading API variations guide](https://developer.ebay.com/api-docs/user-guides/static/trading-user-guide/variations.html),
  fetched 2026-11-11; re-check the page if eBay changes them). Quoted:
  "The maximum number of variations allowed for any listing is 250."
  "You can include up to five (5) name/value pairs in each variation."
  "You can specify up to 30 values for each name in the set."
  "The price of each variation must satisfy the minimum price requirement for
  the marketplace and category of the listing." Plain English: a *variation*
  is one buyable combination (a row). A *name* is a dimension (Series, Range,
  Issue — at most 5 per listing). Each name has at most 30 *distinct values*
  across the WHOLE listing. Rows are flat combinations, not a tree — eBay has no
  "sub-variation" nesting; the buyer picks one value per dropdown, and only
  the rows you actually create are buyable. Worked example: Series > Range >
  Issue is 3 names (fine, max 5), but "Issue" may hold only 30 distinct values
  per listing, so #100-130 (31 issues) already doesn't fit one listing, and 5
  ranges x 30 issues is 150 rows (under 250) only if the issue labels repeat
  (#1-#30 in each range); distinct issue numbers across ranges still count
  toward the 30. Our planner splits by those rules.
- **Auto-split — built 2026-11-11, not live-tested.** `ebay_variant_groups.js`
  plans one eBay item group per <=250 variations / <=30 values per name,
  keeping a primary-option value (a series) whole in one listing. Group 1 keeps
  the legacy key (`productId`), later ones are `${productId}g2`…; titles get
  " - Part N of M". Stable across re-posts: a variant keeps `variants[i].ebayGroupKey`.
  The doc gets `ebayGroups: [{groupKey, listingId}]` only when split;
  `ebayInventoryItemGroupKey` / `crossPostListingIds.ebay` / `ebayListingId`
  stay the FIRST group. Over 5 variation types is refused with a readable error.
  `postMultiVariant` writes the doc after each group, so a failure on group 3
  never loses groups 1-2. `ebayDeleteListing` withdraws every group.
  **Reads/sync (2026-11-11):** `ebayGetListing` returns `groups[]` (one per eBay
  listing, with its listingId); `readMultiVariantEbayData` (pull sync, details),
  `syncMultiVariantFromEbay` and the sale cascade already spanned every variant
  offer, so quantity / price / "ended" cover all groups. The title comes from
  group 1 with " - Part N of M" stripped (`stripGroupTitle`) so it never leaks
  into the Wonni title. Gap: the web "View on eBay" link still shows group 1.
- **Bulk posting — built:** `ebay_bulk.js` — inventory items via
  `bulk_create_or_replace_inventory_item` and new offers via `bulk_create_offer`
  (25 per call, failed rows retried singly so the real eBay error surfaces and
  create-or-adopt still applies); existing offers PUT with bounded concurrency
  (8); the shared-pool quantity push to `bulk_update_price_quantity` is now
  chunked by 25 (it was a single call, a bug past 25 variants). Still ONE
  callable (300 s) — a 600-variant product is ~3 groups x a few dozen calls,
  expected to fit, unmeasured. A queued background job with progress is the
  next step if a real run times out.
- **Background posting jobs — built 2026-11-11 (fake-db tests only; NOT
  deployed, needs a rules deploy too):** `post_jobs.js`. `startPostJob
  {productId, platform: ebay|etsy}` returns a job id at once (an unfinished job
  for the same product+platform is returned instead); the Firestore trigger
  `onPostJobCreated` (540 s, eBay + Gemini secrets bound) runs the platform's
  create core with `onProgress` / `shouldStop` / `skipGroupKeys` hooks and writes
  progress to `postJobs/{id}` (`status` queued|running|partial|done|failed,
  `groupsDone/groupsTotal`, `groups[]`, `doneGroupKeys`, `error`). After ~400 s with
  listings left it ends `partial` and queues a continuation (chain capped at 20)
  that skips the listings already live; a failure keeps `doneGroupKeys`, and "retry"
  is just a new job. `firestore.rules`: owner read, no client writes (`postJobs`).
  Semantics change: a split product's `crossPostStatus.<platform>` is now
  "pending" until EVERY listing is up (it was "active" after the first), so a
  half-posted product never looks done. Not built yet: the web/iOS progress UI
  (mock: claude.ai/artifact/NKuzXHbfkNwYTe2og6zyhR, awaiting review) and wiring
  the existing Post buttons to `startPostJob`.
- **Etsy "post as drafts" setting — built 2026-11-12 (replaces the dry-run
  callable `etsyDraftTest`, deleted).** Etsy has no sandbox but charges $0.20 only
  on PUBLISH. Settings › Advanced has "Post to Etsy as drafts (don't publish)"
  (`users/{uid}/sellingSettings/default.etsyPublishAsDraft`, off by default). No new
  buttons: the normal Post flow (`etsyCreateListingCore`, also the background job)
  reads the setting and, when on, runs the same create → photos → real variation
  inventory path but skips the publish PATCH. The product gets
  `crossPostStatus.etsy = "draft"` (not "active", so the sale cascade and live chips
  ignore it; ProductDetail shows "Etsy: Draft (not published)"), and an inventory
  rejection is thrown instead of swallowed so the error shows. Re-posting with the
  setting OFF publishes the same drafts (no duplicates). Delete the drafts with the
  normal "Delete Etsy listing". The response carries `draft: true`; PostModal /
  BulkPostModal then write "draft" rather than "active".
- **Web links for split products:** `web/src/lib/platformLinks.js
  getPlatformListingUrls(platform, product)` returns one `{label, url}` per
  listing (eBay `ebayGroups`, Etsy `etsyListings`); the chip/menu UI waits on the mock.
- **Web posting crawlers (Mercari / Facebook autofill) must survive a long
  list**: resumable, runs in the background, per-listing retry, progress
  persisted (see `CrossPostRunStore` on iOS and the web job queue). A run of
  hundreds of listings is a normal case, not an edge case.

**Done toward this:** `ebayUpdateListing` now edits a multi-variation listing
in place (2026-11-11, `pushEbayEdit` -> `syncMultiVariantToEbay` ->
`postMultiVariant`; it used to throw `unimplemented`). Not live-verified;
unit-tested for routing and the concurrency cap only. Known gap: a variant
deactivated/removed after posting drops out of the group on republish but its
eBay inventory item + offer are left behind (not live, just clutter).

## Stretch goals

- **Email-triggered Mercari sale import.** Manual HTML scraping via the
  extension is tedious. A Cloud Function (Gmail push / `mail` collection /
  forwarding address) parses Mercari's "Your item sold" / shipping-label
  emails into `MercariScrapeItem` rows and calls `recordMercariSalesBatch`.
  Dedupe already handles overlap with a later extension scrape. Non-blocking
  for consolidation; feeds the same Refresh review list (§ Sold-out + sales
  tracking decisions, 2026-10-24, item 3).
- **Sale-alert notifications.** Push/email to the user when any platform sale
  lands (eBay/Etsy poll, Mercari email/scrape), off the same ingest path.
- **Extension Mercari deactivation/relist queue.** The extension can post to
  Mercari and scrape sold items but can't *end* or *re-list* a listing — only
  iOS `CrossPostWebView` does that (reading `pendingMercari*`). A web/extension
  user's sold-out Mercari listings stay live until they open iOS. Add a
  background queue in the extension that watches `products/` for
  `pendingMercari*` (product- and variant-level) and runs the headless flow.
  The action (deactivate vs delete) follows the user's `mercariSoldOutAction`
  setting (same section, item 2).

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
