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

**In-flight branch, not yet merged:** `implement-mercari-cross-posting-phase3`
— the Chrome-extension side of Mercari cross-posting (`extension/
mercari_content.js` new, `background.js`/`manifest.json` updated,
`Dashboard.jsx`/`ProductDetail.jsx` edited). Branched before `3e52231`, so it
will conflict with `ProductDetail.jsx` on merge. This is the piece that
actually calls `mercari_listing.js`'s functions at runtime.

**Cleanup backlog (not urgent, tracked, do next):**
- `draft-photo-split-flow` worktree — fully merged into main already;
  has one stale/superseded uncommitted tweak, worktree can be removed.
- 3 git stashes — `stash@{2}` is superseded Phase-1 WIP; `stash@{0}`/`{1}`
  are near-duplicate pre-commit safety snapshots of `3e52231`, already
  landed on main. All believed safe to drop, pending confirmation.

## Phase 1 notes (variations)
- `MAX_VARIATION_DIMENSIONS` in `ProductDetail.jsx` caps variation structure
  at 2 dimensions (primary + sub), matching Etsy's UI. Not generalized to N
  dimensions — no user has needed 3+ yet.
- AliExpress paste-a-URL import path uses the real AliExpress API
  (`aliexpress_auth.js`'s `callAliexpressApi`) for structured `sku_attr`;
  the extension's DOM-scraping fallback for AliExpress is deprioritized.
