const { onCall, HttpsError } = require("firebase-functions/v2/https");

const {
  isAllowedImageUrl,
  normalizeInfoTable,
  buildDescriptionFromInfoTable,
  cleanText,
  USER_AGENT,
} = require("./weverse_product");

const MAX_PREVIEW_ITEMS = 100;

// Parse a Weverse Shop "section" URL — an artist shop root, category, or
// any other listing page for an artist (anything that isn't a single sale
// page, which is handled by parseWeverseUrl in weverse_product.js).
// e.g. https://shop.weverse.io/en/shop/USD/artists/255
//      https://shop.weverse.io/en/shop/USD/artists/255/category/all
function parseWeverseShopUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.hostname !== "shop.weverse.io") return null;
  if (/\/sales\/\d+/.test(url.pathname)) return null; // that's a single-sale URL
  const match = url.pathname.match(/\/artists\/(\d+)/);
  if (!match) return null;
  return { artistId: match[1], url: url.href };
}

// A "sale-like" object has enough fields to build a preview tile. Weverse's
// dehydrated query cache nests these at different depths depending on the
// page (shop home, category grid, search), so rather than hard-coding one
// query key we walk the whole tree and collect anything shaped like a sale.
function isSaleLike(node) {
  return (
    node &&
    typeof node === "object" &&
    !Array.isArray(node) &&
    (typeof node.saleId === "number" || typeof node.saleId === "string") &&
    typeof node.name === "string"
  );
}

function collectSaleLikeNodes(root, out, seen) {
  if (!root || typeof root !== "object") return;
  if (Array.isArray(root)) {
    for (const entry of root) collectSaleLikeNodes(entry, out, seen);
    return;
  }
  if (isSaleLike(root)) {
    const key = String(root.saleId);
    if (!seen.has(key)) {
      seen.add(key);
      out.push(root);
    }
    // A sale object shouldn't nest further sale-like objects worth
    // recursing into (its own related items would be a separate query),
    // so stop here rather than descending into its fields.
    return;
  }
  for (const value of Object.values(root)) collectSaleLikeNodes(value, out, seen);
}

async function fetchWeverseShopSales(pageUrl) {
  const response = await fetch(pageUrl, {
    headers: { "User-Agent": USER_AGENT, "Accept-Language": "en" },
  });
  if (!response.ok) {
    throw new HttpsError("unavailable", `Weverse returned ${response.status}.`);
  }
  const html = await response.text();

  const match = html.match(
    /<script id="__NEXT_DATA__" type="application\/json">([\s\S]*?)<\/script>/
  );
  if (!match) throw new HttpsError("not-found", "Could not find shop data on the page.");

  let nextData;
  try {
    nextData = JSON.parse(match[1]);
  } catch {
    throw new HttpsError("internal", "Failed to parse Weverse page data.");
  }

  const queries = nextData?.props?.pageProps?.$dehydratedState?.queries ?? [];
  const sales = [];
  const seen = new Set();
  for (const query of queries) {
    collectSaleLikeNodes(query?.state?.data, sales, seen);
  }
  return sales;
}

function mapSaleToPreview(sale, artistId) {
  const price = sale.price?.salePrice ?? sale.price?.originalPrice ?? 0;
  const infoTable = normalizeInfoTable(sale.notificationInfos);
  const description = buildDescriptionFromInfoTable(
    infoTable,
    [sale.description, sale.shortDescription, sale.longDescription].map(cleanText).find(Boolean) ?? ""
  );
  const thumbnailUrl = (sale.thumbnailImageUrls ?? []).find(isAllowedImageUrl) ?? null;

  return {
    saleId: String(sale.saleId),
    artistId,
    title: sale.name ?? "",
    description: description.slice(0, 280),
    price,
    thumbnailUrl,
    artistName: sale.labelArtistInfo?.artistName ?? sale.labelArtistInfo?.name ?? "",
    saleStatus: sale.status ?? "",
    productUrl: `https://shop.weverse.io/en/shop/USD/artists/${artistId}/sales/${sale.saleId}`,
  };
}

// Preview the items on a Weverse shop/artist listing page without importing
// anything — lets the client show a selectable grid before committing.
exports.weverseShopPreview = onCall(
  { timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const parsed = parseWeverseShopUrl(request.data?.shopUrl ?? "");
    if (!parsed) {
      throw new HttpsError("invalid-argument", "Not a valid Weverse Shop section URL.");
    }

    const sales = await fetchWeverseShopSales(parsed.url);
    if (!sales.length) {
      throw new HttpsError("not-found", "No items found on that page.");
    }

    const items = sales
      .slice(0, MAX_PREVIEW_ITEMS)
      .map((sale) => mapSaleToPreview(sale, parsed.artistId));

    return { items, artistId: parsed.artistId };
  }
);

module.exports.parseWeverseShopUrl = parseWeverseShopUrl;
module.exports.fetchWeverseShopSales = fetchWeverseShopSales;
module.exports.mapSaleToPreview = mapSaleToPreview;
