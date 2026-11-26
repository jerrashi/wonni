// Products page order (2026-11-25, mock https://claude.ai/artifact/DuxfEYMMPPJyGNUPB5RX2n).
// "newest" (default) = date added, newest first. "custom" = the seller's drag order,
// stored account-wide as one id list (users/{uid}/sellingSettings/default:
// productSortMode, productOrder), so one drag is one write. Products missing from the
// list (imported since the last drag) go on top, newest first; ids of deleted products
// are ignored and dropped on the next save. Switching back to "newest" keeps the list.

/** `products` must already be newest first. */
export function orderProducts(products, mode, customIds) {
  if (mode !== "custom" || !Array.isArray(customIds) || !customIds.length) return products;
  const rank = new Map(customIds.map((id, i) => [id, i]));
  const fresh = products.filter((p) => !rank.has(p.id));
  const ranked = products.filter((p) => rank.has(p.id)).sort((a, b) => rank.get(a.id) - rank.get(b.id));
  return [...fresh, ...ranked];
}

/** Move `fromId` to where `toId` is now (before it when moving up, after it when moving down). */
export function moveId(ids, fromId, toId) {
  const from = ids.indexOf(fromId);
  const to = ids.indexOf(toId);
  if (from < 0 || to < 0 || from === to) return ids;
  const next = ids.slice();
  next.splice(from, 1);
  next.splice(to, 0, fromId);
  return next;
}
