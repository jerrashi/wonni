# wonni_dropship — current state

Dropshipping/reselling ops app: imports products from AliExpress/Weverse,
lists them on eBay/TikTok Shop/Mercari, tracks orders. Firebase (Firestore +
Cloud Functions) backend, React web app (`web/`), Chrome extension
(`extension/`) for sites without a usable API (Weverse scraping, Mercari
posting/automation).

Design reference: a separate iOS app ("wonni", different Firebase project)
has proven UI/flow patterns worth porting — see local memory
`wonni-ios-design-reference` for specifics. Port design, not data.

## Roadmap (user priority order, set 2026-07-24)
1. Product variations (listing details) — **Phase 1, mostly shipped**
2. eBay + Mercari cross-posting — **Phase 2/3 partially in flight** (see below)
3. Unified sales tracking — **not started**, full spec at
   `~/.claude/plans/sales-dashboard-spec.md`

Full decision history/why lives in local memory
`roadmap-variations-crosspost-sales` (not repo-visible, machine-local).

## TODO (Phase B backend merge, as of 2026-07-31)

Full plan: `~/.claude/plans/wise-sniffing-salamander.md`. Everything below is
prep work already done and verified locally (not yet deployed) unless noted.

External consoles (not doable from here):
- [ ] Update the registered `redirect_uri` at AliExpress Open Platform and
      TikTok Shop Partner Center to `https://wonni-app.web.app/web/oauth/{aliexpress,tiktok}`.
      Confirmed 2026-07-31 this is still correct even under the "one product,
      two platforms" long-term vision — it's tied to which Firebase
      project/Hosting the backend lives in, not to which client calls in;
      AliExpress/TikTok are web-only dropshipping-sourcing features by
      design, out of scope for iOS regardless.
- [ ] Same for eBay's RuName (server-side on eBay's end) — provisional,
      will need to change again once "eBay integration convergence" (below)
      lands and there's one eBay connection instead of two.

Needs explicit go-ahead (irreversible / touches production):
- [ ] Validate merged Firestore/Storage rules — no local emulator available
      (no Java on this machine); use
      `firebase deploy --only firestore:rules,storage --project wonni-app`
      or the Console's Rules Playground.
- [ ] Run data migration: `auth:import` (zero email overlap already
      confirmed between the two projects, so no dedup needed), copy
      `orders`/`users` data, convert `products` → `listings` docs, copy
      Storage objects.
- [ ] Cutover deploy: push merged functions to `wonni-app`, deploy rules,
      deploy the repointed web app, then decommission `wonni-dropship`'s old
      Hosting/Functions.

Deferred code work (not started, no blocker but real scope):
- [ ] `ProductDetail.jsx`'s own read/write migration off `products` onto
      `listings` (20+ scattered `updateDoc` call sites).
- [ ] **eBay integration convergence** (new phase, named 2026-07-31): merge
      dropship's and wonni-app's separate eBay Developer App
      connections/credentials into one, so a user connects eBay once and
      either client posts through it — the real reason `dropshipEbay*` was
      kept as a deliberately temporary name rather than renamed by platform.
- [ ] Phase 3, unified sales/orders dashboard — spec written
      (`~/.claude/plans/sales-dashboard-spec.md`), untouched so far; today's
      `orders` rule merge is a step toward it, not the implementation.

## As of 2026-07-29

**Main was fixed today.** `functions/index.js`, `aliexpress_product.js`,
`weverse_product.js`, and `weverse_bulk_import.js` had `require()`s for
`gemini_identify.js`, `mercari_listing.js`, and `product_cleanup.js` that
were committed (`3e52231`) without the files themselves ever being
`git add`-ed — main was broken (`Cannot find module`) until commit
`b431996`, which added those files plus a `generate_description.js` Cloud
Function and an "✨ AI Suggest" description button in `CreateDraftModal.jsx`
/ `ProductDetail.jsx` (Gemini-generated listing descriptions from
title+photo). **Not yet pushed to origin.**

