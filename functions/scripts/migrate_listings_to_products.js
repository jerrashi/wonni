#!/usr/bin/env node
/**
 * migrate_listings_to_products.js — BACKEND.md step 7.
 *
 * One-shot: for every `listings/{id}` (the retired iOS per-user model) with no
 * matching `products/{id}`, create `products/{id}` via
 * `listing_shape.listingDocToProduct`. The `listings/{id}` doc is LEFT IN PLACE
 * — it doubles as the Wonni marketplace feed entry and keeps `Sale.listingId`
 * / eBay SKU `wonni_${id}` pointing somewhere real until iOS is repointed
 * (step 8). Idempotent, non-destructive, batched.
 *
 *   # dry run (default) — prints the plan, writes nothing
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/migrate_listings_to_products.js
 *
 *   # apply
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/migrate_listings_to_products.js --apply
 *
 *   optional:  --user <uid>   limit to one user
 */

"use strict";

const admin = require("firebase-admin");
const { listingDocToProduct } = require("../listing_shape");

const args = process.argv.slice(2);
const APPLY = args.includes("--apply");
const userFilter = args.includes("--user") ? args[args.indexOf("--user") + 1] : null;

admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const now = admin.firestore.FieldValue.serverTimestamp();

function toTs(v) {
  if (!v) return null;
  if (v._seconds != null) return new admin.firestore.Timestamp(v._seconds, v._nanoseconds || 0);
  if (v.toMillis) return v;
  return null;
}

(async () => {
  console.log(`\nmigrate_listings_to_products — ${APPLY ? "APPLY" : "DRY RUN"}${userFilter ? ` (user ${userFilter})` : ""}\n`);

  const [listingsSnap, productsSnap] = await Promise.all([
    db.collection("listings").get(),
    db.collection("products").select().get(), // ids only
  ]);
  const productIds = new Set(productsSnap.docs.map((d) => d.id));

  const plan = [];
  for (const doc of listingsSnap.docs) {
    const l = doc.data();
    if (userFilter && l.userId !== userFilter) continue;
    if (productIds.has(doc.id)) { plan.push({ id: doc.id, action: "skip (products/ doc exists)", title: l.customTitle }); continue; }

    const product = listingDocToProduct(l, doc.id);
    // Preserve the original timestamps; stamp fresh ones for the migration row.
    product.importedAt = toTs(l.createdAt) || now;
    product.updatedAt = now;
    if (toTs(l.publishedAt)) product.publishedAt = toTs(l.publishedAt);
    if (toTs(l.soldAt)) product.soldAt = toTs(l.soldAt);
    product.migratedAt = now;

    plan.push({ id: doc.id, action: "create products/ doc", title: product.title, doc: product });
  }

  const creates = plan.filter((p) => p.doc);
  console.table(plan.map(({ id, action, title }) => ({ id, action, title: (title || "").slice(0, 50) })));
  console.log(`\n${creates.length} to create, ${plan.length - creates.length} skipped.`);

  if (creates.length && plan.find((p) => p.doc)) {
    console.log("\n── sample product doc ──");
    console.log(JSON.stringify(creates[0].doc, null, 1).slice(0, 1500));
  }

  if (!APPLY) { console.log("\n(dry run — nothing written. Re-run with --apply)\n"); process.exit(0); }
  if (!creates.length) { console.log("\nNothing to do.\n"); process.exit(0); }

  let batch = db.batch();
  let n = 0;
  let written = 0;
  for (const { id, doc } of creates) {
    batch.set(db.collection("products").doc(id), doc, { merge: true });
    if (++n === 400) { await batch.commit(); written += n; batch = db.batch(); n = 0; }
  }
  if (n) { await batch.commit(); written += n; }
  console.log(`\n✓ wrote ${written} products/ docs.\n`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
