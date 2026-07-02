# Wonni

Wonni is an **AI-first mobile app** that helps sellers list in seconds with just a photo. One key differentiator is our unique UI design that enables users to upload multiple items at once.

**Author:** Jerry Shi  
**Stack:** SwiftUI · Firebase Backend (Auth, Firestore, Storage) · Gemini API

---

## Project Motivation

Every year, countless items are dumped on the curb when people move. Wonni attempts to address this problem by lowering the friction in re-homing items users no longer need.

---

## Product Roadmap

### MVP (✅)
Users can
- Create an account & log in with an Apple account
- Take & upload photos
- Generate a description & price using photos
- Publish listings to wonni
- Save listings to 
- Cross-post to ebay & mercari
- Track sales from ebay & mercari in one dashboard

### Improvements (In Progress)
Users can
- Message other users about listings
- Purchase listings using apple pay
- Search listings with autocomplete & trending searches
- Create policy "rules" (e.g., `IF Weight > 10 lbs THEN 'Buyer Pays Shipping' and 'No Returns'`) for platforms with policies (etsy, ebay)

### Item Catalog (Deferred)
Long-term, we want to switch to a data model organized **by item, not by listing** - think Amazon vs. eBay. 
A `CatalogItem` is a shared, platform-managed product record (think: "2024 Starbucks Popcorn Bucket, Red Edition"). 
Multiple sellers can each have a `UserListing` that references the same `CatalogItem`.
This enables a faster listing process - where users can list from a text search or barcode scan - with less back-end queries for descriptions and pricing.
In addition, a catalog data model has the following benefits:
1) A sold-out `CatalogItem` page can enable:
- A "Notify me when back in stock" function for buyers
- An auto-purchase option for buyers (first seller who relists at ≤ $X automatically fulfills orders)

2) Cancelled order salvage
When Seller A cancels a transaction, Seller B who has the same `CatalogItem` in stock can fulfill the order automatically - reducing lost sales.

3) Better pricing data 
Pricing on eBay requires searching "sold listings" manually. A `CatalogItem` accumulates real transaction history across all sellers — sellers can instantly price their items based on the median sale price, 30-day trend, seasonal patterns, lowest current price, etc.

4) Demand signals for sellers
Sellers can easily see of stock items with a large numbers of buyer watching so they know what items to prioritize listing.

## Building and Running

```bash
open wonni/wonni.xcodeproj
```

Requirements: iOS 17+, Xcode 15+, camera + photo library permissions.

