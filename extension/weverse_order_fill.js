// weverse_order_fill.js — DELIBERATELY UNIMPLEMENTED. Read before touching.
//
// ── Why this file exists but does nothing ──────────────────────────────────
// When a Weverse-sourced product sells on eBay/Etsy/Mercari, the backend
// (functions/weverse_order_tasks.js) creates a `weverseOrderTasks/{id}` doc
// so the user can go re-buy the item on Weverse to fulfill the order. Today
// the extension's job stops at surfacing that task (popup.js's "Weverse
// re-orders" section): it deep-links the user to the Weverse sale page
// (`weverseUrl`) and lets them confirm "Mark as ordered" by hand once they've
// actually placed the order themselves.
//
// It does NOT click through Weverse's own add-to-cart/checkout flow. That is
// a deliberate scope boundary, not an oversight:
//
//   - Weverse has no official ordering API — any automation here would be
//     scripted DOM interaction against an unofficial, undocumented flow.
//   - Getting that flow wrong (selectors, cart/variant state, session
//     timing) on a REAL commerce site, with REAL money and a REAL payment
//     step, is not something to guess at. It needs to be built and verified
//     against Weverse's live site, which this sandboxed environment can't do.
//   - The user has explicitly decided this stays "fill + approve", never
//     fully automatic, specifically because of the above — a human clicks
//     the final "place order" / payment step, always.
//
// ── What a follow-up task building this out for real needs to do ──────────
// (Once it can be developed and tested against the live shop.weverse.io
// checkout — NOT guessed at from this codebase alone.)
//
//   1. Navigate to `task.weverseUrl` (the original sale/product page) in a
//      new tab, mirroring how `handleStartMercariCrossPost` in background.js
//      opens a tab and hands a content script a pending payload via
//      chrome.storage.local.
//   2. A content script on shop.weverse.io (see weverse_content.js for the
//      existing scrape-only content script on that host) would need to:
//        a. Select the right variant/size/option combination matching the
//           product's `variantId`/`optionValues` snapshotted on the task —
//           Weverse's variant picker UI must be reverse-engineered from the
//           live DOM, not assumed from this repo's other platforms' pickers.
//        b. Click "Add to cart" (or equivalent) and confirm the cart now
//           holds the right item/quantity.
//        c. Navigate to checkout and fill shipping/contact details — where
//           those come from (buyer address? a saved Weverse profile? the
//           user's own default?) is itself a decision that needs the user's
//           input, not an assumption baked in here.
//        d. STOP BEFORE THE FINAL PAYMENT-SUBMIT STEP. Never click "Place
//           order" / "Pay now" or equivalent. Hand control back to the user
//           with the cart/checkout state ready for them to review and pay.
//   3. Only after the user manually completes payment should anything call
//      `recordWeverseOrderPlaced` — and today that's still a manual "Mark as
//      ordered" action in the popup (see popup.js), not something this flow
//      would trigger itself, so the human stays the one confirming an order
//      really went through.
//
// `attemptAutoFillCart` below is the placeholder entry point for step 1-2.
// It is exported so a future implementation has an obvious place to land,
// but it throws today — nothing should call it expecting real behavior.

/**
 * @param {string} saleId - the `sales/{id}` doc this Weverse order task is
 *   fulfilling (or pass the task id — whichever the eventual implementation
 *   needs to look up `weverseUrl` + variant details).
 * @returns {Promise<never>}
 */
export async function attemptAutoFillCart(saleId) {
  throw new Error(
    "attemptAutoFillCart() is not implemented. Weverse cart-fill/checkout " +
    "automation is an explicit follow-up task that must be built and " +
    "verified against the live shop.weverse.io checkout flow — see the " +
    "comment block at the top of extension/weverse_order_fill.js. " +
    "Today the only supported flow is: open task.weverseUrl in a new tab " +
    "and let the user re-order it by hand, then confirm with " +
    "'Mark as ordered' in the popup."
  );
}
