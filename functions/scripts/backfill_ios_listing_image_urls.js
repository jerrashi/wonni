#!/usr/bin/env node
/**
 * backfill_ios_listing_image_urls.js
 *
 * One-shot: `migrate_listings_to_products.js` (2026-09-09) wrote bare Storage
 * paths (e.g. "users/uid/id/0.jpg") into `products/{id}.images` for every
 * `source: "ios-listing"` doc, instead of the public storage.googleapis.com
 * URL every other source uses — see listing_shape.js `resolvePhotoUrl`. This
 * finds those docs, flips each referenced object public, and rewrites
 * `images` to the resolved URL. Idempotent (skips docs with no bare paths
 * left), non-destructive to anything else on the doc. Dry-run by default.
 *
 *   # dry run (default) — prints the plan, writes nothing
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/backfill_ios_listing_image_urls.js
 *
 *   # apply
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/backfill_ios_listing_image_urls.js --apply
 */

"use strict";

const admin = require("firebase-admin");
const { resolvePhotoUrl } = require("../listing_shape");

const APPLY = process.argv.slice(2).includes("--apply");

admin.initializeApp({
  projectId: process.env.GCLOUD_PROJECT || "wonni-app",
  storageBucket: process.env.STORAGE_BUCKET || "wonni-app.firebasestorage.app",
});
const db = admin.firestore();
const bucket = admin.storage().bucket();

function isBarePath(entry) {
  return typeof entry === "string" && entry && !/^https?:\/\//.test(entry);
}

(async () => {
  console.log(`\nbackfill_ios_listing_image_urls — ${APPLY ? "APPLY" : "DRY RUN"}\n`);

  const snap = await db.collection("products").where("source", "==", "ios-listing").get();

  const plan = [];
  for (const doc of snap.docs) {
    const p = doc.data();
    const images = Array.isArray(p.images) ? p.images : [];
    if (!images.some(isBarePath)) continue;
    const resolvedImages = images.map((entry) => (isBarePath(entry) ? resolvePhotoUrl(entry, bucket.name) : entry));
    plan.push({ id: doc.id, title: p.title, barePaths: images.filter(isBarePath), resolvedImages });
  }

  console.table(plan.map(({ id, title, barePaths }) => ({ id, title: (title || "").slice(0, 40), bareCount: barePaths.length })));
  console.log(`\n${plan.length} products/ docs to fix.`);

  if (!APPLY) { console.log("\n(dry run — nothing written. Re-run with --apply)\n"); process.exit(0); }
  if (!plan.length) { console.log("\nNothing to do.\n"); process.exit(0); }

  for (const { barePaths } of plan) {
    for (const p of barePaths) {
      await bucket.file(p).makePublic().catch((e) => console.warn(`  makePublic failed for ${p}: ${e.message}`));
    }
  }

  let batch = db.batch();
  let n = 0;
  let written = 0;
  for (const { id, resolvedImages } of plan) {
    batch.update(db.collection("products").doc(id), { images: resolvedImages });
    if (++n === 400) { await batch.commit(); written += n; batch = db.batch(); n = 0; }
  }
  if (n) { await batch.commit(); written += n; }
  console.log(`\n✓ fixed ${written} products/ docs.\n`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