**New Cloud Functions landed today:**
- `gemini_identify.js` — `importTimeGeminiFields`: best-effort Gemini
  enrichment (suggested description/category/tags) called at import time
  from AliExpress/Weverse/bulk-import. Never throws — failures return `{}`.
- `generate_description.js` — `generateProductDescription` callable: on-demand
  Gemini description generation from the web UI (title + one image, base64
  or URL).
- `mercari_listing.js` — `updateMercariListingStatus` (called by the
  extension's background script after a post attempt) and
  `ensureMercariListingDetails` (prefills the cross-post form).
- `product_cleanup.js` — `onProductDeleted` Firestore trigger, deletes
  orphaned Storage files when a product doc is deleted.

**Resolved 2026-07-29:** the `implement-mercari-cross-posting-phase3` branch
and `draft-photo-split-flow` worktree (both leftover from interrupted parallel
agent runs) have been reconciled and removed.
- `implement-mercari-cross-posting-phase3` turned out fully redundant — main
  already had the same feature independently via commit `e867310`, with a
  byte-identical `mercari_content.js` and a superset of the message-passing
  wiring. Deleted without merging.
- `draft-photo-split-flow`'s one uncommitted tweak was **not** stale (initial
  assessment was wrong): the recent cut-line UX commits (drag lines, ✕
  delete, real-time evenly-slice) only ever touched `ProductDetail.jsx`'s
  split editor, never `CreateDraftModal.jsx`'s own copy used during draft
  creation. Ported that diff to main (commit `cb563b1`) to bring the two
  editors back to parity, then removed the worktree/branch.

**Cleanup backlog: closed out 2026-07-29.** All 3 leftover git stashes were
verified line-by-line against current main and dropped:
- `stash@{2}` was literally the pre-patch old Phase-1 WIP (old single-"Option"
  variant seeding, old `suggestedSellPrice`/`listingStatus` shape) kept as a
  rollback reference during the variant-redesign patch — long since obsolete.
- `stash@{0}`/`{1}` were two checkpoints of an abandoned alternate
  implementation: a `MercariListModal` component (never committed, file
  unrecoverable) invoked per-card from the Dashboard, and a DOM/CSS-based
  split-line editor — both superseded by what actually shipped (the inline
  `MercariModal` in `ProductDetail.jsx`, and the canvas-drawn cut-line editor).

No more worktrees, extra branches, or stashes outstanding as of this pass.

## As of 2026-07-31 — Phase B backend merge with wonni-app (iOS) in flight

Full plan: `~/.claude/plans/wise-sniffing-salamander.md`. Goal: wonni_dropship
and the separate iOS app "wonni" (`~/Documents/GitHub/wonni`, Firebase
project `wonni-app`) share one backend — one account, one Firestore/Storage,
one Cloud Functions deploy — rather than two disconnected Firebase projects.
`wonni-app` is the survivor project.

**Phase A (shipped 2026-07-30):** both apps now support Google + Apple
sign-in with Firebase's native account-linking within their own project
(`web/src/firebase.js`/`Login.jsx`; iOS `AuthManager.swift`/`SignInView.swift`
using a generic `OAuthProvider("google.com")` web-based flow, not the
separate GoogleSignIn SDK).

**Phase B (in progress, 2026-07-31):**
- Renamed the 3 colliding eBay Cloud Functions (dropship and wonni-app each
  have their own independent eBay integration/credentials) to
  `dropshipEbay*` — **naming under review, see below**.
- `functions/listing_shape.js`: dropship's import/cross-post functions
  (`aliexpress_product.js`, `weverse_product.js`, `weverse_bulk_import.js`,
  `ebay_listing.js`, `tiktok_listing.js`, `mercari_listing.js`,
  `product_cleanup.js`) now dual-write into a `listings` collection using
  wonni-app's `UserListing` shape, alongside the existing `products` doc
  (which stays canonical for `ProductDetail.jsx` until its own migration
  pass — deferred, 20+ scattered `updateDoc` call sites, too risky to do
  blind in one pass). `UserListing.ListingVariation` (iOS) got additive
  `crossPostStatus`/`crossPostListingIds` fields for Mercari's
  one-listing-per-variant posting model.
