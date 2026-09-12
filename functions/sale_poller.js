/**
 * sale_poller.js — syncSales + getOrderTakeHome
 *
 * Consolidated from the nested tree's `sale_poller.js` (719 L) + `sale_fetch.js`
 * (198 L), rebased onto:
 *   - the canonical `products/{id}` model (was `listings/{id}`)
 *   - the shared eBay app keyset via `ebayRequest` (was per-user isSandbox)
 *   - the ONE write path `recordSaleCore` (was a bare `sales.add()` + a separate
 *     `decrementAndCascadeInternal`)
 *
 * syncSales        — on-demand poll of eBay + Etsy for orders not yet in sales/.
 * getOrderTakeHome — fetch a recorded sale's net payout (eBay Finances / Etsy
 *                    Payments) and persist it onto the sale.
 *
 * eBay order + finance reads need the `sell.fulfillment` / `sell.finances`
 * scopes. `ebay_auth.refreshScopeFor` sends them only for accounts that granted
 * them; `hasOrderReadScopes` gates the poll with a friendly "reconnect" error.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { validated } = require("./contracts");
const {
  ebayRequest, hasOrderReadScopes, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET,
} = require("./ebay_auth");
const { getActiveEtsyToken } = require("./etsy_auth");
const { variantSkuFor } = require("./ebay_listing");
const { _internal } = require("./sales");

const { recordSaleCore } = _internal;
const EBAY_SECRETS = [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET];
const DEFAULT_LOOKBACK_MS = 30 * 24 * 60 * 60 * 1000;

// ── product matching ───────────────────────────────────────────────────────

/** eBay SKU → { productId, variantSku } for every product this user owns. */
function buildEbaySkuMap(productDocs) {
  const map = new Map();
  for (const doc of productDocs) {
    const p = doc.data();
    const variants = Array.isArray(p.variants) ? p.variants : [];
    const isVariant = p.hasVariants === true || variants.length > 0;
    if (isVariant) {
      variants.forEach((v, i) => {
        const sku = v.ebayVariantSku || variantSkuFor(doc.id, v, i);
        if (sku && !map.has(sku)) map.set(sku, { productId: doc.id, variantSku: v.sku ?? null });
      });
    } else {
      map.set(doc.id, { productId: doc.id, variantSku: null });
      // Legacy iOS SKU, for listings not yet migrated off `listings/`.
      map.set(`wonni_${doc.id}`, { productId: doc.id, variantSku: null });
    }
  }
  return map;
}

/** Etsy listing id (string) → { productId, variantSku }. */
function buildEtsyListingMap(productDocs) {
  const map = new Map();
  for (const doc of productDocs) {
    const p = doc.data();
    const add = (id, variantSku) => {
      if (id != null && !map.has(String(id))) map.set(String(id), { productId: doc.id, variantSku });
    };
    add(p.crossPostListingIds?.etsy, null);
    add(p.etsyListingId, null);
    for (const v of Array.isArray(p.variants) ? p.variants : []) {
      add(v.crossPostListingIds?.etsy, v.sku ?? null);
    }
  }
  return map;
}

// ── eBay order → canonical sale fields ─────────────────────────────────────

const num = (v) => {
  const n = parseFloat(v ?? "0");
  return Number.isFinite(n) ? n : 0;
};

/** eBay order lifecycle → our SaleStatus. Cancellation wins over fulfillment. */
function resolveEbayStatus(order, hasTracking) {
  if (order.cancelStatus?.cancelState === "CANCELED") return "cancelled";
  if (order.orderFulfillmentStatus === "FULFILLED") return "complete";
  if (hasTracking) return "shipped";
  return "pending";
}

function ebayBuyerAddress(order) {
  const shipTo = (order.fulfillmentStartInstructions ?? [])
    .map((i) => i.shippingStep?.shipTo)
    .find(Boolean);
  const a = shipTo?.contactAddress ?? order.buyer?.buyerRegistrationAddress?.contactAddress ?? {};
  const name = shipTo?.fullName ?? order.buyer?.buyerRegistrationAddress?.fullName ?? null;
  if (!a.addressLine1 && !name) return null;
  return {
    name,
    line1: a.addressLine1 ?? null,
    line2: a.addressLine2 ?? null,
    city: a.city ?? null,
    state: a.stateOrProvince ?? null,
    zip: a.postalCode ?? null,
    country: a.countryCode ?? "US",
  };
}

