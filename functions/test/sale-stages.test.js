/**
 * sale-stages.test.js — the kanban/spreadsheet bucket list
 * (docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §1).
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { BUILT_IN_SALE_STAGES, loadSaleStages, validateSaleStages } = require("../sale_stages");

test("loadSaleStages: falls back to built-ins when the user has never customized", async () => {
  const db = new FakeFirestore({ users: { u1: {} } });
  const stages = await loadSaleStages(db, "u1");
  assert.deepEqual(stages, BUILT_IN_SALE_STAGES);
});

test("loadSaleStages: falls back to built-ins when the user doc doesn't even exist", async () => {
  const db = new FakeFirestore();
  const stages = await loadSaleStages(db, "ghost");
  assert.deepEqual(stages, BUILT_IN_SALE_STAGES);
});

test("loadSaleStages: returns the user's customized list once set", async () => {
  const custom = [
    ...BUILT_IN_SALE_STAGES.map((s) => (s.key === "cancelled" ? { ...s, label: "Refunded" } : s)),
    { key: "awaiting_parts", label: "Awaiting Parts", builtIn: false },
  ];
  const db = new FakeFirestore({ users: { u1: { saleStages: custom } } });
  const stages = await loadSaleStages(db, "u1");
  assert.deepEqual(stages, custom);
  assert.equal(stages.find((s) => s.key === "cancelled").label, "Refunded");
});

test("validateSaleStages: accepts the untouched built-in defaults", () => {
  assert.doesNotThrow(() => validateSaleStages(BUILT_IN_SALE_STAGES));
});

test("validateSaleStages: accepts a built-in renamed + a custom bucket added", () => {
  const stages = [
    ...BUILT_IN_SALE_STAGES.map((s) => (s.key === "returned" ? { ...s, label: "Sent Back" } : s)),
    { key: "awaiting_parts", label: "Awaiting Parts" },
  ];
  assert.doesNotThrow(() => validateSaleStages(stages));
});

test("validateSaleStages: rejects removing a built-in key", () => {
  const stages = BUILT_IN_SALE_STAGES.filter((s) => s.key !== "cancelled");
  assert.throws(() => validateSaleStages(stages), /cancelled.*cannot be removed/);
});

test("validateSaleStages: rejects a built-in key present but not flagged builtIn", () => {
  const stages = BUILT_IN_SALE_STAGES.map((s) =>
    s.key === "returned" ? { key: "returned", label: "Returned", builtIn: false } : s);
  assert.throws(() => validateSaleStages(stages), /returned.*must stay marked built-in/);
});

test("validateSaleStages: rejects duplicate keys", () => {
  const stages = [...BUILT_IN_SALE_STAGES, { key: "cancelled", label: "Dup", builtIn: true }];
  assert.throws(() => validateSaleStages(stages), /Duplicate stage key/);
});

test("validateSaleStages: rejects an empty or blank label", () => {
  const stages = BUILT_IN_SALE_STAGES.map((s) => (s.key === "delivered" ? { ...s, label: "  " } : s));
  assert.throws(() => validateSaleStages(stages), /non-empty label/);
});

test("validateSaleStages: rejects an empty array", () => {
  assert.throws(() => validateSaleStages([]), /non-empty array/);
});
