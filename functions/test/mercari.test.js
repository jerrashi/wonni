/**
 * mercari.test.js — the Mercari-specific pieces of recordMercariSalesBatch:
 * the item-id → product/variant match map, the loose date parser, and the
 * contract envelope. Recording + cascade itself is covered in sales.test.js
 * (shared `recordSaleCore`).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal } = require("../mercari_sales");
const { MercariScrapeItemSchema } = require("../contracts");
const { RequestSchemas } = require("../contracts");

const { buildMercariMatchMap, looseDate } = _internal;

/** Mimic a Firestore query snapshot's `.docs` — [{ id, data() }]. */
function docs(map) {
  return Object.entries(map).map(([id, data]) => ({ id, data: () => data }));
}

// ── buildMercariMatchMap ────────────────────────────────────────────────────

test("buildMercariMatchMap: product-level pointer (current + legacy keys)", () => {
  const map = buildMercariMatchMap(docs({
    p_current: { crossPostListingIds: { mercari: "m111" } },
    p_legacy: { mercariListingId: "m222" },
  }));
  assert.deepEqual(map.get("m111"), { productId: "p_current", variantSku: null });
  assert.deepEqual(map.get("m222"), { productId: "p_legacy", variantSku: null });
});

test("buildMercariMatchMap: per-variant pointers carry the variant sku", () => {
  const map = buildMercariMatchMap(docs({
    p1: {
      variants: [
        { sku: "TEE-S", crossPostListingIds: { mercari: "m_s" } },
        { sku: "TEE-M", mercariListingId: "m_m" },
      ],
    },
  }));
  assert.deepEqual(map.get("m_s"), { productId: "p1", variantSku: "TEE-S" });
  assert.deepEqual(map.get("m_m"), { productId: "p1", variantSku: "TEE-M" });
});

test("buildMercariMatchMap: first writer wins on a duplicate item id", () => {
  const map = buildMercariMatchMap(docs({
    a: { crossPostListingIds: { mercari: "dup" } },
    b: { crossPostListingIds: { mercari: "dup" } },
  }));
  assert.equal(map.get("dup").productId, "a");
});

test("buildMercariMatchMap: an unmatched id returns undefined", () => {
  const map = buildMercariMatchMap(docs({ a: { crossPostListingIds: { mercari: "x" } } }));
  assert.equal(map.get("nope"), undefined);
});

// ── looseDate ───────────────────────────────────────────────────────────────

test("looseDate: parses common scraped formats, null on junk", () => {
  assert.equal(looseDate("2026-01-02"), Date.parse("2026-01-02"));
  assert.equal(looseDate("Jul 8, 2026"), Date.parse("Jul 8, 2026"));
  assert.equal(looseDate("   "), null);
  assert.equal(looseDate("sometime last week"), null);
  assert.equal(looseDate(null), null);
  assert.equal(looseDate(42), null);
});

// ── contract: MercariScrapeItemSchema ───────────────────────────────────────

test("MercariScrapeItemSchema: requires a positive price and an item id", () => {
  assert.equal(MercariScrapeItemSchema.safeParse({ mercariItemId: "m1", priceSoldFor: 12.5 }).success, true);
  assert.equal(MercariScrapeItemSchema.safeParse({ priceSoldFor: 12.5 }).success, false);
  assert.equal(MercariScrapeItemSchema.safeParse({ mercariItemId: "m1", priceSoldFor: 0 }).success, false);
  assert.equal(MercariScrapeItemSchema.safeParse({ mercariItemId: "m1", priceSoldFor: -3 }).success, false);
});

test("MercariScrapeItemSchema: accepts the current extension shape (soldDate alias, extra keys ignored via batch loose parse)", () => {
  const r = MercariScrapeItemSchema.safeParse({
    mercariItemId: "m1", priceSoldFor: 30, soldDate: "7/8/2026", buyerName: "A. Buyer",
  });
  assert.equal(r.success, true);
  assert.equal(r.data.soldDate, "7/8/2026");
});

// ── contract: batch envelope ────────────────────────────────────────────────

test("recordMercariSalesBatch request: accepts items OR rawItems, rejects an empty batch", () => {
  const schema = RequestSchemas.recordMercariSalesBatch;
  assert.equal(schema.safeParse({ items: [{ mercariItemId: "m1" }] }).success, true);
  assert.equal(schema.safeParse({ rawItems: [{ mercariItemId: "m1" }] }).success, true);
  assert.equal(schema.safeParse({ items: [], rawItems: [] }).success, false);
  assert.equal(schema.safeParse({}).success, false);
});
