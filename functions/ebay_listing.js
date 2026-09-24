const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { ebayRequest, ebayApiHost, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, EBAY_ENV } = require("./ebay_auth");
const {
  toEbayInventoryProduct, canonicalDescription, listingImagesFor, buildEbayVariations,
  resolveListingPrice, variantPriceOr,
} = require("./platform_adapters");
const { fillBlankFieldsInline, geminiApiKey } = require("./listing_fields");

const MARKETPLACE_ID = "EBAY_US";

// Price model: `product.listingPrice` is the single cross-platform list price
// (see platform_adapters.resolveListingPrice). A variant's own `price` is a
// deliberate per-variant override; blank ⇒ it follows `listingPrice`. Cost
// fields (`sourceCost` / `sourcePrice`) are never part of pricing.

// eBay requires a package weight on every inventory item to publish an offer
// (error 25020). Use the product's weight (lbs + oz, or a fractional lbs);
// when unset, fall back to the app's own documented default — a 6 oz light
// package, the same default ProductDetail shows in the shipping row.
// Dimensions are included only when all three are present.
function ebayPackageWeightAndSize(product) {
  const lbs = Number(product.weightLbs);
  const oz = Number(product.weightOz);
  let totalLbs = (Number.isFinite(lbs) ? lbs : 0) + (Number.isFinite(oz) ? oz : 0) / 16;
  if (!(totalLbs > 0)) totalLbs = 0.375; // 6 oz
  const pkg = { weight: { value: Math.round(totalLbs * 1000) / 1000, unit: "POUND" } };
  const [l, w, h] = [product.lengthIn, product.widthIn, product.heightIn].map(Number);
  if ([l, w, h].every((n) => Number.isFinite(n) && n > 0)) {
    pkg.dimensions = { length: l, width: w, height: h, unit: "INCH" };
  }
  return pkg;
}

// eBay stable SKU for a variant. `productId::variantId` — survives variant
// reorder/delete (Firestore ids are ~20 chars, well under eBay's 64).
// eBay SKUs must be alphanumeric and <= 50 chars (err 25707). Firestore doc
// ids are a fixed 20 alphanumeric chars, so `productId` + a stripped variant
// id can't collide across products and stays well under the limit.
function variantSkuFor(productId, variant, index) {
  const vid = String(variant?.id ?? variant?.sku ?? `v${index}`).replace(/[^A-Za-z0-9]/g, "");
  return `${productId}${vid}`.slice(0, 50);
}

// Build a `/sell/inventory/v1/offer` body. `forUpdate` omits the immutable
// keys (sku/marketplaceId/format) that eBay's updateOffer (EbayOfferDetailsWithId)
// rejects — only createOffer (EbayOfferDetailsWithKeys) accepts them.
function buildEbayOfferPayload(
  { sku, price, quantity, categoryId, description, listingPolicies, merchantLocationKey },
  { forUpdate = false } = {}
) {
  const payload = {
    availableQuantity: quantity,
    categoryId,
    listingDescription: description,
    listingPolicies,
    merchantLocationKey,
    // Always the real sell price. NEVER minimumAdvertisedPrice — that's eBay's
    // MAP-policy field, not a price, and setting it instead of `price` is why
    // multi-variant publishes used to fail with error 25016.
    pricingSummary: { price: { value: Number(price).toFixed(2), currency: "USD" } },
  };
  if (!forUpdate) {
    payload.sku = sku;
    payload.marketplaceId = MARKETPLACE_ID;
    payload.format = "FIXED_PRICE";
  }
  return payload;
}

// GET an offer by id, returning null (instead of throwing) when eBay says it's
// gone — the signal that the user deleted the listing on eBay directly, or
// eBay purged a long-unpublished offer, so we should create a fresh one.
async function getOfferOrNull(uid, offerId) {
  try {
    return await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${offerId}`);
  } catch (e) {
    const gone = e.status === 404
      || e.ebayErrors?.some((x) => [25713, 25710].includes(x.errorId));
    if (gone) return null;
    throw e;
  }
}

// Live title/price/quantity for a multi-variant listing, read directly from
// the doc's own stored pointers (inventory_item_group + each variant's own
// offer) — mirrors the already-correct pattern in `ebayGetListing`.
// Deliberately does NOT go through `resolveEbayOffer`: its `bulk_migrate_listing`
// step 409s with "already migrated" (errorId 25002) for every listing Wonni
// itself posted via the Inventory API, since there's nothing to migrate —
// that's expected, not a failure. It then silently fell through to a
// SKU/title search that can latch onto an unrelated stale offer (confirmed
// via prod logs 2026-09-16: it kept resolving a pre-variant-SKU-scheme offer
// under the bare productId SKU instead of any of the listing's real, current
// per-variant offers). When the doc already knows its own group key + offer
// IDs, use them directly — `resolveEbayOffer` is for recovery only (a lost
// pointer, or a pre-Inventory-API legacy listing).
async function readMultiVariantEbayData(uid, product) {
  const groupKey = product.ebayInventoryItemGroupKey;
  const variants = Array.isArray(product.variants) ? product.variants : [];
  const [group, perVariantOffers] = await Promise.all([
    groupKey
      ? ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item_group/${encodeURIComponent(groupKey)}`)
          .catch((e) => { if (e.status !== 404) throw e; return null; })
      : null,
    Promise.all(variants.map((v) => (v.ebayOfferId ? getOfferOrNull(uid, v.ebayOfferId) : null))),
  ]);
  const firstOffer = perVariantOffers.find(Boolean) || null;
  // "Ended" = the user (or eBay) took the listing down directly on eBay,
  // outside Wonni — none of the offers we know about are still published.
  // Surfaced as upstream drift (Path 4 of the listing-lifecycle design in
  // CLAUDE.md), not an error: the sync-diff UI's existing "keep eBay
  // version" choice already means "match Wonni to what's live on eBay",
  // which for a gone listing is exactly "mark out of stock."
  const ended = !perVariantOffers.some((o) => o?.status === "PUBLISHED");
  return {
    title: group?.title || "",
    description: firstOffer?.listingDescription ?? group?.description ?? "",
    photoCount: group?.imageUrls?.length ?? 0,
    price: firstOffer?.pricingSummary?.price?.value != null ? parseFloat(firstOffer.pricingSummary.price.value) : null,
    quantity: perVariantOffers.reduce((sum, o) => sum + (o?.availableQuantity ?? 0), 0),
    offerId: firstOffer?.offerId ?? null,
    listingId: firstOffer?.listing?.listingId ?? product.ebayListingId ?? null,
    ended,
  };
}

// True when the doc already knows its own multi-variant offer pointers —
// the signal to use `readMultiVariantEbayData` instead of `resolveEbayOffer`.
function hasKnownMultiVariantOffers(product) {
  return !!(product.ebayHasVariations && product.ebayInventoryItemGroupKey
    && Array.isArray(product.variants) && product.variants.some((v) => v.ebayOfferId));
}

// Create (or reuse) a fulfillment policy that matches `base` in every way
// except handling time. Named deterministically off the requested value so a
// later listing that wants the same handling time reuses it instead of
// spawning a duplicate every post.
async function cloneFulfillmentPolicyWithHandlingTime(uid, base, handlingTimeDays) {
  const name = `${base.name || "Wonni Shipping"} (${handlingTimeDays}d handling)`.slice(0, 64);
  try {
    const existing = await ebayRequest(
      uid, "GET",
      `/sell/account/v1/fulfillment_policy/get_by_policy_name?marketplace_id=${MARKETPLACE_ID}&name=${encodeURIComponent(name)}`
    );
    if (existing?.fulfillmentPolicyId) return existing;
  } catch (_) {
    // 404 = doesn't exist yet, fall through to create it.
  }
  try {
    const { fulfillmentPolicyId, ...rest } = base;
    const created = await ebayRequest(uid, "POST", "/sell/account/v1/fulfillment_policy", {
      ...rest,
      name,
      handlingTime: { value: handlingTimeDays, unit: "DAY" },
    });
    return created;
  } catch (e) {
    console.warn(`[getListingPolicies] Could not create ${handlingTimeDays}-day fulfillment policy, falling back to account default:`, e.message);
    return null;
  }
}

// First existing inventory location — eBay requires one to publish an offer.
async function getMerchantLocationKey(uid) {
  const result = await ebayRequest(uid, "GET", "/sell/inventory/v1/location?limit=1");
  const key = result?.locations?.[0]?.merchantLocationKey;
  if (!key) {
    throw new HttpsError(
      "failed-precondition",
      "No eBay inventory location found. Create one in Seller Hub (or via the Inventory API) with your ship-from address first."
    );
  }
  return key;
}

// eBay's Account API rejects a fulfillment policy's handlingTime above this.
// The web handling-time dropdown intentionally goes higher (matching Etsy's
// up-to-10-week options) since it's a shared cross-platform field — eBay
// just gets the closest value it can actually accept.
const EBAY_MAX_HANDLING_TIME_DAYS = 30;

// First business policy of each type — eBay offers require all three.
async function getListingPolicies(uid, handlingTimeDays) {
  if (typeof handlingTimeDays === "number" && handlingTimeDays > EBAY_MAX_HANDLING_TIME_DAYS) {
    handlingTimeDays = EBAY_MAX_HANDLING_TIME_DAYS;
  }
  const [fulfillment, payment, returns] = await Promise.all([
    ebayRequest(uid, "GET", `/sell/account/v1/fulfillment_policy?marketplace_id=${MARKETPLACE_ID}`),
    ebayRequest(uid, "GET", `/sell/account/v1/payment_policy?marketplace_id=${MARKETPLACE_ID}`),
    ebayRequest(uid, "GET", `/sell/account/v1/return_policy?marketplace_id=${MARKETPLACE_ID}`),
  ]);

  const fulfillmentPolicies = fulfillment?.fulfillmentPolicies || [];
  let matchingFulfillment = null;

  if (typeof handlingTimeDays === "number" && handlingTimeDays > 0) {
    matchingFulfillment = fulfillmentPolicies.find(
      (p) => p.handlingTime?.value === handlingTimeDays && p.handlingTime?.unit === "DAY"
    );
    // No account policy already has this handling time — picking
    // fulfillmentPolicies[0] here would silently ignore the value the user
    // chose (that's how a listing ended up back at the account default of
    // 1 business day). Clone the base policy with the requested handling
    // time instead of mutating a policy other listings may also use.
    if (!matchingFulfillment && fulfillmentPolicies[0]) {
      matchingFulfillment = await cloneFulfillmentPolicyWithHandlingTime(
        uid, fulfillmentPolicies[0], handlingTimeDays
      );
    }
  }

  const fulfillmentPolicyId = matchingFulfillment?.fulfillmentPolicyId
    || fulfillmentPolicies[0]?.fulfillmentPolicyId;
  const paymentPolicyId = payment?.paymentPolicies?.[0]?.paymentPolicyId;
  const returnPolicyId = returns?.returnPolicies?.[0]?.returnPolicyId;

  if (!fulfillmentPolicyId || !paymentPolicyId || !returnPolicyId) {
    throw new HttpsError(
      "failed-precondition",
      "Missing eBay business policies (shipping/payment/return). Opt in to business policies in Seller Hub and create one of each."
    );
  }
  return { fulfillmentPolicyId, paymentPolicyId, returnPolicyId };
}

