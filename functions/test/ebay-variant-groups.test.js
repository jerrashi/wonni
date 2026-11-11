"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { planVariantGroups, groupKeyFor, groupTitle, EBAY_LIMITS } = require("../ebay_variant_groups");

const opts = [{ name: "Series" }, { name: "Issue" }];
const make = (series, issues) => {
  const out = []; let i = 0;
  for (let s = 0; s < series; s++) for (let n = 0; n < issues; n++) {
    out.push({ i, v: { id: `v${i}`, optionValues: { Series: `S${s}`, Issue: `#${n}` } } }); i++;
  }
  return out;
};

test("a small product is one group keyed by the productId (legacy listings unchanged)", () => {
  const g = planVariantGroups(make(2, 3), opts, { productId: "p1" });
  assert.equal(g.length, 1);
  assert.equal(g[0].key, "p1");
  assert.equal(g[0].items.length, 6);
});

test("the comic collection: 30 series x 20 issues (600 variants) respects 250 variations AND 30 values per name", () => {
  const items = make(30, 20);
  const g = planVariantGroups(items, opts, { productId: "p1" });
  assert.ok(g.length >= 3, "600 / 250 needs at least 3 listings");
  assert.equal(g.reduce((n, x) => n + x.items.length, 0), 600, "every variant placed exactly once");
  for (const grp of g) {
    assert.ok(grp.items.length <= EBAY_LIMITS.maxVariations);
    for (const n of ["Series", "Issue"]) {
      assert.ok(new Set(grp.items.map((it) => it.v.optionValues[n])).size <= EBAY_LIMITS.maxValuesPerAspect);
    }
  }
  assert.deepEqual(g.map((x) => x.key), ["p1", "p1g2", "p1g3"].slice(0, g.length).concat(g.slice(3).map((x) => x.key)));
});

test("a series stays together in one listing", () => {
  const g = planVariantGroups(make(30, 20), opts, { productId: "p1" });
  const where = new Map();
  for (const grp of g) for (const it of grp.items) {
    const s = it.v.optionValues.Series;
    where.set(s, (where.get(s) ?? new Set()).add(grp.key));
  }
  assert.ok([...where.values()].every((set) => set.size === 1));
});

test("one dimension with 70 values splits at 30 values per name", () => {
  const items = Array.from({ length: 70 }, (_, i) => ({ i, v: { id: `v${i}`, optionValues: { Vol: `V${i}` } } }));
  const g = planVariantGroups(items, [{ name: "Vol" }], { productId: "p1" });
  assert.deepEqual(g.map((x) => x.items.length), [30, 30, 10]);
});

test("stable: an already-posted variant stays in its group; new variants fill room or open a new group", () => {
  const posted = Array.from({ length: 250 }, (_, i) => ({ i, v: { id: `v${i}`, ebayOfferId: "o", ebayGroupKey: "p1", optionValues: { Vol: `V${i % 30}`, N: String(i) } } }));
  const fresh = { i: 250, v: { id: "new", optionValues: { Vol: "V0", N: "new" } } };
  const g = planVariantGroups([...posted, fresh], [{ name: "Vol" }, { name: "N" }], { productId: "p1", limits: { ...EBAY_LIMITS, maxValuesPerAspect: 1000 } });
  assert.equal(g.length, 2);
  assert.equal(g[0].items.length, 250);
  assert.deepEqual(g[1].items.map((x) => x.v.id), ["new"]);
  assert.equal(g[1].key, "p1g2");
});

test("legacy posted variants (no ebayGroupKey) belong to group 1", () => {
  const items = [{ i: 0, v: { id: "a", ebayOfferId: "o", optionValues: { Size: "S" } } }];
  const g = planVariantGroups(items, [{ name: "Size" }], { productId: "p1" });
  assert.equal(g[0].key, "p1");
});

test("more than 5 variation types is refused with a clear message", () => {
  const o = Array.from({ length: 6 }, (_, i) => ({ name: `D${i}` }));
  assert.throws(() => planVariantGroups([{ i: 0, v: { optionValues: {} } }], o, { productId: "p" }), /at most 5 variation types/);
});

test("keys are alphanumeric and titles stay within 80 chars", () => {
  assert.match(groupKeyFor("abc123", 2), /^[A-Za-z0-9]+$/);
  const t = groupTitle("X".repeat(80), 1, 3);
  assert.ok(t.length <= 80);
  assert.ok(t.endsWith(" - Part 2 of 3"));
  assert.equal(groupTitle("Hello", 0, 1), "Hello");
});
