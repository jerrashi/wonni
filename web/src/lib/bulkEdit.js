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
    || Boolean(edits.markOutOfStock);
}
