# Wonni Agent Task Breakdown

Generated: 2026-06-13  
Use this file to spin up parallel Claude Code agents on independent feature tracks.

---

## Dependency Map

```
Wave 1 (parallel): A (Mercari bugs+UX) · B (Search autocomplete) · C (Inbox context) · D (Char counter)
                          ↓
Wave 2 (parallel): E (Sell Similar, needs D merged) · F (Stripe checkout)
                          ↓
Wave 3:            G (Price comparison, needs F) · H (Item catalog — plan first)

Separate repo:     Web app (no iOS dependencies)
```

---

## Wave 1 — Run in Parallel

### Agent A · Mercari Bug Trifecta (items #6, #7, #8)
**Files:** `wonni/wonni/Views/ImportListingSheet.swift`, `wonni/wonni/Views/CrossPostWebView.swift`, `wonni/wonni/Views/BulkImportPillView.swift`, `wonni/wonni/Views/UploadPillView.swift`, `wonni/functions/sale_sync.js`

**Scope:**
- **#7** Mercari sales sync not working; manual importer doesn't import the photo of the sold item
- **#8** Mercari auto-updater reports success but changes don't actually sync to the live listing
- **6** Refactor auto-updater UX: show progress in the shared pill bar (see UploadPillView/BulkImportPillView pattern) and surface a ModalView when there's an error instead of silent failure

**Prompt:** → See "Wave 1 Agent Prompts" section below

---

### Agent B · Search Autocomplete (item #1)
**Files:** `wonni/wonni/Views/SearchView.swift`, `wonni/wonni/Views/SearchBarView.swift`, `wonni/wonni/Data/SearchRepository.swift`

**Scope:**
- Inline autocomplete suggestions as user types (hook into existing `SearchRepository.search(query:)`)
- Trending searches already seeded in Firestore `trending` collection — surface in suggestion list

**Prompt:** → See "Wave 1 Agent Prompts" section below

---

### Agent C · Inbox Buyer/Seller Context (item #2)
**Files:** `wonni/wonni/Views/InboxView.swift`, `wonni/wonni/Views/ConversationView.swift`, `wonni/wonni/Data/ConversationRepository.swift`

**Scope:**
- Derive buyer vs. seller role from deterministic conversation ID (`buyerId_listingId`)
- Label threads in InboxView; conditionally show seller actions vs. buyer actions in ConversationView

**Prompt:** → See "Wave 1 Agent Prompts" section below

---

### Agent D · Title Character Counter Bug (item #5)
**Files:** `wonni/wonni/Views/CreateListingView.swift`

**Scope:**
- Spaces not being counted in title character counter, causing titles to be silently truncated on publish
- One-line fix; verify against eBay and Mercari platform char limits

**Prompt:** → See "Wave 1 Agent Prompts" section below

---

## Wave 2 — After Wave 1 Merges

### Agent E · Sell Similar (item #9)
**Files:** `wonni/wonni/Views/ListingDetailView.swift`, `wonni/wonni/Views/ProfileView.swift`, `wonni/wonni/Views/CreateListingView.swift`
**Depends on:** Agent D merged (both touch CreateListingView)

