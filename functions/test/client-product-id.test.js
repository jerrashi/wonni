"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { FakeFirestore } = require("./helpers/fake-firestore");
const { newProductRef, madeOnFields } = require("../client_product_id");

const UUID = "1030914D-8CEE-4EB7-9F22-9B91CE423505";

test("an iOS UUID becomes the doc id and marks the import as made on the phone", async () => {
  const db = new FakeFirestore();
  const { ref, madeOn } = await newProductRef(db, UUID);
  assert.equal(ref.id, UUID);
  assert.equal(madeOn, "phone");
  assert.deepEqual(madeOnFields(madeOn), { madeOn: "phone" });
});

test("no id or a non-UUID id gets an auto-id (web / extension imports, unchanged)", async () => {
  const db = new FakeFirestore();
  for (const id of [undefined, null, "", "WphLZ61Q9IKvWwjTm06z", "../../users/x", 42]) {
    const { ref, madeOn } = await newProductRef(db, id);
    assert.notEqual(ref.id, id);
    assert.equal(madeOn, null);
    assert.deepEqual(madeOnFields(madeOn), {});
  }
});

test("regression: a UUID already in use is never overwritten", async () => {
  const db = new FakeFirestore();
  await db.collection("products").doc(UUID).set({ userId: "someone-else", title: "theirs" });
  const { ref, madeOn } = await newProductRef(db, UUID);
  assert.notEqual(ref.id, UUID);
  assert.equal(madeOn, null);
});
