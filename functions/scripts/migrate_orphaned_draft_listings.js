#!/usr/bin/env node
/**
 * migrate_orphaned_draft_listings.js
 *
 * One-shot cleanup for the "Sell Similar wrote into the dead listings-draft
 * path" bug (fixed in ProfileView.sellSimilar around the same time this
 * script landed). Every `listings/{id}` with `status == "draft"` predates
 * that fix, or is a legacy pre-2026-08-18 draft-continuity-refactor doc —
 * either way, nothing in the app reads `status: "draft"` anymore
 * (`ListingRepository.fetchDrafts`/`draftsPublisher` were dead code and have
 * been deleted), so these docs are permanently unreachable as they sit.
 *
 * For each: create/merge a `products/{id}` catalog-shaped doc via the same
 * `listingDocToProduct` mapper `migrate_listings_to_products.js` (BACKEND.md
 * step 7) already uses, so it surfaces in the existing "Desktop Drafts"
 * screen with zero new UI. Then, UNLIKE that script (which leaves published
 * `listings/{id}` docs in place — they double as the live marketplace feed
 * entry and Sale.listingId target), this one DELETES the original doc once
 * its products/ twin is written: a draft was never a real marketplace entry
 * and nothing else points at it, so leaving it behind only risks a future
 * session reintroducing the same dead-code read path. Defensive re-check:
 * re-reads `status` immediately before each delete and skips if it's no
 * longer "draft" (nothing else should be able to flip these to active once
 * `sellSimilar` stops writing here, but cheap insurance).
 *
 *   # dry run (default) — prints the plan, writes nothing
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/migrate_orphaned_draft_listings.js
 *
 *   # apply
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
 *     node functions/scripts/migrate_orphaned_draft_listings.js --apply
 *
 *   optional:  --user <uid>   limit to one user
 */

"use strict";

const admin = require("firebase-admin");
const { listingDocToProduct } = require("../listing_shape");

const args = process.argv.slice(2);
const APPLY = args.includes("--apply");
const userFilter = args.includes("--user") ? args[args.indexOf("--user") + 1] : null;

admin.initializeApp({
  projectId: process.env.GCLOUD_PROJECT || "wonni-app",
  storageBucket: process.env.STORAGE_BUCKET || "wonni-app.firebasestorage.app",
});
const db = admin.firestore();
const bucket = admin.storage().bucket();
const now = admin.firestore.FieldValue.serverTimestamp();

function toTs(v) {
  if (!v) return null;
  if (v._seconds != null) return new admin.firestore.Timestamp(v._seconds, v._nanoseconds || 0);
  if (v.toMillis) return v;
  return null;
}

(async () => {
  console.log(`\nmigrate_orphaned_draft_listings — ${APPLY ? "APPLY" : "DRY RUN"}${userFilter ? ` (user ${userFilter})` : ""}\n`);

  let query = db.collection("listings").where("status", "==", "draft");
  if (userFilter) query = query.where("userId", "==", userFilter);
  const [draftsSnap, productsSnap] = await Promise.all([
    query.get(),
    db.collection("products").select().get(), // ids only
  ]);
  const productIds = new Set(productsSnap.docs.map((d) => d.id));

  const plan = [];
  for (const doc of draftsSnap.docs) {
    const l = doc.data();
    if (productIds.has(doc.id)) {
      plan.push({ id: doc.id, action: "skip (products/ doc already exists)", title: l.customTitle });
      continue;
    }
    const photoCount = Array.isArray(l.photoPaths) ? l.photoPaths.length : 0;

    const product = listingDocToProduct(l, doc.id, { bucketName: bucket.name });
    product.importedAt = toTs(l.createdAt) || now;
    product.updatedAt = now;
    product.migratedAt = now;

    plan.push({
      id: doc.id,
      action: photoCount ? "migrate + delete listing" : "migrate + delete listing (no photos — draft was created photo-less or photos never uploaded)",
      title: product.title,
      doc: product,
      photoCount,
    });
  }

  const migrates = plan.filter((p) => p.doc);
  console.table(plan.map(({ id, action, title, photoCount }) => ({
    id, action, title: (title || "").slice(0, 40), photos: photoCount ?? "-",
  })));
  console.log(`\n${migrates.length} to migrate, ${plan.length - migrates.length} skipped.`);

  if (!APPLY) { console.log("\n(dry run — nothing written. Re-run with --apply)\n"); process.exit(0); }
  if (!migrates.length) { console.log("\nNothing to do.\n"); process.exit(0); }

  // Write every products/ doc first (batched), THEN delete originals one at a
  // time with a fresh status re-check — never delete before the twin exists.
  let batch = db.batch();
  let n = 0;
  let written = 0;
  for (const { id, doc } of migrates) {
    batch.set(db.collection("products").doc(id), doc, { merge: true });
    if (++n === 400) { await batch.commit(); written += n; batch = db.batch(); n = 0; }
  }
  if (n) { await batch.commit(); written += n; }
  console.log(`✓ wrote ${written} products/ docs.`);

  let deleted = 0;
  let deleteSkipped = 0;
  for (const { id } of migrates) {
    const fresh = await db.collection("listings").doc(id).get();
    if (!fresh.exists || fresh.data().status !== "draft") {
      console.warn(`  skip delete for ${id}: status changed since plan was built (now ${fresh.exists ? fresh.data().status : "deleted"})`);
      deleteSkipped++;
      continue;
    }
    await fresh.ref.delete();
    deleted++;
  }
  console.log(`✓ deleted ${deleted} orphaned draft listings/ docs (${deleteSkipped} skipped on re-check).\n`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
