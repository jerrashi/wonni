# Selling Flow Overhaul — Spec

**Date:** 2026-07-14 · **Status:** Draft for review
**Related issues:** #43 (AI output tracking), #44 (stuck publish modal), #42 (draft edit persistence)

## 1. Problem statement

An audit of the selling flow (camera → picker → drafts → AI process → review → publish → cross-post)
found that most reported problems share one architectural root: **transient flow state and long-running
job UI live in view-local `@State` inside stacked sheets/modals**. Stacking sheets on top of the live
camera degrades render performance (reported lag, unresponsive undo, transient dead taps), and
sheet-local continuation state dies when a sheet is dismissed (leftover drafts after publish, stuck
publish button).

### Verified root causes

| # | Symptom | Root cause | Evidence |
|---|---------|-----------|----------|
| 1 | "+" on a draft opens 3/4 modal; flow gets laggy | `DraftHistoryModal` (a sheet) presents `CustomPhotoPickerView` as a *nested* sheet; camera keeps rendering underneath | `CreateListingView.swift:821`, `CameraView.swift:119` |
| 2 | "Undo AI edits" slow to update | Undo writes to SwiftData → synchronous save → Firestore sync → UI updates only after `.onChange` round-trip | `CreateListingView.swift:2794-2826` |
| 3 | No AI-vs-published tracking | Publish writes only merged finals; when user had a title, Gemini output *overwrites* `userEditedTitle` in place, making AI output unrecoverable | `UploadManager.swift:529-530, 746-748` |
| 4 | Vision title pollutes AI input | Vision title is prefilled as real text; any user edit sends vision text as a "user hint" to Gemini; `DraftRow.saveLocalStateToModel` commits the prefill as user-edited on scroll-away (missing placeholder guard) | `CreateListingView.swift:951, 1191, 1238` |
| 5 | Vision labels vague ("Structure") | Classifier picks max-confidence label; in a hierarchical taxonomy broad ancestors always beat specific leaves | `UploadManager.swift:949-980` |
| 6 | Can't exit publish flow; drafts left over | Review & Publish sheet pinned open while publishing (`interactiveDismissDisabled`); post-publish continuation lives in view `@State` and dies if dismissed → `publishedPendingDeletionIDs` never drains | `CreateListingView.swift:1848-1859, 2002` |
| 7 | "Listed on Mercari!" blocks progress pill | Mercari pill is a separate `safeAreaInset` from the task-queue pill; success lingers 2.5s (8s on submit-confirm path) before queue advances; no aggregate progress | `MainView.swift:93,183`, `CrossPostWebView.swift:2376,2415` |
| 8 | Platform toggle appeared dead once | Not reproducible in code (toggle binding + `touchedPlatforms` race fix are correct). Almost certainly render-pressure from stacked views; also row tap does nothing (only the switch is tappable) | `CreateListingView.swift:2990-3032` |

Additional finding (user sidenote): deleting a draft sometimes surfaces a "Delete Failed" alert —
suspected interaction between the corner photo-stack views and `deleteDraftLocallyAndCloud` cloud
cleanup. Needs investigation (see W8).

## 2. Requirements (agreed 2026-07-14)

### Navigation (single full-screen flow, no stacked modals)
- N1. Draft history and the photo picker replace the camera **full screen**; the live camera preview
  is not rendered (and its session is paused) while hidden.
- N2. Tapping "+" on a draft returns to the **existing** photo-picker screen with that draft's photos
  shown in the bottom carousel — reuse the view, don't stack a new one.
- N3. On "Process": clear the selling view hierarchy; `ProcessProgressView` remains full screen with
  minimize (current behavior is good).
- N4. Review & Publish becomes a **full-screen view** (not a sheet) with a Back button.
  Back → camera view with drafts saved. *(Default chosen by Claude; Home was acceptable too.)*
- N5. Publish confirmation stays a modal (no change).
- N6. After confirming publish: clear the view hierarchy; show a full-screen **publish progress view**
  (per listing × platform rows: "publishing to eBay…", "posting to Mercari…") with minimize,
  mirroring the AI-processing treatment.

### Unified task queue / pill
- Q1. One central pill-bar (`AppTaskQueue`) for all long jobs: AI processing, publishing, Mercari/
  Facebook autofill. Jobs queue behind each other ("AI Processing x/y" → "Publishing x/y" → …).