// Resiliently resolve the eBay Offer ID for a product.
// Recovers automatically if the stored ID is a 12-digit listing ID (e.g. 147542181716), draft ID, or if offer moved.
async function resolveEbayOffer(uid, product, productId) {
  const storedId = String(product?.crossPostListingIds?.ebay || product?.ebayListingId || "").trim();

  // 1. If storedId is a 12-digit listing ID, attempt bulk_migrate_listing to convert/retrieve its Inventory API offer
  if (storedId && /^\d{12}$/.test(storedId)) {
    try {
      console.log(`[resolveEbayOffer] Attempting bulk_migrate_listing for listingId=${storedId}`);
      const migrateRes = await ebayRequest(uid, "POST", "/sell/inventory/v1/bulk_migrate_listing", {
        requests: [{ listingId: storedId }],
      });
      console.log(`[resolveEbayOffer] bulk_migrate_listing response:`, JSON.stringify(migrateRes));
      const resp = migrateRes?.responses?.[0];
      // Real response shape is `{ inventoryItems: [{ sku, offerId }, ...] }`,
      // one entry per SKU (N for a multi-variant group) — NOT `resp.offers`.
      // That wrong field name meant `migratedOfferId` was always undefined
      // and this whole branch silently no-opped even when eBay returned
      // perfectly good, current offer data (confirmed via prod logs
      // 2026-09-16: bulk_migrate_listing returned 200 with 4 live
      // inventoryItems, but the old code fell through to the much less
      // reliable SKU/group-key search below, which then latched onto a
      // stale/unrelated offerId — the source of the stale drift-check UI).
      const inventoryItems = Array.isArray(resp?.inventoryItems) ? resp.inventoryItems : [];
      const migratedOfferId = resp?.offerId || inventoryItems[0]?.offerId;
      if (migratedOfferId) {
        console.log(`[resolveEbayOffer] Successfully migrated listingId=${storedId} to offerId=${migratedOfferId}`);
        const offer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${migratedOfferId}`);
        const docRef = admin.firestore().collection("products").doc(productId);
        const updatePayload = {
          ebayOfferId: migratedOfferId,
          "crossPostListingIds.ebay": storedId,
          ebayListingId: storedId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        // Multi-variant group: bulk_migrate's inventoryItems is the
        // authoritative current SKU->offerId map for every variant. Backfill
        // it onto product.variants so a subsequent pull-sync/quantity-sum
        // (which reads product.variants[i].ebayOfferId directly, not this
        // function's single returned `offer`) reads live offers instead of
        // whatever stale ebayOfferId the doc happened to still be holding.
        if (inventoryItems.length > 1 && Array.isArray(product?.variants)) {
          const offerIdBySku = Object.fromEntries(inventoryItems.map((it) => [it.sku, it.offerId]));
          updatePayload.variants = product.variants.map((v) => (
            v.ebayVariantSku && offerIdBySku[v.ebayVariantSku]
              ? { ...v, ebayOfferId: offerIdBySku[v.ebayVariantSku] }
              : v
          ));
          if (resp?.inventoryItemGroupKey) updatePayload.ebayInventoryItemGroupKey = resp.inventoryItemGroupKey;
          delete updatePayload.ebayOfferId; // single-offer field; this is a group
        }
        await docRef.update(updatePayload);
        return { offer, offerId: migratedOfferId, sku: offer?.sku || resp?.inventoryItemGroupKey || productId, inventoryItemGroupKey: resp?.inventoryItemGroupKey };
      }
    } catch (migErr) {
      console.warn(`[resolveEbayOffer] bulk_migrate_listing for ${storedId} failed (${migErr.message}). Continuing with search...`);
    }
  }

  // 2. If storedId is present and not a 12-digit listing ID, try fetching it directly as an offerId
  if (storedId && !/^\d{12}$/.test(storedId)) {
    try {
      const offer = await ebayRequest(uid, "GET", `/sell/inventory/v1/offer/${storedId}`);
      if (offer && offer.offerId) {
        return { offer, offerId: offer.offerId, sku: offer.sku || productId };
      }
    } catch (err) {
      console.log(`[resolveEbayOffer] Direct fetch of offer ${storedId} failed (${err.message}). Searching by candidate SKUs...`);
    }
  }

  // 3. Build list of candidate SKUs to query (productId, draftId, listingId, product.sku, variant SKUs)
  const candidateSkus = new Set();
  if (productId) {
    candidateSkus.add(productId);
    candidateSkus.add(`wonni_${productId}`);
  }
  if (product?.draftId) {
    candidateSkus.add(product.draftId);
    candidateSkus.add(`wonni_${product.draftId}`);
  }
  if (product?.listingId) {
    candidateSkus.add(product.listingId);
    candidateSkus.add(`wonni_${product.listingId}`);
  }
  if (product?.sourceListingId) {
    candidateSkus.add(product.sourceListingId);
    candidateSkus.add(`wonni_${product.sourceListingId}`);
  }
  if (product?.sku) {
    candidateSkus.add(product.sku);
    candidateSkus.add(`wonni_${product.sku}`);
  }
  if (Array.isArray(product?.variants)) {
    product.variants.forEach((v) => {
      if (v.sku) candidateSkus.add(v.sku);
      if (v.ebayVariantSku) candidateSkus.add(v.ebayVariantSku);
    });
  }

  for (const querySku of candidateSkus) {
    // 3a. Check by single SKU
    try {
      const result = await ebayRequest(
        uid,
        "GET",
        `/sell/inventory/v1/offer?sku=${encodeURIComponent(querySku)}&marketplace_id=${MARKETPLACE_ID}`
      );
      const offers = result?.offers || [];
      if (offers.length > 0) {
        const targetOffer = (storedId && offers.find((o) => o.listingId === storedId || o.offerId === storedId))
          || offers.find((o) => o.status === "PUBLISHED")
          || offers[0];

        if (targetOffer?.offerId) {
          console.log(`[resolveEbayOffer] Recovered offerId=${targetOffer.offerId} (listingId=${targetOffer.listingId}) for SKU ${querySku}`);
          const docRef = admin.firestore().collection("products").doc(productId);
          const resolvedListingId = targetOffer.listingId || (storedId && /^\d{12}$/.test(storedId) ? storedId : null);
          await docRef.update({
            ebayOfferId: targetOffer.offerId,
            "crossPostListingIds.ebay": resolvedListingId,
            ebayListingId: resolvedListingId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          return { offer: targetOffer, offerId: targetOffer.offerId, sku: targetOffer.sku || querySku };
        }
      }
    } catch (skuErr) {
      console.warn(`[resolveEbayOffer] Error querying offers for SKU ${querySku}:`, skuErr.message);
    }

    // 3b. Check by inventory_item_group_key (for multi-variation listings)
    try {
      const groupResult = await ebayRequest(
        uid,
        "GET",
        `/sell/inventory/v1/offer?inventory_item_group_key=${encodeURIComponent(querySku)}&marketplace_id=${MARKETPLACE_ID}`
      );
      const groupOffers = groupResult?.offers || [];
      if (groupOffers.length > 0) {
        const targetOffer = (storedId && groupOffers.find((o) => o.listingId === storedId || o.offerId === storedId))
          || groupOffers.find((o) => o.status === "PUBLISHED")
          || groupOffers[0];

        if (targetOffer?.offerId) {
          console.log(`[resolveEbayOffer] Recovered offerId=${targetOffer.offerId} (listingId=${targetOffer.listingId}) for inventory_item_group_key ${querySku}`);
          const docRef = admin.firestore().collection("products").doc(productId);
          const resolvedListingId = targetOffer.listingId || (storedId && /^\d{12}$/.test(storedId) ? storedId : null);
          await docRef.update({
            ebayOfferId: targetOffer.offerId,
            ebayInventoryItemGroupKey: querySku,
            "crossPostListingIds.ebay": resolvedListingId,
            ebayListingId: resolvedListingId,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          return { offer: targetOffer, offerId: targetOffer.offerId, sku: targetOffer.sku || querySku, inventoryItemGroupKey: querySku };
        }
      }
    } catch (groupErr) {
      console.warn(`[resolveEbayOffer] Error querying offers for groupKey ${querySku}:`, groupErr.message);
    }
  }

  // 4. Query user's offers from eBay (up to 100) and find by storedId (listingId or offerId) or title match
  try {
    const allOffersRes = await ebayRequest(
      uid,
      "GET",
      `/sell/inventory/v1/offer?format=FIXED_PRICE&limit=100`
    );
    const allOffers = allOffersRes?.offers || [];
    if (allOffers.length > 0) {
      const matchedOffer = (storedId && allOffers.find((o) => o.listingId === storedId || o.offerId === storedId))
        || (product?.title && allOffers.find((o) => o.title?.toLowerCase() === product.title.trim().toLowerCase()))
        || (product?.title && allOffers.find((o) => o.title && (product.title.toLowerCase().includes(o.title.toLowerCase().slice(0, 20)) || o.title.toLowerCase().includes(product.title.toLowerCase().slice(0, 20)))));

      if (matchedOffer?.offerId) {
        console.log(`[resolveEbayOffer] Recovered offerId=${matchedOffer.offerId} (listingId=${matchedOffer.listingId}, SKU=${matchedOffer.sku}) from user offer list`);
        const docRef = admin.firestore().collection("products").doc(productId);
        const resolvedListingId = matchedOffer.listingId || (storedId && /^\d{12}$/.test(storedId) ? storedId : null);
        await docRef.update({
          ebayOfferId: matchedOffer.offerId,
          "crossPostListingIds.ebay": resolvedListingId,
          ebayListingId: resolvedListingId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { offer: matchedOffer, offerId: matchedOffer.offerId, sku: matchedOffer.sku || productId };
      }
    }
  } catch (allErr) {
    console.warn("[resolveEbayOffer] Error fetching user offers list:", allErr.message);
  }

  throw new HttpsError(
    "not-found",
    `No eBay offer found for product ${productId} (stored ID: ${storedId || "none"}).`
  );
}

// Fetch an application-level access token (Client Credentials grant).
// The Taxonomy API is a public lookup API that only needs an app token —
// it does NOT require a user-scoped OAuth token and has no dedicated user scope.
async function getEbayAppToken() {
  const creds = `${EBAY_CLIENT_ID.value()}:${EBAY_CLIENT_SECRET.value()}`;
  const host = ebayApiHost();
  const response = await fetch(`https://${host}/identity/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(creds).toString("base64")}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      scope: "https://api.ebay.com/oauth/api_scope",
    }).toString(),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.access_token) {
    throw new Error(`eBay app token error (${response.status}): ${json.error_description ?? JSON.stringify(json)}`);
  }
  return json.access_token;
}

