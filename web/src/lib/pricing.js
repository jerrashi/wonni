// Single source of truth for listing prices — mirrors the backend helper in
// `wonni/functions/platform_adapters.js`. Keep the two in sync.
//
// `product.listingPrice` is THE cross-platform list price used for every
// channel (eBay / TikTok / Mercari / Etsy). It is never derived from the cost
// field (`sourcePrice`) or an invented markup — cost is tracking only.

/**
 * The product's list price. Throws if it isn't a positive number so callers
 * block the post with a readable message instead of shipping a bad price.
 * @returns {number}
 */
export function resolveListingPrice(product) {
  const price = Number(product?.listingPrice);
  if (!Number.isFinite(price) || price <= 0) {
    throw new Error("Set a listing price before posting (Draft details → Listing price).");
  }
  return price;
}

/**
 * Per-variant price: the variant's own `price` only when it's a positive
 * number (a deliberate override); otherwise the product-level list price.
 * @returns {number}
 */
export function variantPrice(variant, basePrice) {
  const p = Number(variant?.price);
  return Number.isFinite(p) && p > 0 ? p : basePrice;
}

/**
 * The known unit cost, for margin display and the suggested-price chip only —
 * never a fallback for the list price. `sourcePrice` is the one cost field
 * (the old `sourceCost` / `aliexpressPrice` split was renamed away 2026-09-03,
 * `functions/scripts/backfill_source_price.js`).
 * @returns {number|null}
 */
export function productCost(product) {
  const c = Number(product?.sourcePrice);
  return Number.isFinite(c) && c > 0 ? c : null;
}

/**
 * One-click suggested list price for the "✨ Suggested $X" chip: 2× cost,
 * grossed up for ~10% marketplace fees, rounded to the nearest dollar.
 * Returns null when a price is already set or no cost is known — so the chip
 * only appears when it's actually useful.
 * @returns {number|null}
 */
export function suggestedListingPrice(product) {
  if (Number(product?.listingPrice) > 0) return null;
  const cost = productCost(product);
  return cost == null ? null : Math.round((2 * cost) / 0.9);
}
