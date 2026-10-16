#!/usr/bin/env node
/**
 * backfill_mercari_status.js — copy the Mercari state iOS wrote to listings/{id}
 * onto the shared products/{id} doc (2026-10-16).
 *
 * Until this date the app's Mercari poster wrote `crossPostStatus.mercari =
 * "posted"` + `crossPostListingIds.mercari` ONLY to listings/{id}; the web
 * dashboard, `isLiveOnMercari` and the sales cascade read products/{id}, so every
 * iOS Mercari post was invisible there. The app now mirrors on every post
 * (ProductRepository.mirrorMercariPosted); this fills in the history.
 *
 * Rules: only listings with a Mercari id and status "posted"; only products that
 * have NO Mercari id yet (never overwrite a product's own record); merge-set so
 * other platforms' keys stay.
 *
 *   node scripts/backfill_mercari_status.js            # dry run
 *   node scripts/backfill_mercari_status.js --apply
 */

"use strict";

const admin = require("firebase-admin");
admin.initializeApp({ projectId: process.env.GOOGLE_CLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const apply = process.argv.includes("--apply");

(async () => {
  const snap = await db.collection("listings").where("crossPostStatus.mercari", "==", "posted").get();
  let written = 0, skipped = 0, noProduct = 0, noId = 0;
  for (const doc of snap.docs) {
    const l = doc.data();
    const mercariId = l.crossPostListingIds?.mercari;
    if (!mercariId) { noId++; continue; }
    const productRef = db.collection("products").doc(doc.id);
    const product = await productRef.get();
    if (!product.exists) { noProduct++; continue; }
    if (product.data().crossPostListingIds?.mercari) { skipped++; continue; }
    console.log(`${apply ? "write" : "would write"} products/${doc.id} ← mercari ${mercariId}  (${(l.customTitle || "").slice(0, 50)})`);
    if (apply) {
      await productRef.set({
        crossPostStatus: { mercari: "active" },
        crossPostListingIds: { mercari: mercariId },
        crossPostUrls: { mercari: `https://www.mercari.com/us/item/${mercariId}/` },
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    written++;
  }
  console.log(`\n${snap.size} posted listings: ${written} ${apply ? "written" : "to write"}, ${skipped} already on the product, ${noProduct} without a product doc, ${noId} without an id.`);
})().catch((e) => { console.error(e); process.exit(1); });