- Q2. The Mercari cross-post pill is **merged into** the task-queue pill (no second pill). When the
  webview needs user interaction (login, category review), the queue pill expands to the full-screen
  webview, as today.
- Q3. The pill expands to a full-screen (or ~3/4, implementer's choice) **activity view** listing
  everything queued/running/completed.
- Q4. No lingering per-item success state: on Mercari success, advance to the next job immediately.
  Sequential (one at a time) is fine — reliability over speed.
- Q5. When all publish + cross-post jobs finish: published drafts are deleted, and the user gets a
  **results summary** (per listing × platform) with actionable errors
  (e.g. "eBay failed: missing weight") instead of silent failure. `CrossPostStatusView` is the seed
  for this; error strings must be preserved per platform.

### Publish pipeline ownership
- P1. The post-publish continuation (web autofill job building, eBay/Etsy API triggers, draft
  deletion bookkeeping: `pendingWebPlatforms`, `pendingWebJobItems`, `pendingAPITriggers`,
  `pendingPublishContinuation`) moves from `ProcessResultsOverviewView` `@State` into
  `UploadManager`, so it survives any view dismissal. This is the fix for leftover drafts and
  closes the remaining risk behind #44.

### AI quality tracking (#43)
- T1. Persist on each **published Firestore listing doc**: `aiSuggestedTitle`, `aiSuggestedDescription`,
  `aiSuggestedPrice`, `visionTitle`, `visionTitleAccepted` (bool, set by the Phase-1 chip),
  `aiModel` (e.g. `gemini-2.5-flash-lite`), `promptVersion`
  (manually bumped string constant), `aiTitleEdited` / `aiDescriptionEdited` / `aiPriceEdited`
  (bool: final differs from AI), `aiUndoCount` (times user tapped any "Undo AI edits").
- T2. To make T1 possible, Gemini output must **always** be stored in `aiSuggestedTitle` /
  `aiSuggestedDescription` on the Item, even when it is also merged into the user-edited fields
  (today the user-title path skips `aiSuggestedTitle` entirely).
- T3. Enables future analysis: "% similar to final output by model" to decide flash-lite vs flash
  vs provider change.

### Re-processing guard *(revised 2026-07-14 during Phase 1)*
- R1. Skip AI processing when `processedAt != nil` AND the photo **set** is unchanged
  (`processedPhotoIDs` compared as a Set: reorders never re-bill; add/remove/swap re-processes,
  since the photos are the AI's actual input). Set comparison beats a count check — it catches
  "swapped photo A for B".
- R2. ~~Deferred to issue #61~~ **Kept**: the logic was factored into the pure
  `DraftAIProcessingPolicy.shouldSkip` and covered by `DraftAIProcessingPolicyTests`
  (never-processed / nil-snapshot / reorder / add / remove / swap cases). Issue #61 closed.

### Vision title *(semantics finalized 2026-07-14 during Phase 1)*
- V1. The title field is never prefilled with vision output. Vision title appears as a tappable
  **suggestion chip** below the field ("Use: 'CD'") that fills the field only on tap.
  Typing anything keeps the field 100% user text (clean signal for the Gemini `userTitle` hint).
  - Chip shows only **pre-AI** (`processedAt == nil`) while the field is empty. An unaccepted
    suggestion is simply dropped at process time: the user proceeding with an empty title means
    "let the AI title it" → **no** title hint is sent to Gemini.
  - Accepting the chip sets `Item.visionTitleAccepted = true`; an accepted (possibly edited)
    title IS a deliberate user hint, so the old `userEditedTitle != visionTitle` exclusion in
    the Gemini call is removed. `visionTitleAccepted` rides to the published listing doc in
    Phase 2 → "% of vision suggestions accepted/discarded" per model.
  - Vision text may still appear as a **display-only** gray fallback label in read-only spots
    (draft history selection mode, processing progress rows), ranked after AI titles.
- V2. Remove the DraftRow scroll-away leak: with nothing prefilled, `saveLocalStateToModel`
  can only commit text the user actually typed or accepted. Done alongside V1.
- V3. Label quality — selection order (user-specified: classification is primary, OCR fallback):
  1. **Specificity-first classification**: among labels passing
     `hasMinimumRecall(0.01, forPrecision: 0.9)` AND `confidence ≥ 0.6`
     (`VisionTitlePolicy.minClassificationConfidence`), compound identifiers
     ("compact_disc" — taxonomy leaves) outrank single words; confidence breaks ties;
     generic ancestors are denylisted (`VisionTitlePolicy.genericLabelDenylist`).
  2. Fall back to OCR text (brands/model numbers are genuinely useful).
  3. Fall back to **no suggestion** (blank beats useless).
  Policy is the pure `VisionTitlePolicy.suggestion(classifications:ocrText:)` with named
  constants, covered by `VisionTitlePolicyTests` for future threshold/denylist experiments.

### Responsiveness
- U1. "Undo AI edits" updates the local field state immediately (optimistic), with `modelContext.save()`
  and Firestore sync deferred off the tap path.
- U2. Publish-confirmation platform rows: whole row toggles, not just the switch (cheap affordance
  win; the reported dead tap was likely render pressure, expected to improve with N1–N6).

## 3. Non-goals
- Parallel Mercari autofill (explicitly: sequential, reliable).
- Photo-set-change re-processing (deferred to issue).
- Changing Gemini models/prompts (T1 only creates the measurement substrate).

## 4. Implementation plan (phased)

**Phase 1 — Quick wins, no architecture risk**
U1 optimistic undo · V1/V2 suggestion chip + leak fix · V3 classifier rework · U2 row-tap toggle.
Test: unit-test `generateVisionTitle` selection policy with fixture labels (pattern per
MercariScanJS fixture tests); manual: undo latency, chip flow.

**Phase 2 — AI tracking + reprocess guard**
T2 always-store AI output → T1 Firestore fields + undo counter → R1 skip check → R2 strip WIP + file issue.
Test: publish a listing, verify doc fields in Firestore emulator/console; process-twice draft skips Gemini.

**Phase 3 — Publish pipeline ownership (prereq for Phase 4 UI)**
P1 move continuation into UploadManager; delete-drafts-after-publish correctness; keep current UI.
Test: publish with Mercari+eBay selected, dismiss everything mid-flight, verify drafts deleted and
jobs complete; UI test in SellingFlowTests.

**Phase 4 — Navigation architecture**
N1/N2 full-screen draft history + picker reuse, camera session paused when hidden ·
N4 Review & Publish full screen with Back · investigate photo-stack delete error (W8).

**Phase 5 — Unified queue + publish progress UI**
Q1–Q4 merge Mercari pill into AppTaskQueue + activity view · N6 publish progress view ·
Q5 results summary with actionable errors.

Each phase is independently shippable; 1–2 have no dependency on 3–5.

## 4b. Phase 1.1 — device-feedback round (2026-07-14 evening)

User tested Phase 1 on device; agreed follow-ups:
- **Vision labels:** "Wood Processed" (photo's wooden background) slipped through — a compound
  *material* leaf that the compound-preference actively favored. Added token-level filter:
  identifiers whose tokens are ALL material/composition words (`VisionTitlePolicy.genericTokens`)
  are rejected, letting OCR/blank take over. Regression-tested.
- **Vision metrics:** "% drafts with a suggestion" = `visionTitle != nil`; "% accepted" =
  `visionTitleAccepted`, cleaned **offline** by token-overlap between suggestion and the title
  submitted to AI (excludes accidental taps / fully-replaced text). No client-side cleaning —
  raw signals only; all fields ship to Firestore in Phase 2.
- **Review & Publish, AI-edit rows:** when AI edited a field, show ONLY the word-diff + undo link
  (was: diff AND a duplicate editable field/box). Accept = leave it · Reject = undo link ·
  Edit = tap the diff (or arrow-key into it) → editable field; committing a *changed* text
  retires the diff permanently (`originalUser*BeforeAI = nil` — the user owns the text now);
  unchanged text brings the diff back. Same ownership rule applies to edits via DraftEditSheet
  and the description editor sheet.
- **Undo toast:** in-flow element at the bottom of the row (occupies vacated space) instead of a
  floating overlay that covered neighboring rows.
- Platform-toggle dead tap: confirmed fixed on device; consistent with render-pressure, not logic.
- "+" in drafts overview not full-screen: correct — that's Phase 4 scope, untouched in Phase 1.

## 5. Open items
- W8 investigation: "Delete Failed" alert after draft deletion (suspected photo-stack / cloud-cleanup
  race). Reproduce with a draft that has uploaded photos, then delete.
- Similarity metric for "AI vs final" analysis (edit distance vs embedding) is an offline-analysis
  concern — not needed in-app; fields from T1 are sufficient.
