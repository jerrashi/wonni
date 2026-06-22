# Wonni — Claude Code Context

Wonni is a solo-developer iOS app (SwiftUI + Firebase) for listing and selling items across multiple marketplaces. The seller photographs items, AI generates titles/descriptions/prices, and the app cross-posts to Wonni, eBay, Etsy, Mercari, and Facebook Marketplace.

## Repo layout

```
wonni/                          ← repo root
├── CLAUDE.md                   ← this file
├── wonni/                      ← Xcode project root
│   ├── wonni/                  ← Swift source
│   │   ├── Views/              ← all SwiftUI views
│   │   ├── Data/               ← managers, repos, services
│   │   └── Models/             ← SwiftData + Firestore model types
│   └── functions/              ← Firebase Cloud Functions (Node.js / JS)
```

## Key files

| File | Purpose |
|---|---|
| `Views/MainView.swift` | Root TabView (5 tabs). Hosts global sheets: `ProcessResultsOverviewView`, `CrossPostStatusView`, and the global `MercariAutoPosterView` pill. |
| `Views/CreateListingView.swift` | Contains `BulkListingOverviewView`, `ProcessResultsOverviewView`, `CrossPostStatusView`. The entire sell flow after camera. |
| `Views/ProcessProgressView.swift` | Full-screen / pill sheet showing AI processing progress per draft. |
| `Views/ProfileView.swift` | Listings management. Very large view — body is split into `profileNavCore` → `profileNavStack` → `body` to avoid Swift compiler type-check timeouts. Toolbar extracted to `@ToolbarContentBuilder profileToolbar`. |
| `Views/CrossPostWebView.swift` | All web-autofill logic for Mercari and Facebook. `MercariAutoPosterView` runs a headless WKWebView and surfaces a pill UI. `CrossPostJob` struct lives here. |
| `Data/UploadManager.swift` | Central state machine for the sell flow. Published properties drive the entire photo upload → AI process → publish → cross-post UX. |
| `Data/AppTaskQueue.swift` | Singleton pill queue shown above the tab bar. `begin/update/complete` with UUID task IDs. |
| `Data/IntegrationRepository.swift` | Manages platform OAuth connections in Firestore. Also `triggerCrossPost` and `triggerCrossDelete` which call eBay/Etsy Cloud Functions. |
| `Data/ListingRepository.swift` | Firestore CRUD for `UserListing`. |
| `functions/index.js` | Cloud Function entry point — exports all functions. |
| `functions/ebay_listing.js` | `ebayCreateListing`, `ebayUpdateListing`, `ebayDeleteListing`. |
| `functions/sale_sync.js` | `markSoldOutAndCascade`, `restockAndCascade`, `decrementAndCascade` — updates eBay quantity and Etsy inventory on cross-platform sales events. |

## Data models

### `Item` (SwiftData — local draft)
Lives on-device only. Represents a draft being photographed/processed before publishing.
- `id: UUID` — primary key
- `sourceAssetIdentifiers: [String]` — Photos library asset IDs
- `firebasePhotoPaths: [String]?` — Storage paths written after upload
- `firestoreListingId: String?` — pre-assigned Firestore doc ID (set at draft creation)
- `processedAt: Date?` — non-nil once Gemini has run
- `userEdited{Title,Price,Description}` override `aiSuggested*` fields
- Deleted after cross-posting completes (`publishedPendingDeletionIDs` gates deletion)

### `UserListing` (Firestore — published listing)
Document at `users/{uid}/listings/{listingId}`.
- `crossPostStatus: [String: String]?` — e.g. `["ebay": "posted", "mercari": "pending", "facebook": "failed"]`
- `crossPostListingIds: [String: String]?` — e.g. `["ebay": "123456789"]`
- `photoPaths: [String]` — Firebase Storage paths
- `status: ListingStatus` — `.active`, `.sold`, `.soldOut`

## Sell flow (end to end)

```
Camera/Picker → CameraView
    ↓  tap Proceed
BulkListingOverviewView          (SwiftData drafts filtered by sessionDraftIDs)
    ↓  tap Process
ProcessProgressView              (fullScreenCover or pill sheet)
    ↓  AI finishes → showProcessResults = true → MainView defers 0.5s → showResultsOverview = true
ProcessResultsOverviewView       (global sheet from MainView)
    ↓  tap Publish
  • Wonni + eBay/Etsy via Cloud Functions (isPublishing = true)
  • pendingAutofillJobsCount tracks web-autofill queue
    ↓  isPublishing = false → checkAndStartNextWebJob()
  • Mercari → uploadManager.globalMercariJob → MercariAutoPosterView pill in MainView
  • Facebook → activeAutofillJob → CrossPostContainerView sheet
    ↓  queue empty → showResultsOverview = false, delay 0.4s → showCrossPostStatus = true
CrossPostStatusView              (global sheet from MainView)
    ↓  tap Done → shouldReturnToRoot = true → selectedTab = 0
```

## Navigation rules — critical

**Never mutate two SwiftUI navigation states in the same synchronous call.** Dismissing a sheet/cover and pushing a destination, or switching tabs, in the same frame corrupts the nav stack with "NavigationRequestObserver tried to update multiple times per frame."

Always interleave with `DispatchQueue.main.asyncAfter(deadline: .now() + 0.35)` (dismiss first) or `+ 0.5` (when a new sheet needs to present after another closes).

## UploadManager key published properties

