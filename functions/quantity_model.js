"use strict";

/**
 * Quantity model for products with variations.
 *
 * `product.quantityVariesByVariant`:
 *   - true      → each variant tracks its own stock.
 *   - false     → ONE shared pool at `product.quantity`.
 *   - undefined → SHARED POOL (default, decided 2026-11-11: the user enters
 *     per-variant numbers only when they tick "Quantity varies by variant",
 *     like eBay/Etsy). Products created before that decision were backfilled
 *     by scripts/backfill_quantity_model.js, so unset now really means "new".
 *
 * A product with no variants/variations is never a pool — it just has
 * `product.quantity` — unless the flag is explicitly false (kept for the
 * callers that already treated that as "master number").
 */
function isSharedPool(product) {
  if (!product) return false;
  if (product.quantityVariesByVariant === true) return false;
  if (product.quantityVariesByVariant === false) return true;
  return product.hasVariants === true || (Array.isArray(product.variants) && product.variants.length > 0);
}

module.exports = { isSharedPool };