// App token is valid ~2h; memoize so category + aspect lookups in one post
// don't each mint a new one.
let _appTokenCache = { token: null, exp: 0 };
async function getEbayAppTokenCached() {
  if (_appTokenCache.token && Date.now() < _appTokenCache.exp) return _appTokenCache.token;
  const token = await getEbayAppToken();
  _appTokenCache = { token, exp: Date.now() + 90 * 60 * 1000 };
  return token;
}

// Taxonomy API is a public lookup — app token, no user scope.
async function ebayTaxonomyFetch(path) {
  const appToken = await getEbayAppTokenCached();
  const res = await fetch(`https://${ebayApiHost()}${path}`, {
    headers: {
      Authorization: `Bearer ${appToken}`,
      Accept: "application/json",
      "Accept-Language": "en-US", // see ebayRestHeaders — undici's `*` default is rejected
    },
  });
  if (!res.ok) {
    const detail = await res.json().catch(() => ({}));
    throw new Error(`eBay taxonomy ${path} failed (${res.status}): ${detail?.errors?.[0]?.message ?? JSON.stringify(detail)}`);
  }
  return res.json();
}

// Auto-pick a leaf category from the title (+ the Gemini category leaf as a
// query hint when present — no extra Gemini call, just uses an existing field).
async function suggestCategoryId(uid, title, geminiCategory) {
  let query = title || "";
  if (geminiCategory) {
    const leaf = String(geminiCategory).split(">").pop().trim();
    if (leaf && !query.toLowerCase().includes(leaf.toLowerCase())) query = `${leaf} ${query}`;
  }
  query = query.trim().slice(0, 80);

  const tree = await ebayTaxonomyFetch(`/commerce/taxonomy/v1/get_default_category_tree_id?marketplace_id=${MARKETPLACE_ID}`);
  const treeId = tree?.categoryTreeId ?? "0";
  const suggestions = await ebayTaxonomyFetch(
    `/commerce/taxonomy/v1/category_tree/${treeId}/get_category_suggestions?q=${encodeURIComponent(query)}`
  );
  const categoryId = suggestions?.categorySuggestions?.[0]?.category?.categoryId;
  if (!categoryId) throw new HttpsError("not-found", "eBay could not suggest a category for this title.");
  return categoryId;
}

// All item aspects for a category: [{ name, mode, values, required }].
// mode = FREE_TEXT | SELECTION_ONLY. Returns [] on failure (the reactive
// publish-retry is the safety net).
async function getCategoryAspects(categoryId) {
  try {
    const data = await ebayTaxonomyFetch(
      `/commerce/taxonomy/v1/category_tree/0/get_item_aspects_for_category?category_id=${encodeURIComponent(categoryId)}`
    );
    return (data.aspects || []).map((a) => ({
      name: a.localizedAspectName,
      mode: a.aspectConstraint ? a.aspectConstraint.aspectMode : "FREE_TEXT",
      values: (a.aspectValues || []).map((v) => v.localizedValue),
      required: !!(a.aspectConstraint && a.aspectConstraint.aspectRequired),
      // eBay enforces its value list for variation-enabled aspects at publish
      // time even when mode is FREE_TEXT (err 25129) — e.g. apparel "Size".
      variationEnabled: !!(a.aspectConstraint && a.aspectConstraint.aspectEnabledForVariations),
    }));
  } catch (err) {
    console.warn(`[getCategoryAspects] ${err.message}`);
    return [];
  }
}

// Condition IDs a category accepts (Sell Metadata API, user token).
// null on failure → caller keeps its mapped condition.
async function getAllowedConditionIds(uid, categoryId) {
  try {
    const filter = encodeURIComponent(`categoryIds:{${categoryId}}`);
    const data = await ebayRequest(uid, "GET", `/sell/metadata/v1/marketplace/${MARKETPLACE_ID}/get_item_condition_policies?filter=${filter}`);
    const policy = (data?.itemConditionPolicies || [])[0];
    if (!policy) return null;
    return (policy.itemConditions || []).map((c) => String(c.conditionId));
  } catch (err) {
    console.warn(`[getAllowedConditionIds] ${err.message}`);
    return null;
  }
}

// ---- item aspects: proactive fill + reactive publish-error recovery --------

const KNOWN_BRANDS = [
  "BTS", "BT21", "BLACKPINK", "NewJeans", "TWICE", "Stray Kids", "SEVENTEEN",
  "TXT", "TOMORROW X TOGETHER", "ENHYPEN", "LE SSERAFIM", "IVE", "aespa",
  "NCT", "NCT 127", "NCT DREAM", "ATEEZ", "ITZY", "(G)I-DLE", "Red Velvet",
  "EXO", "SHINee", "IU", "ZEROBASEONE", "BOYNEXTDOOR", "RIIZE", "TWS",
  "Sanrio", "Hello Kitty", "Kuromi", "Cinnamoroll", "My Melody", "Pochacco",
  "Pokemon", "Nintendo", "Disney", "Line Friends", "Kakao Friends", "Pop Mart",
  "Nike", "Adidas", "Jordan", "Supreme", "Stussy", "Fear of God", "Essentials",
];

