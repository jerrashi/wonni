#!/usr/bin/env node
/**
 * backfill_variants_on.js — turn on every variant of an imported product
 * (2026-11-26, user: "turn sizes on for every imported product").
 *
 * Until 44b538d the Weverse importer turned off every size Weverse showed as sold
 * out (`active: !soldOut`). That is Weverse's stock, not the seller's, and an
 * all-off product posted to eBay with no sizes. New imports start all on; this
 * fixes the products imported before.
 *
 * Imported = source "weverse" or "aliexpress". Whole-array write (never a dotted
 * `variants.0.active` path, which turns the array into a map).
 *
 *   node scripts/backfill_variants_on.js            # dry run
 *   node scripts/backfill_variants_on.js --apply
 */

"use strict";

const admin = require("firebase-admin");
admin.initializeApp({ projectId: process.env.GOOGLE_CLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const apply = process.argv.includes("--apply");
const IMPORT_SOURCES = ["weverse", "aliexpress"];

(async () => {
  const snap = await db.collection("products").where("source", "in", IMPORT_SOURCES).get();
  let products = 0, variants = 0, allOff = 0;
  for (const doc of snap.docs) {
    const p = doc.data();
    if (!Array.isArray(p.variants)) continue;
    const off = p.variants.filter((v) => v && v.active === false).length;
    if (!off) continue;
    const wasAllOff = off === p.variants.length;
    if (wasAllOff) allOff++;
    products++;
    variants += off;
    const ebay = p.crossPostStatus?.ebay === "active" ? `  [live on eBay ${p.crossPostListingIds?.ebay || ""}]` : "";
    console.log(`${apply ? "on" : "would turn on"} ${off}/${p.variants.length}${wasAllOff ? " (all off)" : ""}  ${doc.id}  ${(p.title || "").slice(0, 60)}${ebay}`);
    if (apply) {
      await doc.ref.update({
        variants: p.variants.map((v) => (v && v.active === false ? { ...v, active: true } : v)),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  console.log(`\n${snap.size} imported products: ${products} ${apply ? "fixed" : "to fix"} (${variants} variants, ${allOff} had every variant off).`);
})().catch((e) => { console.error(e); process.exit(1); });
