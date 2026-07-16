const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { downloadBuffer, savePublicBuffer } = require("./product_media");

const MAX_IMAGES = 24;
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

const DESCRIPTION_FIELDS = new Set([
  "Product material",
  "Size (cm)",
  "Contents",
  "Manufacturer (Importer)",
  "Country of manufacture",
  "Year and month of manufacture",
  "Information that confirms that the product has been certified or permitted by law",
  "Precautions for handling",
  "Quality assurance standards",
  "Name",
]);

function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeInfoTable(notificationInfos) {
  if (!Array.isArray(notificationInfos)) return [];

  return notificationInfos
    .map((entry) => {
      if (typeof entry === "string") {
        return { label: "Info", value: cleanText(entry) };
      }

      const label = cleanText(
        entry.label ??
          entry.title ??
          entry.name ??
          entry.key ??
          entry.itemName ??
          entry.notificationInfoName ??
          entry.notificationTitle
      );
      const value = cleanText(
        entry.value ??
          entry.content ??
          entry.text ??
          entry.description ??
          entry.notificationInfoValue ??
          entry.notificationContent ??
          entry.detail
      );

      return { label, value };
    })
    .filter((entry) => entry.label && entry.value);
}

function buildDescriptionFromInfoTable(infoTable, fallbackText = "") {
  const lines = infoTable
    .filter((entry) => DESCRIPTION_FIELDS.has(entry.label))
    .map((entry) => `${entry.label}: ${entry.value}`);

  return lines.length ? lines.join("\n\n") : cleanText(fallbackText);
}

function isAllowedImageUrl(rawUrl) {
  try {
    const { protocol, hostname } = new URL(rawUrl);
    if (protocol !== "https:") return false;
    return hostname.endsWith(".weverseshop.io") || hostname === "shop.weverse.io";
  } catch {
    return false;
  }
}

// Parse a Weverse Shop sale URL, e.g.
// https://shop.weverse.io/en/shop/USD/artists/255/sales/64536
function parseWeverseUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.hostname !== "shop.weverse.io") return null;
  const match = url.pathname.match(/\/artists\/(\d+)\/sales\/(\d+)/);
  if (!match) return null;
  return { artistId: match[1], saleId: match[2], url: url.href };
}

// Fetch the sale page and pull the sale object out of the Next.js dehydrated state
async function fetchWeverseSale(pageUrl, saleId) {
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
  if (!match) throw new HttpsError("not-found", "Could not find product data on the page.");

  let nextData;
  try {
    nextData = JSON.parse(match[1]);
  } catch {
    throw new HttpsError("internal", "Failed to parse Weverse page data.");
  }

  const queries = nextData?.props?.pageProps?.$dehydratedState?.queries ?? [];
  const saleQuery = queries.find((q) => {
    const key = q.queryKey ?? [];
    return String(key[0] ?? "").includes("/sales/") && String(key[1]?.saleId) === String(saleId);
  });
  const sale = saleQuery?.state?.data;
  if (!sale?.saleId) throw new HttpsError("not-found", "Sale not found on Weverse page.");
  return sale;
}

// ── Import policy ─────────────────────────────────────────────────────────────
// Decides whether a Weverse sale is safe to import as a dropship draft.
// Return { ok: true } to allow, or { ok: false, reason: "..." } to block.
function validateSaleForImport(sale) {
  // TODO: encode a stronger policy once we’ve tested the end-to-end flow.
  return { ok: true };
}

