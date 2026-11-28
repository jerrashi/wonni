#!/usr/bin/env node
/**
 * remove_ai_tags.js — remove the AI's tags (2026-11-28, user: "please remove all the
 * ai generated tags"). The AI wrote up to 8 lowercase search keywords per product
 * into `tags`; 917 tags across 348 products buried the seller's own. New AI tags are
 * only suggestions (`suggestedTags`, 1-3, saved on +).
 *
 * Rule: the AI always lowercased, so an all-lowercase tag is the AI's and is removed;
 * a tag with a capital letter was typed by the seller and stays. Same rule as iOS
 * `Item.tagsWithoutLegacyAI`, which cleans local drafts. Covers products/{id}.tags,
 * listings/{id}.tags (the app's copy) and sales/{id}.productTags (Sales tag filter).
 *
 * Writes a backup of every removed tag (doc path → removed tags) to --backup FILE so
 * any of them can be put back.
 *
 *   node scripts/remove_ai_tags.js --backup /path/removed.json            # dry run
 *   node scripts/remove_ai_tags.js --backup /path/removed.json --apply
 */

"use strict";

const fs = require("fs");
const admin = require("firebase-admin");
admin.initializeApp({ projectId: process.env.GOOGLE_CLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();
const apply = process.argv.includes("--apply");
const backupPath = process.argv[process.argv.indexOf("--backup") + 1];
if (!process.argv.includes("--backup") || !backupPath) {
  console.error("--backup FILE is required");
  process.exit(1);
}

const isAITag = (t) => typeof t === "string" && t === t.toLowerCase();

(async () => {
  const backup = {};
  const kept = new Map();
  let docs = 0, removed = 0;
  for (const [collection, field] of [["products", "tags"], ["listings", "tags"], ["sales", "productTags"]]) {
    const snap = await db.collection(collection).get();
    let changed = 0;
    for (const doc of snap.docs) {
      const tags = doc.data()[field];
      if (!Array.isArray(tags) || !tags.some(isAITag)) continue;
      const keep = tags.filter((t) => !isAITag(t));
      backup[`${collection}/${doc.id}`] = { field, removed: tags.filter(isAITag) };
      keep.forEach((t) => kept.set(t, (kept.get(t) || 0) + 1));
      removed += tags.length - keep.length;
      changed++;
      if (apply) await doc.ref.update({ [field]: keep });
    }
    docs += changed;
    console.log(`${collection}: ${changed} ${apply ? "cleaned" : "to clean"} of ${snap.size}`);
  }
  fs.writeFileSync(backupPath, JSON.stringify(backup, null, 1));
  console.log(`\n${removed} AI tags ${apply ? "removed" : "to remove"} on ${docs} docs. Backup: ${backupPath}`);
  console.log(`Tags kept on those docs: ${[...kept].map(([t, n]) => `${t} (${n})`).join(", ") || "none"}`);
})().catch((e) => { console.error(e); process.exit(1); });
