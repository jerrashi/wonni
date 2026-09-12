# Sale stages (kanban/spreadsheet) + revenue-accounting fix

Grounded in code as of 2026-09-11. Extends `2026-09-09-phase3-sales-dashboard.md`
(3a/3b already shipped). Two problems, one field:

1. **UX**: user wants to track sales as a kanban board (drag between columns)
   or a spreadsheet (dropdown per row), with the four default columns
   "ready to ship / in transit / delivered / completed" plus the ability to
   add custom columns — instead of today's single "advance status" arrow.
2. **Accounting bug found along the way**: `cancelled`/`returned` sales are
   currently zeroed out of every total (revenue, cost, *and* net), which
   hides real money lost on a return (unrefunded fees, return shipping,
   eaten outbound shipping) instead of showing it as a loss.

Status quo, for reference: `web/src/pages/Sales.jsx` `NEXT_STATUS` (line 28)
is a fixed forward-only chain (`pending→shipped→delivered→complete`,
cancelled/returned are dead ends with no UI to reach them at all today);
`wonni/wonni/Models/Sale.swift` `SaleStatus` mirrors the same 6-value fixed
enum; `functions/contracts/_shared.js` `SaleStatusSchema` is a `z.enum` of
those same 6 strings.

**Decision, settled over discussion:** don't add a separate `stage` field —
`status` *becomes* the open, user-editable board/dropdown field directly.
No locked buckets; `cancelled`/`returned` are draggable/selectable like any
other column, not special-cased in the UI.

## 1. Data model

### `users/{uid}/settings.saleStages` — new, per-user, ordered list

```js
saleStages: [
  { key: "pending",   label: "Ready to Ship", builtIn: true },
  { key: "shipped",   label: "In Transit",    builtIn: true },
  { key: "delivered", label: "Delivered",     builtIn: true },
  { key: "complete",  label: "Completed",     builtIn: true },
  { key: "cancelled", label: "Cancelled",     builtIn: true },
  { key: "returned",  label: "Returned",      builtIn: true },
]
```

- Seeded with the above 6 on first use. `label` is the user's kanban wording;
  `key` is the LITERAL value `sale.status` already holds today — matches
  `sales.js`'s `SALE_STATUS_ORDER`/`SALE_STATUS_TERMINAL`,
  `resolveEbayStatus()`/the Etsy status ternary (`sale_poller.js`), and the
  web `Sales.jsx` chips, so every already-recorded sale (and every sale a
  poller writes going forward) lands on a key that's guaranteed to exist in
  the board — no migration of existing `sales/{id}` docs needed. (First
  draft of this table used friendlier-looking keys like `ready_to_ship` /
  `in_transit` / `completed` that didn't match those wire values — caught
  before the UI shipped, since the board renders one column per key and an
  unmatched status would have nowhere to land. Fixed 2026-09-11.) Order here
  = column/dropdown order.
- `key` is **permanent** for the 6 built-ins — never editable, never
  deletable. `label` is the only thing the user can rename, so renaming
  never breaks old sales or the revenue-exclusion match below (which keys
  off `key`, not `label`).
- User *can* add/rename/reorder/delete their own custom buckets
  (`builtIn: false` or absent). Deleting a custom bucket that sales still
  reference: block deletion (or offer "reassign existing sales to ___") —
  don't let sales point at a vanished `key`. Open UX detail, not a blocker
  for backend work.
- **No per-bucket revenue-inclusion toggle for now** (see §2 below) —
  considered, deferred as a future feature per issue #70.

### `sale.status` — was a fixed enum, becomes an open string

`contracts/_shared.js` `SaleStatusSchema`: `z.enum([...6 values])` →
`z.string().min(1).max(40)`. Validate *membership* (does this key exist in
the user's `saleStages`?) at the call site (`recordSaleCore` / the new
`updateSaleStatus`), not in the wire schema — the schema can't see per-user
config. Existing sales keep working unchanged since the 6 default keys are
still valid strings.

### `sale.takeHome` — unchanged shape, changed meaning at the edges

Already `number | null` (`contracts/sales.js`). No new fields
(`refundAmount`, `returnShippingCost`, etc. — considered and rejected, see
§4). The only change is what's allowed to flow into it (see §3).

## 2. Revenue vs. net — the split that makes this work

Two totals, kept conceptually separate (matches existing `aggregate()`
shape, `functions/sales_metrics.js`):