/**
 * One eBay order + one matched line item → the `fields` arg for recordSaleCore.
 * `tracking` / `finance` are the (optional) results of the per-order lookups.
 */
function ebayOrderToSaleFields(order, lineItem, match, { tracking, finance } = {}) {
  const hasTracking = !!tracking?.trackingNumber;
  return {
    platform: "ebay",
    productId: match.productId,
    variantSku: match.variantSku,
    soldPrice: num(order.pricingSummary?.priceSubtotal?.value ?? order.pricingSummary?.total?.value),
    shippingRevenue: num(order.pricingSummary?.deliveryCost?.value) || null,
    shippingLabelCost: finance?.labelCost ?? null,
    takeHome: finance?.takeHome ?? null,
    quantity: Number(lineItem.quantity) || 1,
    soldAt: order.creationDate ?? null,
    platformOrderId: order.orderId,
    platformItemId: lineItem.legacyItemId ?? null,
    buyerName: order.buyer?.username ?? null,
    buyerAddress: ebayBuyerAddress(order),
    trackingNumber: tracking?.trackingNumber ?? null,
    carrier: tracking?.carrier ?? null,
    listingTitle: lineItem.title ?? null,
    thumbnailUrl: lineItem.image?.imageUrl ?? null,
    status: resolveEbayStatus(order, hasTracking),
    source: "ebay-poll",
    cascade: true,
  };
}

/** Etsy receipt → recordSaleCore fields. */
function etsyReceiptToSaleFields(receipt, match, takeHome) {
  const price = num(receipt.total_price?.amount) / (receipt.total_price?.divisor || 100);
  const etsyStatus = receipt.status;
  const status =
    etsyStatus === "completed" ? "complete"
      : etsyStatus === "canceled" ? "cancelled"
        : receipt.is_shipped ? "shipped"
          : "pending";
  return {
    platform: "etsy",
    productId: match?.productId ?? null,
    variantSku: match?.variantSku ?? null,
    soldPrice: Math.round(price * 100) / 100,
    takeHome: takeHome ?? null,
    quantity: 1,
    soldAt: (receipt.created_timestamp ?? receipt.creation_tsz ?? Math.floor(Date.now() / 1000)) * 1000,
    platformOrderId: String(receipt.receipt_id),
    listingTitle: receipt.transactions?.[0]?.title ?? null,
    buyerName: receipt.name ?? null,
    buyerAddress: {
      name: receipt.name ?? null,
      line1: receipt.first_line ?? null,
      line2: receipt.second_line ?? null,
      city: receipt.city ?? null,
      state: receipt.state ?? null,
      zip: receipt.zip ?? null,
      country: receipt.country_iso ?? "US",
    },
    status,
    source: "etsy-poll",
    cascade: true,
  };
}

// ── eBay per-order lookups (best-effort — a failure never fails the sale) ───

async function ebayFetchTracking(uid, orderId) {
  try {
    const res = await ebayRequest(
      uid, "GET",
      `/sell/fulfillment/v1/order/${encodeURIComponent(orderId)}/shipping_fulfillment`,
      null, { marketplaceId: "EBAY_US" },
    );
    const f = (res?.fulfillments ?? []).at(-1);
    if (!f) return null;
    return { trackingNumber: f.shipmentTrackingNumber ?? null, carrier: f.shippingCarrierCode ?? null };
  } catch (e) {
    console.warn(`[syncSales] tracking lookup failed order=${orderId}: ${e.message}`);
    return null;
  }
}