- Long-press / context menu on any listing → pre-populate a new draft with title, description, price, condition, tags, shippingConfig
- Skip listingId, userId, platformListingId, crossPostStatus — new listing starts clean
- Accessible from both ProfileView (own listings) and ListingDetailView (other users' listings)

---

### Agent F · Stripe Checkout (item #3)
**Files:** `wonni/wonni/Views/ListingDetailView.swift`, new `wonni/wonni/Views/CheckoutView.swift`, new `wonni/functions/stripe_checkout.js`

- Cloud Function creates Stripe Checkout Session → URL opened in ASWebAuthenticationSession (same pattern as eBay/Etsy OAuth)
- On success: write pending `sale` doc to Firestore; Stripe webhook flips to `paid`
- Keep Make Offer visible alongside Buy Now; hide both for listing owner (already gated)
- Add `STRIPE_SECRET_KEY` to Firebase Secret Manager

---

## Wave 3 — Larger Features

### Agent G · Price Comparison Tool (item #11)
**Files:** `wonni/wonni/Views/ListingDetailView.swift`, new `wonni/functions/price_comparison.js`
**Depends on:** Agent F merged (both touch ListingDetailView)

- Cloud Function scrapes eBay sold listings by title (eBay Browse API `filter=soldItems:true`)
- Returns: median sold price, 30-day sell-through rate, price range, recent comps
- Collapsible section in ListingDetailView; for own listing show prominently in EditListingSheet
- Cache under `listings/{id}/priceComps` with 24h TTL

---

### Agent H · Item Catalog (item #10)
**Files:** `wonni/wonni/Models/CatalogItem.swift`, `wonni/wonni/Data/ListingRepository.swift`, new `wonni/wonni/Data/CatalogRepository.swift`, new `wonni/wonni/Views/CatalogItemView.swift`

- FK `catalogItemId` already on every listing and saved item; `CatalogItem.swift` model exists
- Phase 1: Gemini Cloud Function on listing creation to match/create CatalogItem (title + category embedding; if similarity > threshold → link, else create new)
- Phase 2: CatalogItemView grouping all listings under one item page (Amazon-style)
- **Write a planning doc first** — touches the data model fundamentally; matching function must be idempotent

---

## Separate Repo — Web App (item #4)

**New repo:** `wonni-web/`  
**Stack:** Next.js (App Router) deployed to Firebase Hosting / App Hosting  
**Key point:** Same Firestore project — reads existing data, no schema changes needed

```
wonni-web/
  app/
    (auth)/          # sign-in (email/password; Sign in with Apple is iOS-only)
    listings/[id]/   # listing detail → mirrors ListingDetailView
    search/          # mirrors SearchView
    inbox/           # mirrors InboxView (read-only for web MVP)
  lib/
    firebase.ts      # same project credentials
```

MVP scope for one agent: listing feed, detail page, search — read-only. Checkout and posting are stretch goals.

---

## Wave 1 Agent Prompts

### Agent A — Mercari Bug Trifecta

```
You are working on Wonni, an iOS reseller app (SwiftUI + Firebase). The project root is at wonni/wonni.xcodeproj; all source is under wonni/wonni/.

You have three related Mercari tasks to complete. All touch the headless WKWebView cross-posting flow.

CONTEXT
- MercariAutoPoster drives a headless WKWebView to inject listing data into the Mercari sell form and submit it.
- CrossPostWebView.swift is the container view for visible cross-posting flows and the Mercari auto-update flow.
- sale_sync.js (functions/) syncs sales from Mercari to Firestore.
- ImportListingSheet.swift lets users manually import a listing by URL; it scrapes product info including photos.
- BulkImportPillView.swift and UploadPillView.swift are the shared "pill" progress indicators shown during upload and bulk import — study these as the UX pattern to follow.

TASK #8 — Auto-updater says success but changes don't sync
The MercariAutoEditSheet / auto-updater flow completes without error but the live Mercari listing is unchanged. Investigate:
1. Trace the JS injection in CrossPostWebView (or wherever the edit flow lives) to find where the React form fields are being written but not committing (React state not triggering onChange, field not focused, submit button not actually enabled when clicked).
2. Fix the root cause. The existing MercariAutoPoster.swift has patterns for awaiting React form mount and polling for button enabled state before clicking — apply the same approach to the edit flow.
3. Add a real success check: after submit, confirm navigation away from the edit page before writing crossPostStatus to Firestore.

TASK #7 — Sales sync broken + manual importer missing photo
- In sale_sync.js: diagnose why sales aren't syncing. Check the Mercari order API response shape, field mappings, and any auth/cookie issues.
- In ImportListingSheet.swift: when a user manually imports a listing by URL, the sold item's photo is not being imported. Find where the photo URL is scraped (likely URLExtractor.swift) and ensure it is stored in the sale document or listing record.

TASK #6 — Refactor auto-updater UX
After fixing #8, change the auto-updater UX:
- Replace the current inline/modal update progress with the shared pill bar pattern (study BulkImportPillView.swift and UploadPillView.swift for the exact approach).
- If the update fails (including the new success-check from #8), surface a ModalView that shows the specific error and lets the user retry or open the browser manually — no more silent failure.

CONVENTIONS
- New Views/ files need to be added to wonni.xcodeproj/project.pbxproj (4 places: PBXBuildFile, PBXFileReference, Views group, PBXSourcesBuildPhase). Use the add_file.rb script in wonni/scripts/ if available, or follow the existing pattern in pbxproj.
- New Firestore collections need a security rule in firestore.rules.
- Deploy functions: cd wonni && firebase deploy --only functions:<name>
- Do not add comments explaining what code does; only comment non-obvious WHY (hidden constraints, workarounds).
```

---

### Agent B — Search Autocomplete

```
You are working on Wonni, an iOS reseller app (SwiftUI + Firebase). The project root is at wonni/wonni.xcodeproj; all source is under wonni/wonni/.

CONTEXT
- SearchView.swift: the Search tab. Already shows Saved searches, Recent searches, and Trending searches in that order.
- SearchBarView.swift: the liquid-glass capsule search bar component with .ultraThinMaterial frosted background.
- SearchRepository.swift: has search(query:) for prefix-match listing search against Firestore, plus methods for trending, recent, and saved searches.
- Trending searches are manually seeded in Firestore `trending` collection (fields: query, sortOrder, isActive).
- Recent searches are stored in Firestore, capped at 10, deduped by query key.

TASK #1 — Autocomplete + trending suggestions
1. As the user types in the search bar (before they hit Search), show an inline suggestion list below the bar with:
   a. Autocomplete: call SearchRepository.search(query:) with a debounce (~200ms) and show the top 5 matching listing titles as tappable suggestions. Tapping a suggestion fills the bar and executes the search immediately.
   b. Trending: below autocomplete results (or when the bar is focused with no text), show the trending searches from Firestore. These are already fetched — wire them into the suggestion UI.
2. The suggestion list should appear/disappear based on focus state (visible when bar is focused, hidden on cancel or after search executes).
3. Style to match the existing liquid-glass aesthetic: use the same .ultraThinMaterial background, capsule/rounded shapes, and font weights already in SearchView.

CONVENTIONS
- New Views/ files need to be registered in wonni.xcodeproj/project.pbxproj (4 places). Follow the existing pattern or use wonni/scripts/add_file.rb.
- Do not add extraneous comments; only non-obvious WHY comments.
- Prefer @State / @StateObject patterns already in SearchView; don't introduce new architecture layers.
```

---

### Agent C — Inbox Buyer/Seller Context

```
You are working on Wonni, an iOS reseller app (SwiftUI + Firebase). The project root is at wonni/wonni.xcodeproj; all source is under wonni/wonni/.

CONTEXT
- InboxView.swift: lists conversations with filter pills (All / Buying / Selling / Unread / Offers).
- ConversationView.swift: the message thread. Shows message list, offer cards, and input bar.
- ConversationRepository.swift: real-time Firestore listener for conversations and messages.
- Conversation IDs are deterministic: "\(buyerId)_\(listingId)". This means the current user's role is always derivable: if authManager.currentUser.uid == the first segment of the conversation ID, the user is the buyer; otherwise they are the seller.
- The Firestore `conversations` collection stores: conversationId, buyerId, sellerId, listingId, lastMessage, lastMessageAt, unreadCount (and possibly per-role unread counts).

TASK #2 — Buyer/seller role context
1. Derive the current user's role (buyer vs. seller) from the conversation ID in both InboxView and ConversationView. Do not add a new Firestore field — compute it from the existing ID structure.
2. In InboxView: label each thread row with a subtle "Buying" or "Selling" badge/chip so the user knows their role at a glance. The existing filter pills (Buying / Selling) already filter by this — make sure those filters work correctly based on the derived role.
3. In ConversationView: conditionally show role-appropriate actions:
   - Seller: "Mark as Shipped" button (or similar seller action stub) in the input area or as a toolbar button.
   - Buyer: "Confirm Received" button stub.
   Keep these as stubs (show the button, tap shows a "coming soon" alert or no-op) if the full fulfillment flow isn't wired yet — the goal is correct role surfacing, not full fulfillment implementation.
4. Make sure the "Buying" and "Selling" filter pills in InboxView correctly filter based on the derived role.

CONVENTIONS
- Real-time listener is already wired in ConversationRepository — do not replace or duplicate it.
- Do not add a new `role` field to Firestore; derive from the existing conversation ID.
- New Views/ files need pbxproj registration (4 places). Follow the existing pattern.
- Do not add comments that explain what code does; only non-obvious WHY.
```

---

### Agent D — Title Character Counter Bug

```
You are working on Wonni, an iOS reseller app (SwiftUI + Firebase). The project root is at wonni/wonni.xcodeproj; all source is under wonni/wonni/.

CONTEXT
- CreateListingView.swift: the listing creation form. Contains a title field with a character counter.
- Titles are validated against platform limits before publishing (eBay: 80 chars, Mercari: 40 chars approximately).
- Bug: spaces are not being counted in the character counter display, so users see a count that's lower than the actual character count. This causes titles to appear within limit but get silently truncated on publish.

TASK #5 — Fix title character counter
1. Find the character counter logic in CreateListingView.swift (likely a `.count` on a trimmed or filtered string).
2. Fix it so all characters including spaces are counted. The `.count` property on a Swift String counts Unicode grapheme clusters — that's correct. The bug is likely that the string is being `.trimmingCharacters(in: .whitespaces)` or similar before counting, or a filter is stripping spaces.
3. Verify the counter limit constants match the actual platform limits enforced at publish time. If they differ, align them.
4. No new UI needed — just fix the counting logic so the displayed count matches what platforms will receive.

This is a small, focused fix. Do not refactor surrounding code.
```

---

## Status Tracking

| Agent | Task | Status |
|---|---|---|
| A | Mercari Bug Trifecta (#6, #7, #8) | ⬜ Not started |
| B | Search Autocomplete (#1) | ⬜ Not started |
| C | Inbox Buyer/Seller Context (#2) | ⬜ Not started |
| D | Title Char Counter (#5) | ⬜ Not started |
| E | Sell Similar (#9) | ⏳ Waiting on D |
| F | Stripe Checkout (#3) | ⏳ Wave 2 |
| G | Price Comparison (#11) | ⏳ Waiting on F |
| H | Item Catalog (#10) | ⏳ Wave 3 |
| Web | Web App (#4) | ⏳ Separate repo |