- **`revenue`** = gross `priceSoldFor + shippingRevenue`. Stays **gated** by
  status, same as today: `key === "cancelled" || key === "returned"` is
  excluded, everything else counts — this is the top-line "how much did I
  sell" number, and a cancelled/returned sale didn't really land. Per-status
  configurability (letting a user opt a specific status in/out of the
  revenue line, e.g. a shop that wants a return to still count for tax
  reasons) is **deferred** — see issue #70. Since the two
  built-in keys are permanent (§1), the existing hardcoded check keeps
  working even after buckets are renamed.
- **`net`** (= take-home − cost) is **never** status-gated. Every non-deleted
  sale contributes its real `takeHome` to the net/take-home total,
  regardless of status. A returned sale with
  `takeHome: -8.40` shows as a −$8.40 hit to net take-home even though its
  $40 `revenue` is excluded from the revenue line. This is the fix for the
  "I lost money on this return and want that visible" case — no new fields
  needed, `net = takeHome - cost` already does it once `isCounted` stops
  zeroing the whole sale.

`margin = net / revenue` stays as-is; it'll occasionally look odd (net
negative, revenue excluded → margin undefined for that sale) which is
correct, not a bug — a status-excluded sale has no revenue to take a margin
against, only a net loss.

## 3. `functions/sales_metrics.js` changes

```js
// unchanged from today — EXCLUDED_STATUSES stays a hardcoded pair, because
// the "cancelled"/"returned" keys are now permanent (§1) so the string match
// survives label renames. No per-user config needed for this part.
const EXCLUDED_STATUSES = new Set(["cancelled", "returned"]);
function isRevenueCounted(sale) {
  if (!sale || sale.isDeleted) return false;
  return !EXCLUDED_STATUSES.has(sale.status);
}
```

- `revenue`/`avgOrderValue`/`margin` computed only over
  `isRevenueCounted` sales — this part of `aggregate()` barely changes from
  today's code.
