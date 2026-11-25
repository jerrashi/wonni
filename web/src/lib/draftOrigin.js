// Phone vs PC drafts (2026-11-25, mock https://claude.ai/artifact/1L7JKHqXkmPP5MAkJLn6Eu).
// One drafts folder (products/{id}, isDraft) for both clients; each draft is tagged by
// where it was made, and the tag never changes. The web shows PC drafts; phone drafts
// only with the account setting `showPhoneDraftsOnWeb` (users/{uid}/sellingSettings/
// default) or under the Phone button. iOS mirrors this with `showPcDraftsOnPhone`.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** "phone" | "pc" — where the product was made. iOS gives every draft a UUID id at
 *  creation; web ids are Firestore auto-ids. Same rule as iOS DraftOrigin.isMadeOnPC.
 *  The id beats `source`: iOS syncs used to overwrite `source` with "ios" on PC drafts
 *  edited on the phone. iOS now also writes `madeOn`, which wins when present. */
export function madeOn(product) {
  if (product?.madeOn === "pc" || product?.madeOn === "phone") return product.madeOn;
  return UUID_RE.test(String(product?.id ?? "")) ? "phone" : "pc";
}

/** A draft made on the phone (listed products are never hidden, wherever they came from). */
export function isPhoneDraft(product) {
  return madeOn(product) === "phone" && product?.isDraft !== false;
}

/** A phone draft that is still only photos (AI hasn't written a title yet). */
export function isWaitingForAI(product) {
  return isPhoneDraft(product) && !String(product?.title ?? "").trim();
}

/**
 * The products the Products page shows.
 *  - phoneOnly (the Phone button): only phone drafts.
 *  - otherwise: everything except phone drafts, plus them when showPhoneDrafts is on.
 */
export function visibleProducts(products, { showPhoneDrafts = false, phoneOnly = false } = {}) {
  if (phoneOnly) return products.filter(isPhoneDraft);
  return showPhoneDrafts ? products : products.filter((p) => !isPhoneDraft(p));
}
