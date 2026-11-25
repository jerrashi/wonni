/**
 * client_product_id.js — where a new import's products/{id} doc goes.
 *
 * Phone vs PC drafts (2026-11-25) are told apart by id: iOS UUIDs = made on the
 * phone, Firestore auto-ids = made on the PC (web lib/draftOrigin.js, iOS
 * PCDrafts.swift). The importers (weverseImportProduct, weverseBulkImportProducts,
 * aliexpressImportProduct) used to always pick an auto-id, so a link pasted into the
 * iOS "Drafts from a List" would have landed as a PC draft. iOS now passes its own
 * UUID as `productId`; the import is written there and stamped `madeOn: "phone"`.
 * Anything else (no id, not a UUID, id already taken) gets an auto-id, as before.
 */

"use strict";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** @returns {Promise<{ ref, madeOn: "phone" | null }>} */
async function newProductRef(db, clientProductId) {
  const products = db.collection("products");
  if (typeof clientProductId === "string" && UUID_RE.test(clientProductId)) {
    const ref = products.doc(clientProductId);
    const snap = await ref.get();
    if (!snap.exists) return { ref, madeOn: "phone" };
  }
  return { ref: products.doc(), madeOn: null };
}

/** Fields to add to the new doc (buildNewProductDoc's allowlist has no `madeOn`). */
const madeOnFields = (madeOn) => (madeOn ? { madeOn } : {});

module.exports = { newProductRef, madeOnFields, _internal: { UUID_RE } };
