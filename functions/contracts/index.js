/**
 * contracts/index.js — the backend contract registry.
 *
 * ONE source of truth for the callable surface shared by the web app, the
 * iOS app, and the Chrome extension. Consumed three ways:
 *
 *   1. Runtime validation — each `onCall` does:
 *        const { RequestSchemas } = require("./contracts");
 *        const data = RequestSchemas.recordSale.parse(request.data);
 *
 *   2. Swift codegen — `node scripts/gen-swift-contracts.js` turns every
 *      schema here into `contracts/generated/backend-contracts.schema.json`
 *      and then `ios/.../Generated/BackendContracts.swift` via quicktype.
 *
 *   3. Human reference — BACKEND.md links each function to its schema here.
 *
 * Adding a function: add its `{ name, summary, request, response }` to the
 * relevant domain file's `contracts` array. Nothing else.
 */

const { z } = require("zod");

const shared = require("./_shared");
const sales = require("./sales");
const mercari = require("./mercari");
const listings = require("./listings");
const ebay = require("./ebay");
const etsy = require("./etsy");
const enrichment = require("./enrichment");

const domains = { sales, mercari, listings, ebay, etsy, enrichment };

/** Flat list of every contract: [{ name, summary, request, response, domain }]. */
const ALL = Object.entries(domains).flatMap(([domain, mod]) =>
  (mod.contracts || []).map((c) => ({ ...c, domain }))
);

// Fail loud on a duplicate callable name across domains.
const seen = new Set();
for (const c of ALL) {
  if (seen.has(c.name)) throw new Error(`Duplicate contract name: ${c.name}`);
  seen.add(c.name);
}

const RequestSchemas = Object.fromEntries(ALL.map((c) => [c.name, c.request]));
const ResponseSchemas = Object.fromEntries(ALL.map((c) => [c.name, c.response]));

/**
 * Wrap an onCall handler with request validation + response validation
 * (response check is dev-only — set CONTRACTS_STRICT=1 to enforce).
 *
 *   exports.recordSale = onCall(validated("recordSale", async (data, request) => {
 *     ...
 *     return { saleId, created: true, cascade };
 *   }));
 */
function validated(name, handler) {
  const reqSchema = RequestSchemas[name];
  const resSchema = ResponseSchemas[name];
  if (!reqSchema) throw new Error(`No contract registered for "${name}"`);

  return async (request) => {
    const { HttpsError } = require("firebase-functions/v2/https");
    let data;
    try {
      data = reqSchema.parse(request.data ?? {});
    } catch (err) {
      throw new HttpsError("invalid-argument", `Bad ${name} payload: ${err.errors?.[0]?.message ?? err.message}`, err.errors);
    }
    const result = await handler(data, request);
    if (process.env.CONTRACTS_STRICT === "1" && resSchema) {
      const check = resSchema.safeParse(result);
      if (!check.success) {
        console.error(`[contract] ${name} response violates schema`, check.error.errors);
      }
    }
    return result;
  };
}

module.exports = {
  z,
  ...shared,
  SaleDocSchema: sales.SaleDocSchema,
  MercariScrapeItemSchema: mercari.MercariScrapeItemSchema,
  ListingFieldsSchema: enrichment.ListingFieldsSchema,
  ALL,
  RequestSchemas,
  ResponseSchemas,
  validated,
};