function resolveBrand(product = {}) {
  const explicit = (product.brand || "").trim();
  if (explicit && explicit !== "Generic") return explicit;
  if ((product.artistName || "").trim()) return product.artistName.trim();
  const title = product.title || "";
  for (const brand of KNOWN_BRANDS) {
    const re = new RegExp(`\\b${brand.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i");
    if (re.test(title)) return brand;
  }
  if ((product.aiSuggestedBrand || "").trim()) return product.aiSuggestedBrand.trim();
  return "Unbranded";
}

function findMatchingAspectValue(aspectMeta, title = "", optionValues = {}) {
  for (const [optName, optVal] of Object.entries(optionValues)) {
    if (typeof optVal === "string" && optVal.trim()) {
      if (optName.toLowerCase() === aspectMeta.name.toLowerCase()) return optVal.trim();
      const match = (aspectMeta.values || []).find((v) => v.toLowerCase() === optVal.toLowerCase());
      if (match) return match;
    }
  }
  const a = aspectMeta.name.toLowerCase();
  if (a === "size type") return "Regular";
  if (a === "department") {
    if (/\b(women|women's|womens|ladies)\b/i.test(title)) return "Women";
    if (/\b(men|men's|mens)\b/i.test(title)) return "Men";
    if (/\b(kids|youth|child)\b/i.test(title)) return "Kids";
    return "Unisex Adults";
  }
  if (a === "size") {
    const m = title.match(/\b(XS|S|M|L|XL|2XL|3XL|Small|Medium|Large|X-Large|XX-Large)\b/i);
    if (m) {
      const s = m[1].toUpperCase();
      return { SMALL: "S", MEDIUM: "M", LARGE: "L", "X-LARGE": "XL", "XX-LARGE": "2XL" }[s] || s;
    }
  }
  if (a === "color") {
    const m = title.match(/\b(Black|White|Red|Blue|Navy|Green|Yellow|Pink|Purple|Orange|Grey|Gray|Brown|Beige|Gold|Silver)\b/i);
    if (m) return m[1];
  }
  for (const val of aspectMeta.values || []) {
    if (val.length >= 3 && new RegExp(`\\b${val.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i").test(title)) return val;
  }
  return null;
}

function fillValueForAspect(name, categoryAspects, brand, title = "", optionValues = {}) {
  const meta = categoryAspects.find((a) => a.name === name);
  if (meta) {
    const matched = findMatchingAspectValue(meta, title, optionValues);
    if (matched) return [matched];
    if (meta.mode === "SELECTION_ONLY" && meta.values.length > 0) return [meta.values[0]];
  }
  return [brand && brand !== "Generic" && brand !== "Unbranded" ? brand : "Unbranded"];
}

// Map a user's variation value (e.g. "XXL", "Small") to the category's
// controlled value ("2XL", "S"). eBay rejects off-list values on
// SELECTION_ONLY aspects with err 25129. Returns the input unchanged when the
// category has no controlled list or nothing matches.
const SIZE_ALIASES = {
  xxs: "XXS", xs: "XS", s: "S", m: "M", l: "L", xl: "XL",
  xxl: "2XL", xxxl: "3XL", xxxxl: "4XL", xxxxxl: "5XL",
  "2xl": "2XL", "3xl": "3XL", "4xl": "4XL", "5xl": "5XL",
  small: "S", medium: "M", large: "L", "extra large": "XL", "x-large": "XL",
  "xx-large": "2XL", "xxx-large": "3XL", "one size": "One Size",
};
function normalizeVariationValue(rawValue, allowedValues) {
  const v = String(rawValue ?? "").trim();
  if (!allowedValues || !allowedValues.length || !v) return v || rawValue;
  const ci = (s) => String(s).toLowerCase();
  const exact = allowedValues.find((a) => ci(a) === ci(v));
  if (exact) return exact;
  const aliased = SIZE_ALIASES[ci(v)];
  if (aliased) {
    const hit = allowedValues.find((a) => ci(a) === ci(aliased));
    if (hit) return hit;
  }
  // Loose fallback: an allowed value that contains the user's input as a
  // substring (min 3 chars so "S"/"XL" can't swallow "One Size").
  if (v.length >= 3) {
    const partial = allowedValues.find((a) => ci(a).includes(ci(v)));
    if (partial) return partial;
  }
  return v;
}

// product.aspects satisfying every required aspect (+ Size Type / Department
// when the category has them) so the publish validates.
// { "Type": "Photo Card" } | { "Type": ["Photo Card"] } → { "Type": ["Photo Card"] }
function toAspectArrays(obj = {}) {
  return Object.fromEntries(
    Object.entries(obj)
      .filter(([, v]) => v != null && v !== "")
      .map(([k, v]) => [k, (Array.isArray(v) ? v : [v]).map(String)])
  );
}

function buildProductAspects(categoryAspects, brand, title = "", optionValues = {}, customAspects = {}) {
  const aspects = { ...customAspects };
  aspects.Brand = [brand && brand !== "Generic" ? brand : "Unbranded"];
  for (const aspect of categoryAspects) {
    if (aspects[aspect.name]) continue;
    if (!aspect.required && aspect.name !== "Size Type" && aspect.name !== "Department") continue;
    aspects[aspect.name] = fillValueForAspect(aspect.name, categoryAspects, brand, title, optionValues);
  }
  return aspects;
}

// Aspect name(s) eBay flagged as *missing/required* in a failed publish.
// Only "is missing" / "is a required field" errors — NOT "is not a valid
// value" (25129), whose parameters carry a rejected VALUE, not an aspect
// name (that's handled proactively by normalizeVariationValue). Excludes
// grading fields — those route to a condition retry, not a fabricated value.
function extractMissingAspects(ebayErrors = []) {
  const names = new Set();
  for (const err of ebayErrors) {
    const msg = err.message || "";
    if (!/is missing|is a required field|required aspect/i.test(msg)) continue;
    const m1 = msg.match(/item specific (.+?) is missing/i);
    if (m1?.[1]) names.add(m1[1].trim());
    const m2 = msg.match(/\b([A-Z][\w /-]*?)\s*(?:\(\d+\))?\s*is a required field/i);
    if (m2?.[1] && !/^(professional grader|grade)$/i.test(m2[1].trim())) names.add(m2[1].trim());
  }
  return [...names];
}

// eBay Inventory API condition enum <-> numeric condition ID.
const CONDITION_ENUM_TO_ID = {
  NEW: "1000", NEW_OTHER: "1500", NEW_WITH_DEFECTS: "1750", LIKE_NEW: "2750",
  USED_EXCELLENT: "3000", USED_VERY_GOOD: "4000", USED_GOOD: "5000",
  USED_ACCEPTABLE: "6000", FOR_PARTS_OR_NOT_WORKING: "7000",
};
const CONDITION_ID_TO_ENUM = Object.fromEntries(Object.entries(CONDITION_ENUM_TO_ID).map(([k, v]) => [v, k]));

function conditionPreferenceIds(enumName) {
  switch (enumName) {
    case "NEW": return ["1000", "1500", "3000"];
    case "NEW_OTHER": return ["1500", "1000", "3000"];
    case "LIKE_NEW": return ["2750", "1500", "3000", "4000"];
    case "USED_EXCELLENT": return ["3000", "4000", "5000", "6000"];
    case "USED_VERY_GOOD": return ["4000", "3000", "5000", "6000"];
    case "USED_GOOD": return ["5000", "4000", "3000", "6000"];
    case "USED_ACCEPTABLE": return ["6000", "5000", "3000", "7000"];
    case "FOR_PARTS_OR_NOT_WORKING": return ["7000", "6000", "3000"];
    default: return ["3000", "4000", "5000", "1000"];
  }
}

// app/iOS condition value → eBay Inventory API condition enum.
function productConditionToEbayEnum(product) {
  const raw = String(product.condition ?? product.mercariCondition ?? "new")
    .toLowerCase().replace(/[^a-z]/g, "");
  return {
    new: "NEW", newwithtags: "NEW", brandnew: "NEW",
    newwithouttags: "NEW_OTHER", newother: "NEW_OTHER",
    likenew: "LIKE_NEW", mint: "LIKE_NEW",
    good: "USED_GOOD", used: "USED_GOOD",
    fair: "USED_ACCEPTABLE",
    poor: "FOR_PARTS_OR_NOT_WORKING", forparts: "FOR_PARTS_OR_NOT_WORKING",
  }[raw] || "USED_GOOD";
}

// Pick a condition enum the category will accept.
function resolveCondition(intendedEnum, allowedIds) {
  if (!allowedIds || allowedIds.length === 0) return intendedEnum;
  const intendedId = CONDITION_ENUM_TO_ID[intendedEnum];
  if (intendedId && allowedIds.includes(intendedId)) return intendedEnum;
  for (const id of conditionPreferenceIds(intendedEnum)) {
    if (allowedIds.includes(id) && CONDITION_ID_TO_ENUM[id]) return CONDITION_ID_TO_ENUM[id];
  }
  return CONDITION_ID_TO_ENUM[allowedIds[0]] || intendedEnum;
}

// Resolve a reusable single-variant offerId for a product, or null to create
// fresh. Order: stored `ebayOfferId` (verified live) → legacy id via
// resolveEbayOffer (lazy migration) → null.
async function resolveSingleOfferId(uid, product, productId) {
  if (product.ebayOfferId) {
    const offer = await getOfferOrNull(uid, product.ebayOfferId);
    if (offer?.offerId) return offer.offerId;
    // eBay says it's gone — drop the stale pointer, fall through to create.
    await admin.firestore().collection("products").doc(productId).update({
      ebayOfferId: admin.firestore.FieldValue.delete(),
    });
  }
  // Pre-`ebayOfferId` doc, or a legacy 12-digit listingId in
  // crossPostListingIds.ebay — let resolveEbayOffer find + backfill it.
  if (product.crossPostListingIds?.ebay || product.ebayListingId) {
    try {
      const resolved = await resolveEbayOffer(uid, product, productId);
      if (resolved?.offerId) return resolved.offerId;
    } catch (_) { /* nothing to reuse */ }
  }
  return null;
}

// createOffer, with recovery when eBay says an offer already exists (25002)
// for this SKU — adopt it and push the current values.
async function createOrAdoptOffer(uid, sku, offerBody) {
  try {
    const created = await ebayRequest(uid, "POST", "/sell/inventory/v1/offer", offerBody);
    return created.offerId;
  } catch (e) {
    const dup = e.ebayErrors?.find((err) => err.errorId === 25002);
    if (!dup) throw e;
    let offerId = dup.parameters?.find((p) => p.name === "offerId")?.value;
    if (!offerId) {
      const existing = await ebayRequest(
        uid, "GET", `/sell/inventory/v1/offer?sku=${encodeURIComponent(sku)}&marketplace_id=${MARKETPLACE_ID}`
      );
      offerId = existing?.offers?.[0]?.offerId;
    }
    if (!offerId) throw e;
    const { sku: _s, marketplaceId: _m, format: _f, ...updateBody } = offerBody;
    await ebayRequest(uid, "PUT", `/sell/inventory/v1/offer/${offerId}`, updateBody);
    return offerId;
  }
}

// Publish, recovering from the two category-validation failures eBay only
// surfaces at publish time: missing required item aspects (fill the named
// aspect, retry) and a condition the category rejects (downgrade once to
// generic Used, retry). `refresh({ addedAspects, condition })` re-PUTs the
// inventory item(s)/group so the changes take effect before the next attempt.
async function publishWithRecovery({ doPublish, refresh, categoryAspects, brand, title }) {
  const addedAspects = {};
  let conditionOverride = null;
  let triedCondition = false;
  let triedTransient = false;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      return await doPublish();
    } catch (e) {
      const errs = e.ebayErrors || [];
      // eBay's own generic "system error" (25001) is transient on their end —
      // seen 2026-09-15 mid-publish with no request-side cause. One immediate
      // retry before giving up, since eBay gives no retry-after guidance.
      if (!triedTransient && errs.some((x) => x.errorId === 25001)) {
        triedTransient = true;
        console.warn("[ebay publish] eBay system error (25001) — retrying once");
        continue;
      }
      if (!triedCondition && errs.some((x) => [25021, 25059].includes(x.errorId))) {
        triedCondition = true;
        conditionOverride = "USED_EXCELLENT";
        console.warn("[ebay publish] category rejected condition — retrying as USED_EXCELLENT");
        await refresh({ addedAspects, condition: conditionOverride });
        continue;
      }
      const missing = extractMissingAspects(errs).filter((n) => !addedAspects[n]);
      if (!missing.length || attempt === 3) throw e;
      for (const n of missing) addedAspects[n] = fillValueForAspect(n, categoryAspects, brand, title, {});
      console.warn(`[ebay publish] filling missing aspects: ${missing.join(", ")}`);
      await refresh({ addedAspects, condition: conditionOverride });
    }
  }
}