function mapSaleToProduct(sale, sourceUrl) {
  const price = sale.price?.salePrice ?? sale.price?.originalPrice ?? 0;
  const infoTable = normalizeInfoTable(sale.notificationInfos);
  const description = buildDescriptionFromInfoTable(
    infoTable,
    [
      sale.description,
      sale.shortDescription,
      sale.longDescription,
      sale.detailDescription,
      sale.productDescription,
    ].map(cleanText).find(Boolean) ?? ""
  );

  const images = [
    ...(sale.thumbnailImageUrls ?? []).map((url) => ({ url, kind: "thumbnail", width: null, height: null })),
    ...(sale.detailImages ?? []).map((img) => ({
      url: img.imageUrl,
      kind: "detail",
      width: typeof img.width === "number" ? img.width : null,
      height: typeof img.height === "number" ? img.height : null,
    })),
  ].filter((entry) => entry.url && isAllowedImageUrl(entry.url));

  const variants = (sale.option?.options ?? []).map((opt) => ({
    stockId: opt.saleStockId,
    name: opt.saleOptionName,
    price: opt.optionSalePrice ?? price,
    addPrice: opt.optionAddPrice ?? 0,
    soldOut: Boolean(opt.isSoldOut),
    maxOrderQuantity: opt.optionOrderLimit?.maxOrderQuantity ?? null,
  }));

  return {
    title: sale.name ?? "",
    price,
    description,
    infoTable,
    images: images.slice(0, MAX_IMAGES).map((image) => image.url),
    imageAssets: images.slice(0, MAX_IMAGES),
    variants,
    artistName: sale.labelArtistInfo?.artistName ?? sale.labelArtistInfo?.name ?? "",
    saleStatus: sale.status ?? "",
    preOrder: sale.preOrder?.enablePreOrder
      ? {
          deliveryStartAt: sale.preOrder.deliveryStartAt ?? null,
          deliveryEndAt: sale.preOrder.deliveryEndAt ?? null,
        }
      : null,
    sourceUrl,
  };
}

// Import a product from a Weverse Shop sale URL (URL-paste flow, no extension needed)
exports.weverseImportProduct = onCall(
  { timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const parsed = parseWeverseUrl(request.data?.productUrl ?? "");
    if (!parsed) {
      throw new HttpsError("invalid-argument", "Not a valid Weverse Shop sale URL.");
    }

    const sale = await fetchWeverseSale(parsed.url, parsed.saleId);

    const verdict = validateSaleForImport(sale);
    if (!verdict.ok) {
      throw new HttpsError("failed-precondition", verdict.reason ?? "Sale cannot be imported.");
    }

    const product = mapSaleToProduct(sale, parsed.url);

    const db = admin.firestore();
    const storage = admin.storage().bucket();

    // Idempotency: one draft per user per sale
    const existing = await db
      .collection("products")
      .where("userId", "==", uid)
      .where("weverseSaleId", "==", parsed.saleId)
      .limit(1)
      .get();
    if (!existing.empty) return { productId: existing.docs[0].id, existing: true };

    // Re-host images in Firebase Storage so listings don't depend on Weverse CDN
    const storedImages = [];
    const storedImageAssets = [];
    for (let i = 0; i < product.imageAssets.length; i++) {
      try {
        const sourceAsset = product.imageAssets[i];
        const buffer = await downloadBuffer(sourceAsset.url);
        const ext = sourceAsset.url.endsWith(".png") ? "png" : "jpg";
        const path = `dropship/${uid}/weverse-${parsed.saleId}/${i}.${ext}`;
        const file = storage.file(path);
        const storedUrl = await savePublicBuffer(storage.name, file, buffer, ext === "png" ? "image/png" : "image/jpeg");
        storedImages.push(storedUrl);
        storedImageAssets.push({ ...sourceAsset, url: storedUrl, sourceUrl: sourceAsset.url });
      } catch {
        // Skip images that fail to download
      }
    }

    const docRef = db.collection("products").doc();
    await docRef.set({
      userId: uid,
      source: "weverse",
      weverseSaleId: parsed.saleId,
      weverseArtistId: parsed.artistId,
      sourceUrl: product.sourceUrl,
      title: product.title,
      description: product.description,
      images: storedImages.length ? storedImages : product.images,
      imageAssets: storedImageAssets.length ? storedImageAssets : product.imageAssets,
      weverseInfoTable: product.infoTable,
      sourcePrice: product.price,
      // Kept for compatibility with Dashboard/ListModal which read aliexpressPrice
      aliexpressPrice: product.price,
      suggestedSellPrice: null,
      variants: product.variants,
      artistName: product.artistName,
      saleStatus: product.saleStatus,
      preOrder: product.preOrder,
      listingStatus: { ebay: "draft", mercari: "draft", etsy: "draft" },
      tiktokStatus: "draft",
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { productId: docRef.id };
  }
);
