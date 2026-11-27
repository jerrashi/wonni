#!/usr/bin/env node
/**
 * rename_style_option.js — rename the old Weverse importer's catch-all "Style"
 * dimension to what it actually is (2026-11-27, user): Size (S/M/L/XL…), City
 * (tour stamps), Color (Red/White…). One-value "Style" is left alone (it posts
 * plain). New imports already name a lone size dimension Size (581ca48).
 *
 * Whole-array writes only (never `variants.0.x`). Prints products live on eBay
 * whose eBay name would change, so the eBay group can be migrated (eBay refuses
 * a plain push that renames a live variation, 25013).
 *
 *   node scripts/rename_style_option.js            # dry run
 *   node scripts/rename_style_option.js --apply
 */

"use strict";

const admin = require("firebase-admin");
admin.initializeApp({ projectId: process.env.GOOGLE_CLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const apply = process.argv.includes("--apply");

const SIZE = /^(xxs|xs|s|m|l|xl|xxl|2xl|xxxl|3xl|4xl|free|one size|[a-z]{1,3}-[a-z]{1,3})$/i;
const COLORS = new Set(["red", "white", "black", "gray", "grey", "blue", "green", "pink", "yellow", "purple", "navy", "beige", "brown", "orange", "charcoal", "ivory", "maroon"]);
const CITIES = new Set(["tampa", "el paso", "mexico city", "stanford", "las vegas", "east rutherford", "foxborough", "baltimore", "arlington", "toronto", "chicago", "los angeles", "madrid", "brussels", "london", "munich", "paris"]);

function newName(values) {
  if (values.length < 2) return null;
  const v = values.map((x) => String(x).trim().toLowerCase());
  if (v.every((x) => SIZE.test(x))) return "Size";
  if (v.every((x) => COLORS.has(x))) return "Color";
  if (v.every((x) => CITIES.has(x))) return "City";
  return null;
}

(async () => {
  const snap = await db.collection("products").where("source", "in", ["weverse", "aliexpress"]).get();
  let renamed = 0, unknown = 0;
  for (const doc of snap.docs) {
    const p = doc.data();
    const opts = Array.isArray(p.options) ? p.options : [];
    const style = opts.find((o) => o.name === "Style");
    if (!style || (style.values || []).length < 2) continue;
    const to = newName(style.values);
    if (!to) { unknown++; console.log(`?? no rule  ${doc.id}  ${style.values.join("|")}`); continue; }
    if (opts.some((o) => o.name === to)) { console.log(`skip (already has ${to}) ${doc.id}`); continue; }
    const live = p.crossPostStatus?.ebay === "active";
    // eBay already receives a Style of sizes as "Size" (variation_names.js), so only
    // City/Color change the live eBay name.
    const ebayChanges = live && to !== "Size";
    console.log(`${apply ? "renamed" : "would rename"} Style → ${to}  ${doc.id}  ${(p.title || "").slice(0, 50)}${live ? "  [eBay" + (ebayChanges ? ", needs eBay migration]" : ", eBay unchanged]") : ""}`);
    renamed++;
    if (apply) {
      await doc.ref.update({
        options: opts.map((o) => (o === style ? { ...o, name: to } : o)),
        variants: (p.variants || []).map((v) => {
          if (!v?.optionValues || !("Style" in v.optionValues)) return v;
          const { Style, ...rest } = v.optionValues;
          return { ...v, optionValues: { [to]: Style, ...rest } };
        }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  console.log(`\n${renamed} ${apply ? "renamed" : "to rename"}, ${unknown} with no rule.`);
})().catch((e) => { console.error(e); process.exit(1); });