- All of dropship's Cloud Functions are copied into wonni-app's `functions/`
  (47 total, zero name collisions after the eBay rename); `jimp` added to
  its `package.json`.
- wonni-app's `firestore.rules`/`storage.rules` gained dropship's `orders`
  collection and `dropship/{userId}/**` storage prefix.
- New Web app registered under the `wonni-app` Firebase project;
  `web/src/firebase.js` repointed at it (not yet deployed).
- wonni-app's Hosting site already serves the iOS app's OAuth-redirect and
  privacy pages at its root, so dropship's dashboard is set up to live at
  `wonni-app.web.app/web` instead (Vite `base`, React Router `basename`, a
  Hosting rewrite, and the 3 OAuth-redirect static pages copied into
  wonni-app's repo). Found and fixed two latent bugs in that pass:
  `oauth/ebay/index.html` still called the pre-rename `ebayExchangeToken`,
  and all 3 OAuth pages plus `Settings.jsx` had `wonni-dropship`'s Firebase
  config/URLs hardcoded independently of `firebase.js`. **Renamed the
  subpath from `/dashboard` to `/web` on 2026-08-02** — chosen for symmetry
  with a future `/mobile` OAuth surface once eBay integration convergence
  gives iOS its own redirect target; that target won't necessarily be a
  hosted path the way web's is (native OAuth typically returns via a
  custom-scheme/universal-link callback, not a browser redirect page), so
  `/mobile/oauth/*` wasn't created yet — only rename, no premature scaffold.

**Still open / needs manual action, not doable from here:**
- AliExpress Open Platform and TikTok Shop Partner Center's registered
  `redirect_uri` need updating to `https://wonni-app.web.app/web/oauth/*`
  to match the code — until then those OAuth connect flows will fail.
  Same idea for eBay's RuName (maps server-side on eBay's end).
- Firestore/Storage rules aren't emulator-validated (no Java on this
  machine) — needs `firebase deploy --only firestore:rules,storage --project wonni-app`
  or the Console's Rules Playground.
- Data migration (`auth:import`, Firestore/Storage copy) and the actual
  cutover deploy are unstarted — both are explicitly waiting on manual
  go-ahead per the plan (irreversible/production-affecting).
- `ProductDetail.jsx`'s own read/write migration off `products` onto
  `listings` is deferred, scope not yet started.

**Resolved 2026-07-31 — eBay naming + a new future phase.** User's real
long-term vision: wonni_dropship (web, power-user tooling) and wonni-app
(iOS, stripped-down native) become **one product on two platforms** — like
eBay's own web vs. mobile clients — not two products. Under that vision,
neither `dropshipEbay*` nor platform-based names
(`postToEbayMobile`/`postToEbayWebApp`) are the real target: the end state
is a single `ebayCreateListing` called by either client against **one**
eBay OAuth connection per user (today there are two separate eBay Developer
App registrations/credentials — that's the actual thing that differs, not
which device calls in). Decided: keep `dropshipEbay*` as an intentionally
temporary name for "the not-yet-consolidated one." The real follow-up is a
new **eBay integration convergence** phase (not scoped/started) — merge the
two eBay Developer App connections into one, migrate whichever users already
have a dropship-side eBay connection onto the unified one, and merge
`computeEbaySellPrice`/category-resolution logic — sitting downstream of
Phase B's listing-model unification, which is its precondition.

