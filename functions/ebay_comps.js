const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { ebayApiHost, EBAY_CLIENT_ID, EBAY_CLIENT_SECRET } = require("./ebay_auth");
const { getEbayAppTokenCached } = require("./ebay_listing");

// Retrieval only — no ranking/scoring/recommendation math. eBay has no
// "recommended price" endpoint (confirmed 2026-09-28: nothing price-
// suggestion-shaped exists in the Sell APIs, and the only sold-price data,
// the Marketplace Insights API, is limited-release/gated by a developer-
// program application we haven't confirmed access to). This function just
// hands back active comparable listings via the generally-available Browse
// API; sort/filter/display is a later, deliberately deferred UI decision.
//
// Browse API is public marketplace data — no seller account/uid involved,
// so this reuses ebay_listing.js's app-level (client_credentials) token
// cache (`getEbayAppTokenCached`, already proven working for ebayImportListing's
// item lookup) rather than a per-user OAuth token.
async function retrieveComps({ title, categoryId, condition, limit }, { fetchImpl = fetch } = {}) {
  const appToken = await getEbayAppTokenCached();
  const params = new URLSearchParams();
  params.set("q", title);
  const rawLimit = Number(limit);
  const effectiveLimit = Number.isFinite(rawLimit) ? rawLimit : 25;
  params.set("limit", String(Math.min(Math.max(effectiveLimit, 1), 50)));
  if (categoryId) params.set("category_ids", String(categoryId));
  // Browse API's filter param is itself a comma-separated "name:{values}"
  // mini-language. conditionIds are eBay's numeric condition codes (e.g.
  // 1000 = New, 3000 = Used) — this passes through whatever the caller
  // already resolved (see platform_adapters' condition mapping); no new
  // condition-name mapping is introduced here.
  if (condition) params.set("filter", `conditionIds:{${condition}}`);

  const res = await fetchImpl(
    `https://${ebayApiHost()}/buy/browse/v1/item_summary/search?${params.toString()}`,
    {
      headers: {
        Authorization: `Bearer ${appToken}`,
        "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
        "Accept-Language": "en-US",
      },
    }
  );
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new HttpsError(
      "internal",
      `eBay comp search failed (${res.status}): ${json.errors?.[0]?.message ?? JSON.stringify(json)}`
    );
  }

  const items = json.itemSummaries ?? [];
  return items.map((item) => ({
    itemId: item.itemId ?? null,
    title: item.title ?? "",
    price: item.price?.value != null ? parseFloat(item.price.value) : null,
    currency: item.price?.currency ?? "USD",
    condition: item.condition ?? null,
    itemWebUrl: item.itemWebUrl ?? null,
    imageUrl: item.image?.imageUrl ?? item.thumbnailImages?.[0]?.imageUrl ?? null,
  }));
}

/** Browse API thumbnails are `.../s-l225.jpg`; the same CDN path serves the
 *  full upload at `s-l1600` (verified 2026-10-01). Non-eBay URLs pass through. */
function fullSizeEbayImage(url) {
  if (typeof url !== "string") return url;
  return url.replace(/(\/\/i\.ebayimg\.com\/.*\/s-l)\d+(\.(?:jpg|jpeg|png|webp))$/i, "$11600$2");
}

// The "sell similar" half of a comp: Browse `getItem` returns what a search
// summary doesn't — every photo, the eBay category id, the numeric condition
// id, the catalog ePID, and the seller's item specifics (`localizedAspects`).
// Still app-token, still public marketplace data.
async function retrieveCompDetail(itemId, { fetchImpl = fetch } = {}) {
  const appToken = await getEbayAppTokenCached();
  const res = await fetchImpl(
    `https://${ebayApiHost()}/buy/browse/v1/item/${encodeURIComponent(itemId)}`,
    {
      headers: {
        Authorization: `Bearer ${appToken}`,
        "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
        "Accept-Language": "en-US",
      },
    }
  );
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new HttpsError("internal", `eBay item lookup failed (${res.status}): ${json.errors?.[0]?.message ?? ""}`);
  }
  const images = [json.image?.imageUrl, ...(json.additionalImages ?? []).map((i) => i?.imageUrl)]
    .filter(Boolean)
    .map(fullSizeEbayImage);
  const aspects = {};
  for (const a of json.localizedAspects ?? []) {
    if (a?.name && a?.value != null && String(a.value).trim()) aspects[String(a.name)] = String(a.value).trim();
  }
  return {
    itemId: json.itemId ?? itemId,
    title: json.title ?? "",
    categoryId: json.categoryId ?? null,
    categoryPath: json.categoryPath ?? null,
    conditionId: json.conditionId ?? null,
    condition: json.condition ?? null,
    epid: json.epid ?? null,
    images: [...new Set(images)],
    aspects,
    shortDescription: json.shortDescription ?? null,
  };
}

exports.ebayRetrieveComps = onCall(
  { timeoutSeconds: 30, secrets: [EBAY_CLIENT_ID, EBAY_CLIENT_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { title, categoryId, condition, limit } = request.data ?? {};
    if (!title || typeof title !== "string" || !title.trim()) {
      throw new HttpsError("invalid-argument", "title is required.");
    }

    const comps = await retrieveComps({ title, categoryId, condition, limit });
    return { comps };
  }
);

exports._internal = { retrieveComps, retrieveCompDetail, fullSizeEbayImage };
