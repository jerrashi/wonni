import { test } from "node:test";
import assert from "node:assert/strict";
import { orderProducts, moveId } from "./productOrder.js";

const newest = [{ id: "e" }, { id: "d" }, { id: "c" }, { id: "b" }, { id: "a" }];
const ids = (list) => list.map((p) => p.id).join("");

test("newest mode keeps the date order", () => {
  assert.equal(ids(orderProducts(newest, "newest", ["a", "b"])), "edcba");
});

test("custom mode follows the saved list", () => {
  assert.equal(ids(orderProducts(newest, "custom", ["a", "c", "b", "e", "d"])), "acbed");
});

test("products added since the last drag go on top, newest first", () => {
  assert.equal(ids(orderProducts(newest, "custom", ["a", "c", "b"])), "edacb");
});

test("ids of deleted products are ignored", () => {
  assert.equal(ids(orderProducts(newest, "custom", ["zz", "a", "e", "d", "c", "b"])), "aedcb");
});

test("custom mode with no saved list falls back to newest", () => {
  assert.equal(ids(orderProducts(newest, "custom", [])), "edcba");
});

test("moveId moves down and up", () => {
  assert.deepEqual(moveId(["a", "b", "c", "d"], "a", "c"), ["b", "c", "a", "d"]);
  assert.deepEqual(moveId(["a", "b", "c", "d"], "d", "b"), ["a", "d", "b", "c"]);
  assert.deepEqual(moveId(["a", "b"], "a", "zz"), ["a", "b"]);
});