**Direction set 2026-07-31:** orders should live in one central,
user-associated collection (already true — `orders/{orderId}` has
`userId`), and wonni_dropship + wonni-app should build toward sharing the
*same* sales dashboard/tracking functionality rather than parallel
implementations — this is the direction Phase 3 (`~/.claude/plans/sales-dashboard-spec.md`)
was already written toward; nothing new to build yet, just confirms that
spec is still the target once Phase B's backend merge is further along.

## As of 2026-08-18 — eBay setup for web/iOS parity & Cloud Function deployment

**eBay env vars configured (2026-08-18)** — Added to `web/.env.local` and Google
Cloud Secrets:
- `VITE_EBAY_CLIENT_ID=JerryShi-Listify-PRD-ee56a6601-f3a9f5df` ✓
- `VITE_EBAY_RU_NAME=Jerry_Shi-JerryShi-Listif-gmmxbsbd` ✓
- `VITE_EBAY_ENV=production` ✓

Web and iOS app now share the same eBay Developer App (wonni-app project) and
can both sign in and cross-post to eBay. The RuName is pre-configured in eBay
Partner Center to map to `https://wonni-app.web.app/web/oauth/ebay`.

**Dropship functions prepared for deployment (2026-08-18):**
- Uncommented dropship auth/listing/order functions in wonni-app's `functions/index.js`
- Functions renamed with `dropshipEbay*` prefix to avoid collisions with wonni-app's own eBay integration
- All Google Cloud Secrets updated with correct eBay and dropship credentials

**BLOCKER: Consolidate eBay functions (proper fix for defineSecret conflict)**

The web/iOS parity goal requires ONE unified backend, not two separate function
sets. Current state: wonni-app has `ebayExchangeToken`/`ebayCreateListing`
(iOS), dropship has `dropshipEbayExchangeToken`/`dropshipEbayCreateListing`
(web). Deploying both causes Cloud Run's "secret env var overlaps non-secret
env var" conflict because `defineSecret()` (Cloud Secrets) + .env (regular env
vars) cannot coexist.

**Proper fix (2026-08-18 direction):**
1. Refactor `wonni-app/functions/ebay_auth.js:ebayExchangeToken` to accept
   `credentialSet: "ios" | "web"` parameter
2. Use Google Cloud Secret Manager API directly at runtime (replace all
   `defineSecret()` calls with `secretmanager.accessSecret()`) — eliminates
   deployment-time secret validation that causes the overlap
3. For web calls, fetch `DROPSHIP_EBAY_CLIENT_ID` and `DROPSHIP_EBAY_CLIENT_SECRET`
   from Secret Manager; for iOS, use existing `EBAY_CLIENT_ID`/`EBAY_CERT_ID`
4. Delete `dropship_ebay_auth.js`, `dropship_ebay_listing.js`, and all
   `dropship*` exports from `index.js`
5. Update `web/src/pages/Settings.jsx` OAuth pages to call unified
   `ebayExchangeToken` (not `dropshipEbayExchangeToken`) with
   `credentialSet: "web"`

This achieves true backend consolidation, eliminates the defineSecret conflict
entirely, and makes the codebase maintainable long-term. Estimated scope: 2-3
hours for a careful refactor + testing.

**Remaining blockers (unchanged):**

1. **Firestore/Storage rules** — not locally validated; need Firebase Console or test deploy before prod cutover.

2. **Data migration** — users from wonni-dropship project can't sign in to wonni-app backend until auth:import + copy runs.

3. **OAuth redirect URIs** — AliExpress & TikTok console registrations still need manual update to `/web/oauth/*` paths.

## Phase 1 notes (variations)
- `MAX_VARIATION_DIMENSIONS` in `ProductDetail.jsx` caps variation structure
  at 2 dimensions (primary + sub), matching Etsy's UI. Not generalized to N
  dimensions — no user has needed 3+ yet.
- AliExpress paste-a-URL import path uses the real AliExpress API
  (`aliexpress_auth.js`'s `callAliexpressApi`) for structured `sku_attr`;
  the extension's DOM-scraping fallback for AliExpress is deprioritized.
