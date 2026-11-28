// Bulk edit math for the Products page (web port of iOS BulkEditSheet,
// 2026-11-24). Pure: product + the dialog's edits in, a products/{id} patch out.
// Blank edits leave each product's own value alone.

export const HANDLING_DAYS = [1, 2, 3, 4, 5, 7, 10, 14, 21, 30]; // iOS HandlingTimeOptions.days

const num = (v) => {
  if (v === "" || v == null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const cents = (n) => Math.round(n * 100) / 100;

/** A variant with its own price (not following the listing price). */
const ownPrice = (v) => v && v.price != null && v.price !== "" && Number.isFinite(Number(v.price));

/** True when at least one variant's price differs from the listing price —
 *  the only case where "change variant prices too?" is a real question. */
export function hasVariantPriceOverrides(product) {
  const base = Number(product?.listingPrice);
  return (product?.variants ?? []).some((v) => ownPrice(v) && Number(v.price) !== base);
}

/** One price through the dialog's rule. null = leave as is. */
export function adjustPrice(current, { mode, unit, amount, limit }) {
  const a = num(amount);
  if (!mode || a == null) return null;
  if (mode === "set") return a > 0 ? cents(a) : null;
  const c = Number(current);
  if (!(c > 0)) return null; // nothing to raise or lower
  const signed = mode === "decrease" ? -a : a;
  let next = unit === "pct" ? c * (1 + signed / 100) : c + signed;
  const lim = num(limit);
  if (mode === "decrease") next = Math.max(next, lim ?? 0.01);
  if (mode === "increase" && lim != null) next = Math.min(next, lim);
  return cents(Math.max(next, 0.01));
}

const joinText = (pre, text, app, sep) => {
  let out = text ?? "";
  if (pre) out = out ? `${pre}${sep}${out}` : pre;
  if (app) out = out ? `${out}${sep}${app}` : app;
  return out;
};

/** The products/{id} patch for one product, or null when nothing changes. */
export function bulkEditPatch(product, edits) {
  const patch = {};
  const t = (s) => (s ?? "").trim();

  const title = joinText(t(edits.titlePrepend), product.title ?? "", t(edits.titleAppend), " ");
  if (title !== (product.title ?? "")) patch.title = title;
  const description = joinText(t(edits.descPrepend), product.description ?? "", t(edits.descAppend), "\n\n");
  if (description !== (product.description ?? "")) patch.description = description;

  const price = edits.price ?? {};
  const listingPrice = adjustPrice(product.listingPrice, price);
  if (listingPrice != null && listingPrice !== product.listingPrice) patch.listingPrice = listingPrice;
  if (edits.changeVariantPrices && price.mode && Array.isArray(product.variants) && product.variants.some(ownPrice)) {
    // Whole-array write: a dotted "variants.0.price" path turns the array into a map.
    // "Set" makes every variant follow the one new price (null = follow).
    const variants = product.variants.map((v) => {
      if (!ownPrice(v)) return v;
      const next = price.mode === "set" ? null : adjustPrice(v.price, price);
      return price.mode === "set" || next != null ? { ...v, price: next } : v;
    });
    if (variants.some((v, i) => v !== product.variants[i])) patch.variants = variants;
  }

  if (edits.condition) {
    patch.condition = edits.condition;
    patch.mercariCondition = edits.condition;
  }
  if (edits.shipping === "buyer" || edits.shipping === "free") {
    patch.buyerPaysShipping = edits.shipping === "buyer";
    patch.mercariBuyerPaysShipping = patch.buyerPaysShipping;
  }
  if (edits.handling === "reset") patch.handlingTimeDays = null;
  else if (num(edits.handling) > 0) patch.handlingTimeDays = num(edits.handling);

  const lb = num(edits.weightLbs), oz = num(edits.weightOz);
  if ((lb ?? 0) > 0 || (oz ?? 0) > 0) {
    patch.weightLbs = Math.floor(lb ?? 0);
    patch.weightOz = oz ?? 0;
  }
  const dims = [edits.lengthIn, edits.widthIn, edits.heightIn].map(num);
  if (dims.every((d) => d > 0)) [patch.lengthIn, patch.widthIn, patch.heightIn] = dims;

  return Object.keys(patch).length ? patch : null;
}

/** Does the dialog change anything at all? (Apply stays disabled until it does.) */
export function hasAnyEdit(edits) {
  return bulkEditPatch({ title: "", description: "", listingPrice: 10, variants: [{ price: 12 }] }, { ...edits, changeVariantPrices: false }) != null
    || Boolean(edits.markOutOfStock)
    || adjustQuantity(0, edits.quantity ?? {}) != null;
}

// ── Quantity: Remove / Set / Add (2026-11-28) ───────────────────────────────
// Same rule as functions/sales.js planQuantityAdjustment, which does the real
// write; this only drives the dialog's "N will be marked out of stock" line.

/** Remove never goes below 0. null = no quantity change. */
export function adjustQuantity(current, { mode, amount }) {
  const a = num(amount);
  if (!mode || a == null || a < 0 || !Number.isInteger(a)) return null;
  const q = Math.max(0, Number(current) || 0);
  if (mode === "set") return a;
  if (mode === "add") return q + a;
  return Math.max(0, q - a);
}

/** Total stock before and after for one product (every active variant when the
 *  quantity varies by variant, else the one shared number). */
export function quantityChange(product, quantity) {
  const variants = Array.isArray(product?.variants) ? product.variants : [];
  const perVariant = variants.length > 0 && product.quantityVariesByVariant === true;
  if (!perVariant) {
    const before = Math.max(0, Number(product?.quantity) || 0);
    const after = adjustQuantity(before, quantity);
    return after == null ? null : { before, after };
  }
  let before = 0, after = 0;
  for (const v of variants) {
    if (!v || v.active === false) continue;
    const b = Math.max(0, Number(v.quantity) || 0);
    const n = adjustQuantity(b, quantity);
    if (n == null) return null;
    before += b; after += n;
  }
  return { before, after };
}

/** "2 will be marked out of stock · 1 will be restocked and re-listed." or "". */
export function quantityWarning(products, quantity) {
  let out = 0, back = 0;
  for (const p of products) {
    const c = quantityChange(p, quantity);
    if (!c) continue;
    if (c.before > 0 && c.after === 0) out++;
    if (c.before === 0 && c.after > 0) back++;
  }
  const parts = [];
  if (out) parts.push(`${out} will be marked out of stock`);
  if (back) parts.push(`${back} will be restocked and re-listed`);
  return parts.length ? `${parts.join(" · ")}.` : "";
}
