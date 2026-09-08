# Backend contract & consolidation plan

Single reference for the Cloud Functions surface shared by the **web app**
(`wonni_dropship/web`), the **iOS app** (`wonni/wonni`), and the **Chrome
extension** (`wonni_dropship/extension`). All three call the same project:
**`wonni-app`**.

- **Canonical data model:** the web app's. `products/{id}` (with an inline
  `variants[]` array) is the listing record. The iOS `listings/{id}` +
  `inventory/{unitId}` collections are being retired — see
  [§ Data-model migration](#data-model-migration).
- **Canonical function tree:** top-level `functions/`. The nested
  `wonni/wonni/functions/` tree is harvested for its newer sales/variation
  work, then deleted.
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
| `syncSales` | **dead** (iOS) | Port from nested `sale_poller.js` (719 L). Poll eBay + Etsy, import each via `recordSale`. |
| `getOrderTakeHome` | **dead** (iOS calls `ebayGetOrderTakeHome` / `etsyGetReceiptTakeHome`) | Merge the two into one function keyed by the sale's `platform`. Port from nested `sale_fetch.js`. |

**Cascade coverage today:** eBay (via `bulk_update_price_quantity` on the stored
offer pointer), Etsy (`listings` PATCH), Mercari (`pendingMercari*` flags).
TikTok is stubbed `pending-manual` until `tiktokUpdateListing` consolidation.

### Mercari  → `contracts/mercari.js`

| Function | Status | Notes / action |
|---|---|---|
| `recordMercariSalesBatch` | **dead** (extension) | Rewrite: client sends **raw scraped rows** (`rawItems`), server does parse + dedupe + `recordSale` + cascade. Collapses `extension/mercari_sold_content.js` and iOS `MercariSaleParsing.swift` into one impl. Port base from nested `mercari_sale.js`. |
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

### Etsy  → `contracts/etsy.js` *(to add)*

| Function | Status | Notes / action |
|---|---|---|
| `etsyCreateListing` | **orphan** (web uses it, works) | The nested `etsy_listing.js` (1043 L) is the **only** real Etsy impl. Move it into the canonical tree, rebase onto `products/`, re-export from `index.js`. |
| `etsyUpdateListing` / `etsyDeleteListing` / `etsyCheckShopSetup` | **orphan / dead** | same move |
| `getEtsyCategories` / `getEtsyReturnPolicies` / `getEtsyShippingProfiles` / `suggestEtsyCategory` | **dead** (web calls them) | same move — these are why the web Etsy category UI is currently broken |
| `etsyPullSync` / `etsyImportPullSync` | **live** | reconcile top-level vs nested versions |
| `etsyExchangeToken` | **live** | keep one impl (align with the eBay token decision) |
| `dropshipEtsyCreateListing` | **orphan** | **prune** — `firebase functions:delete dropshipEtsyCreateListing` once confirmed no caller |

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
| `enrichListing` | **new** (→ `contracts/enrichment.js`) | **Merges `identifyItem` + `aiAutofillListing`** into one function, one Gemini call, one output shape (`ListingFields`). `mode:"draft"` = photos+hints in, all fields out, persists nothing (iOS pre-product identify). `mode:"product"` = `{productId}` in, blank fields filled + optionally persisted (web autofill button). Core is the existing `resolveListingFields()`, extended to take raw images. |
| `identifyItem` | **dead** (iOS) | Remove — replaced by `enrichListing` mode:"draft". |
| `aiAutofillListing` | **live** | Remove — replaced by `enrichListing` mode:"product". Keep as an alias through the web migration. |
| `generateProductDescription` | **live** | keep (single-purpose "✨ AI Suggest" description button) |
| `splitProductImage` | **live** | keep |
| `publishStorageObject` | ✅ **built** (`functions/publish_storage_object.js`, wired, not deployed) | Copied verbatim from nested. Deploy unblocks web image uploads. |
| `refreshSourceData` | **orphan** (web uses it, works) | move source into canonical tree |
| `onProductDeleted` | **live** | keep |
| `postToWonni` | **orphan** (web uses it, works) | move `wonni_listing.js` into canonical tree; add the "skip when live listing exists" guard (open roadmap item) |

### Auth / settings / account

| Function | Status | Notes / action |
|---|---|---|
| `generateOAuthState` | **live** | add `"etsy"` to the platform allowlist (nested has it) |
| `disconnectPlatform` / `updateSettings` | **live** | add `"etsy"` to allowlists |
| `aliexpressExchangeToken` / `tiktokExchangeToken` | **live** | reconcile integration-doc field shape (`platform`, `connectedAt` vs token-only) |
| `requestAccountDeletion` / `cancelAccountDeletion` / `purgeDeletedAccounts` | **dead** (nested `account_deletion.js`, iOS #62) | port into canonical tree |
| `notifySavedSearchMatches` | **dead** (nested) | port (Wonni-marketplace feature) |
| `ebayWebhook` / `setupEbayNotifications` | **dead** (nested `ebay_webhook.js`) | port — eBay platform-notification subscription |
| `placeAliexpressOrder` / `confirmTiktokShipment` / `pollAliexpressTracking` | **live** | keep |

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

---

## Sequenced work

1. **Contract scaffold** — ✅ `functions/contracts/` (sales, mercari, listings,
   ebay, enrichment). Add `etsy.js`, `tiktok.js`, `products.js`.
2. **Port the dead-but-needed functions** onto the canonical tree + schema:
   ✅ `publishStorageObject`, ✅ `recordSale` + cascade family (eBay/Etsy/Mercari).
   Next: `recordMercariSalesBatch` → `syncSales` + `getOrderTakeHome` →
   Etsy CRUD → account deletion / webhook.
3. **Deploy `functions/` from the canonical tree** so the built functions
   actually run (nothing above is live yet). Verify with a real recordSale
   from web, then the Mercari + iOS pieces.
5. **Wire `validated(...)`** into the remaining pre-existing shared functions.
6. **Merge repos** — `web/` + `extension/` into this repo; one `firebase.json`,
   one `firestore.rules`, one `storage.rules`.
7. **One `index.js`**; delete `wonni/wonni/functions/`; delete the empty
   `wonni_dropship` functions stub.
8. **Migrate the 2–3 iOS users'** `listings` → `products`.
9. **Repoint iOS** call sites at the canonical names/payloads; add the generated
   `BackendContracts.swift` to the Xcode project.
10. **Deploy once**; `firebase functions:delete dropshipEtsyCreateListing` and
    any other confirmed-dead orphan. Smoke-test from web + iOS + extension.

## Backfill (before or with the deploy)

Existing `sales/{id}` docs written by the old web `LogSaleModal`:
`salePrice` → `priceSoldFor`, `productTitle` → `listingTitle`,
`productImageUrl` → `thumbnailUrl`, add `status: "complete"`, `quantity` default 1.
Only a few dozen docs — a one-shot `functions/scripts/backfill_sales_schema.js`.
`Sales.jsx` already reads both names, so this is not release-blocking.

---

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