// Single-variation listing: one inventory item → one offer → publish.
async function postSingleVariant(ctx) {
  const { uid, product, productId, docRef, basePrice, categoryId, listingPolicies, merchantLocationKey, title, description, categoryAspects, brand, conditionEnum } = ctx;
  const sku = productId;
  const itemQty = typeof product.quantity === "number" && product.quantity > 0 ? product.quantity : 1;
  const productAspects = buildProductAspects(categoryAspects, brand, title, {}, { ...toAspectArrays(product.geminiItemSpecifics), ...toAspectArrays(product.ebayAspects) });

  const putItem = ({ addedAspects = {}, condition } = {}) =>
    ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, {
      product: { ...toEbayInventoryProduct(product, { imageLimit: 12, title }), aspects: { ...productAspects, ...addedAspects } },
      condition: condition || conditionEnum,
      packageWeightAndSize: ebayPackageWeightAndSize(product),
      availability: { shipToLocationAvailability: { quantity: itemQty } },
    });
  await putItem();

  const offerArgs = { sku, price: basePrice, quantity: itemQty, categoryId, description, listingPolicies, merchantLocationKey };
  let offerId = await resolveSingleOfferId(uid, product, productId);
  if (offerId) {
    await ebayRequest(uid, "PUT", `/sell/inventory/v1/offer/${offerId}`, buildEbayOfferPayload(offerArgs, { forUpdate: true }));
  } else {
    offerId = await createOrAdoptOffer(uid, sku, buildEbayOfferPayload(offerArgs));
  }

  const published = await publishWithRecovery({
    doPublish: () => ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`),
    refresh: putItem,
    categoryAspects, brand, title,
  });
  const listingId = published?.listingId ?? null;

  await docRef.update({
    "crossPostStatus.ebay": "active",
    "crossPostListingIds.ebay": listingId,
    ebayOfferId: offerId,
    ebayListingId: listingId,
    ebayListingUrl: listingId ? `https://www.ebay.com/itm/${listingId}` : null,
    ebayHasVariations: false,
    ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { listingId, offerId, alreadyListed: false, hasVariations: false };
}

// Multi-variation listing: one inventory item per active variant → an
// inventory item group → one offer per variant → publishOfferByInventoryItemGroup.
// Result is ONE eBay listing with N selectable variations.
async function postMultiVariant(ctx) {
  const { uid, product, productId, docRef, basePrice, categoryId, listingPolicies, merchantLocationKey, title, description, categoryAspects, brand, conditionEnum } = ctx;
  const groupKey = productId;
  const options = Array.isArray(product.options) ? product.options : [];
  const productVariants = Array.isArray(product.variants)
    ? product.variants
    : Object.values(product.variants || {});
  const activeVariants = productVariants
    .map((v, i) => ({ v, i }))
    .filter(({ v }) => v.active !== false);
  if (activeVariants.length === 0) {
    throw new HttpsError("failed-precondition", "This product has no active variants to post.");
  }

  // Per-variant offers we already have — from the doc's stored pointers, and
  // (if the SKU is eBay-clean) a `getOffers?sku=` lookup. We do NOT use
  // `?inventory_item_group_key=` — it 400s (25707) when any member SKU has a
  // non-alphanumeric char.
  const offersBySku = {};
  for (const { v } of activeVariants) {
    if (v.ebayVariantSku && v.ebayOfferId) offersBySku[v.ebayVariantSku] = v.ebayOfferId;
  }

  // Per-variation-dimension: map user values to the category's controlled
  // values ("XXL" → "2XL") so publish doesn't reject them (err 25129). Both
  // variesBy.specifications and each variant's own value must use the mapped
  // form and stay aligned.
  const aspectByName = Object.fromEntries(categoryAspects.map((a) => [a.name.toLowerCase(), a]));
  // A variation aspect whose value list eBay enforces (SELECTION_ONLY, or
  // FREE_TEXT + variation-enabled — apparel "Size" is the latter).
  const controlledAspect = (optName) => {
    const meta = aspectByName[String(optName).toLowerCase()];
    if (!meta || !meta.values?.length) return null;
    return meta.mode === "SELECTION_ONLY" || meta.variationEnabled ? meta : null;
  };
  const mapOptionValue = (optName, val) => {
    const meta = controlledAspect(optName);
    return meta ? normalizeVariationValue(val, meta.values) : String(val);
  };

  // Pre-flight: check every variation value resolves to one of eBay's values
  // for THIS category. For a truly closed list (SELECTION_ONLY) fail here
  // with the accepted list, before creating anything on eBay. For FREE_TEXT
  // aspects that merely publish-enforce their list (Size) just warn and let
  // eBay have the final say — some FREE_TEXT aspects genuinely take custom
  // values (Color).
  {
    const ci = (s) => String(s).toLowerCase();
    const badValues = [];
    for (const opt of options) {
      const meta = controlledAspect(opt.name);
      if (!meta) continue;
      const seen = new Set();
      for (const { v } of activeVariants) {
        const raw = v.optionValues?.[opt.name];
        for (const one of Array.isArray(raw) ? raw : [raw]) {
          if (one == null || one === "" || seen.has(ci(one))) continue;
          seen.add(ci(one));
          const mapped = normalizeVariationValue(one, meta.values);
          if (!meta.values.some((a) => ci(a) === ci(mapped))) {
            if (meta.mode === "SELECTION_ONLY") {
              badValues.push({ dimension: opt.name, value: one, accepted: meta.values });
            } else {
              console.warn(`[ebay] ${opt.name} "${one}" not in eBay's list — sending as-is`);
            }
          }
        }
      }
    }
    if (badValues.length) {
      const b = badValues[0];
      throw new HttpsError(
        "failed-precondition",
        `"${b.value}" isn't a valid ${b.dimension} for this eBay category. Accepted values: ${b.accepted.slice(0, 25).join(", ")}${b.accepted.length > 25 ? ", …" : ""}.`
      );
    }
  }

  // Shared pool (`quantityVariesByVariant === false`): every variant offer
  // gets the SAME master quantity — it's one stock number tracked at the
  // product level, not summed/split across variants (see CLAUDE.md's eBay
  // listing lifecycle section, and `resolveStock` in sales.js which decrements
  // this same master field regardless of which variant actually sold).
  const sharedPoolQty = product.quantityVariesByVariant === false
    ? (typeof product.quantity === "number" && product.quantity >= 0 ? Math.floor(product.quantity) : 0)
    : null;

  const perVariant = activeVariants.map(({ v, i }) => {
    const sku = v.ebayVariantSku || variantSkuFor(productId, v, i);
    const qty = sharedPoolQty != null
      ? sharedPoolQty
      : (typeof v.quantity === "number" && v.quantity >= 0 ? Math.floor(v.quantity) : 0);
    // { "Size": ["2XL"], "Color": ["Red"] } — mapped + arrays.
    const aspects = Object.entries(v.optionValues ?? {}).reduce((acc, [k, val]) => {
      const values = (Array.isArray(val) ? val : [val]).map((x) => mapOptionValue(k, x));
      acc[k] = values;
      return acc;
    }, {});
    return { variantIndex: i, sku, qty, price: variantPriceOr(v, basePrice), aspects };
  });

  // variesBy values = exactly the (mapped) values the variants actually use,
  // deduped — so the group's dimension list and the per-variant values align.
  const variesByValues = {};
  for (const pv of perVariant) {
    for (const [k, vals] of Object.entries(pv.aspects)) {
      (variesByValues[k] ||= new Set());
      vals.forEach((x) => variesByValues[k].add(x));
    }
  }

  const sharedProduct = toEbayInventoryProduct(product, { imageLimit: 12, title });
  const packageWeightAndSize = ebayPackageWeightAndSize(product);
  // Non-varying required aspects (Brand/Type/…) live on the group; each
  // variant item carries those + its own option values (Size/Color). Drop
  // any aspect that IS a variation dimension — it belongs in variesBy, not
  // as a fixed value.
  const productAspects = buildProductAspects(categoryAspects, brand, title, {}, { ...toAspectArrays(product.geminiItemSpecifics), ...toAspectArrays(product.ebayAspects) });
  for (const opt of options) delete productAspects[opt.name];

  const putAllItems = ({ addedAspects = {}, condition } = {}) => Promise.all(
    perVariant.map((pv) => ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(pv.sku)}`, {
      product: { ...sharedProduct, aspects: { ...productAspects, ...addedAspects, ...pv.aspects } },
      condition: condition || conditionEnum,
      packageWeightAndSize,
      availability: { shipToLocationAvailability: { quantity: pv.qty } },
    }))
  );
  const putGroup = ({ addedAspects = {} } = {}) => ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item_group/${encodeURIComponent(groupKey)}`, {
    title,
    description,
    imageUrls: sharedProduct.imageUrls,
    aspects: { ...productAspects, ...addedAspects },
    variesBy: {
      specifications: options.map((opt) => ({
        name: opt.name,
        values: [...(variesByValues[opt.name] || new Set())],
      })),
    },
    variantSKUs: perVariant.map((pv) => pv.sku),
  });

  // 1. Inventory items + 2. the group.
  await putAllItems();
  await putGroup();

  // 3. One offer per variant (reuse the group's existing offers where possible).
  for (const pv of perVariant) {
    const offerArgs = {
      sku: pv.sku, price: pv.price, quantity: pv.qty,
      categoryId, description, listingPolicies, merchantLocationKey,
    };
    const existing = offersBySku[pv.sku];
    if (existing) {
      await ebayRequest(uid, "PUT", `/sell/inventory/v1/offer/${existing}`, buildEbayOfferPayload(offerArgs, { forUpdate: true }));
      pv.offerId = existing;
    } else {
      pv.offerId = await createOrAdoptOffer(uid, pv.sku, buildEbayOfferPayload(offerArgs));
    }
  }

  // 4. Publish the whole group as one multi-variation listing.
  const published = await publishWithRecovery({
    doPublish: () => ebayRequest(uid, "POST", "/sell/inventory/v1/offer/publish_by_inventory_item_group", {
      inventoryItemGroupKey: groupKey,
      marketplaceId: MARKETPLACE_ID,
    }),
    refresh: async ({ addedAspects, condition }) => {
      await putAllItems({ addedAspects, condition });
      await putGroup({ addedAspects });
    },
    categoryAspects, brand, title,
  });
  const listingId = published?.listingId ?? null;

  // Rewrite the whole `variants` array — NEVER `update({ "variants.0.x": … })`:
  // a dotted numeric field path clobbers the array into a map and drops every
  // other variant field (price/quantity/optionValues/active).
  const baseVariants = Array.isArray(product.variants)
    ? product.variants
    : Object.values(product.variants || {});
  const nextVariants = baseVariants.map((v, i) => {
    const pv = perVariant.find((p) => p.variantIndex === i);
    return pv ? { ...v, ebayVariantSku: pv.sku, ebayOfferId: pv.offerId } : v;
  });

  await docRef.update({
    "crossPostStatus.ebay": "active",
    "crossPostListingIds.ebay": listingId,
    ebayInventoryItemGroupKey: groupKey,
    ebayOfferId: admin.firestore.FieldValue.delete(), // single-variant only; clear any stale one
    ebayListingId: listingId,
    ebayListingUrl: listingId ? `https://www.ebay.com/itm/${listingId}` : null,
    ebayHasVariations: true,
    variants: nextVariants,
    ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { listingId, groupKey, alreadyListed: false, hasVariations: true, variantOfferIds: perVariant.map((pv) => pv.offerId) };
}

// One-click list a product on eBay. Single- or multi-variation; re-posting a
// previously-withdrawn product reuses its stable offer(s).
// Core create-listing logic, shared by the `ebayCreateListing` callable and
// any other server-side caller (e.g. cross_post.js's rule-driven cross-post)
// that needs to post to eBay without going through another Cloud Function
// over HTTP. Assumes `uid`/`productId` are already validated/authenticated —
// mirrors the `recordSale` / `recordSaleCore` split in sales.js.
async function ebayCreateListingCore(uid, productId) {
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

  const db = admin.firestore();
  const docRef = db.collection("products").doc(productId);
  const snap = await docRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");
  if (product.crossPostStatus?.ebay === "active") {
    return { listingId: product.crossPostListingIds?.ebay, alreadyListed: true };
  }

  // Fill any blank shared fields (description/brand/condition/tags/category
  // hint) with one Gemini call, persisted for later cross-posts. Best-effort.
  await fillBlankFieldsInline(product, productId);

  const title = (product.title ?? "").slice(0, 80); // eBay title limit
  const description = canonicalDescription(product);
  const basePrice = resolveListingPrice(product);

  const [merchantLocationKey, listingPolicies, categoryId] = await Promise.all([
    getMerchantLocationKey(uid),
    getListingPolicies(uid, product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays),
    suggestCategoryId(uid, title, product.geminiCategory || product.category),
  ]);

  // Fill eBay's category-required fields the user left blank: item aspects
  // (Brand/Type/…) from the title + known brands, and a category-valid
  // condition. Both degrade gracefully — the publish retry loop is the net.
  const [categoryAspects, allowedConditionIds] = await Promise.all([
    getCategoryAspects(categoryId),
    getAllowedConditionIds(uid, categoryId),
  ]);
  const brand = resolveBrand(product);
  const conditionEnum = resolveCondition(productConditionToEbayEnum(product), allowedConditionIds);

  const ctx = {
    uid, product, productId, docRef, basePrice, categoryId, listingPolicies,
    merchantLocationKey, title, description, categoryAspects, brand, conditionEnum,
  };
  const hasVariations = buildEbayVariations(product) !== null;
  return hasVariations ? postMultiVariant(ctx) : postSingleVariant(ctx);
}

exports.ebayCreateListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET, geminiApiKey], timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    return ebayCreateListingCore(uid, request.data?.productId);
  }
);

