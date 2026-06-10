/**
 * Tests for the ebayWebhook HTTP handler (challenge verification + POST routing).
 */

const crypto = require("crypto");

// ── Secrets used across tests ────────────────────────────────────────────────

const TEST_SECRETS = {
  EBAY_VERIFICATION_TOKEN: "test-verify-token",
  EBAY_CLIENT_ID: "test-client-id",
  EBAY_CERT_ID: "test-cert-id",
  ETSY_CLIENT_ID: "test-etsy-id",
};

// ── Module mocks (hoisted by Jest before any require) ────────────────────────

jest.mock("firebase-functions/params", () => ({
  defineSecret: (name) => ({ value: () => TEST_SECRETS[name] || "" }),
}));

jest.mock("firebase-functions/v2/https", () => ({
  onRequest: (_opts, handler) => handler,
  onCall:    (_opts, handler) => handler,
  HttpsError: class extends Error {
    constructor(code, msg) { super(msg); this.code = code; }
  },
}));

const mockCollectionGroup = jest.fn();
jest.mock("firebase-admin", () => ({
  apps: [],
  initializeApp: jest.fn(),
  firestore: Object.assign(
    jest.fn(() => ({ collectionGroup: mockCollectionGroup })),
    {
      FieldValue: { serverTimestamp: jest.fn(() => "SERVER_TS") },
      Timestamp: {
        fromMillis: jest.fn((ms) => ({ toDate: () => new Date(ms) })),
        fromDate:   jest.fn((d)  => ({ toDate: () => d })),
        now:        jest.fn(() => ({ toDate: () => new Date() })),
      },
    }
  ),
}));

const mockProcessOrder = jest.fn().mockResolvedValue({ isNew: true, count: 1 });
const mockGetToken     = jest.fn().mockResolvedValue({ accessToken: "tok", isSandbox: false });
const mockMakeRequest  = jest.fn();

jest.mock("../sale_poller", () => ({
  processSingleEbayOrder: mockProcessOrder,
  getEbayAccessToken:     mockGetToken,
  makeRequest:            mockMakeRequest,
}));

// ── Module under test ────────────────────────────────────────────────────────

const { ebayWebhook } = require("../ebay_webhook");

// ── Request / response helpers ────────────────────────────────────────────────

function fakeReq({ method = "GET", query = {}, body = {}, path = "/ebayWebhook", hostname = "run.app", headers = {} } = {}) {
  return {
    method, query, body, path, hostname,
    protocol: "http", // Cloud Run sees http internally; x-forwarded-proto carries the real scheme
    get: (k) => headers[k.toLowerCase()] ?? null,
  };
}

function fakeRes() {
  const r = {};
  r.status    = (code) => { r._status = code; return r; };
  r.send      = (body) => { r._body = body;   return r; };
  r.json      = (obj)  => { r._json = obj;    return r; };
  r.setHeader = jest.fn();
  return r;
}

// ── Challenge verification (GET) ─────────────────────────────────────────────

describe("GET — challenge verification", () => {
  it("returns 400 when challenge_code is absent", async () => {
    const res = fakeRes();
    await ebayWebhook(fakeReq({ method: "GET", query: {} }), res);
    expect(res._status).toBe(400);
  });

  it("returns the correct SHA-256 hash using the hardcoded Cloud Run URL", async () => {
    const code = "abc123challenge";
    // The Cloud Run URL is hardcoded in ebay_webhook.js to avoid proxy hostname rewriting.
    const CLOUD_RUN_URL = "https://ebaywebhook-dynv7fggca-uc.a.run.app";
    const res = fakeRes();

    await ebayWebhook(fakeReq({ method: "GET", query: { challenge_code: code } }), res);

    const expected = crypto.createHash("sha256")
      .update(code)
      .update(TEST_SECRETS.EBAY_VERIFICATION_TOKEN)
      .update(CLOUD_RUN_URL)
      .digest("hex");

    expect(res._status).toBe(200);
    expect(res._json).toEqual({ challengeResponse: expected });
  });

  it("returns the same hash regardless of request headers (URL is hardcoded)", async () => {
    const code = "headertest";
    const CLOUD_RUN_URL = "https://ebaywebhook-dynv7fggca-uc.a.run.app";

    const res1 = fakeRes();
    await ebayWebhook(fakeReq({
      method: "GET", query: { challenge_code: code },
      headers: { "x-forwarded-host": "some-proxy.example.com", "x-forwarded-proto": "http" },
    }), res1);

    const res2 = fakeRes();
    await ebayWebhook(fakeReq({ method: "GET", query: { challenge_code: code } }), res2);

    // Both should return the same hash (derived from the hardcoded URL, not request headers)
    expect(res1._json.challengeResponse).toBe(res2._json.challengeResponse);
    const expected = crypto.createHash("sha256")
      .update(code).update(TEST_SECRETS.EBAY_VERIFICATION_TOKEN).update(CLOUD_RUN_URL).digest("hex");
    expect(res1._json.challengeResponse).toBe(expected);
  });
});

// ── POST routing ──────────────────────────────────────────────────────────────

describe("POST — routing and error handling", () => {
  it("returns 405 for unsupported HTTP methods", async () => {
    const res = fakeRes();
    await ebayWebhook(fakeReq({ method: "PATCH" }), res);
    expect(res._status).toBe(405);
  });

  it("returns 200 for unrecognised topics (no crash)", async () => {
    const res = fakeRes();
    await ebayWebhook(fakeReq({
      method: "POST",
      body: { metadata: { topic: "SOME_FUTURE_TOPIC" }, notification: {} },
    }), res);
    expect(res._status).toBe(200);
  });

  it("returns 200 even when internal processing throws (eBay retry protection)", async () => {
    // Firestore collectionGroup throws — should not propagate as a non-200 response
    mockCollectionGroup.mockImplementation(() => ({
      where: function() { return this; },
      limit: function() { return this; },
      get:   () => Promise.reject(new Error("db unavailable")),
    }));

    const res = fakeRes();
    await ebayWebhook(fakeReq({
      method: "POST",
      body: {
        metadata: { topic: "MARKETPLACE_ORDER_COMPLETED" },
        notification: { data: { orderId: "O-999", username: "seller1" } },
      },
    }), res);

    expect(res._status).toBe(200);
  });

  it("returns 200 for account deletion notifications", async () => {
    mockCollectionGroup.mockReturnValue({
      where: function() { return this; },
      get:   () => Promise.resolve({ empty: true }),
    });

    const res = fakeRes();
    await ebayWebhook(fakeReq({
      method: "POST",
      body: {
        metadata: { topic: "MARKETPLACE_ACCOUNT_DELETION" },
        notification: { data: { userId: "ebayuser123" } },
      },
    }), res);

    expect(res._status).toBe(200);
  });
});
