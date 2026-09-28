/**
 * ebay-shipping-rule.test.js — the pure naming + payload-building logic
 * behind ebaySetShippingRule. The callable itself (Firestore-backed OAuth
 * token refresh + live eBay fulfillment_policy calls) needs a sandbox smoke
 * test, same caveat as the rest of ebay_listing.js — see
 * docs/specs/2026-09-28-ebay-listing-management-api.md.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const { _internal } = require("../ebay_listing");
const { buildShippingRuleName, buildShippingRulePayload } = _internal;

// ── buildShippingRuleName ───────────────────────────────────────────────────

test("buildShippingRuleName: 'X business days - itemType - $Y handling'", () => {
  assert.equal(
    buildShippingRuleName({ handlingTimeDays: 2, handlingCost: 10, itemType: "Trading Cards" }),
    "2 business days - Trading Cards - $10 handling"
  );
});

test("buildShippingRuleName: omits itemType segment when not given", () => {
  assert.equal(
    buildShippingRuleName({ handlingTimeDays: 3, handlingCost: 5 }),
    "3 business days - $5 handling"
  );
});

test("buildShippingRuleName: keeps cents when non-whole", () => {
  assert.equal(
    buildShippingRuleName({ handlingTimeDays: 1, handlingCost: 4.5, itemType: "Media" }),
    "1 business days - Media - $4.50 handling"
  );
});

test("buildShippingRuleName: blank itemType treated same as omitted", () => {
  assert.equal(
    buildShippingRuleName({ handlingTimeDays: 1, handlingCost: 5, itemType: "   " }),
    "1 business days - $5 handling"
  );
});

// ── buildShippingRulePayload ────────────────────────────────────────────────

test("buildShippingRulePayload: preferredService builds a single-service FLAT_RATE policy", () => {
  const payload = buildShippingRulePayload(
    { handlingTimeDays: 2, handlingCost: 10, itemType: "Trading Cards", preferredCarrier: "USPS", preferredService: "USPSFirstClass" },
    null
  );
  assert.equal(payload.name, "2 business days - Trading Cards - $10 handling");
  assert.equal(payload.handlingTime.value, 2);
  assert.equal(payload.handlingTime.unit, "DAY");
  assert.equal(payload.shippingOptions[0].shippingServices[0].shippingServiceCode, "USPSFirstClass");
  assert.equal(payload.shippingOptions[0].shippingServices[0].shippingCarrierCode, "USPS");
  assert.equal(payload.shippingOptions[0].shippingServices[0].shippingCost.value, "10.00");
});

test("buildShippingRulePayload: no preferredService, no basePolicy -> null (nothing valid to build)", () => {
  const payload = buildShippingRulePayload({ handlingTimeDays: 2, handlingCost: 10 }, null);
  assert.equal(payload, null);
});

test("buildShippingRulePayload: no preferredService clones basePolicy's shippingOptions, overriding only the first service's cost", () => {
  const basePolicy = {
    marketplaceId: "EBAY_US",
    categoryTypes: [{ name: "ALL_EXCLUDING_MOTORS_VEHICLES", default: true }],
    shippingOptions: [{
      optionType: "DOMESTIC",
      costType: "FLAT_RATE",
      shippingServices: [
        { sortOrder: 1, shippingServiceCode: "USPSGroundAdvantage", shippingCost: { value: "6.99", currency: "USD" } },
        { sortOrder: 2, shippingServiceCode: "USPSPriorityMail", shippingCost: { value: "12.00", currency: "USD" } },
      ],
    }],
  };
  const payload = buildShippingRulePayload({ handlingTimeDays: 1, handlingCost: 3 }, basePolicy);

  assert.equal(payload.shippingOptions[0].shippingServices[0].shippingServiceCode, "USPSGroundAdvantage");
  assert.equal(payload.shippingOptions[0].shippingServices[0].shippingCost.value, "3.00");
  // Second service (not overridden) is left as-is
  assert.equal(payload.shippingOptions[0].shippingServices[1].shippingServiceCode, "USPSPriorityMail");
  assert.equal(payload.shippingOptions[0].shippingServices[1].shippingCost.value, "12.00");
});

test("buildShippingRulePayload: handlingTimeDays clamps to eBay's max", () => {
  const payload = buildShippingRulePayload(
    { handlingTimeDays: 999, handlingCost: 1, preferredService: "USPSFirstClass" },
    null
  );
  assert.equal(payload.handlingTime.value, 30);
});
