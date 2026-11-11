/**
 * One-shot backfill for the 2026-11-11 default flip: an UNSET
 * `quantityVariesByVariant` used to mean per-variant and now means shared pool.
 * This pins every existing variant product to what it was effectively doing:
 *   - active variants with DIFFERING quantities → quantityVariesByVariant: true
 *   - identical quantities (nothing to lose)    → false, product.quantity seeded
 *     from the existing master number or the common variant quantity
 * Products with the flag already set, or without variants, are untouched.
 *
 * DRY RUN by default. Run:
 *   cd functions && node scripts/backfill_quantity_model.js          # report only
 *   cd functions && node scripts/backfill_quantity_model.js --apply  # write
 * Idempotent (a second run finds nothing unset).
 */

/** Pure decision: returns {value, quantity?} to write, or null to leave alone. */
function chooseBackfillValue(product) {
  if (!product || typeof product.quantityVariesByVariant === "boolean") return null;
  const variants = Array.isArray(product.variants) ? product.variants : [];
  if (!(product.hasVariants === true || variants.length)) return null;
  const active = variants.filter((v) => v && v.active !== false);
  if (!active.length) return null;
  const qs = active.map((v) => Number(v.quantity) || 0);
  if (new Set(qs).size > 1) return { value: true };
  const master = typeof product.quantity === "number" ? product.quantity : qs[0];
  return { value: false, quantity: master };
}

async function main() {
  const apply = process.argv.includes("--apply");
  const admin = require("firebase-admin");
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "wonni-app" });
  const db = admin.firestore();
  const snap = await db.collection("products").get();
  let perVariant = 0, shared = 0, untouched = 0;
  for (const doc of snap.docs) {
    const pick = chooseBackfillValue(doc.data());
    if (!pick) { untouched += 1; continue; }
    if (pick.value) perVariant += 1; else shared += 1;
    console.log(`${apply ? "set" : "would set"} ${doc.id}: ${JSON.stringify(pick)}`);
    if (apply) {
      const update = { quantityVariesByVariant: pick.value };
      if (pick.quantity !== undefined) update.quantity = pick.quantity;
      await doc.ref.update(update);
    }
  }
  console.log(`${apply ? "applied" : "dry run"} — per-variant: ${perVariant}, shared: ${shared}, untouched: ${untouched} of ${snap.size}`);
}

module.exports = { chooseBackfillValue };
if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });
