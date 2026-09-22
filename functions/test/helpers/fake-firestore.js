/**
 * fake-firestore.js — an in-memory Firestore double, just enough of the API
 * for the sales / cascade unit tests. No emulator, no Java, no network.
 *
 * Supported surface (everything sales.js + mercari_sales.js actually call):
 *   db.collection(name).doc(id?)            → FakeDoc  (auto-id when id omitted)
 *   ref.get()                               → { exists, id, ref, data() }
 *   ref.set(patch, { merge })               → deep? no — top-level merge only
 *   ref.update(patch)                       → top-level merge, throws if absent
 *   db.runTransaction(fn)                    → fn({ get, update, set })  (no retry)
 *   db.collection(name).where(f,"==",v).get() → { docs: [{ id, data() }] }
 *
 * FieldValue sentinels are resolved on write: serverTimestamp() → a JS Date,
 * delete() → the key is removed. That matches the only two the code uses and
 * keeps the stored docs plain-inspectable in assertions.
 *
 * Firestore's real `update`/merge-`set` do FIELD-PATH merges; this fake does
 * TOP-LEVEL key merges only. That's deliberate — the codebase is banned from
 * dotted `variants.0.x` paths (they corrupt the array), so every write here is
 * a whole-value replace of a top-level key, which top-level merge models exactly.
 */

"use strict";

function sentinelKind(v) {
  const n = v && typeof v === "object" ? v.constructor?.name || "" : "";
  if (/ServerTimestamp/.test(n)) return "serverTimestamp";
  if (/Delete/.test(n)) return "delete";
  return null;
}

function applyPatch(target, patch) {
  for (const [k, v] of Object.entries(patch)) {
    const kind = sentinelKind(v);
    if (kind === "delete") delete target[k];
    else if (kind === "serverTimestamp") target[k] = new Date();
    else target[k] = v;
  }
}

/** Structured deep clone so a returned `data()` can't be mutated back into the store. */
function snapshot(o) {
  return o === undefined ? undefined : structuredClone(o);
}

class FakeDoc {
  // NOTE: the parent is stored as `_parentCollection`, NOT `this.collection`
  // — a same-named `collection` INSTANCE property would shadow the
  // `collection()` PROTOTYPE method below (own properties win over prototype
  // methods on `this.collection(...)` lookups), silently breaking every
  // subcollection call.
  constructor(parentCollection, id) {
    this._parentCollection = parentCollection;
    this.id = id;
  }
  get ref() {
    return this;
  }
  /** Subcollection under this doc, e.g. `users/{uid}/crossPostRules`. Keyed
   *  by full path so two different parent docs' same-named subcollections
   *  (`users/a/crossPostRules` vs `users/b/crossPostRules`) don't share a
   *  store. */
  collection(name) {
    return new FakeCollection(`${this._parentCollection.path}/${this.id}/${name}`, this._parentCollection.db);
  }
  async get() {
    const stored = this._parentCollection.store.get(this.id);
    return {
      exists: stored !== undefined,
      id: this.id,
      ref: this,
      data: () => snapshot(stored),
    };
  }
  async set(patch, opts = {}) {
    const cur = this._parentCollection.store.get(this.id);
    if (opts.merge && cur) {
      applyPatch(cur, patch);
    } else {
      const fresh = {};
      applyPatch(fresh, patch);
      this._parentCollection.store.set(this.id, fresh);
    }
  }
  async update(patch) {
    const cur = this._parentCollection.store.get(this.id);
    if (!cur) throw new Error(`update() on missing doc ${this._parentCollection.name}/${this.id}`);
    applyPatch(cur, patch);
  }
}

class FakeQuery {
  constructor(collection, predicates, limitN = null) {
    this.collection = collection;
    this.predicates = predicates;
    this.limitN = limitN;
  }
  where(field, op, value) {
    if (op !== "==") throw new Error(`fake-firestore: only "==" where() is supported (got "${op}")`);
    return new FakeQuery(this.collection, [...this.predicates, { field, value }], this.limitN);
  }
  limit(n) {
    return new FakeQuery(this.collection, this.predicates, n);
  }
  async get() {
    const docs = [];
    for (const [id, data] of this.collection.store.entries()) {
      if (this.predicates.every((p) => data[p.field] === p.value)) {
        docs.push({ id, data: () => snapshot(data) });
        if (this.limitN != null && docs.length >= this.limitN) break;
      }
    }
    return { docs, empty: docs.length === 0, size: docs.length };
  }
}

class FakeCollection {
  /** @param {string} path  Full path, e.g. "products" or "users/u1/crossPostRules". */
  constructor(path, db) {
    this.path = path;
    this.name = path.split("/").pop();
    this.db = db;
    if (!db.collections.has(path)) db.collections.set(path, new Map());
    this.store = db.collections.get(path);
  }
  doc(id) {
    return new FakeDoc(this, id ?? `auto_${this.name}_${++this.db._autoId}`);
  }
  where(field, op, value) {
    return new FakeQuery(this, []).where(field, op, value);
  }
  limit(n) {
    return new FakeQuery(this, []).limit(n);
  }
  async get() {
    return new FakeQuery(this, []).get();
  }
}

class FakeFirestore {
  /** @param {Record<string, Record<string, object>>} seed  collection → id → doc */
  constructor(seed = {}) {
    this.collections = new Map();
    this._autoId = 0;
    for (const [name, docs] of Object.entries(seed)) {
      const m = new Map();
      for (const [id, data] of Object.entries(docs)) m.set(id, structuredClone(data));
      this.collections.set(name, m);
    }
  }
  collection(name) {
    return new FakeCollection(name, this);
  }
  async runTransaction(fn) {
    // No contention in a single-threaded test → no retry loop needed.
    const tx = {
      get: (ref) => ref.get(),
      update: (ref, patch) => void ref.update(patch),
      set: (ref, patch, opts) => void ref.set(patch, opts),
    };
    return fn(tx);
  }

  // ── test-only inspection helpers ────────────────────────────────────────
  peek(collection, id) {
    return snapshot(this.collections.get(collection)?.get(id));
  }
  all(collection) {
    return [...(this.collections.get(collection)?.entries() ?? [])].map(([id, data]) => ({
      id,
      ...snapshot(data),
    }));
  }
}

module.exports = { FakeFirestore };
