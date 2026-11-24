/**
 * duplicate_titles.js — eBay's "identical item" rejection and the "(1)" title rule.
 *
 * eBay refuses a second listing it judges identical to one the seller already has
 * live (publish error 25002, "It looks like this listing is for an item you already
 * have on eBay: <title> (<listingId>)" — live 2026-11-16, two Jaemin photocards).
 * User rule 2026-11-23: two DIFFERENT Wonni products with the same title get
 * file-system style names, "Title (1)", "Title (2)", … . So when the listing eBay
 * points at belongs to another Wonni product, this product is renamed and the post
 * retried once. When it doesn't (same product, or a listing Wonni doesn't know),
 * the post fails with eBay's reason and the product shows eBay as failed.
 */

"use strict";

const { HttpsError } = require("firebase-functions/v2/https");

const SUFFIX_RE = /\s\((\d+)\)$/;

/** "Title (2)" → "Title"; anything else unchanged (trimmed). */
function baseTitle(title) {
  return String(title ?? "").trim().replace(SUFFIX_RE, "").trim();
}

const norm = (t) => String(t ?? "").trim().replace(/\s+/g, " ").toLowerCase();

/** The first "Base (n)", n ≥ 1, that no title in `taken` already uses. */
function nextFreeTitle(title, taken) {
  const used = new Set([...taken].map(norm));
  const base = baseTitle(title);
  for (let n = 1; ; n++) {
    const candidate = `${base} (${n})`;
    if (!used.has(norm(candidate))) return candidate;
  }
}

/** Cut a title to `max` characters without losing a trailing " (n)" — a plain
 *  slice would drop the suffix on a long title and eBay would see a duplicate again. */
function fitTitle(title, max = 80) {
  const t = String(title ?? "");
  if (t.length <= max) return t;
  const m = t.match(SUFFIX_RE);
  if (!m) return t.slice(0, max);
  return t.slice(0, max - m[0].length).trimEnd() + m[0];
}

/** eBay's identical-item refusal, or null. Same errorId as the create-offer
 *  "offer already exists" case (25002), so it is told apart by its wording. */
function ebayDuplicateOf(e) {
  const err = e?.ebayErrors?.find((x) => x.errorId === 25002 && /already have on eBay|identical items/i.test(x.message || ""));
  if (!err) return null;
  const param = (name) => err.parameters?.find((p) => p.name === name)?.value ?? null;
  const fromMessage = (err.message || "").match(/\((\d{9,})\)/)?.[1] ?? null;
  return { existingListingId: param("1") || fromMessage, existingTitle: param("0") };
}

/** eBay listing ids a product holds (single, mirror, and split groups). */
function ebayListingIdsOf(p) {
  const ids = [p.crossPostListingIds?.ebay, p.ebayListingId];
  if (Array.isArray(p.ebayListings)) for (const g of p.ebayListings) ids.push(g?.listingId);
  return ids.filter((x) => x != null && x !== "").map(String);
}

/**
 * Handle an identical-item refusal for `productId`.
 * - The eBay listing belongs to another of the user's products → rename this one
 *   to the next free "Title (n)" (products/{id}.title and the iOS copy
 *   listings/{id}.customTitle) and return `{ renamed: true, title }`; the caller retries.
 * - Otherwise → mark eBay failed on the product with a readable reason and throw it.
 */
async function resolveEbayDuplicate(db, uid, productId, dup) {
  const snap = await db.collection("products").where("userId", "==", uid).get();
  const docs = snap.docs.map((d) => ({ id: d.id, data: d.data() }));
  const self = docs.find((d) => d.id === productId)?.data || {};
  const owner = dup.existingListingId
    ? docs.find((d) => ebayListingIdsOf(d.data).includes(String(dup.existingListingId)))
    : null;

  if (owner && owner.id !== productId) {
    const title = nextFreeTitle(self.title, docs.filter((d) => d.id !== productId).map((d) => d.data.title));
    await db.collection("products").doc(productId).update({ title });
    const listingRef = db.collection("listings").doc(productId);
    if ((await listingRef.get()).exists) await listingRef.update({ customTitle: title });
    console.log(`[ebay duplicate] ${productId} matches ${owner.id} (eBay ${dup.existingListingId}) — renamed to "${title}"`);
    return { renamed: true, title };
  }

  const where = dup.existingListingId ? ` (eBay listing ${dup.existingListingId})` : "";
  const message = owner
    ? `eBay already has this product live${where}.`
    : `eBay says you already have this item listed${where}, and it isn't one of your Wonni products. ` +
      "To sell more than one, raise that listing's quantity, or give this one a different title.";
  await db.collection("products").doc(productId).update({ "crossPostStatus.ebay": "failed", "crossPostErrors.ebay": message });
  throw new HttpsError("already-exists", message);
}

module.exports = { baseTitle, nextFreeTitle, fitTitle, ebayDuplicateOf, ebayListingIdsOf, resolveEbayDuplicate };