| Property | Role |
|---|---|
| `isUploadingPhotos` | True while Firebase Storage uploads are in flight |
| `uploadProgress: Double` | 0–1, shown in ProcessProgressView caption |
| `showProcessResults` | Set true when AI finishes; MainView gates on this to open results sheet |
| `showResultsOverview` | Drives the ProcessResultsOverviewView global sheet |
| `showCrossPostStatus` | Drives the CrossPostStatusView global sheet |
| `sessionCrossPostItems` | Populated before publish; passed to CrossPostStatusView |
| `sessionDraftIDs` | Set of IDs for the current session's drafts (filters BulkListingOverviewView) |
| `globalMercariJob: CrossPostJob?` | Active Mercari web-autofill job; shown as pill from MainView |
| `onMercariJobComplete: (() -> Void)?` | Closure called by MainView when Mercari job finishes to advance the queue |
| `shouldReturnToRoot` | Set true by CrossPostStatusView.onDone to switch to tab 0 |
| `selectedTab: Int` | Bound to TabView selection |

## AppTaskQueue pill system

`AppTaskQueue.shared` is a singleton FIFO queue. Each task has a `UUID` id, label, optional detail, progress (−1 = spinner, 0–1 = ring), accentColor, and optional `onTap` closure.

Currently registered tasks:
- **"Processing"** (purple) — AI phase; `onTap` opens `showResultsOverview`
- **"Publishing"** (accent) — Wonni/eBay/Etsy upload phase; `onTap` opens `showResultsOverview`

Photo upload no longer registers a pill (removed; shown inline in ProcessProgressView instead).

## Platform cross-posting summary

| Platform | Post method | Delete method | Mark sold out |
|---|---|---|---|
| Wonni | Firestore write | Firestore delete | `status = .sold` |
| eBay | `ebayCreateListing` CF | `ebayDeleteListing` CF | `markSoldOutAndCascade` sets qty=0 |
| Etsy | `etsyCreateListing` CF | `etsyDeleteListing` CF | `markSoldOutAndCascade` |
| Mercari | Web autofill (`MercariAutoPosterView`) | Manual (no public API) | Manual (no public API) |
| Facebook | Web autofill (`CrossPostContainerView`) | Manual (no public API) | Manual (no public API) |

## Cloud Functions

All in `wonni/functions/`. Deployed via Firebase CLI.
- `identifyItem` — Gemini Vision for AI listing generation
- `ebayExchangeToken` — OAuth code → eBay access token
- `ebayCreateListing`, `ebayUpdateListing`, `ebayDeleteListing`
- `etsyExchangeToken`, `etsyCreateListing`, `etsyUpdateListing`, `etsyDeleteListing`
- `markSoldOutAndCascade` — marks sold out in Firestore, sets eBay qty=0, updates Etsy
- `restockAndCascade` — restores quantity on eBay and Etsy
- `decrementAndCascade` — called on sale; decrements inventory across platforms
- `ebayGetOrderTakeHome`, `etsyGetReceiptTakeHome` — fee calculation for sales dashboard
- `syncSales` — scheduled sync of eBay/Etsy orders into Firestore

## Mercari web autofill architecture

`MercariAutoPosterView` (in `CrossPostWebView.swift`) runs a `WKWebView` headlessly in a `.background()` modifier. It:
1. Loads `mercari.com/sell`
2. Injects JS to fill title, description, price, photos, shipping
3. Shows a pill UI above the tab bar (via `MainView`'s `safeAreaInset`)
4. Expands to a `fullScreenCover` only when user interaction is needed (login, category review)

`MercariSyncManager` is a separate manager for syncing existing Mercari listings back into Wonni (price/title/sold-status drift detection).

## Known constraints

- **ProfileView is very large** — body is split across `profileNavCore` / `profileNavStack` / `body` @ViewBuilder properties and a `@ToolbarContentBuilder profileToolbar` to avoid Swift compiler type-check timeouts. Do not collapse them.
- **Mercari and Facebook have no public APIs** — all cross-posting and status updates are web-automation only. Deletion and sold-out cascade for these platforms require manual action by the user.
- **Two navigation mutations per frame = freeze** — see Navigation rules above.
- **SwiftData `Item` vs Firestore `UserListing`** — drafts are `Item` (local SwiftData). After publishing they become `UserListing` in Firestore. The two never coexist for the same listing.

## Testing strategy

**Goal**: Prevent broken code reaching main by testing critical user flows automatically.

**Test layers**:
1. **SwiftLint** (code quality) — runs on all PRs, warnings only
2. **Unit tests** (XCTest) — test data models, managers, state logic
3. **UI tests** (XCUITest) — test end-to-end selling flow on every PR
4. **Build check** — verify app builds without errors

**Critical test: Selling flow end-to-end** (`SellingFlowTests.swift`)
- Camera → Proceed to drafts → Process (AI) → Review & Publish → Platform toggles → Publish
- Runs on iPhone 15 simulator, timeout: 60s for AI processing
- MUST pass before main merge

**Running tests locally**:
```bash
cd wonni

# Unit tests
xcodebuild test -scheme wonni -destination 'platform=iOS Simulator,name=iPhone 15'

# UI tests (selling flow)
xcodebuild test -scheme wonniUITests -destination 'platform=iOS Simulator,name=iPhone 15'
```

**GitHub Actions** (`.github/workflows/test.yml`)
- Runs on all PRs and pushes to main
- Blocks merge if tests fail
- Uploads logs on failure for debugging

**When adding features**:
- Add unit tests for new managers/models
- Add UI test scenarios for user-facing flows
- All tests must pass before PR merge

## Dev workflow

- **Branch naming**: `claude/<short-slug>` for AI-assisted work
- **Commit style**: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`) — no `Co-Authored-By` lines
- **CI**: GitHub Actions runs SwiftLint, unit tests, and UI tests on all PRs (required to pass before merge)
- **Testing**: See Testing strategy section above
- **Git worktrees**: used to isolate feature branches while keeping main buildable
- **Cloud Functions deploy**: `firebase deploy --only functions` from `wonni/` directory
