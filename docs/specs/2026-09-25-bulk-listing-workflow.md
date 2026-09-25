# Bulk Listing Workflow — Acceptance Criteria

Sep 25, 2026 · @Jerry

## Overview

Bulk listing mode is a separate workflow layered on top of Wonni's existing single-item draft/listing pipeline, built for high-volume, low-attention sessions — an attic cleanout, a bulk box, a relative's estate — where the constraint isn't ability to sell, it's the brainpower cost of hundreds of per-item micro-decisions.

- **Product vision**: Wonni acts as an AI agent for marketplaces that don't offer their own AI/MCP integration (eBay, Etsy, Mercari, Facebook Marketplace) — natural language in, structured listing/pricing/platform actions out, for power sellers who don't want to build or maintain their own integration.
- **How the 8 features connect**: the intent form (§1) sets an anchor prompt used by platform AI-suggest (§2), description chip generation (§3), bulk photo split (§4) / photo generation (§5), and the pricing rules engine (§6). Bulk photo entry (§4) and bulk text entry (§7) are two input paths into the same draft-generation pipeline. Sales tracking (§8) closes the loop once items sell, tracking what still needs to be bought/shipped.
- **Scope**: this doc specifies the bulk-workflow layer only. It assumes the existing single-item draft → listing → cross-post pipeline as the primitive every bulk action ultimately produces (N drafts in, same per-draft publish flow out).

## 1. Bulk Intent Capture (Natural-Language Form)

**Entry point**

- [ ] Shown when a user starts a bulk session (bulk photo capture, bulk text entry, or an explicit "New Bulk Batch" action)
- [ ] Optional — skipping is one tap; the batch proceeds with system defaults (no auction, market pricing, all connected platforms AI-suggested per category)
- [ ] Single free-text field with placeholder example text (e.g. "I want to get rid of everything within a week. Price competitively.")
- [ ] Generous character limit (e.g. 500) with a counter that appears near the limit

**Parsing**

- [ ] On submit, an LLM call parses the text into a structured `BatchIntent`: urgency (asap / normal / patient), pricing stance (aggressive / market / premium), platform stance (all / cheapest-fee / platforms named), and the raw text preserved verbatim for prompt-anchoring
- [ ] Low-confidence or failed structured extraction still stores the raw text and passes it as context to downstream AI calls (description, platform suggestion, pricing) — extraction failure never blocks the batch
- [ ] Parsed intent is shown back to the user as confirmable chips (e.g. "Timeline: 1 week", "Pricing: competitive") before being applied — user can edit or dismiss any field

**Application & persistence**

- [ ] `BatchIntent` attaches to the batch/session, not the account — different batches can carry different intents
- [ ] Passed as system-prompt context to platform AI-suggest (§2), description/chip generation (§3), and pricing rule defaults (§6) for every draft in that batch
- [ ] Editable after the fact; editing does not silently rewrite already-generated content, but flags not-yet-finalized items for re-suggestion rather than re-running everything automatically
- [ ] The intent (and its parsed fields) stays visible per item — e.g. a "why this platform/price" info tap — so AI decisions are auditable, not a black box

## 2. Platform Selection: All / AI Suggested / Manual

Three batch-level modes, with per-listing override always available.

**Modes**

- [ ] **All Listings** — every draft posts to every currently connected platform
- [ ] **AI Suggested** — platform mix computed per draft from item category/condition (AI classification), the batch's NL intent (§1), and which platforms the user has connected — e.g. bulky/large → Facebook only; vintage/collectible → Facebook + eBay + Etsy; retro electronics/games → eBay (+ Etsy if the collectible signal is strong)
- [ ] **Manual** — user picks platforms per draft directly, no AI involved (existing single-item toggle UI)
- [ ] A 3-way segmented control at the batch level applies the chosen mode to every draft not yet manually overridden

**AI Suggested — inputs & rules**

- [ ] Never hardcoded platform-per-category — always an AI call (or AI-classification-informed ruleset) so the mix varies per user's connected platforms and stated intent
- [ ] If only one platform is connected, AI Suggested collapses to that platform for every item — no error state
- [ ] Computed once per draft at creation/classification time; re-computed only if the item's AI-detected category changes (e.g. user edits title/category), not on every keystroke
- [ ] Each draft visually distinguishes "AI chose this platform" from "user chose this platform" so switching to Manual later shows a sensible starting point, not a blank slate