// Remove an eBay listing: withdraw the offer(s) so the item is no longer
// purchasable, but KEEP the stable offer pointer(s) (`ebayOfferId` /
// `ebayInventoryItemGroupKey` / `variants[i].ebayOfferId`) so a later re-post
// reuses the same offer(s) rather than creating fresh ones.
exports.ebayDeleteListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, force } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const hasEbay = product.crossPostStatus?.ebay === "active"
      || product.crossPostListingIds?.ebay
      || product.ebayOfferId
      || product.ebayInventoryItemGroupKey;
    if (!hasEbay) {
      throw new HttpsError("failed-precondition", "No eBay listing found.");
    }

    const isMultiVariant = product.ebayHasVariations || !!product.ebayInventoryItemGroupKey;

    // force=true: user has confirmed they already ended the listing on eBay
    // manually — skip the API call, just clear the Firestore record.
    if (!force) {
      try {
        if (isMultiVariant) {
          const groupKey = product.ebayInventoryItemGroupKey || productId;
          try {
            await ebayRequest(uid, "POST", "/sell/inventory/v1/offer/withdraw_by_inventory_item_group", {
              inventoryItemGroupKey: groupKey,
              marketplaceId: MARKETPLACE_ID,
            });
          } catch (withdrawErr) {
            // 25702 = nothing published to withdraw; 404 / 25713 = group already gone — all fine.
            const code = withdrawErr.ebayErrors?.[0]?.errorId;
            if (code !== 25702 && code !== 25713 && withdrawErr.status !== 404) throw withdrawErr;
          }
        } else {
          let offerId = product.ebayOfferId;
          if (!offerId) {
            try {
              offerId = (await resolveEbayOffer(uid, product, productId))?.offerId;
            } catch (_) {
              throw new HttpsError(
                "not-found",
                "No eBay offer found for this listing. If you already ended it manually on eBay, you can mark it as removed here."
              );
            }
          }
          if (offerId) {
            try {
              await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/withdraw`);
            } catch (withdrawErr) {
              const code = withdrawErr.ebayErrors?.[0]?.errorId;
              if (code !== 25702 && code !== 25713 && withdrawErr.status !== 404) throw withdrawErr;
            }
          }
        }
      } catch (e) {
        if (e instanceof HttpsError) throw e;
        const errorMsg = e.ebayErrors?.map((err) => `${err.errorId}: ${err.message}`).join("; ") || e.message;
        throw new HttpsError("internal", `Failed to remove eBay listing: ${errorMsg}`);
      }
    }

    // Clear the live-listing fields; keep the offer pointer(s) for re-posting.
    await docRef.update({
      "crossPostStatus.ebay": admin.firestore.FieldValue.delete(),
      "crossPostListingIds.ebay": admin.firestore.FieldValue.delete(),
      ebayListingId: admin.firestore.FieldValue.delete(),
      ebayListingUrl: admin.firestore.FieldValue.delete(),
      ebayLastSyncedAt: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      // KEPT: ebayHasVariations, ebayOfferId, ebayInventoryItemGroupKey, and
      // every variants[i].* (ebayVariantSku / ebayOfferId included) so a
      // re-post reuses them.
    });

    return { success: true };
  }
);

// Fetch current eBay listing details for comparison/sync
exports.ebayGetListingDetails = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const snap = await db.collection("products").doc(productId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const wonniPhotos = listingImagesFor(product);
    const wonni = {
      title: product.title ?? "",
      description: canonicalDescription(product),
      price: Number.isFinite(Number(product.listingPrice)) ? Number(product.listingPrice) : null,
      quantity: product.variants?.reduce((sum, v) => sum + (v.quantity ?? 0), 0) ?? (product.quantity ?? 1),
      photoCount: wonniPhotos.length,
      handlingTimeDays: product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays ?? null,
    };

    try {
      let ebayTitle, ebayDescription, ebayPrice, ebayQuantity, ebayPhotoCount, offerId, listingId, ended;
      if (hasKnownMultiVariantOffers(product)) {
        const data = await readMultiVariantEbayData(uid, product);
        ebayTitle = data.title;
        ebayDescription = data.description;
        ebayPrice = data.price;
        ebayQuantity = data.quantity;
        ebayPhotoCount = data.photoCount;
        offerId = data.offerId;
        listingId = data.listingId;
        ended = data.ended;
      } else {
        let offer = null, sku = null;
        try {
          ({ offer, sku } = await resolveEbayOffer(uid, product, productId));
        } catch (_) {
          // Nothing found anywhere on eBay — treat as ended, not a hard error.
        }
        ended = !offer || offer.status !== "PUBLISHED";
        let inventory = null;
        if (sku) {
          try {
            inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
          } catch {
            // Ignore inventory fetch error for multi-variant items
          }
        }
        ebayTitle = offer?.title || inventory?.product?.title || "";
        ebayDescription = offer?.listingDescription ?? "";
        ebayPrice = offer?.pricingSummary?.price?.value
          ? parseFloat(offer.pricingSummary.price.value)
          : (offer?.pricingSummary?.minimumAdvertisedPrice?.value ? parseFloat(offer.pricingSummary.minimumAdvertisedPrice.value) : null);
        ebayQuantity = inventory?.availability?.shipToLocationAvailability?.quantity ?? (offer?.availableQuantity ?? 0);
        ebayPhotoCount = inventory?.product?.imageUrls?.length ?? 0;
        offerId = offer?.offerId;
        listingId = offer?.listingId;
      }

      // Ended (user or eBay took it down directly on eBay): a gone listing's
      // title/description/price are meaningless to diff — the only real
      // drift is quantity, which is now 0. Mirror Wonni's own values for
      // everything else so the sync-diff UI's existing "keep eBay version"
      // choice reduces to exactly "mark out of stock" (see readMultiVariantEbayData).
      if (ended) {
        return {
          wonni,
          ebay: { ...wonni, quantity: 0, offerId, listingId, ended: true },
        };
      }

      return {
        wonni,
        ebay: {
          title: ebayTitle,
          description: ebayDescription,
          price: ebayPrice,
          quantity: ebayQuantity,
          photoCount: ebayPhotoCount,
          offerId,
          listingId,
        },
      };
    } catch (e) {
      throw new HttpsError("internal", `Failed to fetch eBay listing: ${e.message}`);
    }
  }
);

// Sync bidirectional: apply chosen version (wonni or ebay) to the other platform
exports.ebaySyncListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId, applyFrom } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
    if (!["wonni", "ebay"].includes(applyFrom)) throw new HttpsError("invalid-argument", "applyFrom must be 'wonni' or 'ebay'.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    try {
      const isMultiVariant = product.ebayHasVariations || !!product.ebayInventoryItemGroupKey
        || buildEbayVariations(product) !== null;

      if (isMultiVariant) {
        if (applyFrom === "wonni") {
          await syncMultiVariantToEbay(uid, product, productId, docRef);
        } else {
          await syncMultiVariantFromEbay(uid, product, productId, docRef);
        }
      } else if (applyFrom === "ebay") {
        // Pull eBay version to Wonni. First check whether the listing is
        // even still live — a gone/unpublished offer has no meaningful
        // title/description/price to pull, only "mark out of stock" (see
        // readMultiVariantEbayData's comment for the full ended-listing design).
        let offer = null, sku = null;
        try {
          ({ offer, sku } = await resolveEbayOffer(uid, product, productId));
        } catch (_) {
          // Nothing found anywhere on eBay — treat as ended.
        }
        const ended = !offer || offer.status !== "PUBLISHED";
        if (ended) {
          await docRef.update({ quantity: 0 });
        } else {
          const inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);

          const updatePayload = {
            title: offer?.title ?? product.title,
            description: offer?.listingDescription ?? product.description,
            listingPrice: offer?.pricingSummary?.price?.value
              ? parseFloat(offer.pricingSummary.price.value)
              : product.listingPrice,
          };

          if (inventory?.availability?.shipToLocationAvailability?.quantity != null) {
            updatePayload.quantity = inventory.availability.shipToLocationAvailability.quantity;
          }

          await docRef.update(updatePayload);
        }
      } else {
        // applyFrom === "wonni": push Wonni version to eBay (title,
        // description, price, photos, shipping/handling time, quantity).
        const { offerId, sku } = await resolveEbayOffer(uid, product, productId);

        const title = (product.title ?? "").slice(0, 80);
        const description = canonicalDescription(product);
        const basePrice = resolveListingPrice(product);

        const qty = typeof product.quantity === "number" && product.quantity >= 0 ? product.quantity : 1;
        const inventoryPayload = {
          product: toEbayInventoryProduct(product, { imageLimit: 12, title }),
          condition: "NEW",
          availability: { shipToLocationAvailability: { quantity: qty } },
        };

        await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, inventoryPayload);

        // Re-resolve policies for handling time updates
        const handlingTimeDays = product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays;
        let listingPolicies = null;
        try {
          listingPolicies = await getListingPolicies(uid, handlingTimeDays);
        } catch (polErr) {
          console.warn("[ebaySyncListing] Retaining existing listing policies:", polErr.message);
        }

        const offerPatchPayload = {
          listingDescription: description,
        };
        if (listingPolicies) {
          offerPatchPayload.listingPolicies = listingPolicies;
        }

        offerPatchPayload.availableQuantity = qty;
        offerPatchPayload.pricingSummary = { price: { value: basePrice.toFixed(2), currency: "USD" } };

        await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${offerId}`, offerPatchPayload);

        // Re-publish existing offer to apply changes in-place
        await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);
      }

      // Update sync timestamp
      await docRef.update({
        ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { success: true };
    } catch (e) {
      throw new HttpsError("internal", `Failed to sync listing: ${e.message}`);
    }
  }
);

// Push the Wonni doc's current data to an already-live multi-variation eBay
// listing. Reuses `postMultiVariant` — the same PUT-items → PUT-group →
// per-variant offer create-or-update → publish_by_inventory_item_group flow
// the create path uses. Each variant already carries its stable
// `ebayVariantSku` / `ebayOfferId` from the original post, so this updates
// those inventory items/offers and republishes in place rather than minting
// new SKUs or offers.
async function syncMultiVariantToEbay(uid, product, productId, docRef) {
  const title = (product.title ?? "").slice(0, 80);
  const description = canonicalDescription(product);
  const basePrice = resolveListingPrice(product);

  const [merchantLocationKey, listingPolicies, categoryId] = await Promise.all([
    getMerchantLocationKey(uid),
    getListingPolicies(uid, product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays),
    suggestCategoryId(uid, title, product.geminiCategory || product.category),
  ]);
  const [categoryAspects, allowedConditionIds] = await Promise.all([
    getCategoryAspects(categoryId),
    getAllowedConditionIds(uid, categoryId),
  ]);
  const brand = resolveBrand(product);
  const conditionEnum = resolveCondition(productConditionToEbayEnum(product), allowedConditionIds);

  await postMultiVariant({
    uid, product, productId, docRef, basePrice, categoryId, listingPolicies,
    merchantLocationKey, title, description, categoryAspects, brand, conditionEnum,
  });
}

// Pull the live eBay group + per-variant offers/inventory items back onto the
// Wonni doc. Mirrors `ebayGetListing`'s multi-variant read, but writes the
// result back: group title/description at the top level, and per-variant
// price/quantity into `product.variants`. Always read-modify-write the WHOLE
// `variants` array — a dotted `variants.N.x` update path clobbers the array
// into a map and drops every other field on each variant.
async function syncMultiVariantFromEbay(uid, product, productId, docRef) {
  const groupKey = product.ebayInventoryItemGroupKey || productId;
  let group = null;
  try {
    group = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item_group/${encodeURIComponent(groupKey)}`);
  } catch (e) {
    if (e.status !== 404) throw e;
  }

  const baseVariants = Array.isArray(product.variants) ? product.variants : Object.values(product.variants || {});
  const nextVariants = await Promise.all(baseVariants.map(async (v) => {
    if (!v.ebayOfferId && !v.ebayVariantSku) return v;
    const [offer, item] = await Promise.all([
      v.ebayOfferId ? getOfferOrNull(uid, v.ebayOfferId) : null,
      v.ebayVariantSku ? readEbayInventoryItem(uid, v.ebayVariantSku) : null,
    ]);
    const next = { ...v };
    // Ended (offer gone or unpublished) — mirrors the ended-listing handling
    // in readMultiVariantEbayData/ebaySyncListing's single-variant branch:
    // no meaningful price to pull, just mark this variant out of stock.
    if (!offer || offer.status !== "PUBLISHED") {
      next.quantity = 0;
      return next;
    }
    if (offer.pricingSummary?.price?.value != null) {
      next.price = parseFloat(offer.pricingSummary.price.value);
    }
    if (item?.availability?.shipToLocationAvailability?.quantity != null) {
      next.quantity = item.availability.shipToLocationAvailability.quantity;
    }
    return next;
  }));

  const updatePayload = { variants: nextVariants };
  if (group?.title) updatePayload.title = group.title;
  if (group?.description != null) updatePayload.description = group.description;

  await docRef.update(updatePayload);
}

// Update an eBay listing with current Wonni product data (title, description, price, images, variations/quantities, shipping)
exports.ebayUpdateListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const docRef = db.collection("products").doc(productId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    try {
      const { offerId, sku } = await resolveEbayOffer(uid, product, productId);

      const title = (product.title ?? "").slice(0, 80);
      const description = canonicalDescription(product);
      const basePrice = resolveListingPrice(product);

      // Multi-variation in-place edit isn't wired to the Inventory API's
      // item-group flow yet (a single-offer PATCH can't express N variations).
      if (buildEbayVariations(product) !== null) {
        throw new HttpsError(
          "unimplemented",
          "Editing a multi-variation eBay listing in place isn't supported yet — delete the listing and re-post it to apply changes.",
        );
      }

      const qty = typeof product.quantity === "number" && product.quantity >= 0 ? product.quantity : 1;

      // 1. Update inventory item in-place via idempotent PUT
      const inventoryPayload = {
        product: toEbayInventoryProduct(product, { imageLimit: 12, title }),
        condition: "NEW",
        availability: { shipToLocationAvailability: { quantity: qty } },
      };

      await ebayRequest(uid, "PUT", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`, inventoryPayload);

      // Re-resolve policies for handling time updates
      const handlingTimeDays = product.shippingInfo?.handlingTimeDays ?? product.handlingTimeDays;
      let listingPolicies = null;
      try {
        listingPolicies = await getListingPolicies(uid, handlingTimeDays);
      } catch (polErr) {
        console.warn("[ebayUpdateListing] Retaining existing listing policies:", polErr.message);
      }

      // 2. Update the existing offer in-place (PATCH)
      const offerPatchPayload = {
        listingDescription: description,
      };
      if (listingPolicies) {
        offerPatchPayload.listingPolicies = listingPolicies;
      }

      offerPatchPayload.availableQuantity = qty;
      offerPatchPayload.pricingSummary = { price: { value: basePrice.toFixed(2), currency: "USD" } };

      await ebayRequest(uid, "PATCH", `/sell/inventory/v1/offer/${offerId}`, offerPatchPayload);

      // 3. Re-publish the existing offer to apply changes to the live listing without deleting/recreating
      await ebayRequest(uid, "POST", `/sell/inventory/v1/offer/${offerId}/publish`);

      // Update last-synced timestamp
      await docRef.update({
        ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { success: true };
    } catch (e) {
      throw new HttpsError("internal", `Failed to update eBay listing: ${e.message}`);
    }
  }
);

// Pull sync: check eBay listing drift against local Wonni product
exports.ebayPullSync = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { productId } = request.data;
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const db = admin.firestore();
    const snap = await db.collection("products").doc(productId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    try {
      let ebayTitle, ebayPrice, ebayQuantity, offerId, listingId, ended;
      if (hasKnownMultiVariantOffers(product)) {
        const data = await readMultiVariantEbayData(uid, product);
        ebayTitle = data.title;
        ebayPrice = data.price;
        ebayQuantity = data.quantity;
        offerId = data.offerId;
        listingId = data.listingId;
        ended = data.ended;
      } else {
        let offer = null, sku = null;
        try {
          ({ offer, sku } = await resolveEbayOffer(uid, product, productId));
        } catch (_) {
          // Nothing found anywhere on eBay — treat as ended, not a hard error.
        }
        ended = !offer || offer.status !== "PUBLISHED";
        let inventory = null;
        if (sku) {
          try {
            inventory = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
          } catch (_) {}
        }
        ebayTitle = offer?.title || inventory?.product?.title || "";
        ebayPrice = offer?.pricingSummary?.price?.value
          ? parseFloat(offer.pricingSummary.price.value)
          : (offer?.pricingSummary?.minimumAdvertisedPrice?.value ? parseFloat(offer.pricingSummary.minimumAdvertisedPrice.value) : null);
        ebayQuantity = inventory?.availability?.shipToLocationAvailability?.quantity ?? (offer?.availableQuantity ?? 0);
        offerId = offer?.offerId;
        listingId = offer?.listingId;
      }

      const localTitle = product.title ?? "";
      const localPrice = Number(product.listingPrice);
      const localQuantity = product.variants?.reduce((sum, v) => sum + (v.quantity ?? 0), 0) ?? (product.quantity ?? 1);

      // Ended (taken down directly on eBay): title/price of a gone listing
      // aren't meaningful drift — surface only the quantity→0 row, so
      // "keep eBay version" in the sync-diff UI means exactly "mark out of
      // stock" (see readMultiVariantEbayData's comment for the full design).
      const diff = [];
      if (ended) {
        ebayQuantity = 0;
        if (localQuantity !== 0) diff.push({ field: "quantity", wonni: localQuantity, external: 0 });
      } else {
        if (ebayTitle && ebayTitle !== localTitle) {
          diff.push({ field: "title", wonni: localTitle, external: ebayTitle });
        }
        if (ebayPrice != null && Number.isFinite(localPrice) && Math.abs(ebayPrice - localPrice) > 0.01) {
          diff.push({ field: "price", wonni: localPrice, external: ebayPrice });
        }
        if (ebayQuantity != null && ebayQuantity !== localQuantity) {
          diff.push({ field: "quantity", wonni: localQuantity, external: ebayQuantity });
        }
      }

      const hasDrift = diff.length > 0;

      return {
        hasDrift,
        diff,
        ebayData: {
          title: ebayTitle,
          price: ebayPrice,
          quantity: ebayQuantity,
          offerId,
          listingId,
          ended,
        },
        lastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
    } catch (e) {
      console.warn("eBay pull sync check error:", e.message);
      return { hasDrift: false, diff: [], error: e.message };
    }
  }
);

// Import pull sync changes into local Wonni product
exports.ebayImportPullSync = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

  const { productId, fields } = request.data;
  if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");
  if (!fields || typeof fields !== "object") throw new HttpsError("invalid-argument", "Missing fields to update.");

  const db = admin.firestore();
  const docRef = db.collection("products").doc(productId);
  const snap = await docRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Product not found.");

  const product = snap.data();
  if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

  const updatePayload = {
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    ebayLastSyncedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (fields.title) updatePayload.title = fields.title;
  if (typeof fields.price === "number") updatePayload.listingPrice = fields.price;
  if (typeof fields.quantity === "number") {
    if (product.ebayHasVariations && Array.isArray(product.variants)) {
      // Rewrite the whole array — a dotted `variants.N.x` path clobbers it to a map.
      updatePayload.variants = product.variants.map((v) => ({ ...v, quantity: Math.max(0, fields.quantity) }));
    } else {
      updatePayload.quantity = fields.quantity;
    }
  }

  await docRef.update(updatePayload);
  return { success: true };
});

