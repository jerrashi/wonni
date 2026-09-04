/**
 * One-shot migration: consolidate the product cost field to `sourcePrice`.
 *
 * Renames `sourceCost` / `aliexpressPrice` → `sourcePrice` on every product
 * doc (and every variant), then deletes the old fields. Idempotent: safe to
 * run more than once.
 *
 * Run:  cd functions && GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json \
 *         node scripts/backfill_source_price.js
 * or, if `firebase login` ADC is set up:  node scripts/backfill_source_price.js
 */
const admin = require("firebase-admin");

admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const { FieldValue } = admin.firestore;

function pickCost(...vals) {
  for (const v of vals) {
    const n = Number(v);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return null;
}

(async () => {
  const snap = await db.collection("products").get();
  let changed = 0;

  for (const doc of snap.docs) {
    const d = doc.data();
    const update = {};

    const hadOldTop = d.sourceCost !== undefined || d.aliexpressPrice !== undefined;
    if (hadOldTop) {
      const resolved = pickCost(d.sourcePrice, d.sourceCost, d.aliexpressPrice);
      if (resolved != null && !(Number(d.sourcePrice) > 0)) update.sourcePrice = resolved;
      update.sourceCost = FieldValue.delete();
      update.aliexpressPrice = FieldValue.delete();
    }

    if (Array.isArray(d.variants) && d.variants.some((v) => v && v.sourceCost !== undefined)) {
      update.variants = d.variants.map((v) => {
        if (!v || v.sourceCost === undefined) return v;
        const { sourceCost, ...rest } = v;
        const resolved = pickCost(rest.sourcePrice, sourceCost);
        return resolved != null && !(Number(rest.sourcePrice) > 0)
          ? { ...rest, sourcePrice: resolved }
          : rest;
      });
    }

    if (Object.keys(update).length) {
      await doc.ref.update(update);
      changed += 1;
      console.log(`migrated ${doc.id}`);
    }
  }

  console.log(`done — ${changed}/${snap.size} products updated`);
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
