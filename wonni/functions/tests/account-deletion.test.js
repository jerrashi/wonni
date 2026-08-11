/**
 * Tests for account_deletion.js (#62): requestAccountDeletion,
 * cancelAccountDeletion, and the purge/defer branches of
 * purgeDeletedAccounts.
 */

jest.mock("firebase-functions/v2/https", () => ({
  onCall: (handler) => handler,
  HttpsError: class extends Error {
    constructor(code, msg) { super(msg); this.code = code; }
  },
}));

jest.mock("firebase-functions/v2/scheduler", () => ({
  onSchedule: (_schedule, handler) => handler,
}));

// ── Firestore mock ──────────────────────────────────────────────────────────
// Minimal in-memory-ish mock: enough to observe what the functions write,
// without a full emulator. Mirrors the mocking style already used in
// sale-poller.test.js.

function makeQuerySnap(docs) {
  return { docs, empty: docs.length === 0, size: docs.length };
}

function chainableQuery(docs) {
  const q = {
    where: () => q,
    get: jest.fn().mockResolvedValue(makeQuerySnap(docs)),
  };
  return q;
}

let batchCommits;
let deletedFilesPrefix;
let deletedAuthUid;
let deletionRequestWrites;
let userWrites;

function makeBatch() {
  const ops = [];
  return {
    set: (ref, data) => ops.push({ type: "set", ref, data }),
    delete: (ref) => ops.push({ type: "delete", ref }),
    commit: async () => {
      batchCommits.push(ops.slice());
    },
  };
}

function makeDb({ listings = [], marketplaceOrders = [] } = {}) {
  return {
    collection: (name) => {
      if (name === "listings") {
        return {
          where: (field, _op, value) => {
            if (field === "userId") return chainableQuery(listings.filter((l) => l.data().userId === value));
            return chainableQuery(listings);
          },
        };
      }
      if (name === "marketplaceOrders") {
        return { where: () => chainableQuery(marketplaceOrders) };
      }
      if (name === "sales") {
        return { where: () => chainableQuery([]) };
      }
      if (name === "deletionRequests") {
        return {
          doc: (uid) => ({
            id: uid,
            delete: async () => { deletionRequestWrites.push({ uid, op: "delete" }); },
          }),
          where: () => chainableQuery([]),
        };
      }
      if (name === "users") {
        return { doc: (uid) => ({ id: uid }) };
      }
      return { doc: () => ({}), where: () => chainableQuery([]), get: jest.fn().mockResolvedValue(makeQuerySnap([])) };
    },
    doc: (path) => ({
      path,
      delete: async () => { deletionRequestWrites.push({ path, op: "delete" }); },
    }),
    batch: makeBatch,
  };
}

jest.mock("firebase-admin", () => {
  let db;
  return {
    apps: [],
    initializeApp: jest.fn(),
    firestore: Object.assign(jest.fn(() => db), {
      Timestamp: {
        now: jest.fn(() => ({ toMillis: () => 1000, _iso: "now" })),
        fromMillis: jest.fn((ms) => ({ toMillis: () => ms, _ms: ms })),
      },
      __setDb: (newDb) => { db = newDb; },
    }),
    storage: jest.fn(() => ({
      bucket: () => ({
        deleteFiles: jest.fn(async ({ prefix }) => { deletedFilesPrefix = prefix; }),
      }),
    })),
    auth: jest.fn(() => ({
      deleteUser: jest.fn(async (uid) => { deletedAuthUid = uid; }),
    })),
  };
});

const admin = require("firebase-admin");
const { requestAccountDeletion, cancelAccountDeletion, purgeDeletedAccounts } = require("../account_deletion");

beforeEach(() => {
  batchCommits = [];
  deletedFilesPrefix = undefined;
  deletedAuthUid = undefined;
  deletionRequestWrites = [];
  userWrites = [];
});

describe("requestAccountDeletion", () => {
  test("rejects unauthenticated calls", async () => {
    admin.firestore.__setDb(makeDb());
    await expect(requestAccountDeletion({ auth: null })).rejects.toThrow("You must be signed in.");
  });

  test("marks listings sellerDeletionPending and creates a pending deletionRequest", async () => {
    const listingDoc = { data: () => ({ userId: "u1" }), ref: { id: "listing1" } };
    admin.firestore.__setDb(makeDb({ listings: [listingDoc] }));

    const result = await requestAccountDeletion({ auth: { uid: "u1" } });

    expect(result.success).toBe(true);
    // First commit: the listings batch (sellerDeletionPending = true)
    const listingOps = batchCommits[0];
    expect(listingOps).toEqual([
      { type: "set", ref: listingDoc.ref, data: { sellerDeletionPending: true } },
    ]);
    // Second commit: deletionRequests doc + users.deletionPending
    const requestOps = batchCommits[1];
    expect(requestOps.some((op) => op.data && op.data.status === "pending")).toBe(true);
    expect(requestOps.some((op) => op.data && op.data.deletionPending === true)).toBe(true);
  });
});

describe("cancelAccountDeletion", () => {
  test("rejects unauthenticated calls", async () => {
    admin.firestore.__setDb(makeDb());
    await expect(cancelAccountDeletion({ auth: null })).rejects.toThrow("You must be signed in.");
  });
});

describe("purgeDeletedAccounts", () => {
  test("defers purge when the seller has open marketplaceOrders", async () => {
    let deferOps;
    const db = makeDb({
      marketplaceOrders: [{ id: "order1" }],
    });
    // Override deletionRequests.doc to capture the deferral write.
    const originalCollection = db.collection;
    db.collection = (name) => {
      if (name === "deletionRequests") {
        return {
          where: () => chainableQuery([
            { ref: { set: async (data, opts) => { deferOps = { data, opts }; } }, data: () => ({ userId: "seller1" }) },
          ]),
        };
      }
      return originalCollection(name);
    };
    admin.firestore.__setDb(db);

    await purgeDeletedAccounts({});

    expect(deferOps.data.status).toBe("deferred");
    expect(deferOps.data.deferredReason).toContain("open order");
    expect(deletedAuthUid).toBeUndefined();
  });

  test("purges everything when there are no open orders", async () => {
    let deleteCalled = false;
    const listingDoc = { data: () => ({ userId: "seller2" }), ref: { id: "listing2" } };
    const db = makeDb({ listings: [listingDoc], marketplaceOrders: [] });
    const originalCollection = db.collection;
    db.collection = (name) => {
      if (name === "deletionRequests") {
        return {
          where: () => chainableQuery([
            { ref: { delete: async () => { deleteCalled = true; } }, data: () => ({ userId: "seller2" }) },
          ]),
        };
      }
      if (name === "users") {
        return { doc: () => ({}) };
      }
      return originalCollection(name);
    };
    admin.firestore.__setDb(db);

    await purgeDeletedAccounts({});

    expect(deleteCalled).toBe(true);
    expect(deletedFilesPrefix).toBe("users/seller2/");
    expect(deletedAuthUid).toBe("seller2");
    // listings batch should have been a delete, not a set
    const listingBatch = batchCommits.find((ops) => ops.some((op) => op.ref === listingDoc.ref));
    expect(listingBatch[0].type).toBe("delete");
  });
});