// Fetch ANY eBay listing by its item id (Browse API, app token, no
// ownership check) — used to seed a new product from an existing eBay
// listing (iOS's "paste an eBay URL" import). `fetchImpl` is injectable so
// this is testable without a live eBay call. Accept-Language pinned to
// en-US: undici's default `*` value gets rejected by eBay error 25709 on
// REST calls (see wonni-repo memory on this).
async function ebayImportListingCore(itemId, { fetchImpl = fetch } = {}) {
  const appToken = await getEbayAppTokenCached();
  const res = await fetchImpl(
    `https://${ebayApiHost()}/buy/browse/v1/item/get_item_by_legacy_id?legacy_item_id=${encodeURIComponent(itemId)}`,
    {
      headers: {
        Authorization: `Bearer ${appToken}`,
        "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
        "Accept-Language": "en-US",
        "Content-Language": "en-US",
      },
    }
  );
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new HttpsError(
      "not-found",
      `eBay item ${itemId} not found or unavailable (${res.status}): ${json.errors?.[0]?.message ?? JSON.stringify(json)}`
    );
  }

  const price = parseFloat(json.price?.value ?? "0");
  const imageUrls = [json.image?.imageUrl, ...(json.additionalImages ?? []).map((i) => i.imageUrl)].filter(Boolean);

  return {
    title: json.title ?? "",
    price: Number.isFinite(price) ? price : 0,
    description: (json.shortDescription ?? json.description ?? "").toString(),
    imageUrls,
    condition: json.condition ?? "",
  };
}