/**
 * Sum one order's eBay Finances transactions into a take-home + label cost.
 * Pure/pageable so it can be unit-tested without the HTTP layer.
 *
 * Fixed 2026-09-11 (docs/specs/2026-09-11-stage-board-and-revenue-accounting.md
 * §4) — the original version only ever looked at the first `SALE` row it found
 * (via an early `break`) and floored a negative net to `null`. That silently
 * discarded `REFUND` rows a return posts to this same order, even though
 * eBay's Finances API — the same data source eBay's own payout page reads —
 * carries them. Now: every non-SHIPPING_LABEL row tied to the order is summed
 * into `takeHome` (SALE, REFUND, and any other adjustment/credit type eBay
 * ties to the order — deliberately not an allowlist, since eBay's own set of
 * transactionTypes isn't fully enumerated here), and a negative sum is
 * returned as-is: a return can leave the seller genuinely out of pocket
 * (unrefunded original shipping/fees, a return-shipping charge), and that's a
 * real loss to show, not a signal to discard.
 */
function summarizeEbayTransactions(transactions, orderId) {
  let takeHome = null; // null = "no relevant transaction seen yet", not zero
  let labelCost = 0;
  for (const tx of transactions ?? []) {
    if (tx.orderId !== orderId) continue;
    if (tx.transactionType === "SHIPPING_LABEL") {
      labelCost += num(tx.amount?.value);
    } else {
      takeHome = (takeHome ?? 0) + num(tx.amount?.value);
    }
  }
  return { takeHome, labelCost };
}

/**
 * eBay Finances transactions for one order. SALE/REFUND amounts are already
 * net of eBay fees; SHIPPING_LABEL rows are costs, tracked separately and
 * deducted. apiz.* host.
 */
async function ebayFetchFinance(uid, orderId) {
  try {
    let takeHome = null;
    let labelCost = 0;
    for (let offset = 0, page = 0; page < 5; page++, offset += 20) {
      const res = await ebayRequest(
        uid, "GET",
        `/sell/finances/v1/transaction?limit=20&offset=${offset}`,
        null, { host: "apiz", marketplaceId: "EBAY_US" },
      );
      const summary = summarizeEbayTransactions(res?.transactions, orderId);
      if (summary.takeHome != null) takeHome = (takeHome ?? 0) + summary.takeHome;
      labelCost += summary.labelCost;
      // No early exit on finding a SALE row — a REFUND for the same order can
      // land on a later page (or a later poll, once more transactions exist).
      if ((res?.transactions ?? []).length < 20) break;
    }
    if (takeHome == null) return null;
    const net = Math.round((takeHome - labelCost) * 100) / 100;
    return {
      takeHome: net,
      labelCost: labelCost > 0 ? Math.round(labelCost * 100) / 100 : null,
      fees: null, // SALE amount is already net of fees; eBay doesn't itemize here
    };
  } catch (e) {
    console.warn(`[syncSales] finance lookup failed order=${orderId}: ${e.message}`);
    return null;
  }
}

/**
 * Re-fetch + persist a sale's take-home from the platform API — the same work
 * `getOrderTakeHome` does, factored out so `sales.js`'s `updateSaleStatusCore`
 * can trigger it automatically when a sale moves into `cancelled`/`returned`
 * (docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §4, "Re-poll
 * on status change") instead of waiting on a manual refresh action. Mercari/
 * manual sales have no take-home API — no-op for those, matching
 * `getOrderTakeHome`'s own `failed-precondition` boundary. Best-effort: never
 * throws, returns null on any failure or when there's nothing new to fetch.
 */
