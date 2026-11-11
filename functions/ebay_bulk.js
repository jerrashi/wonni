"use strict";

/**
 * eBay Inventory API bulk calls (25 per request) with an individual fallback.
 * `request(method, path, body)` is injected (ebayRequest bound to a uid), so
 * this is testable without the network.
 *
 * A bulk response reports per-row status codes; any row that is not 2xx is
 * re-run through the single-item path so the caller sees eBay's real error
 * (and the existing create-or-adopt logic) instead of a vague bulk failure.
 */

const BULK_LIMIT = 25;

function chunk(list, size = BULK_LIMIT) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

const ok = (r) => r && Number(r.statusCode) >= 200 && Number(r.statusCode) < 300;

/**
 * PUT many inventory items. `items` = [{sku, body}] where body is the normal
 * single-item payload. Falls back to PUT /inventory_item/{sku} for failed rows.
 */
async function bulkPutInventoryItems(request, items) {
  for (const batch of chunk(items)) {
    let rows = [];
    try {
      const res = await request("POST", "/sell/inventory/v1/bulk_create_or_replace_inventory_item", {
        requests: batch.map(({ sku, body }) => ({ sku, ...body })),
      });
      rows = res?.responses ?? [];
    } catch (_) {
      rows = []; // whole call failed → every row retried singly below
    }
    const done = new Set(rows.filter(ok).map((r) => r.sku));
    for (const { sku, body } of batch) {
      if (done.has(sku)) continue;
      await request("PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, body);
    }
  }
}

/**
 * Create offers for many SKUs. `offers` = [{sku, body}] (full create payloads).
 * Returns {sku: offerId}. Rows bulk can't create (already exists, validation)
 * go through `createSingle(sku, body)` (createOrAdoptOffer) for the same
 * adopt-the-existing-offer behavior the one-at-a-time path always had.
 */
async function bulkCreateOffers(request, offers, createSingle) {
  const ids = {};
  for (const batch of chunk(offers)) {
    let rows = [];
    try {
      const res = await request("POST", "/sell/inventory/v1/bulk_create_offer", { requests: batch.map((o) => o.body) });
      rows = res?.responses ?? [];
    } catch (_) {
      rows = [];
    }
    for (const r of rows) if (ok(r) && r.offerId) ids[r.sku] = r.offerId;
    for (const { sku, body } of batch) {
      if (!ids[sku]) ids[sku] = await createSingle(sku, body);
    }
  }
  return ids;
}

module.exports = { BULK_LIMIT, chunk, bulkPutInventoryItems, bulkCreateOffers };
