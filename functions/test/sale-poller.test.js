/**
 * sale-poller.test.js — the pure mapping layer of syncSales.
 *
 * The HTTP layer (ebayRequest / fetch) isn't injectable here, so the callables
 * themselves need an emulator / manual smoke test. What IS unit-covered: SKU →
 * product matching, order/receipt → canonical sale fields, status mapping, and
 * that the mapper output flows correctly through recordSaleCore.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { FakeFirestore } = require("./helpers/fake-firestore");
const { _internal: poller } = require("../sale_poller");
const { _internal: sales } = require("../sales");

const {
  buildEbaySkuMap, buildEtsyListingMap, ebayOrderToSaleFields,
  etsyReceiptToSaleFields, resolveEbayStatus, ebayBuyerAddress,
  summarizeEbayTransactions, sumEtsyPayments,
} = poller;

const UID = "user_1";
const docs = (map) => Object.entries(map).map(([id, data]) => ({ id, data: () => data }));

// ── SKU / listing matching ─────────────────────────────────────────────────

test("buildEbaySkuMap: single = productId + legacy wonni_ alias; variant = per-variant SKU", () => {
  const map = buildEbaySkuMap(docs({
    p1: { title: "Plain" },
    p2: { hasVariants: true, variants: [
      { id: "vS", sku: "TEE-S" },
      { id: "vM", sku: "TEE-M", ebayVariantSku: "CUSTOM-M" },
    ] },
  }));
  assert.deepEqual(map.get("p1"), { productId: "p1", variantSku: null });
  assert.deepEqual(map.get("wonni_p1"), { productId: "p1", variantSku: null });
  assert.deepEqual(map.get("p2vS"), { productId: "p2", variantSku: "TEE-S" });
  assert.deepEqual(map.get("CUSTOM-M"), { productId: "p2", variantSku: "TEE-M" }, "stored ebayVariantSku wins");
});

test("buildEtsyListingMap: product- and variant-level ids, current + legacy keys", () => {
  const map = buildEtsyListingMap(docs({
    p1: { crossPostListingIds: { etsy: 111 } },
    p2: { etsyListingId: "222" },
    p3: { variants: [{ sku: "V", crossPostListingIds: { etsy: 333 } }] },
  }));
  assert.equal(map.get("111").productId, "p1");
  assert.equal(map.get("222").productId, "p2");
  assert.deepEqual(map.get("333"), { productId: "p3", variantSku: "V" });
});

// ── status mapping ─────────────────────────────────────────────────────────

test("resolveEbayStatus: cancellation > fulfillment > tracking > pending", () => {
  assert.equal(resolveEbayStatus({ cancelStatus: { cancelState: "CANCELED" }, orderFulfillmentStatus: "FULFILLED" }, true), "cancelled");
  assert.equal(resolveEbayStatus({ orderFulfillmentStatus: "FULFILLED" }, false), "complete");
  assert.equal(resolveEbayStatus({ orderFulfillmentStatus: "IN_PROGRESS" }, true), "shipped");
  assert.equal(resolveEbayStatus({}, false), "pending");
});

// ── eBay order → sale fields ───────────────────────────────────────────────

const EBAY_ORDER = {
  orderId: "05-12345-67890",
  orderPaymentStatus: "PAID",
  orderFulfillmentStatus: "NOT_STARTED",
  creationDate: "2026-09-01T12:00:00.000Z",
  pricingSummary: {
    priceSubtotal: { value: "24.00", currency: "USD" },
    deliveryCost: { value: "4.50", currency: "USD" },
    total: { value: "28.50", currency: "USD" },
  },
  buyer: { username: "happybuyer" },
  fulfillmentStartInstructions: [
    { shippingStep: { shipTo: { fullName: "A Buyer", contactAddress: {
      addressLine1: "1 Main St", city: "Portland", stateOrProvince: "OR", postalCode: "97201", countryCode: "US",
    } } } },
  ],
  lineItems: [
    { sku: "p1", title: "Plain Tee", quantity: 1, legacyItemId: "1122334455", image: { imageUrl: "https://i.ebayimg.com/x.jpg" } },
  ],
};

test("ebayOrderToSaleFields: item price only, shipping split out, address + thumb mapped", () => {
  const f = ebayOrderToSaleFields(EBAY_ORDER, EBAY_ORDER.lineItems[0], { productId: "p1", variantSku: null }, {});
  assert.equal(f.soldPrice, 24, "priceSubtotal, not total");
  assert.equal(f.shippingRevenue, 4.5);
  assert.equal(f.platformOrderId, "05-12345-67890");
  assert.equal(f.platformItemId, "1122334455");
  assert.equal(f.thumbnailUrl, "https://i.ebayimg.com/x.jpg");
  assert.equal(f.buyerAddress.city, "Portland");
  assert.equal(f.status, "pending");
  assert.equal(f.source, "ebay-poll");
});

test("ebayOrderToSaleFields: folds in tracking + finance lookups", () => {
  const f = ebayOrderToSaleFields(EBAY_ORDER, EBAY_ORDER.lineItems[0], { productId: "p1", variantSku: null }, {
    tracking: { trackingNumber: "1Z999", carrier: "UPS" },
    finance: { takeHome: 21.1, labelCost: 3.9 },
  });
  assert.equal(f.trackingNumber, "1Z999");
  assert.equal(f.carrier, "UPS");
  assert.equal(f.takeHome, 21.1);
  assert.equal(f.shippingLabelCost, 3.9);
  assert.equal(f.status, "shipped", "tracking present → shipped");
});

test("ebayBuyerAddress: null when there's no ship-to and no name", () => {
  assert.equal(ebayBuyerAddress({ fulfillmentStartInstructions: [] }), null);
});

// ── eBay/Etsy take-home accuracy fix (regression, 2026-09-11 spec §4) ──────

test("regression: summarizeEbayTransactions sums SALE + REFUND, doesn't stop at the first row", () => {
  const s = summarizeEbayTransactions([
    { orderId: "o1", transactionType: "SALE", amount: { value: "20.00" } },
    { orderId: "o1", transactionType: "REFUND", amount: { value: "-18.50" } },
    { orderId: "other-order", transactionType: "SALE", amount: { value: "999.00" } },
  ], "o1");
  assert.equal(s.takeHome, 1.5, "20 - 18.50, not just the first SALE row");
});

test("regression: summarizeEbayTransactions returns a negative sum as-is (a real loss), not floored to null/0", () => {
  const s = summarizeEbayTransactions([
    { orderId: "o1", transactionType: "SALE", amount: { value: "20.00" } },
    { orderId: "o1", transactionType: "REFUND", amount: { value: "-25.00" } },
  ], "o1");
  assert.equal(s.takeHome, -5, "the seller lost money on this return");
});

test("summarizeEbayTransactions: SHIPPING_LABEL tracked separately from takeHome, still summed across rows", () => {
  const s = summarizeEbayTransactions([
    { orderId: "o1", transactionType: "SALE", amount: { value: "20.00" } },
    { orderId: "o1", transactionType: "SHIPPING_LABEL", amount: { value: "4.10" } },
    { orderId: "o1", transactionType: "SHIPPING_LABEL", amount: { value: "1.00" } },
  ], "o1");
  assert.equal(s.takeHome, 20);
  assert.equal(s.labelCost, 5.1);
});

test("summarizeEbayTransactions: no matching transaction for the order -> takeHome null (found-nothing, not zero)", () => {
  const s = summarizeEbayTransactions([{ orderId: "other", transactionType: "SALE", amount: { value: "20.00" } }], "o1");
  assert.equal(s.takeHome, null);
});

test("regression: sumEtsyPayments sums every payment row (a refund's negative amount_net included)", () => {
  const net = sumEtsyPayments([
    { amount_net: { amount: 1500, divisor: 100 } },
    { amount_net: { amount: -1200, divisor: 100 } },
  ]);
  assert.equal(net, 3, "15.00 - 12.00");
});

test("regression: sumEtsyPayments returns a negative net as-is, not floored to null", () => {
  const net = sumEtsyPayments([
    { amount_net: { amount: 1500, divisor: 100 } },
    { amount_net: { amount: -2000, divisor: 100 } },
  ]);
  assert.equal(net, -5);
});

test("sumEtsyPayments: no rows at all -> null (distinct from a real zero/negative sum)", () => {
  assert.equal(sumEtsyPayments([]), null);
  assert.equal(sumEtsyPayments(null), null);
});

// ── Etsy receipt → sale fields ─────────────────────────────────────────────

test("etsyReceiptToSaleFields: divisor math, status, unmatched receipt still maps", () => {
  const f = etsyReceiptToSaleFields({
    receipt_id: 987654,
    status: "completed",
    is_shipped: true,
    total_price: { amount: 1899, divisor: 100 },
    created_timestamp: 1_756_000_000,
    name: "Etsy Buyer",
    first_line: "9 Etsy Rd",
    city: "Austin",
    country_iso: "US",
    transactions: [{ title: "Handmade Thing", listing_id: 333 }],
  }, null, 15.25);

  assert.equal(f.soldPrice, 18.99);
  assert.equal(f.status, "complete");
  assert.equal(f.takeHome, 15.25);
  assert.equal(f.productId, null, "no match → still a recordable manual-style row");
  assert.equal(f.platformOrderId, "987654");
  assert.equal(f.buyerAddress.city, "Austin");
});

// ── mapper → recordSaleCore integration ────────────────────────────────────

test("an eBay poll result flows through recordSaleCore: new sale + cascade + dedupe", async () => {
  const product = {
    userId: UID, title: "Plain Tee", quantity: 5,
    images: ["https://storage/x.jpg"], crossPostStatus: { ebay: "active" }, ebayOfferId: "OF-1",
  };
  const db = new FakeFirestore({ products: { p1: product } });

  const fields = ebayOrderToSaleFields(EBAY_ORDER, EBAY_ORDER.lineItems[0], { productId: "p1", variantSku: null }, {
    finance: { takeHome: 20, labelCost: null },
  });

  const first = await sales.recordSaleCore(db, UID, fields, product);
  assert.equal(first.created, true);
  assert.equal(first.saleId, "ebay_05-12345-67890");
  const sale = db.peek("sales", "ebay_05-12345-67890");
  assert.equal(sale.priceSoldFor, 24);
  assert.equal(sale.takeHome, 20);
  assert.equal(sale.source, "ebay-poll");
  assert.equal(db.peek("products", "p1").quantity, 4, "cascade decremented stock once");

  // Re-poll the same order — no second decrement, take-home refresh allowed.
  const again = await sales.recordSaleCore(
    db, UID, { ...fields, takeHome: 19.5 }, db.peek("products", "p1"),
  );
  assert.equal(again.created, false);
  assert.equal(db.peek("products", "p1").quantity, 4, "no double decrement on re-poll");
  assert.equal(db.peek("sales", "ebay_05-12345-67890").takeHome, 19.5, "corrected take-home merged in");
});