exports.ebayImportListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const { itemId } = request.data ?? {};
    if (!itemId) throw new HttpsError("invalid-argument", "Missing itemId.");
    return ebayImportListingCore(itemId);
  }
);

// READ: the full current state of a product's eBay listing, pulled live from
// the Inventory API. Single- or multi-variation. Uses the stable pointers on
// the product doc (ebayOfferId / ebayInventoryItemGroupKey /
// variants[i].ebayOfferId) — no reliance on the group-key offer query.
async function readEbayInventoryItem(uid, sku) {
  try {
    return await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item/${encodeURIComponent(sku)}`);
  } catch (e) {
    if (e.status === 404) return null;
    throw e;
  }
}

function shapeOffer(o) {
  if (!o) return null;
  return {
    offerId: o.offerId,
    sku: o.sku,
    status: o.status, // PUBLISHED | UNPUBLISHED
    price: o.pricingSummary?.price?.value != null ? parseFloat(o.pricingSummary.price.value) : null,
    availableQuantity: o.availableQuantity ?? null,
    categoryId: o.categoryId ?? null,
    listingId: o.listing?.listingId ?? null,
    listingStatus: o.listing?.listingStatus ?? null, // ACTIVE | ENDED | ...
    soldQuantity: o.listing?.soldQuantity ?? 0,
  };
}

exports.ebayGetListing = onCall(
  { secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET], timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");
    const { productId } = request.data ?? {};
    if (!productId) throw new HttpsError("invalid-argument", "Missing productId.");

    const snap = await admin.firestore().collection("products").doc(productId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Product not found.");
    const product = snap.data();
    if (product.userId !== uid) throw new HttpsError("permission-denied", "Not your product.");

    const hasVariations = product.ebayHasVariations || !!product.ebayInventoryItemGroupKey;
    const variants = Array.isArray(product.variants) ? product.variants : Object.values(product.variants || {});

    try {
      if (hasVariations) {
        const groupKey = product.ebayInventoryItemGroupKey || productId;
        let group = null;
        try {
          group = await ebayRequest(uid, "GET", `/sell/inventory/v1/inventory_item_group/${encodeURIComponent(groupKey)}`);
        } catch (e) {
          if (e.status !== 404) throw e;
        }

        const rows = await Promise.all(
          variants
            .filter((v) => v.ebayOfferId || v.ebayVariantSku)
            .map(async (v) => {
              const [offer, item] = await Promise.all([
                v.ebayOfferId ? getOfferOrNull(uid, v.ebayOfferId) : null,
                v.ebayVariantSku ? readEbayInventoryItem(uid, v.ebayVariantSku) : null,
              ]);
              return {
                sku: v.ebayVariantSku ?? null,
                optionValues: item?.product?.aspects ?? null,
                quantity: item?.availability?.shipToLocationAvailability?.quantity ?? null,
                condition: item?.condition ?? null,
                packageWeightAndSize: item?.packageWeightAndSize ?? null,
                offer: shapeOffer(offer),
              };
            })
        );

        const anyLive = rows.find((r) => r.offer?.listingStatus === "ACTIVE");
        return {
          productId,
          hasVariations: true,
          found: !!group || rows.some((r) => r.offer || r.optionValues),
          listingId: anyLive?.offer?.listingId ?? product.ebayListingId ?? null,
          listingStatus: anyLive ? "ACTIVE" : (rows.some((r) => r.offer) ? "NOT_PUBLISHED" : "GONE"),
          listingUrl: product.ebayListingUrl ?? null,
          inventoryItemGroupKey: groupKey,
          group: group && {
            title: group.title ?? null,
            description: group.description ?? null,
            imageCount: group.imageUrls?.length ?? 0,
            variesBy: group.variesBy?.specifications ?? null,
            variantSKUs: group.variantSKUs ?? [],
          },
          variants: rows,
          totalSold: rows.reduce((s, r) => s + (r.offer?.soldQuantity ?? 0), 0),
        };
      }

      // single-variant
      const offerId = product.ebayOfferId
        || (/^\d{12}$/.test(String(product.crossPostListingIds?.ebay || "")) ? null : product.crossPostListingIds?.ebay);
      const [offer, item] = await Promise.all([
        offerId ? getOfferOrNull(uid, offerId) : null,
        readEbayInventoryItem(uid, productId),
      ]);
      return {
        productId,
        hasVariations: false,
        found: !!(offer || item),
        listingId: offer?.listing?.listingId ?? product.ebayListingId ?? null,
        listingStatus: offer?.listing?.listingStatus ?? (offer ? "NOT_PUBLISHED" : "GONE"),
        listingUrl: product.ebayListingUrl ?? null,
        title: item?.product?.title ?? null,
        description: offer?.listingDescription ?? null,
        imageCount: item?.product?.imageUrls?.length ?? 0,
        condition: item?.condition ?? null,
        quantity: item?.availability?.shipToLocationAvailability?.quantity ?? null,
        packageWeightAndSize: item?.packageWeightAndSize ?? null,
        aspects: item?.product?.aspects ?? null,
        offer: shapeOffer(offer),
      };
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      const msg = e.ebayErrors?.map((x) => `${x.errorId}: ${x.message}`).join("; ") || e.message;
      throw new HttpsError("internal", `Failed to read eBay listing: ${msg}`);
    }
  }
);

module.exports = {
  ebayCreateListing: exports.ebayCreateListing,
  ebayDeleteListing: exports.ebayDeleteListing,
  ebayUpdateListing: exports.ebayUpdateListing,
  ebayGetListing: exports.ebayGetListing,
  ebayGetListingDetails: exports.ebayGetListingDetails,
  ebaySyncListing: exports.ebaySyncListing,
  ebayPullSync: exports.ebayPullSync,
  ebayImportPullSync: exports.ebayImportPullSync,
  ebayImportListing: exports.ebayImportListing,
  // shared helpers (used by sales.js cascade)
  variantSkuFor,
  ebayPackageWeightAndSize,
  // testable core (used by functions/test/ebay_import_listing.test.js)
  _internal: { ebayImportListingCore, ebayCreateListingCore },
};
