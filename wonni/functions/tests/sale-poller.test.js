/**
 * Tests for processSingleEbayOrder — the shared eBay order processing logic
 * used by both the poll path (syncSales) and the push path (ebayWebhook).
 */

// ── Module mocks ──────────────────────────────────────────────────────────────

jest.mock("firebase-functions/params", () => ({
  defineSecret: (name) => ({ value: () => `test-${name}` }),
}));

jest.mock("firebase-functions/v2/https", () => ({
  onCall: (_opts, handler) => handler,
  HttpsError: class extends Error {
    constructor(code, msg) { super(msg); this.code = code; }
  },
}));

jest.mock("../etsy_auth", () => ({ refreshEtsyToken: jest.fn() }));

const mockCascade = jest.fn().mockResolvedValue(undefined);
jest.mock("../sale_sync", () => ({ decrementAndCascadeInternal: mockCascade }));

// Mock https so makeRequest doesn't make real network calls
jest.mock("https", () => ({ request: jest.fn() }));
const https = require("https");

// ── Firebase admin mock ───────────────────────────────────────────────────────

const mockSaleGet    = jest.fn();
const mockListingGet = jest.fn();
const mockSaleAdd    = jest.fn().mockResolvedValue({ id: "new-sale-id" });
const mockDocUpdate  = jest.fn().mockResolvedValue(undefined);

function chainable(terminal) {
  const c = {
    where: () => c,
    limit: () => c,
    get:   terminal,
  };
  return c;
}

const mockDb = {
  collection: (name) => {
    if (name === "sales")    return Object.assign(chainable(mockSaleGet), { add: mockSaleAdd });
    if (name === "listings") return { doc: () => ({ get: mockListingGet }) };
    return {};
  },
};

jest.mock("firebase-admin", () => ({
  apps: [],
  initializeApp: jest.fn(),
  firestore: Object.assign(
    jest.fn(() => mockDb),
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

// ── Module under test ─────────────────────────────────────────────────────────

const { processSingleEbayOrder } = require("../sale_poller");

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeOrder(overrides = {}) {
  return {
    orderId: "ORDER-001",
    orderPaymentStatus: "PAID",
    creationDate: "2026-06-10T12:00:00.000Z",
    pricingSummary: {
      priceSubtotal: { value: "29.99" },
      deliveryCost:  { value: "5.00" },
      total:         { value: "34.99" },
    },
    lineItems: [{ sku: "wonni_listing123", title: "Vintage Jacket" }],
    buyer: {
      buyerRegistrationAddress: {
        fullName: "Jane Doe",
        contactAddress: {
          addressLine1: "123 Main St",
          city: "Springfield",
          stateOrProvince: "IL",
          postalCode: "62701",
          countryCode: "US",
        },
      },
    },
    fulfillmentStartInstructions: [],
    ...overrides,
  };
}

// Configures https.request to return controlled responses for finance and tracking endpoints.
function setupHttpsMock({ transactions = [], fulfillments = [], statusCode = 200 } = {}) {
  https.request.mockImplementation((opts, callback) => {
    const isFinances = opts.path && opts.path.includes("transaction");
    const body = isFinances
      ? JSON.stringify({ transactions })
      : JSON.stringify({ fulfillments });

    const mockResp = { statusCode };
    mockResp.on = (event, handler) => {
      if (event === "data") handler(body);
      if (event === "end") handler();
      return mockResp;
    };
    callback(mockResp);

    return { on: jest.fn(), write: jest.fn(), end: jest.fn() };
  });
}

// ── Setup / teardown ──────────────────────────────────────────────────────────

beforeEach(() => {
  jest.clearAllMocks();
  mockSaleGet.mockResolvedValue({ empty: true }); // no existing sale
  mockListingGet.mockResolvedValue({ exists: false }); // no listing
  setupHttpsMock(); // no tracking, no finances by default
});

// ── Payment gate ──────────────────────────────────────────────────────────────

describe("payment gate", () => {
  it("skips orders that are not PAID", async () => {
    const result = await processSingleEbayOrder(
      makeOrder({ orderPaymentStatus: "UNPAID" }),
      "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(result).toEqual({ isNew: false });
    expect(mockSaleAdd).not.toHaveBeenCalled();
  });

  it("processes PAID orders", async () => {
    const result = await processSingleEbayOrder(
      makeOrder(), "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(result.isNew).toBe(true);
    expect(mockSaleAdd).toHaveBeenCalledTimes(1);
  });
});

// ── SKU filtering ─────────────────────────────────────────────────────────────

describe("SKU filtering", () => {
  it("skips line items without the wonni_ prefix", async () => {
    const result = await processSingleEbayOrder(
      makeOrder({ lineItems: [{ sku: "external-999", title: "Random item" }] }),
      "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(result).toEqual({ isNew: false, count: 0 });
    expect(mockSaleAdd).not.toHaveBeenCalled();
  });

  it("extracts listingId by stripping the wonni_ prefix", async () => {
    await processSingleEbayOrder(
      makeOrder({ lineItems: [{ sku: "wonni_abc456", title: "My Item" }] }),
      "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(mockSaleAdd).toHaveBeenCalledWith(
      expect.objectContaining({ listingId: "abc456" })
    );
  });
});

// ── New sale fields ───────────────────────────────────────────────────────────

describe("new sale document fields", () => {
  it("records platform, userId, orderId, and prices", async () => {
    await processSingleEbayOrder(
      makeOrder(), "uid-test", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(mockSaleAdd).toHaveBeenCalledWith(
      expect.objectContaining({
        platform:        "ebay",
        userId:          "uid-test",
        platformOrderId: "ORDER-001",
        priceSoldFor:    29.99,
        shippingRevenue: 5.0,
      })
    );
  });

  it("sets status to pending when no tracking is available", async () => {
    await processSingleEbayOrder(
      makeOrder(), "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(mockSaleAdd).toHaveBeenCalledWith(
      expect.objectContaining({ status: "pending", trackingNumber: null })
    );
  });

  it("sets status to shipped and records tracking when fulfillment is present", async () => {
    setupHttpsMock({
      fulfillments: [{
        fulfillmentId: "f1",
        shipmentTrackingNumber: "1Z999AA10123456784",
        shippingCarrierCode: "UPS",
        shippedDate: "2026-06-10T14:00:00.000Z",
      }],
    });

    await processSingleEbayOrder(
      makeOrder(), "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(mockSaleAdd).toHaveBeenCalledWith(
      expect.objectContaining({
        status:         "shipped",
        trackingNumber: "1Z999AA10123456784",
        carrier:        "UPS",
      })
    );
  });

  it("records takeHome from the SALE finance transaction", async () => {
    setupHttpsMock({
      transactions: [{
        orderId: "ORDER-001",
        transactionType: "SALE",
        amount: { value: "25.50" },
      }],
    });

    await processSingleEbayOrder(
      makeOrder(), "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(mockSaleAdd).toHaveBeenCalledWith(
      expect.objectContaining({ takeHome: 25.5 })
    );
  });
});

// ── Deduplication ─────────────────────────────────────────────────────────────

describe("deduplication", () => {
  it("does not create a duplicate sale for an existing order", async () => {
    mockSaleGet.mockResolvedValueOnce({
      empty: false,
      docs: [{
        data: () => ({
          trackingNumber: null,
          priceSoldFor: 29.99,
          shippingRevenue: null,
          buyerAddress: { line1: null },
        }),
        ref: { update: mockDocUpdate },
      }],
    });

    const result = await processSingleEbayOrder(
      makeOrder(), "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(result).toEqual({ isNew: false });
    expect(mockSaleAdd).not.toHaveBeenCalled();
  });

  it("backfills tracking onto an existing sale that had none", async () => {
    setupHttpsMock({
      fulfillments: [{
        fulfillmentId: "f1",
        shipmentTrackingNumber: "TRACK999",
        shippingCarrierCode: "USPS",
        shippedDate: "2026-06-10T15:00:00.000Z",
      }],
    });

    mockSaleGet.mockResolvedValueOnce({
      empty: false,
      docs: [{
        data: () => ({
          trackingNumber: null,
          priceSoldFor: 29.99,
          shippingRevenue: null,
          buyerAddress: { line1: "123 Main St" },
        }),
        ref: { update: mockDocUpdate },
      }],
    });

    await processSingleEbayOrder(
      makeOrder(), "uid1", "tok", false, mockDb, "cid", "cert", "etsy"
    );
    expect(mockDocUpdate).toHaveBeenCalledWith(
      expect.objectContaining({
        trackingNumber: "TRACK999",
        carrier: "USPS",
        status: "shipped",
      })
    );
  });
});