- `net`/`cost`/`units`/`count` computed over **all** non-deleted sales
  (deleted sales still excluded entirely — that's a real "this never
  happened", different from cancelled/returned).
- Mirror the same split into `web/src/lib/salesMetrics.js` and
  `wonni/wonni/Data/SalesMetrics.swift` — same pattern as the 3a work, kept
  in lockstep by hand.

Tests to add in `functions/test/sales-metrics.test.js`: a returned sale with
negative real `takeHome` shows up as negative net but zero revenue; a
cancelled sale with `takeHome: null` (nothing happened) contributes zero to
both; a renamed `cancelled`/`returned` bucket (label changed, key untouched)
still excludes correctly, proving the match survives renames.

## 4. Take-home accuracy — the actual bug, found via this discussion

Considered adding `refundAmount`/`returnShippingCost` fields so we could
compute `net = revenue − refundAmount − returnShippingCost` ourselves.
**Rejected**: eBay/Etsy each have their own policy for whether they refund
their own fees, refund the original outbound shipping, and/or charge the
seller for a return label — trying to re-derive that ourselves is exactly
the kind of platform-specific logic `takeHome` already exists to avoid
(see the `sale_poller.js` header comment: "takeHome should almost always be
real"). Simpler and more correct: keep relying on the platform's own
computed take-home, which already nets all of that out — same number the
platform's own payout page shows. That means the real fix is making sure we
actually *fetch* the post-return number.

**Found while checking this:** `ebayFetchFinance()` (`sale_poller.js:190-219`)
has two bugs that currently throw the return signal away entirely:

1. It only sums `transactionType === "SALE"` rows and `break`s on the first
   one found — it never reads `REFUND` (or other adjustment) transaction
   types, which is where eBay Finances records money going back out on a
   return.
2. `takeHome: net > 0 ? net : null` — even if a refund were summed in and
   drove `net` negative, this line throws the result away and reports
   `null` instead.

Fix: sum every transaction row for the order (not just `SALE`), across
whatever `transactionType`s represent money in/out (SALE, REFUND, and any
fee-adjustment/credit rows eBay returns — enumerate from a live Finances
response against a returned order before hardcoding the list), stop
`break`-ing after the first `SALE` row, and return the signed net as-is
(drop the `net > 0` floor). Same audit needed for `etsyReceiptTakeHome`
(not yet read in this pass — check it for the same "only look at the
original sale" assumption before assuming Etsy is fine).

**Re-poll on status change:** `getOrderTakeHome` (`sale_poller.js:355-410`)
already exists as an on-demand callable that re-fetches and persists
take-home for one sale — it's the exact mechanism a return needs, just
currently only wired to a manual refresh action. When a sale's `status`
changes to the `cancelled` or `returned` key (drag, dropdown, or auto-sync —
regardless of what label the user's given that bucket), automatically call
`getOrderTakeHome` for that sale server-side so the
number updates without the user hunting for a button. Mercari/manual sales
have no take-home API — for those, if the new status implies a loss, leave
`takeHome` as whatever was last recorded and let the user hand-edit it (the
field is already editable in both clients' sale-detail sheets).

## 5. Platform auto-sync → auto status transitions

`resolveEbayStatus()` / the Etsy `status` ternary in `sale_poller.js`
already map platform lifecycle → our fixed 6-value enum. Once `status` is
an open per-user list, that mapping needs a target key — but **this is no
longer an open question**: since `cancelled`/`returned` (and the other 4
built-ins) are permanent, non-deletable keys (§1), auto-sync can keep doing
exactly what it does today — write the literal key `"cancelled"` /
`"returned"` / etc. straight from `resolveEbayStatus()` — and that key is
*guaranteed* to still exist in the user's `saleStages`, no matter what
label they've given it or how many custom buckets they've added around it.
No `semantic` field, no "bucket missing" fallback, no auto-create logic
needed. `resolveEbayStatus()` / the Etsy mapping are unchanged by this spec.

## 6. UI (web first, per earlier discussion; iOS after)

- Replace `Sales.jsx`'s single "advance status" arrow button with:
  - **Board view**: one column per `saleStages` entry, cards draggable
    between columns (`@dnd-kit` or similar — no drag library in the repo
    yet, needs adding), drop → `updateDoc(sale, { status: newKey })`.
  - **Spreadsheet view**: existing table, `status` becomes a `<select>` of
    the user's bucket labels instead of plain text.
  - Toggle between the two views, persisted (e.g. `localStorage`, doesn't
    need to be a backend setting).
- **Settings page**: new section to add/reorder/delete custom buckets and
  rename any bucket's label. The 6 built-ins can be renamed but never
  deleted or reordered away from existing (UI: no delete control on them,
  just an edit-label pencil).
- iOS: same `saleStages` doc, tap-to-move (no drag) version of the board,
  after web ships.

## Build order

1. ✅ `saleStages` schema + settings read/write (small, unblocks everything
   else). Shipped 2026-09-11.
2. ✅ `sales_metrics.js` revenue/net split (§2–3) + tests — this alone fixes
   the accounting bug even before any board UI exists. Shipped 2026-09-11.
3. ✅ `ebayFetchFinance` fix + Etsy audit (§4) — makes the fixed accounting
   actually correct end to end for real sales. Shipped 2026-09-11: both
   `ebayFetchFinance` and `etsyReceiptTakeHome` had the same two bugs
   (only-look-at-the-first-row + floor-negative-to-null); fixed via two pure,
   now-unit-tested helpers, `summarizeEbayTransactions` and
   `sumEtsyPayments` (`sale_poller.js`). No live Finances-API response was
   available to enumerate the exact non-SALE `transactionType` list, so the
   fix sums every row for the order except `SHIPPING_LABEL` (tracked
   separately, as before) rather than an allowlist — verify against a real
   returned order before relying on this in production.
4. ✅ Auto re-poll on status change (§4, last paragraph). Shipped 2026-09-11:
   `updateSaleStatusCore` (the one path a drag/dropdown move goes through)
   now fires `sale_poller.js`'s new `refetchTakeHomeForSale` whenever a sale
   lands on `cancelled`/`returned` and its platform is eBay/Etsy — best-effort,
   a failed refetch never undoes the status move. Mercari/manual are
   unaffected (no take-home API, matches `getOrderTakeHome`'s existing
   boundary). Poller re-records don't need this wired in separately — they
   already carry a fresh `finance` fetch in the same pass that sets the
   status.
5. ✅ Web board/spreadsheet UI + settings section (§6). Shipped 2026-09-11:
   `Sales.jsx` gets a Board (native HTML5 drag-and-drop columns, no new
   dependency — `@dnd-kit` wasn't in the repo and wasn't needed for this)
   and the existing Spreadsheet's status cell is now a `<select>` of the
   user's stage labels; both route through `updateSaleStatus`. View choice
   persisted in `localStorage` (per-device convenience, not backend state).
   `Settings.jsx` gets a "Sale Stages" section: reorder (▲▼), rename any
   bucket, add/delete custom buckets (built-ins can't be deleted, no delete
   control shown), batch-saved via `updateSaleStages`. New shared UI mirror:
   `web/src/lib/saleStages.js` (built-ins + chip-color map).
6. iOS board view.

Steps 1–4 are backend-only and independently shippable/testable
(`node --test`, per `backend-task-loop`). §5 no longer blocks anything —
auto-sync needs no changes at all, since built-in keys are permanent.