**Switching between modes**

- [ ] AI Suggested → All: every draft's platform set becomes "every connected platform"; per-item AI variance is discarded, but with an undo/toast — never silent and permanent
- [ ] All (or AI Suggested) → Manual: the current per-draft platform set becomes the manual starting point; nothing resets to empty
- [ ] Per-item override works at any time regardless of batch mode: toggling one platform on a single draft doesn't change the batch-level mode label — the batch shows "Mixed" / "All · 1 override" once any draft diverges from the mode default
- [ ] Concrete flow from the request: user is in AI Suggested → switches batch to All → deselects one platform on one listing → batch shows "All · 1 override" → user taps **Apply** → the shown platform set (mode default + overrides) commits for every draft in the batch, not just the one that changed
- [ ] **Apply** is explicit, visible, and undoable — not autosave-on-every-toggle, since a large batch would otherwise fire one write per tap
- [ ] Switching back to AI Suggested after manual overrides prompts the user: "Reset all to AI suggestions?" vs. "Keep my overrides, AI-suggest only untouched items" — never silently discards manual work

## 3. Condition/Attribute Chips (Bracket → Chip Conversion)

- [ ] AI-generated description text containing bracket-delimited alternatives (e.g. `[tested and working / untested]`) is detected by a parse step run on the generated text before it's ever shown to the user — raw brackets never reach the UI
- [ ] Each detected bracket group renders as a tappable inline chip in place of the bracket text (e.g. a pill reading "✓ tested and working", styled distinctly from plain description text)
- [ ] Default selection: first listed option (or the AI's best guess from photo/context, if inferable) is pre-selected, so the description reads complete with zero taps
- [ ] Tapping a chip opens a picker with: all bracket-suggested alternatives, **Edit** (free-text edit of the chosen value in place), **Add option** (free text), and **Remove** (drops that clause from the description entirely)
- [ ] Selecting an alternative updates the chip immediately and updates the underlying text sent to the marketplace — no separate save step
- [ ] Multiple independent chips per description are supported
- [ ] Chip state (selected option, custom edits) persists with the draft across app restarts and is included verbatim when the draft publishes
- [ ] Non-goal for v1 (flag if deferred): bulk-setting a recurring chip across many items in a batch at once (e.g. "tested and working" on every electronics item) in one action, rather than tapping per item

## 4. Bulk Photo Splitting (One Photo → Multiple Draft Listings)

- [ ] Entry point: a photo of multiple distinct sellable items (e.g. a pile of PC games) gets a "Split into multiple listings" choice, alongside the existing single-item photo flow
- [ ] AI/vision step detects and segments individual items in the photo (bounding boxes + per-item crop)
- [ ] Each detected item becomes its own draft — title, price estimate, and category generated from its crop plus full-photo context and the batch's NL intent (§1) for pricing stance. Matches the example: "Halo — $10 — PC games", "Call of Duty — $5 — FPS"
- [ ] Low-confidence detections (uncertain boundary, unidentifiable item) still become drafts, flagged "needs review" — never silently dropped or silently guessed
- [ ] Review UI after split shows every generated draft from that photo in a list/grid; user can merge two drafts back into one (mis-split), split a draft further, discard a draft (false positive, e.g. background clutter detected as an item), and edit any generated field
- [ ] Every generated draft keeps a reference to the source photo and its crop region, so a different crop can be chosen later and the original wide photo stays available
- [ ] Splitting is not instant for a large pile — drafts should appear progressively as detection/generation completes (skeleton cards filling in) rather than one long blocking spinner for 10+ items

## 5. Photo Sourcing: Stock / Generated Photos, Bulk Apply, Background Removal

**Per-item photo options (tapping "+" on a draft's photo row)**

- [ ] Options: **Take Photo** (camera), **Upload Photo** (library), **Generate Photo** (AI) — matching the existing take/upload pattern plus the new generate option
- [ ] Generate Photo accepts a free-text prompt (e.g. "generate a background setting for this photo"); runs image-to-image against the item's existing photo(s) if any, or text-to-image from title/description if none exist, using category/condition as context
- [ ] Iterative refinement: follow-up feedback in the same prompt box (e.g. "make the fabric leather, not polyester") regenerates from the previous result plus the new instruction — not a one-shot dead end
- [ ] Generated images are clearly marked as AI-generated in-app; whether marketplace AI-image-disclosure policies (eBay/Etsy ToS) need to be checked before publish is an **open question**, not assumed fine (see Open Questions)
- [ ] **Stock photo lookup**: for well-identified items (e.g. UPC-matched product), offer "Use stock photo" pulling a canonical product image as an alternative/supplement to user-taken photos

**Bulk photo apply (batch-level)**

- [ ] One action ("Add photo to all") attaches a single photo — user-taken, generated, or stock — to every draft in a batch (or a selected subset) in one tap, for low-value bulk items where per-item photography isn't worth the time (e.g. a cropped CD spine doesn't sell)
- [ ] Additive by default (added alongside any item-specific photo already present), with an option to replace instead
- [ ] Per-item override after bulk apply is preserved — overriding one draft's photo doesn't affect the rest

**Background removal**

- [ ] One-tap "Remove background" from a photo's edit menu
- [ ] Two-stage pipeline: local/on-device cutout first (fast, offline, no network cost — e.g. iOS's built-in subject-lift capability); falls back to a cloud call (Gemini or similar) for a higher-quality cutout if local confidence is low or fails
- [ ] The two-stage fallback is functionally seamless — one tap, one result; which path ran is exposed only if useful for cost/quality transparency
- [ ] Result is a new photo variant (not a destructive edit) — original is preserved, and the cutout can feed into "generate a background setting" (chaining background removal → generation)

## 6. Cross-Platform Pricing Rules Engine (NL-Driven, eBay Focus)

Extends Wonni's existing cross-post rules concept to be settable via natural language and to close specific gaps versus the native eBay app.

**Natural-language rule capture**

- [ ] User can type a free-text instruction, e.g.: "I want to get rid of items asap, price auctions on the lower end and buy it now on the higher end just for eBay. Use market price minus 10% for Facebook, market price for all other platforms. Enable smart pricing on Mercari and lower prices across platforms besides eBay as Mercari price decreases."
- [ ] Parsed into a structured rule set, one entry per platform: `{platform, listing_format (auction/fixed/best-offer), price_strategy (market / market±X% / market±$X), condition (e.g. value threshold for auction-vs-BIN), processing_time_override, sync_triggers}`
- [ ] Parsed rules are shown back as an editable structured summary (one row/card per platform) before being applied — never applied silently off a single NL parse
- [ ] Ambiguous or conflicting instructions surface as a clarifying question rather than being guessed silently

**eBay-specific gaps vs. the native eBay app** (explicitly called out: "in the eBay app you only select existing rules, I'm stuck using default")

- [ ] Support **auction-format** listings (not just fixed-price) per item or per rule, including start price and duration
- [ ] Support a **price-band rule**: below a configurable value threshold → auction; above it → fixed price / Buy-It-Now
- [ ] Support setting/overriding **handling/processing time** per listing or per rule via a direct value on the eBay API call — not limited to picking from eBay's existing saved business-policy templates
- [ ] Support platform-specific price offsets (e.g. "Facebook = market − 10%") as a rule dimension distinct from Mercari's native smart pricing

**Mercari smart pricing sync**

- [ ] Support enabling Mercari's own smart pricing (automatic gradual price drops) via Wonni for a rule-selected set of items
- [ ] Support a cross-platform sync rule: when Mercari smart pricing drops a price, propagate a corresponding decrease to the same item's other-platform listings, excluding any platform the rule explicitly carves out (e.g. "besides eBay")
- [ ] Needs a defined sync cadence (webhook vs. periodic poll) and a price floor/guardrail so cascading drops can't go below a configurable minimum profitable price
- [ ] Must integrate with the existing shared-inventory/quantity-cascade logic — price sync and quantity sync key off the same product/variant but are separate concerns

**Rule scope & precedence**

- [ ] Rules settable at account, batch, or single-item scope; acceptance criteria must define precedence (item > batch > account) and surface conflicts to the user when scopes disagree
- [ ] Preview before bulk apply: before a rule set is applied across a batch, show a summary (e.g. "12 items → eBay auction, 8 → eBay BIN, all → Facebook @ −10%") so the user can sanity-check before committing

## 7. Bulk Text Entry (Typed List → Draft Listings)

- [ ] Entry point: a text-input mode alongside bulk-photo entry, for items the user wants to list from memory or an inventory sheet rather than photographing first
- [ ] Accepted shape (from the example): optional category header lines ("Pc games:", "N64 games:") followed by one item per line, with optional inline metadata like a year ("Halo (2003)")
- [ ] Parser tolerates variation rather than requiring exact formatting: blank lines between groups, headers with or without a trailing colon, items with or without parenthetical metadata, extra whitespace
- [ ] A category header applies to every item below it until the next header (items before any header, or with none given, get "no category")
- [ ] Each parsed line becomes its own draft through the same title/description/price/category AI pipeline as a photo-sourced draft — this is an alternate entry point into the §4 pipeline, not a separate system; photos are added afterward via §5
- [ ] Ambiguous lines (can't confidently parse, or a likely duplicate) are flagged for review rather than silently dropped or silently guessed
- [ ] After parsing, the same review UI as §4's photo-split review applies — merge/discard/edit before drafts finalize
- [ ] The batch's NL intent (§1) applies identically to text-sourced drafts as to photo-sourced ones (same pricing stance, same platform-suggestion behavior)

## 8. Sales Tracking: Restock / Shopping & Shipping List

Goal: at the point of purchase (e.g. a K-pop merch venue) or before a shipping run, give the user a consolidated, prioritized list of what to buy or ship across all pending sales.

**Restock ("what to buy") list**

- [ ] Aggregates across all sold-but-not-yet-fulfilled sales (or pre-orders, if the app supports listing items not yet in hand) by item + variant, summing quantity needed — matches the example: "Black t-shirt: Medium – 4, Small – 1 / Poster – 5"
- [ ] Groups/sorts by item name with variant (size/color/etc.) as sub-lines — compact and scannable enough to use in-hand at a venue, including on a slow connection
- [ ] Supports checking items off as "acquired" while buying, updating the underlying sale/fulfillment records
- [ ] Reflects real-time changes — a refunded/canceled sale adjusts quantity needed, or at minimum the list is clearly marked stale, never silently wrong

**Prioritization** (for constrained inventory / per-person buying limits)

- [ ] Sort/filter by expected profit margin, by sale price, or by sale date — user-selectable per view
- [ ] Directly supports the constrained-purchase scenario: e.g. "I can only buy 3 posters due to a venue limit — show me the 3 most worth fulfilling" (highest margin or price first)
- [ ] Distinguishes committed sales (must fulfill) from flexible/backorder-style commitments, if the app models that distinction — matters most when not everything can be filled

**Shipping list** (separate but related view)

- [ ] Aggregates sales that are in-hand and ready to ship, by what's needed (label, packaging size/weight if tracked, ship-by date)
- [ ] Same prioritization controls apply, especially by ship-by date, to avoid late shipments and platform penalties
- [ ] Reuses the app's existing sale/order schema as a new aggregate view — not a duplicate data model

## 9. Sell-vs-Donate Triage (Sort & Bulk-Deselect on Review Screen)

Rather than a per-item Gemini call/field for a sell-or-donate judgment, this is handled as a sort-and-filter capability on the existing review-drafts-before-publish screen — more extensible, keeps the value judgment with the user, and generalizes beyond just sell/donate.

- [ ] The review/publish screen (where generated drafts are checked before going live — same screen referenced in §2, §4, §7) supports sorting all drafts by price, high-to-low and low-to-high
- [ ] Each draft on this screen has a selection state (include in this publish action / excluded); sorting does not change selection, only display order
- [ ] After sorting low-to-high, the user can bulk-deselect a contiguous range in one action — e.g. "deselect below $X" (tap a price threshold, or drag-select the low end of the sorted list) rather than tapping every low-value item individually
- [ ] Deselected-as-not-worth-selling drafts are not deleted — they remain as drafts the user can revisit, mark **Donate** (a lightweight status, not a workflow of its own — see non-goals below), or re-include later
- [ ] This sort/deselect pattern is general-purpose, not sell/donate-specific: same mechanic should work for other batch-level cutoffs (e.g. "only publish items I'm confident are worth listing" using an AI confidence score as the sort key instead of price, if that's exposed elsewhere in the app)
- [ ] Non-goal for v1: a dedicated "mark as donate" workflow (e.g. generating a donation receipt/itemized list for tax purposes) is out of scope here — donate is just "excluded from this publish batch," not a tracked outcome, unless the user wants that added as its own feature

## 10. AI-Suggested Bundling

Goal: for a batch containing multiple units of related/compatible items (e.g. 2 N64 consoles, 2 OEM controllers, 2 third-party controllers), suggest how to group them into bundle listings that are more appealing or balanced than the obvious naive grouping — replicating the "ask for suggestions" reasoning from the request (pairing each console with one OEM + one third-party controller, so every bundle has a primary and a second-player option, rather than one all-OEM bundle and one all-third-party bundle).

**Triggering & detection**

- [ ] Available as an on-demand action, either across a whole batch or on a user-selected subset of drafts ("select these items → Suggest Bundles") — not only fully automatic
- [ ] Detects candidate groupings from item compatibility signals: same category/brand/ecosystem (console + its controllers/accessories), matching series/set (a partial collectible set), or explicit multiples of a pairable item — this should be AI-driven pattern matching, not a hardcoded "console + controller" rule, so it generalizes to other domains (e.g. k-pop photocard binders + sleeves, tool + compatible attachments)
- [ ] Quantity-aware: uses all available units in a sensible grouping (doesn't strand one console unbundled) unless the item count genuinely doesn't divide evenly, in which case leftover items are flagged, not silently dropped

**Suggestion & reasoning**

- [ ] Each suggested bundle set comes with a short plain-language reason, shown to the user (e.g. "Splitting one OEM + one third-party controller per console gives each bundle a primary and a second-player option") — matches the transparency pattern already established for platform suggestions (§2) and pricing (§6): the user should be able to see *why*, not just get a black-box grouping
- [ ] When more than one grouping is plausible, present the top options (not just one silent pick) so the user can choose between them rather than only accept/reject a single suggestion

**Editing & control**

- [ ] User can accept a suggested bundle as-is, edit it (drag an item between bundles, add/remove an item), split it back into individual item listings, or reject the suggestion entirely and keep individual listings
- [ ] Un-bundling at any time before publish is non-destructive — breaking a bundle back into individual drafts restores each item's own title/price/photos rather than losing data

**Resulting draft**

- [ ] Accepting a bundle merges the constituent item drafts into one bundle draft: combined title/description generated from the parts (not just concatenated), a bundle price suggestion (not necessarily the sum of individual estimates — may include a bundle discount, informed by the batch's pricing stance from §1), and a combined photo set (individual item photos carried over, plus the option to generate/take a new "whole bundle together" photo per §5)
- [ ] Bundle drafts flow through the same platform-suggestion (§2) and pricing-rule (§6) logic as single-item drafts — bundles may skew toward different platforms than the individual pieces would have (e.g. local-pickup-friendly platforms for a bulky multi-item bundle)

## Open Questions & Non-Goals

- [ ] **AI-suggest recompute triggers** (§2, §6): exactly when does platform suggestion or pricing default recompute vs. stay frozen once a draft has been touched by the user?
- [ ] **Generation cost/rate limits** (§5): per-user quota, cost pass-through, or unlimited AI photo generation? Affects how freely the regenerate-with-feedback loop can be used.
- [ ] **Marketplace AI-photo disclosure policy** (§5): eBay/Etsy AI-image-disclosure rules need an explicit compliance check before shipping — not assumed fine.
- [ ] **Rule precedence conflicts** (§6): needs a concrete, signed-off resolution order for item vs. batch vs. account rules — not left implicit.
- [ ] **Mercari smart-pricing sync floor** (§6): what's the minimum-price guardrail per item, and who sets it?
- [ ] **Non-goal (to confirm)**: full auto-publish with no human review is out of scope for v1 — every bulk-generated draft, however sourced, stops at a review/confirm step before posting to any marketplace, unless the user explicitly opts out.
- [ ] **Batch-level undo/audit trail**: given how many automated decisions this workflow makes per item (platform, price, description chips, photo), should there be a single batch activity log so a user can see/undo what the AI did across 50 items at once, not just per item?
