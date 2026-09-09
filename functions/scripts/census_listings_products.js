#!/usr/bin/env node
/**
 * census_listings_products.js — read-only. Cross-references `listings/` and
 * `products/` to size the listings→products migration (BACKEND.md step 7).
 *
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json \
 *     node functions/scripts/census_listings_products.js
 */

"use strict";

const admin = require("firebase-admin");
admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "wonni-app" });
const db = admin.firestore();

const isUuid = (id) => /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(id);

(async () => {
  const [listingsSnap, productsSnap] = await Promise.all([
    db.collection("listings").get(),
    db.collection("products").get(),
  ]);

  const products = new Map(productsSnap.docs.map((d) => [d.id, d.data()]));
  const byUser = {};
  const cat = { total: listingsSnap.size, hasProduct: 0, noProduct: 0, productIsIosStub: 0, uuidKey: 0, autoIdKey: 0, withVariations: 0 };

  for (const doc of listingsSnap.docs) {
    const l = doc.data();
    const u = l.userId || "(none)";
    byUser[u] = byUser[u] || { listings: 0, migrate: 0 };
    byUser[u].listings++;

    if (isUuid(doc.id)) cat.uuidKey++; else cat.autoIdKey++;
    if (Array.isArray(l.variations) && l.variations.length) cat.withVariations++;

    const p = products.get(doc.id);
    if (!p) {
      cat.noProduct++;
      byUser[u].migrate++;
    } else {
      cat.hasProduct++;
      const stub = p.source === "ios" && !p.title && !p.listingPrice;
      if (stub) { cat.productIsIosStub++; byUser[u].migrate++; }
    }
  }

  const productOnly = productsSnap.docs.filter((d) => !listingsSnap.docs.some((l) => l.id === d.id));
  const iosProducts = productsSnap.docs.filter((d) => d.data().source === "ios");

  console.log("── listings ──────────────────────────────");
  console.log(cat);
  console.log("\n── products ──────────────────────────────");
  console.log({ total: productsSnap.size, source_ios: iosProducts.length, not_also_a_listing: productOnly.length });
  console.log("\n── per user (migrate = listings needing a products/ doc) ──");
  console.table(byUser);
  console.log("\n── sample: a listing with NO products/ doc ──");
  const sampleNo = listingsSnap.docs.find((d) => !products.has(d.id));
  if (sampleNo) console.log(sampleNo.id, JSON.stringify(sampleNo.data(), null, 1).slice(0, 1200));

  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
