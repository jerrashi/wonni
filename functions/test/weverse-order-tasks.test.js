/**
 * weverse-order-tasks.test.js — unit coverage for the Weverse re-order task
 * backbone: creation on a Weverse-sourced sale (and the negative case),
 * `recordWeverseOrderPlaced` updating both the task and the linked sale doc,
 * and the ownership check. Runs on `node --test`, no emulator.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal: salesInternal } = require("../sales");
const { _internal: taskInternal } = require("../weverse_order_tasks");

const { recordSaleCore } = salesInternal;
const { createWeverseOrderTaskIfNeeded, recordWeverseOrderPlacedCore, listWeverseOrderTasksCore } = taskInternal;

const UID = "user_1";
const OTHER_UID = "user_2";

function weverseProduct(overrides = {}) {
  return {
    userId: UID,
    title: "RM Photocard Set",
    images: ["https://cdn.example/rm.jpg"],
    quantity: 3,
    saleStatus: "active",
    crossPostStatus: {},
    source: "weverse",
    sourceUrl: "https://shop.weverse.io/en/artists/1/sales/999",
    weverseSaleId: "999",
    ...overrides,
  };
}

function nonWeverseProduct(overrides = {}) {
  return {
    userId: UID,
    title: "Plain Tee",
    images: ["https://cdn.example/tee.jpg"],
    quantity: 3,
    saleStatus: "active",
    crossPostStatus: {},
    source: "aliexpress",
    ...overrides,
  };
}

// ── createWeverseOrderTaskIfNeeded (direct unit) ───────────────────────────

test("createWeverseOrderTaskIfNeeded: no-op when product isn't Weverse-sourced", async () => {
  const db = new FakeFirestore();
  const id = await createWeverseOrderTaskIfNeeded(db, UID, {
    product: nonWeverseProduct(), productId: "p1", saleId: "s1", variantSku: null,
  });
  assert.equal(id, null);
  assert.equal(db.all("weverseOrderTasks").length, 0);
});

test("createWeverseOrderTaskIfNeeded: no-op when product is null", async () => {
  const db = new FakeFirestore();
  const id = await createWeverseOrderTaskIfNeeded(db, UID, {
    product: null, productId: "p1", saleId: "s1", variantSku: null,
  });
  assert.equal(id, null);
});

test("createWeverseOrderTaskIfNeeded: creates a pending task snapshotting the Weverse fields", async () => {
  const db = new FakeFirestore();
  const product = weverseProduct();
  const id = await createWeverseOrderTaskIfNeeded(db, UID, {
    product, productId: "p1", saleId: "s1", variantSku: "SKU-M",
  });
  assert.ok(id);
  const task = db.peek("weverseOrderTasks", id);
  assert.equal(task.userId, UID);
  assert.equal(task.productId, "p1");
  assert.equal(task.saleId, "s1");
  assert.equal(task.variantId, "SKU-M");
  assert.equal(task.weverseSaleId, "999");
  assert.equal(task.weverseUrl, "https://shop.weverse.io/en/artists/1/sales/999");
  assert.equal(task.listingTitle, "RM Photocard Set");
  assert.equal(task.thumbnailUrl, "https://cdn.example/rm.jpg");
  assert.equal(task.status, "pending");
});

// ── recordSaleCore integration: task creation wired into the sale-write path ─

test("recordSaleCore: a sale on a Weverse-sourced product creates a weverseOrderTasks doc", async () => {
  const product = weverseProduct();
  const db = new FakeFirestore({ products: { p1: product } });
  const { saleId } = await recordSaleCore(db, UID, {
    platform: "ebay", productId: "p1", soldPrice: 40, quantity: 1, cascade: true,
  }, product);

  const tasks = db.all("weverseOrderTasks");
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].saleId, saleId);
  assert.equal(tasks[0].productId, "p1");
  assert.equal(tasks[0].userId, UID);
  assert.equal(tasks[0].status, "pending");
});

test("regression: NO weverseOrderTasks doc for a non-Weverse-sourced product", async () => {
  const product = nonWeverseProduct();
  const db = new FakeFirestore({ products: { p1: product } });
  await recordSaleCore(db, UID, {
    platform: "ebay", productId: "p1", soldPrice: 40, quantity: 1, cascade: true,
  }, product);

  assert.equal(db.all("weverseOrderTasks").length, 0);
});

test("recordSaleCore: a re-record of the same sale does NOT create a second task", async () => {
  const product = weverseProduct();
  const db = new FakeFirestore({ products: { p1: product } });
  await recordSaleCore(db, UID, {
    platform: "ebay", productId: "p1", soldPrice: 40, platformOrderId: "ORD1", cascade: true,
  }, product);
  await recordSaleCore(db, UID, {
    platform: "ebay", productId: "p1", soldPrice: 40, platformOrderId: "ORD1", cascade: true,
  }, db.peek("products", "p1"));

  assert.equal(db.all("weverseOrderTasks").length, 1);
});

test("recordSaleCore: a manual sale with no linked product never creates a task", async () => {
  const db = new FakeFirestore();
  await recordSaleCore(db, UID, {
    platform: "manual", soldPrice: 40, quantity: 1, cascade: true,
  }, null);
  assert.equal(db.all("weverseOrderTasks").length, 0);
});

// ── recordWeverseOrderPlacedCore ────────────────────────────────────────────

test("recordWeverseOrderPlacedCore: marks the task ordered and mirrors costPaid onto the sale", async () => {
  const db = new FakeFirestore({
    weverseOrderTasks: {
      t1: {
        userId: UID, productId: "p1", saleId: "s1", status: "pending",
        weverseSaleId: "999", weverseUrl: "https://shop.weverse.io/x",
      },
    },
    sales: {
      s1: { userId: UID, productId: "p1", platform: "ebay", priceSoldFor: 40, status: "pending" },
    },
  });

  const res = await recordWeverseOrderPlacedCore(db, UID, {
    taskId: "t1", orderNumber: "WV-12345", costPaid: 18.5,
  });

  assert.deepEqual(res, { success: true });
  const task = db.peek("weverseOrderTasks", "t1");
  assert.equal(task.status, "ordered");
  assert.equal(task.orderNumber, "WV-12345");
  assert.equal(task.costPaid, 18.5);
  assert.ok(task.orderedAt);

  const sale = db.peek("sales", "s1");
  assert.equal(sale.actualCostPaid, 18.5);
});

test("recordWeverseOrderPlacedCore: throws not-found for a missing task", async () => {
  const db = new FakeFirestore();
  await assert.rejects(
    () => recordWeverseOrderPlacedCore(db, UID, { taskId: "nope", orderNumber: "X", costPaid: 1 }),
    /not-found|Weverse order task not found/i,
  );
});

test("regression: ownership check — a user cannot mark someone else's task ordered", async () => {
  const db = new FakeFirestore({
    weverseOrderTasks: {
      t1: { userId: OTHER_UID, productId: "p1", saleId: "s1", status: "pending" },
    },
  });

  await assert.rejects(
    () => recordWeverseOrderPlacedCore(db, UID, { taskId: "t1", orderNumber: "WV-1", costPaid: 10 }),
    (err) => {
      assert.match(err.message, /Not your task/);
      return true;
    },
  );
  // Unauthorized attempt must not have mutated the other user's task.
  const task = db.peek("weverseOrderTasks", "t1");
  assert.equal(task.status, "pending");
});

test("recordWeverseOrderPlacedCore: still marks the task ordered even if the linked sale is missing", async () => {
  const db = new FakeFirestore({
    weverseOrderTasks: {
      t1: { userId: UID, productId: "p1", saleId: "does-not-exist", status: "pending" },
    },
  });
  const res = await recordWeverseOrderPlacedCore(db, UID, { taskId: "t1", orderNumber: "WV-2", costPaid: 5 });
  assert.deepEqual(res, { success: true });
  assert.equal(db.peek("weverseOrderTasks", "t1").status, "ordered");
});

// ── listWeverseOrderTasksCore ────────────────────────────────────────────────

test("listWeverseOrderTasksCore: returns only this user's pending tasks", async () => {
  const db = new FakeFirestore({
    weverseOrderTasks: {
      t1: { userId: UID, productId: "p1", saleId: "s1", status: "pending", createdAt: new Date(2026, 0, 1) },
      t2: { userId: UID, productId: "p2", saleId: "s2", status: "ordered", createdAt: new Date(2026, 0, 2) },
      t3: { userId: OTHER_UID, productId: "p3", saleId: "s3", status: "pending", createdAt: new Date(2026, 0, 3) },
    },
  });

  const { tasks, nextCursor } = await listWeverseOrderTasksCore(db, UID, {});
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].id, "t1");
  assert.equal(nextCursor, null);
});

test("listWeverseOrderTasksCore: newest first, respects limit + cursor", async () => {
  const db = new FakeFirestore({
    weverseOrderTasks: {
      t1: { userId: UID, productId: "p1", saleId: "s1", status: "pending", createdAt: new Date(2026, 0, 1) },
      t2: { userId: UID, productId: "p2", saleId: "s2", status: "pending", createdAt: new Date(2026, 0, 3) },
      t3: { userId: UID, productId: "p3", saleId: "s3", status: "pending", createdAt: new Date(2026, 0, 2) },
    },
  });

  const page1 = await listWeverseOrderTasksCore(db, UID, { limit: 2 });
  assert.deepEqual(page1.tasks.map((t) => t.id), ["t2", "t3"]);
  assert.equal(page1.nextCursor, "t3");

  const page2 = await listWeverseOrderTasksCore(db, UID, { limit: 2, cursor: page1.nextCursor });
  assert.deepEqual(page2.tasks.map((t) => t.id), ["t1"]);
  assert.equal(page2.nextCursor, null);
});
