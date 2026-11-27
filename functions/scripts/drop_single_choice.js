#!/usr/bin/env node
/**
 * drop_single_choice.js — a product with exactly one variant becomes a plain
 * product: no options, no variants (2026-11-27, user: "no need for Style for the
 * scarf, there is only one style"). Imports do this now (variation_names.js
 * dropSingleChoice); this fixes the products made before.
 *
 * Keeps product.quantity; when it is missing, takes the lone variant's quantity.
 * A product posted to eBay as a variation group is listed, not changed: eBay can't
 * turn a group into a single listing in place (needs end + re-post).
 *
 *   node scripts/drop_single_choice.js            # dry run
 *   node scripts/drop_single_choice.js --apply
 */

"use strict";

const admin = require("firebase-admin");
admin.initializeApp({ projectId: process.env.GOOGLE_CLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const apply = process.argv.includes("--apply");

(async () => {
  const snap = await db.collection("products").get();
  let fixed = 0, grouped = 0;
  for (const doc of snap.docs) {
    const p = doc.data();
    if (!Array.isArray(p.variants) || p.variants.length !== 1) continue;
    const v = p.variants[0] || {};
    const label = `${doc.id}  ${(p.title || "").slice(0, 55)}  [${JSON.stringify(v.optionValues || {})}]`;
    if (p.crossPostStatus?.ebay === "active" && (p.ebayInventoryItemGroupKey || p.ebayHasVariations)) {
      grouped++;
      console.log(`EBAY GROUP, left as is: ${label}`);
      continue;
    }
    fixed++;
    const qty = typeof p.quantity === "number" ? p.quantity : (typeof v.quantity === "number" ? v.quantity : 1);
    console.log(`${apply ? "plain" : "would make plain"}: ${label}  qty ${qty}${p.crossPostStatus?.ebay === "active" ? "  (live on eBay, single)" : ""}`);
    if (apply) {
      await doc.ref.update({
        options: [], variants: [], quantity: qty,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  console.log(`\n${fixed} ${apply ? "made plain" : "to make plain"}, ${grouped} live eBay groups left as is.`);
})().catch((e) => { console.error(e); process.exit(1); });
