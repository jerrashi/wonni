/**
 * commit_listing_proposals.js — `commitListingProposals`: the web's commit step
 * for `textToListings` (2026-10-15). iOS creates drafts on the device (its
 * SwiftData `Item` → `syncProductData`); the web has no local draft store, so
 * the reviewed proposals are sent here and become `products/{id}` docs in one
 * call — the same doc shape the URL importers write (`buildNewProductDoc`),
 * plus the listing fields a proposal carries that the importers never had
 * (tags, short title, eBay category / condition / ePID / specifics, shipping
 * estimate, quantity, cost + provenance of a pasted link).
 *
 * Photos are re-hosted into our bucket first (eBay sellers' photos, Amazon
 * images, Google results would otherwise 403 or vanish), through
 * source_links.fetchBytes — public https hosts only, same SSRF guard as the
 * link fetch. A photo that fails to download is skipped; a draft with no photo
 * left is still created (the web shows its own placeholder).
 *
 * One proposal failing never fails the batch: `errors` names it.
 */

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { validated } = require("./contracts");
const { buildNewProductDoc } = require("./product_schema");
const { savePublicBuffer } = require("./product_media");
const { fetchBytes } = require("./source_links");
const { maybeApplyCrossPostRulesAfterImport } = require("./cross_post");

const MAX_PHOTOS = 12;
const IMAGE_TYPES = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif" };

/** Download + store one proposal's photos; returns the stored public URLs. */
async function rehostImages(urls, { uid, docId, storage, fetchBytesImpl }) {
  const out = [];
  for (let i = 0; i < Math.min(urls.length, MAX_PHOTOS); i++) {
    try {
      const { buffer, contentType } = await fetchBytesImpl(urls[i]);
      const ext = IMAGE_TYPES[contentType] || (contentType.startsWith("image/") ? "jpg" : null);
      if (!ext) throw new Error(`Not an image (${contentType || "unknown type"})`);
      const file = storage.file(`dropship/${uid}/text-${docId}/${i}.${ext}`);
      out.push(await savePublicBuffer(storage.name, file, buffer, contentType || "image/jpeg"));
    } catch (e) {
      console.warn(`[commitListingProposals] photo ${i} of ${docId} skipped: ${e.message}`);
    }
  }
  return out;
}

/** The products/{id} document for one proposal (pure; tested). */
function productDocFor(uid, p, { images, now }) {
  const doc = buildNewProductDoc({
    userId: uid,
    source: p.source || "text",
    sourceId: p.sourceId,
    sourceUrl: p.sourceUrl,
    title: p.title,
    description: p.description,
    category: p.category,
    brand: p.brand,
    condition: p.condition,
    isDraft: true,
    sourcePrice: p.sourcePrice ?? null,
    listingPrice: p.suggestedPrice ?? null,
    sourceImages: p.imageUrls || [],
    images,
    aiSuggestedTitle: p.shortTitle || p.title,
    aiSuggestedPrice: p.priceSource === "user" ? (p.marketPrice ?? null) : (p.suggestedPrice ?? null),
    aiSuggestedDescription: p.description,
    importedAt: now,
    updatedAt: now,
  });
  // buildNewProductDoc only emits its own allowlist; the proposal's extra
  // listing fields go on afterwards (same keys ebayCreateListing / the web read).
  doc.shortTitle = p.shortTitle || p.title.slice(0, 80);
  doc.tags = p.tags || [];
  doc.quantity = p.quantity || 1;
  if (p.ebayCategoryId) doc.ebayCategoryId = p.ebayCategoryId;
  if (p.ebayConditionId) doc.ebayConditionId = p.ebayConditionId;
  if (p.epid) doc.epid = p.epid;
  if (p.itemSpecifics && Object.keys(p.itemSpecifics).length) doc.geminiItemSpecifics = p.itemSpecifics;
  if (p.weightOz) { doc.weightOz = p.weightOz; doc.weightLbs = Math.round((p.weightOz / 16) * 1000) / 1000; }
  if (p.lengthIn) doc.lengthIn = p.lengthIn;
  if (p.widthIn) doc.widthIn = p.widthIn;
  if (p.heightIn) doc.heightIn = p.heightIn;
  if (p.isBundle && p.bundleItems?.length) doc.bundleItems = p.bundleItems;
  doc.listingSource = {
    kind: "textToListings",
    sourceText: p.sourceText,
    priceSource: p.priceSource,
    imageSource: p.imageSource,
    photoMatch: p.photoMatch ?? null,
    ...(p.searchQuery ? { searchQuery: p.searchQuery } : {}),
    ...(p.included ? { included: p.included } : {}),
  };
  return doc;
}

/**
 * Commit every proposal. `deps` (injectable): db, storage, fetchBytesImpl,
 * applyRules(db, uid, productId), now.
 */
async function commitProposals(uid, proposals, deps = {}) {
  const db = deps.db || admin.firestore();
  const storage = deps.storage || admin.storage().bucket();
  const fetchBytesImpl = deps.fetchBytesImpl || fetchBytes;
  const applyRules = deps.applyRules || maybeApplyCrossPostRulesAfterImport;
  const now = deps.now || admin.firestore.FieldValue.serverTimestamp();

  const productIds = [];
  const errors = [];
  for (const p of proposals) {
    try {
      const docRef = db.collection("products").doc();
      const images = await rehostImages(p.imageUrls || [], { uid, docId: docRef.id, storage, fetchBytesImpl });
      await docRef.set(productDocFor(uid, p, { images, now }));
      await applyRules(db, uid, docRef.id);
      productIds.push(docRef.id);
    } catch (e) {
      console.error(`[commitListingProposals] "${p.title}" failed: ${e.message}`);
      errors.push({ title: p.title, error: String(e.message || e).slice(0, 300) });
    }
  }
  return { productIds, errors };
}

exports.commitListingProposals = onCall(
  { timeoutSeconds: 300, memory: "1GiB" },
  validated("commitListingProposals", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return commitProposals(uid, data.proposals);
  })
);

exports._internal = { productDocFor, commitProposals, rehostImages };