```bash
# CLI build
cd wonni
xcodebuild -project wonni.xcodeproj -scheme wonni \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

---

## Architecture

### Backend

All data lives in Firebase:

| Service | Purpose |
|---|---|
| **Firestore** | Listings, users, sales, conversations, messages, favorites, search history |
| **Firebase Storage** | Listing photos at `users/{userId}/{listingId}/{index}.jpg` |
| **Firebase Auth** | Sign In with Apple + email/password |
| **Firebase AI (Gemini)** | Item identification from photos — model `gemini-1.5-flash` via `.googleAI()` backend |
| **Cloud Functions (Node.js)** | eBay/Etsy OAuth, cross-posting, listing sync, sale sync (`syncSales`) |

### Data Layer (`wonni/Data/`)

| File | Responsibility |
|---|---|
| `ListingRepository.swift` | CRUD for listings, paginated feed (`fetchFeedPage`), prefix-match search support |
| `StorageService.swift` | Photo upload to permanent Storage paths, deletion |
| `GeminiService.swift` | Item identification from `[UIImage]` → `GeminiIdentificationResponse` |
| `ConversationRepository.swift` | Conversations + messages, offer flow, real-time listeners |
| `SearchRepository.swift` | Trending, search history, saved searches, prefix-match listing search |
| `SaleRepository.swift` | Fetch + delete sales ordered by `soldAt DESC`, filtered by `userId` |
| `UploadManager.swift` | Orchestrates draft → upload → Gemini → publish flow |
| `AuthManager.swift` | Firebase Auth state, sign-in/sign-out |
| `ImageCompressor.swift` | Resize images before Storage upload |

### Models (`wonni/Models/`)

| File | Key Types |
|---|---|
| `UserListing.swift` | `UserListing`, `ListingStatus`, `ItemCondition` |
| `Sale.swift` | `Sale`, `SaleStatus`, `SaleAddress` — sales records with take-home breakdown |
| `CatalogItem.swift` | Shared product catalog (future — referenced by `catalogItemId`) |
| `InventoryUnit.swift` | Per-unit inventory tracking |

### View Structure (`wonni/Views/`)

5-tab navigation (`MainView.swift`):

| Tab | View | Status |
|---|---|---|
| Home | `HomeView` | Live feed + promoted carousel + infinite scroll |
| Search | `SearchView` | Saved / recent / trending + prefix-match results |
| Sell | `CameraView` → `CreateListingView` | Full listing flow |
| Inbox | `InboxView` → `ConversationView` | Messages + offer flow |
| Profile | `ProfileView` | Listings grid + sign out |

Supporting views: `ListingDetailView` (photos, offer button, favorites, suggested listings), `IdentificationConfirmationView` (Gemini result review).

### Key Patterns

**Listing photos:** Pre-generate a UUID client-side as `listingId`, upload to `users/{uid}/{listingId}/{index}.jpg`, then write the Firestore document with that same ID. No temp→promote dance.

**Feed pagination:** Firestore cursor-based (`startAfter(document:)`). `ListingRepository.fetchFeedPage(after:)` returns a `FeedPage` with `lastDocument: DocumentSnapshot?` for the next page. Requires composite index: `status ASC + publishedAt DESC`.

**Promoted banners:** `PromotedBanner` documents in a `promotions` Firestore collection. `destinationType` + `destinationValue` fields drive routing via `BannerDestination` enum — adding a new destination is one enum case + one `navigationDestination` branch. `expiresAt: Timestamp?` for scheduled promotions.

**Conversation IDs:** Deterministic — `"\(buyerId)_\(listingId)"` — one thread per buyer+listing pair, no duplicate-check query needed.

**Search:** Firestore prefix-match on `customTitle` for 1.0. `SearchRepository.search(query:)` is the single method to swap for Algolia (see backlog).

**Favorites:** `users/{uid}/saved/{listingId}` with `catalogItemId: String?` nil now, ready for catalog migration.

---

## Firebase Setup

### Firestore Rules
Deploy with:
```bash
cd wonni && firebase deploy --only firestore:rules
```

### Firestore Indexes
Deploy composite indexes (feed + promotions queries):
```bash
cd wonni && firebase deploy --only firestore:indexes
```

### Storage Rules
```bash
cd wonni && firebase deploy --only storage
```

### Trending Searches
Seed manually in Firebase Console → `trending` collection:
```
query: "Sony headphones"   sortOrder: 0   isActive: true
```

### Promoted Banners
Seed in Firebase Console → `promotions` collection:
```
title: "Weekend Sale"   subtitle: "Up to 40% off"
destinationType: "category"   destinationValue: "Electronics"
isActive: true   sortOrder: 0   colorHex: "3B82F6"
expiresAt: <Timestamp>   (optional, omit for permanent)
```

---

## Feature Status

### ✅ = Completed

**Auth & Onboarding**
- Sign In with Apple + email/password via Firebase Auth
- Onboarding flow, sign-out from profile

**Sell Flow**
- Camera view with live viewfinder, photo capture, gallery upload
- Photo stacking (`[[UIImage]]`) with scrollable stack carousel
- Plus button to create new stacks; portrait lock with orientation correction
- Flash animation on capture (known bug: doesn't cover tab bar — see bugs)
- `CustomPhotoPickerView`: library picker with multi-draft support, "hide previously selected" toggle, numbered selection badges
- `BulkListingOverviewView`: draft list with inline title/price/description editing, keyboard navigation, upload progress bar
- `ProcessResultsOverviewView`: AI-processed results, select/deselect per item, "Review & Publish" with per-platform cross-post selection
- `DraftEditSheet`: full per-draft editor (photos, title, price, description, condition, tags, note, shipping, dimensions)
- `DraftHistoryModal`: drag-to-reorder photos across drafts, drag-to-trash, multi-select delete
- `ActiveDraftCarouselView`: shared bottom panel in camera and picker showing committed drafts
- Draft persistence and session restore via SwiftData

**Feed (Home Tab)**
- Live Firestore feed of active listings, 2-column grid with fixed square thumbnails (no overflow)
- Cursor-based infinite scroll (20 per page, `startAfter` cursor)
- Promoted banner carousel: auto-scrolls every 4s, `BannerDestination` routing, `expiresAt` scheduling

**Search Tab**
- Liquid glass search bar: capsule shape + `.ultraThinMaterial` frosted background, camera circle button outside pill, Cancel replaces camera when focused
- Saved searches (Firestore, bookmarked queries, fill bookmark icon when saved)
- Recent searches (Firestore, capped at 10, deduped by query key)
- Trending searches (Firestore `trending` collection, manually curated)
- Section order: Saved → Recent → Trending
- Swipe-to-delete on saved + recent; long-press context menu (Save / Delete)
- Prefix-match search results in 2-column grid

**Listing Detail**
- Photo carousel (TabView paged), price, condition, title, description
- Heart button: tap to save, long-press context menu to add to custom list or create new list
- Make an Offer sheet (hidden for listing owner)
- Offer submitted → conversation created → green toast confirmation
- Suggested listings horizontal scroll

**Inbox & Messaging**
- Mercari-style filter pills: All / Buying / Selling / Unread / Offers
- Real-time conversation listener
- `ConversationView`: message list (auto-scroll to bottom), offer cards, input bar
- Deterministic conversation IDs (one thread per buyer+listing)
- Unread counters, orange Offer badge

**Profile**
- User avatar (initials or photo), display name, @username, email
- Searchable + sortable list of active listings
- `ProfileListingRow` with cross-post status badges (eBay, Mercari, etc.)
- Edit mode with multi-select: bulk delete, bulk "Post to…", bulk edit sheet
- `EditListingSheet`: edit title, price, description, condition, shipping, dimensions, and marketplace toggles
- `EditProfileSheet`: change display name, username, profile photo (Firebase Storage)
- Sign out with confirmation alert
- (If user already has ebay and/or etsy account) Import policies, retaining user's naming conventions


**Cross-Posting**
- **eBay**: full API integration via Firebase Cloud Functions (`ebayCreateListing`, `ebayDeleteListing`, `ebayExchangeToken`); OAuth via `ASWebAuthenticationSession`
- **Mercari**: headless WKWebView auto-poster (`MercariAutoPoster`) using `callAsyncJavaScript`; shared cookie store with `MercariLoginView` (both use `.default()` `WKWebsiteDataStore`); WKNavigationDelegate awaits page load + JS polls for React form mount; writes `crossPostStatus.mercari = "posted"` to Firestore after success
- **Facebook Marketplace**: visible WKWebView (`CrossPostContainerView`) with "Autofill Fields" button; quick-copy header for title/price/description
- Cross-post jobs queue sequentially via `CrossPostJob` / `checkAndStartNextWebJob`; SwiftData items are kept alive until the queue drains, then deleted
- `PlatformStatusBadge`: per-platform posted / pending / failed indicators on listing rows
- `PublishConfirmationSheet` / `BulkCrossPostSheet`: platform selection with API vs autofill labels

**Sales Dashboard**
- `SalesDashboardView` — sales list with summary cards (count / revenue / take-home), platform filter chips, per-sale row with cover photo, take-home hint, and status badge
- `SaleDetailSheet` — full P&L breakdown: item price, shipping charged to buyer, shipping label cost, take-home; ship-to address with copy button; editable carrier / tracking / status
- `SaleRepository.swift` + `Sale.swift` / `SaleStatus` / `SaleAddress` models
- `syncSales` Cloud Function (`functions/sale_poller.js`):
  - Fetches eBay orders via Fulfillment API (`/sell/fulfillment/v1/order`); matches to Wonni listings by `platformListingId`
  - **Take-home**: Finances API paginated up to 5 × 20 transactions, filtered client-side by `orderId` (eBay ignores the server-side filter); uses `SALE.amount` (already net of fees) minus each `SHIPPING_LABEL` cost
  - **Tracking**: `/sell/fulfillment/v1/order/{id}/shipping_fulfillment`, field `shipmentTrackingNumber`; stores latest fulfillment and full `shippingFulfillments` array
  - **Addresses**: ship-to address from `fulfillmentStartInstructions[].shippingStep.shipTo.contactAddress`; `buyerRegisteredAddress` stored separately as bonus data
  - **Revenue split**: `priceSoldFor` = `pricingSummary.priceSubtotal` (item only); `shippingRevenue` = `pricingSummary.deliveryCost`
  - Re-sync / backfill updates tracking, take-home, addresses, and revenue split on all existing orders
- Firestore `sales` collection with owner-only security rule
- Composite index: `sales` collection, `userId ASC + soldAt DESC`

**Backend / Infrastructure**
- Firestore rules: listings, inventory, sales, conversations, messages, users + all subcollections, trending
- Firebase Storage rules: `users/{userId}/**` owner-write + authenticated read
- Composite Firestore indexes: feed query, promotions query, sales query
- Gemini AI: `gemini-1.5-flash` model, resizes images to 1024px before sending

---

### 🔄 Backlog

```mermaid
graph TD
    %% Phase 1
    subgraph P1 [Phase 1: The Camera App That Lists]
        A[Instant AI Identification] --> B[Asynchronous Pipeline]
        B --> C[eBay/Cross-Platform APIs]
    end

    %% Phase 2
    subgraph P2 [Phase 2: The Catalog Feature]
        D[Item-based DB Architecture] --> E[Auto-salvage Cancelled Orders]
    end

    %% Phase 3
    subgraph P3 [Phase 3: Dropshipping Pipeline]
        F[Web Extension Scraper] --> G[API Ingestion]
        G --> H[Automated Bot Fulfillment]
    end

    %% Phase 4
    subgraph P4 [Phase 4: White Labeling]
        I[Identify Market Gaps] --> J[Create Owned Brands]
    end

    P1 --> P2
    P2 --> P3
    P3 --> P4

    classDef phase1 fill:#F3E8FF,stroke:#C084FC,stroke-width:2px;
    classDef phase2 fill:#DBEAFE,stroke:#60A5FA,stroke-width:2px;
    classDef phase3 fill:#D1FAE5,stroke:#34D399,stroke-width:2px;
    classDef phase4 fill:#FEF3C7,stroke:#F59E0B,stroke-width:2px;

    class A,B,C phase1;
    class D,E phase2;
    class F,G,H phase3;
    class I,J phase4;
```

---

#### 🟣 Phase 1: The "Camera App That Happens to List" (Current Focus)
*Core Problem: Fast asynchronous drafting. Snap photos → AI identifies → posted to platforms instantly without waiting.*

- [x] **AI-driven Identification (Gemini 1.5 Flash)**  
  Analyze photos to auto-generate item titles, suggested prices, category taxonomy, and key specifications.
- [x] **Live eBay API Integration**  
  Publish listings directly to eBay using their v1 Inventory API and handle multi-step offers gracefully.
- [x] **Asynchronous Bulk Pipeline**  
  Snap photos → background upload → Gemini batch process → bulk review → publish to Wonni + cross-post to eBay/Mercari/Facebook in one flow. SwiftData drafts survive app restarts; cross-post jobs queue and run sequentially.
- [x] **Mercari & Facebook Marketplace Cross-Posting**  
  `MercariAutoPoster` headless WKWebView flow: await navigation, JS-poll for React form mount, inject title/price/description, attempt photo `DataTransfer`, click submit, write `crossPostStatus` to Firestore. Facebook uses visible WebView with autofill button.
- [x] **Etsy API Integration**  
  `EtsyConnectView` wired into Settings using PKCE OAuth via `ASWebAuthenticationSession`. Firebase Function `etsyExchangeToken` exchanges code for tokens and persists shop info. **TODO:** Set `ETSY_CLIENT_ID = <your-keystring>` in `Secrets.xcconfig` (same value as `ETSY_CLIENT_ID` in Firebase Secret Manager), then deploy: `firebase deploy --only functions:etsyExchangeToken`.
- [x] **Full cross-platform listing sync on edit**  
  Saving a listing in Wonni automatically syncs all fields (title, description, price, quantity, condition, weight, dimensions) to eBay (`ebayUpdateListing`) and Etsy (`etsyUpdateListing`) for already-live listings. For Mercari, a prompt asks if the user wants to auto-update the Mercari listing via headless WKWebView (`MercariAutoEditSheet`); falls back to visible browser if autofill fails. Changing who pays shipping shows an acknowledgment alert reminding the user to update their shipping profile on eBay/Etsy. Bulk edits also push to eBay for all affected listings.
- [ ] **Shipping profile auto-sync**  
  When "who pays shipping" changes in Wonni, automatically update the eBay fulfillment policy and Etsy shipping profile instead of showing a manual reminder. Requires creating/managing platform shipping profiles via API.
- [ ] **eBay Webhooks (Commerce Notifications API)**  
  Replace the manual sync button for sales with real-time eBay push notifications. Requires registering a webhook endpoint, mapping eBay order IDs to Wonni listing IDs, and handling notification verification. See eBay Commerce Notifications API docs.
- [ ] **Voided eBay shipping label refund handling**  
  When a label is voided, eBay eventually posts a refund via the Finances API. If it comes back as a **negative `SHIPPING_LABEL`** transaction, `ebayFetchTakeHome` in `sale_poller.js` already self-corrects (subtracting a negative = adding back). If it posts as a **`CREDIT`** transaction type, handling for that type needs to be added. An affected order (two SHIPPING_LABEL entries, one voided) can be rescanned once the credit appears; check the `[ebayFetchTakeHome]` log lines to confirm the transaction type and sign.
- [ ] **Listing shipping-address field**  
  Add a ship-from address to `Item`/`Listing` so Mercari cross-post can auto-fill the required "shipping address" (currently relies on the Mercari account's saved address loading in time). Needed because the Mercari sell form requires an address before listing.
- [ ] **Mercari Smart Pricing preference**  
  Smart Pricing is currently force-disabled on every cross-post (it auto-enables when the price field receives React events and would undercut the listed price). Add a seller preference — mirroring the shipping prefs — to opt *into* Smart Pricing (and optionally set the floor price Mercari may drop to), stored alongside the shipping prefs in `users/{uid}/settings/mercariShipping` and read by `MercariPostingState` to decide whether to call `disableSmartPricing()` or leave it on.
- [ ] **Mercari shipping/category automation follow-ups**  
  Stronger Tier-2 category matching: a Gemini-backed match against a cached Mercari category tree (fetch + cache the L0/L1/L2 lists to Firebase + on-device, refresh when stale) — current Tier 2 only fuzzy-matches `aiSuggestedCategory` against the live dropdown, then falls back to "Other". Also auto-fill **brand** (required for some categories — no `brand` field on the model yet).  
  ✅ Done: tiered category selection (Tier 1 suggested → Tier 2 fuzzy → Tier 3 Other); full preference-driven shipping (ship-on-own / cheapest prepaid / cheapest among carriers; accept-suggested weight+label; weight + dimensions from the listing); oversized-no-dimensions-step warning; **shoebox-question handling + non-zero weight fallback in the weight modal**; **Smart Pricing off by default**; **robust auto-submit (polls for the enabled List button before clicking, since a disabled-button click silently no-ops)**; `ShippingPreferences` Settings UI synced to Firestore (`users/{uid}/settings/mercariShipping`) and collected on first cross-post.

---

#### 🔵 Phase 2: The Catalog Feature
*Core Goal: Transition from independent listings to an item-centric database (like Amazon) to enable intelligent matching.*

- [ ] **Catalog Deduplication**  
  Use Gemini to identify if a new listing matches an existing global `CatalogItem`.
- [ ] **Salvaging Cancelled Orders**  
  If Seller A cancels an order, route the buyer seamlessly to Seller B's identical catalog item.
- [ ] **Demand Aggregation**  
  Capture waitlist demand on sold-out catalog items to actively recruit sellers to list those specific items.

---

#### 🟢 Phase 3: Dropshipping Pipeline
*Core Goal: Ingest massive amounts of inventory directly from wholesale APIs and retail websites, automating the fulfillment loop.*

- [ ] **Web Extension Scraper**  
  Ingest products from retail websites (JD.com, Barnes & Noble, Shopify stores) using automated one-click web scraping.
- [ ] **Wholesale API Ingestion**  
  Directly plug into APIs (AliExpress, Taobao) to pull items. Use Phase 2's Catalog Feature to deduplicate the massive influx of identical overseas products.
- [ ] **Automated Bot Fulfillment**  
  When an item sells on a Wonni-connected storefront, automate the purchasing/dropship order on the source website using bot automation.

---

#### 🟡 Phase 4: White Labeling & Product Gaps
*Core Goal: Use the data engine to transition from moving other people's products to creating our own.*

- [ ] **Market Gap Analysis**  
  Identify high-demand, low-supply items in the catalog (e.g., items that sell instantly or have massive waitlists).
- [ ] **White-Label Production**  
  Spin up specialized storefronts around specific niches (e.g., a dedicated eBay collectibles store, a daily-use items store) using owned or direct-manufactured white-label goods.

---

## Quick Reference for Claude Code

**Stack:** SwiftUI + Firebase (Auth, Firestore, Storage, AI/Gemini) · Cloud Functions (Node.js)

**Project root:** `wonni/wonni.xcodeproj` — all source under `wonni/wonni/`

**Key conventions:**
- New `Data/` files must be registered in `wonni.xcodeproj/project.pbxproj` (4 places: PBXBuildFile, PBXFileReference, Data group, PBXSourcesBuildPhase)
- New `Views/` files already in the project do not need pbxproj edits; new view files do
- Firebase Storage paths: `users/{userId}/{listingId}/{index}.jpg` — permanent from upload, no temp paths
- Listings pre-generate their Firestore ID client-side (UUID) so Storage path is known before the Firestore write
- Avoid composite Firestore indexes where possible — use single-field queries + client-side sort; add to `firestore.indexes.json` when a compound query is unavoidable
- New Firestore collections need an explicit security rule or all client reads/writes will be silently denied (Admin SDK bypasses rules; client SDK enforces them)
- SourceKit errors ("No such module 'FirebaseAI'", etc.) after edits are stale index noise — not real build errors
- Deploy rules/indexes/functions: `cd wonni && firebase deploy --only firestore:rules,firestore:indexes,storage` or `--only functions:<name>`

---

## Infrastructure & CI

### What's set up

| System | What it does | Triggers |
|---|---|---|
| **GitHub Actions — Functions** | ESLint lint → Jest tests → Firebase deploy | Push to `main` touching `wonni/functions/**` |
| **GitHub Actions — SwiftLint** | Checks Swift files for force unwraps, unused vars, etc. | Pull request touching any `.swift` file |
| **Xcode Cloud** | Archive iOS build → TestFlight internal distribution | Push to any branch (⚠️ change to `main` only) |
| **Branch protection** | Blocks pushes to `main` if `Lint & Test` CI fails | All remote pushes to `main` |

### Secrets required

- `FIREBASE_TOKEN` — GitHub repo secret. Generate with `firebase login:ci`. Used by the Functions workflow to deploy.

### Pending

- [ ] **Unit tests — Swift data layer** (`ListingRepository`, `SearchRepository`, `SaleRepository`). Add a Swift Testing / XCTest target in Xcode. These three files handle all Firestore reads and are the most likely to break silently when queries or indexes change. Do after Wave 1 agent branches are merged so tests reflect the post-merge state.

---

## Known Bugs

| Bug | Details | Fix Direction |
|---|---|---|
| Flash doesn't cover tab bar | `isFlashing` state is local to `CameraView` | Move flash overlay to `MainView` root or increase z-index |
| SourceKit stale index errors | "No such module 'FirebaseAI'" etc. appear after edits | Not real build errors; clear on Xcode clean build |
| Mercari "mark as sold out" broken | Marking a listing as sold out does not propagate to the Mercari listing | Trace the sold-out action in `ProfileView` / `EditListingSheet` → add a Mercari headless WKWebView flow (similar to auto-updater) that navigates to the listing and triggers the sold-out toggle |
| Bulk edit missing "mark as sold out" | Sold-out action is not available in the multi-select bulk edit sheet | Add sold-out as a bulk action in `BulkEditSheet` alongside bulk delete and bulk "Post to…"; wire it to the same per-listing sold-out flow once that is fixed |

---

## Sources & Attributions

- [Apple Capturing Photos sample app](https://developer.apple.com/tutorials/sample-apps/capturingphotos-camerapreview) — camera system architecture
- [Hacking with Swift Complete SwiftUI Tutorial](https://www.hackingwithswift.com/quick-start/swiftui/swiftui-tutorial-building-a-complete-project)
- [Hacking with Swift @FocusState](https://www.hackingwithswift.com/quick-start/swiftui/what-is-the-focusstate-property-wrapper)
- [Hacking with Swift ScrollView](https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-horizontal-and-vertical-scrolling-using-scrollview)
- [Swiftful Thinking — Paging ScrollView iOS 17](https://www.youtube.com/watch?v=hCpM95KHb_Q)
- [Medium — LazyVGrid Collection View](https://bhoopendraumrao.medium.com/a-step-by-step-guide-to-implementing-collection-view-style-in-swiftui-db4c6989a4d)