async function refetchTakeHomeForSale(db, uid, saleRef, sale) {
  try {
    if (!sale.platformOrderId) return null;
    let result = null;
    if (sale.platform === "ebay") {
      const f = await ebayFetchFinance(uid, sale.platformOrderId);
      if (f) result = { takeHome: f.takeHome, shippingLabelCost: f.labelCost };
    } else if (sale.platform === "etsy") {
      const takeHome = await etsyReceiptTakeHome(await getActiveEtsyToken(uid), sale.platformOrderId);
      if (takeHome != null) result = { takeHome };
    } else {
      return null;
    }
    if (result && result.takeHome != null) {
      await saleRef.set({
        takeHome: result.takeHome,
        ...(result.shippingLabelCost != null ? { shippingLabelCost: result.shippingLabelCost } : {}),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    return result;
  } catch (e) {
    console.warn(`[refetchTakeHomeForSale] failed sale=${saleRef.id}: ${e.message}`);
    return null;
  }
}

// ── platform sync passes ──────────────────────────────────────────────────

async function syncEbay(db, uid, productDocs, productById, sinceMs) {
  const integ = (await db.doc(`users/${uid}/integrations/ebay`).get()).data();
  if (!integ?.isConnected) return { imported: 0, skipped: 0, saleIds: [] };
  if (!hasOrderReadScopes(integ)) {
    throw new Error("eBay order sync needs a reconnect — the fulfillment/finances permissions were added 2026-09-09.");
  }

  const skuMap = buildEbaySkuMap(productDocs);
  const from = new Date(sinceMs).toISOString();
  const to = new Date().toISOString();
  const res = await ebayRequest(
    uid, "GET",
    `/sell/fulfillment/v1/order?filter=creationdate:[${from}..${to}]&limit=50`,
    null, { marketplaceId: "EBAY_US" },
  );

  let imported = 0;
  let skipped = 0;
  const saleIds = [];

  for (const order of res?.orders ?? []) {
    if (order.orderPaymentStatus !== "PAID") continue;
    const matches = (order.lineItems ?? [])
      .map((li) => ({ li, match: skuMap.get(li.sku ?? "") }))
      .filter((x) => x.match);
    if (!matches.length) { skipped++; continue; }

    const [tracking, finance] = await Promise.all([
      ebayFetchTracking(uid, order.orderId),
      ebayFetchFinance(uid, order.orderId),
    ]);

    for (const { li, match } of matches) {
      const fields = ebayOrderToSaleFields(order, li, match, { tracking, finance });
      const { saleId, created } = await recordSaleCore(
        db, uid, fields, productById.get(match.productId) ?? null,
      );
      saleIds.push(saleId);
      created ? imported++ : skipped++;
    }
  }

  await db.doc(`users/${uid}/integrations/ebay`).set(
    { lastSalesPollAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true },
  );
  return { imported, skipped, saleIds };
}

async function syncEtsy(db, uid, productDocs, productById, sinceMs) {
  const integ = (await db.doc(`users/${uid}/integrations/etsy`).get()).data();
  if (!integ?.isConnected) return { imported: 0, skipped: 0, saleIds: [] };
  // getActiveEtsyToken refreshes the token (added with the Etsy CRUD port) and
  // recovers a missing shopId; throws failed-precondition -> caught as an error.
  const { accessToken, shopId, clientId } = await getActiveEtsyToken(uid);
  const etsyAuth = { accessToken, shopId, clientId };

  const listingMap = buildEtsyListingMap(productDocs);
  const minCreated = Math.floor(sinceMs / 1000);
  const receiptsRes = await fetch(
    `https://openapi.etsy.com/v3/application/shops/${shopId}/receipts?was_paid=true&min_created=${minCreated}&limit=100`,
    { headers: { "x-api-key": clientId, Authorization: `Bearer ${accessToken}` } },
  );
  if (!receiptsRes.ok) throw new Error(`Etsy receipts ${receiptsRes.status}`);
  const receipts = (await receiptsRes.json()).results ?? [];

  let imported = 0;
  let skipped = 0;
  const saleIds = [];

  for (const receipt of receipts) {
    const etsyListingId = receipt.transactions?.[0]?.listing_id;
    const match = etsyListingId != null ? listingMap.get(String(etsyListingId)) : null;
    const takeHome = await etsyReceiptTakeHome(etsyAuth, receipt.receipt_id).catch(() => null);
    const fields = etsyReceiptToSaleFields(receipt, match, takeHome);
    const { saleId, created } = await recordSaleCore(
      db, uid, fields, match ? productById.get(match.productId) ?? null : null,
    );
    saleIds.push(saleId);
    created ? imported++ : skipped++;
  }

  await db.doc(`users/${uid}/integrations/etsy`).set(
    { lastSalesPollAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true },
  );
  return { imported, skipped, saleIds };
}

/**
 * Sum a shop's /payments rows for one receipt. Pure so it's unit-testable.
 * Fixed 2026-09-11 alongside the eBay fix (same spec, §4): a refund posts its
 * own payment row here with a negative `amount_net`, and the old floor
 * (`net > 0 ? net : null`) discarded that, same bug as eBay's. `null` now
 * means "no payment rows at all" (nothing posted yet), never "the sum was
 * negative or zero."
 */
function sumEtsyPayments(results) {
  if (!results || results.length === 0) return null;
  let net = 0;
  for (const p of results) {
    if (p.amount_net) net += p.amount_net.amount / (p.amount_net.divisor || 100);
  }
  return Math.round(net * 100) / 100;
}

async function etsyReceiptTakeHome({ shopId, accessToken, clientId }, receiptId) {
  const res = await fetch(
    `https://openapi.etsy.com/v3/application/shops/${shopId}/payments?receipt_id=${encodeURIComponent(receiptId)}`,
    { headers: { "x-api-key": clientId, Authorization: `Bearer ${accessToken}` } },
  );
  if (!res.ok) return null;
  return sumEtsyPayments((await res.json()).results);
}

// ── callables ─────────────────────────────────────────────────────────────

exports.syncSales = onCall(
  { secrets: EBAY_SECRETS, timeoutSeconds: 120, memory: "512MiB" },
  validated("syncSales", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();

    const only = data.platform ?? null;
    const sinceMs = data.since != null
      ? (typeof data.since === "number" ? data.since : Date.parse(data.since))
      : Date.now() - DEFAULT_LOOKBACK_MS;

    const productsSnap = await db.collection("products").where("userId", "==", uid).get();
    const productById = new Map(productsSnap.docs.map((d) => [d.id, d.data()]));

    const errors = [];
    const saleIds = [];
    let imported = 0;
    let skipped = 0;

    for (const [platform, fn] of [["ebay", syncEbay], ["etsy", syncEtsy]]) {
      if (only && only !== platform) continue;
      try {
        const r = await fn(db, uid, productsSnap.docs, productById, sinceMs);
        imported += r.imported;
        skipped += r.skipped;
        saleIds.push(...r.saleIds);
      } catch (e) {
        console.error(`[syncSales] ${platform} uid=${uid}: ${e.message}`);
        errors.push({ platform, message: e.message });
      }
    }

    return { imported, skipped, saleIds, errors };
  }),
);

exports.getOrderTakeHome = onCall(
  { secrets: EBAY_SECRETS },
  validated("getOrderTakeHome", async (data, request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const db = admin.firestore();

    // Resolve platform + orderId either from a recorded sale or directly.
    let platform, platformOrderId, saleRef = null;
    if (data.saleId) {
      const saleSnap = await db.collection("sales").doc(data.saleId).get();
      if (!saleSnap.exists) throw new HttpsError("not-found", "Sale not found.");
      const sale = saleSnap.data();
      if (sale.userId !== uid) throw new HttpsError("permission-denied", "Not your sale.");
      if (!sale.platformOrderId) {
        throw new HttpsError("failed-precondition", "This sale has no platform order id.");
      }
      ({ platform, platformOrderId } = sale);
      saleRef = saleSnap.ref;
    } else {
      platform = data.platform;
      platformOrderId = data.platformOrderId;
    }

    let out = { takeHome: null, fees: null, shippingLabelCost: null, provisional: true };
    if (platform === "ebay") {
      const f = await ebayFetchFinance(uid, platformOrderId);
      if (f) out = { takeHome: f.takeHome, fees: f.fees, shippingLabelCost: f.labelCost, provisional: false };
    } else if (platform === "etsy") {
      const takeHome = await etsyReceiptTakeHome(await getActiveEtsyToken(uid), platformOrderId);
      out = { takeHome, fees: null, shippingLabelCost: null, provisional: takeHome == null };
    } else {
      throw new HttpsError("failed-precondition", `Take-home is not available for ${platform}.`);
    }

    if (saleRef && out.takeHome != null) {
      await saleRef.set({
        takeHome: out.takeHome,
        ...(out.shippingLabelCost != null ? { shippingLabelCost: out.shippingLabelCost } : {}),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    return out;
  }),
);

exports._internal = {
  buildEbaySkuMap, buildEtsyListingMap, ebayOrderToSaleFields,
  etsyReceiptToSaleFields, resolveEbayStatus, ebayBuyerAddress,
  summarizeEbayTransactions, sumEtsyPayments, refetchTakeHomeForSale,
};
