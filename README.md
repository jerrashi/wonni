# Wonni

**AI-first marketplace iOS app.** Wonni helps sellers list fast (camera → AI identification → live listing in seconds) and helps buyers discover, save, and buy items.

**Author:** Jerry Shi  
**Stack:** SwiftUI · Firebase (Auth, Firestore, Storage, AI) · Gemini 1.5 Flash

---

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
| **Firestore** | Listings, users, conversations, messages, favorites, search history |
| **Firebase Storage** | Listing photos at `users/{userId}/{listingId}/{index}.jpg` |
| **Firebase Auth** | Sign In with Apple + email/password |
| **Firebase AI (Gemini)** | Item identification from photos — model `gemini-1.5-flash` via `.googleAI()` backend |

### Data Layer (`wonni/Data/`)

| File | Responsibility |
|---|---|
| `ListingRepository.swift` | CRUD for listings, paginated feed (`fetchFeedPage`), prefix-match search support |
| `StorageService.swift` | Photo upload to permanent Storage paths, deletion |
| `GeminiService.swift` | Item identification from `[UIImage]` → `GeminiIdentificationResponse` |
| `ConversationRepository.swift` | Conversations + messages, offer flow, real-time listeners |
| `SearchRepository.swift` | Trending, search history, saved searches, prefix-match listing search |
| `UploadManager.swift` | Orchestrates draft → upload → Gemini → publish flow |
| `AuthManager.swift` | Firebase Auth state, sign-in/sign-out |
| `ImageCompressor.swift` | Resize images before Storage upload |

### Models (`wonni/Models/`)

| File | Key Types |
|---|---|
| `UserListing.swift` | `UserListing`, `ListingStatus`, `ItemCondition` |
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

### ✅ Completed

**Auth & Onboarding**
- Sign In with Apple + email/password via Firebase Auth
- Onboarding flow, sign-out from profile

**Sell Flow**
- Camera view with live viewfinder, photo capture, gallery upload
- Photo stacking (`[[UIImage]]`) with scrollable stack carousel
- Plus button to create new stacks; portrait lock with orientation correction
- Flash animation on capture (known bug: doesn't cover tab bar — see bugs)
- `CreateListingView`: draft carousel, upload progress, Gemini identification confirmation
- Inline price + description editing on result card after upload
- Draft persistence and session restore

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
- User avatar (initials), display name, email
- 2-column grid of active listings with cover photo
- Tap listing → `ListingDetailView`
- Sign out with confirmation alert

**Backend / Infrastructure**
- Firestore rules: listings, inventory, conversations, messages, users + all subcollections, trending
- Firebase Storage rules: `users/{userId}/**` owner-write + authenticated read
- Composite Firestore indexes: feed query, promotions query
- Gemini AI: `gemini-1.5-flash` model, resizes images to 1024px before sending

---

### 🔄 In Progress / Near-term Backlog

| Item | Notes |
|---|---|
| Offer accept / decline | `OfferCard` UI exists in `ConversationView`; Accept/Decline actions are stubs |
| Seller display name | `ListingDetailView` shows truncated `userId`; needs `users` collection with display names |
| Category feed view | `BannerDestination.category` navigates to placeholder; `CategoryFeedView` not built |
| Search banner destination | `BannerDestination.search` navigates to placeholder |
| Deploy Firestore rules + indexes | Run `firebase deploy --only firestore:rules,firestore:indexes` |
| Flash animation tab bar fix | `isFlashing` is local to `CameraView`; move overlay to `MainView` or adjust z-index |
| Extract shared `FeedListingCard` | Currently duplicated in `HomeView.swift` and `SearchView.swift` — both now use the same square-thumbnail pattern |
| Full-text search — Algolia | Replace `SearchRepository.search(query:)` body; interface stays identical (see backlog) |

---

### 📋 Backlog

**Search**
- [ ] Algolia full-text search (Firebase Extension, one-click setup). Replace `SearchRepository.search(query:)` — no other files change. Adds typo tolerance and mid-word matching.
- [ ] Live search suggestions as user types (debounced Firestore queries or Algolia)
- [ ] Browse by category

**Listings & Catalog**
- [ ] `CatalogItem` model integration — shared product data across listings (price history, shared title/description). `UserListing.catalogItemId` is already a FK placeholder.
- [ ] Category tagging on listings
- [ ] "Listing playlists" — seller-organized folders (e.g. "K-pop merch > Jungkook")
- [ ] Price history chart on listing detail

**Buying**
- [ ] Checkout flow
- [ ] Shipping integration (Shippo API for label generation + QR drop-off)
- [ ] Order tracking (USPS/UPS API)
- [ ] Offer alerts for saved searches ("new Sony headphones under $50")
- [ ] "X sold recently" badge

**Selling**
- [ ] Trending items feed for sellers ("This popcorn bucket has high demand — list now?")
- [ ] Multi-platform auto-listing (eBay, Etsy, TikTok Shop APIs)

**Profile & Trust**
- [ ] Seller display name + avatar from `users` collection
- [ ] Seller stats: on-time shipment rate, defect rate, review score
- [ ] Community moderation system for disputes

**App Polish**
- [ ] Photo-shrink animation after capture (photo fills screen → shrinks to stack)
- [ ] Dark mode + iPad adaptive layout
- [ ] App icon + launch screen
- [ ] Widgets for watched items

---

### 💡 Long-term Wishlist

- Multi-platform posting: auto-list on eBay/Etsy/TikTok Shop/Amazon with seller's take-home price + fees
- AliExpress API integration for trending item discovery and bulk purchasing
- Email integration: auto-populate drafts from purchase confirmation emails
- Arbitrage scanner: scrape eBay/Etsy/Mercari for margin opportunities
- Location-based seller alerts (concert merch, movie theater exclusives)
- Live selling + short video selling with affiliate commission model
- Doordash-style door pickup / packaging service
- SMS 2FA + urgent alerts via Twilio
- Cancelled order salvage: route to alternate in-stock sellers
- Local pickup / local sales
- "#1 in Concert Tees" category rank badges (Amazon-style)
- Damaged shipment insurance claim processing
- Community-balanced marketplace policies (7-day buyer return window, auto-5-star if no review within shipping SLA, etc.)

---

## Known Bugs

| Bug | Details | Fix Direction |
|---|---|---|
| Flash doesn't cover tab bar | `isFlashing` state is local to `CameraView` | Move flash overlay to `MainView` root or increase z-index |
| SourceKit stale index errors | "No such module 'FirebaseAI'" etc. appear after edits | Not real build errors; clear on Xcode clean build |

---

## Sources & Attributions

- [Apple Capturing Photos sample app](https://developer.apple.com/tutorials/sample-apps/capturingphotos-camerapreview) — camera system architecture
- [Hacking with Swift Complete SwiftUI Tutorial](https://www.hackingwithswift.com/quick-start/swiftui/swiftui-tutorial-building-a-complete-project)
- [Hacking with Swift @FocusState](https://www.hackingwithswift.com/quick-start/swiftui/what-is-the-focusstate-property-wrapper)
- [Hacking with Swift ScrollView](https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-horizontal-and-vertical-scrolling-using-scrollview)
- [Swiftful Thinking — Paging ScrollView iOS 17](https://www.youtube.com/watch?v=hCpM95KHb_Q)
- [Medium — LazyVGrid Collection View](https://bhoopendraumrao.medium.com/a-step-by-step-guide-to-implementing-collection-view-style-in-swiftui-db4c6989a4d)
