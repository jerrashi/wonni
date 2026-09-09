#!/usr/bin/env node
/**
 * backfill_sale_product_id.js — copy `listingId` → `productId` on every
 * `sales/` doc that has the legacy field but not the canonical one.
 *
 * The consolidated backend (`recordSaleCore`) writes `productId`; old
 * iOS-written sale docs wrote `listingId`. After this backfill every sale has
 * `productId`, so `SaleRepository.hasSale` and the iOS `Sale.linkedProductId`
 * accessor are consistent regardless of which client created the row.
 *
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/backfill_sale_product_id.js [--apply]
 */

"use strict";

const admin = require("firebase-admin");
const APPLY = process.argv.includes("--apply");

admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();

(async () => {
  console.log(`\nbackfill_sale_product_id — ${APPLY ? "APPLY" : "DRY RUN"}\n`);
  const snap = await db.collection("sales").get();

  const todo = snap.docs.filter((d) => {
    const x = d.data();
    return x.listingId && !x.productId;
  });

  console.log(`${snap.size} sales total · ${todo.length} need productId backfilled`);
  for (const d of todo) console.log(`  ${d.id}  listingId=${d.data().listingId}`);

  if (!APPLY) { console.log("\n(dry run — re-run with --apply)\n"); process.exit(0); }
  if (!todo.length) { console.log("\nNothing to do.\n"); process.exit(0); }

  let batch = db.batch();
  let n = 0;
  for (const d of todo) {
    batch.update(d.ref, {
      productId: d.data().listingId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (++n === 400) { await batch.commit(); batch = db.batch(); n = 0; }
  }
  if (n) await batch.commit();
  console.log(`\n✓ backfilled ${todo.length} sales.\n`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
