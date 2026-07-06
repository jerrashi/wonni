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

5) Scan to post/identify
Users can post multiple items at once by taking one photo of a binder sheet of trading cards, for example, and each card can be identified and listed in one step instead of having to take multiple photos. This also enhances seo & social capabilities (i.e. enables social & wiki capabilities similar to biasroom.com)

### Local Map (Deferred)
Users can
- geotag their postings for local meetups
- view local meetup listings on a map
- filter for free listings (i.e. curb alerts)

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

All data lives in Firebase:

| Service | Purpose |
|---|---|
| **Firestore** | Listings, users, sales, conversations, messages, favorites, search history |
| **Firebase Storage** | Listing photos at `users/{userId}/{listingId}/{index}.jpg` |
| **Firebase Auth** | Sign In with Apple + email/password |
| **Firebase AI (Gemini)** | Item identification from photos — model `gemini-1.5-flash` via `.googleAI()` backend |
| **Cloud Functions (Node.js)** | eBay/Etsy OAuth, cross-posting, listing sync, sale sync (`syncSales`) |

5-tab navigation: Home (feed), Search, Sell (camera → AI → publish), Inbox (messages/offers), Profile (listings management).

Open feature work, backlog, and known bugs are tracked in [GitHub Issues](../../issues), not in this README.

---

## Sources & Attributions

- [Apple Capturing Photos sample app](https://developer.apple.com/tutorials/sample-apps/capturingphotos-camerapreview) — camera system architecture
- [Hacking with Swift Complete SwiftUI Tutorial](https://www.hackingwithswift.com/quick-start/swiftui/swiftui-tutorial-building-a-complete-project)
- [Hacking with Swift @FocusState](https://www.hackingwithswift.com/quick-start/swiftui/what-is-the-focusstate-property-wrapper)
- [Hacking with Swift ScrollView](https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-horizontal-and-vertical-scrolling-using-scrollview)
- [Swiftful Thinking — Paging ScrollView iOS 17](https://www.youtube.com/watch?v=hCpM95KHb_Q)
- [Medium — LazyVGrid Collection View](https://bhoopendraumrao.medium.com/a-step-by-step-guide-to-implementing-collection-view-style-in-swiftui-db4c6989a4d)
