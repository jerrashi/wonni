const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const https = require("https");
const { callAliexpressApi, AE_SECRETS } = require("./aliexpress_auth");
const { buildNewProductDoc } = require("./product_schema");
const { newProductRef, madeOnFields } = require("./client_product_id");
const { dropSingleChoice } = require("./variation_names");

const ALLOWED_IMAGE_HOSTS = [".alicdn.com", ".aliexpress-media.com"];
const MAX_IMAGE_BYTES = 10 * 1024 * 1024; // 10 MB

function isAllowedImageUrl(rawUrl) {
  try {
    const { protocol, hostname } = new URL(rawUrl);
    if (protocol !== "https:") return false;
    return ALLOWED_IMAGE_HOSTS.some((h) => hostname === h.slice(1) || hostname.endsWith(h));
  } catch {
    return false;
  }
}

// Download a remote image buffer (for re-uploading to Firebase Storage)
function downloadBuffer(url, depth = 0) {
  if (!isAllowedImageUrl(url)) return Promise.reject(new Error(`Disallowed image URL: ${url}`));
  if (depth > 2) return Promise.reject(new Error("Too many redirects"));
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return downloadBuffer(res.headers.location, depth + 1).then(resolve).catch(reject);
      }
      const chunks = [];
      let size = 0;
      res.on("data", (c) => {
        size += c.length;
        if (size > MAX_IMAGE_BYTES) { res.destroy(); return reject(new Error("Image too large")); }
        chunks.push(c);
      });
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", reject);
    }).on("error", reject);
  });
}

// Extract AliExpress item ID from a URL
function extractItemId(url) {
  const match = url.match(/\/item\/(\d+)\.html/) ?? url.match(/[?&]id=(\d+)/);
  return match?.[1] ?? null;
}

// AliExpress sku_attr is a ";"-separated list of "pid:vid#Name:Value" pairs
// (the "#Name:Value" label suffix is what carries the human-readable
// attribute — pid/vid are internal AliExpress property/value ids).
function parseSkuAttr(skuAttr) {
  if (!skuAttr || typeof skuAttr !== "string") return [];
  return skuAttr
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const labelPart = part.includes("#") ? part.slice(part.indexOf("#") + 1) : part;
      const colonIdx = labelPart.indexOf(":");
      if (colonIdx === -1) return { name: "Option", value: labelPart.trim() };
      return { name: labelPart.slice(0, colonIdx).trim() || "Option", value: labelPart.slice(colonIdx + 1).trim() };
    })
    .filter((p) => p.value);
}

// Map AliExpress SKUs (each carrying a skuAttr like "Color:Red;Size:L") into
// the product's normalized options/variants shape. Falls back to no
// options/variants (single-SKU product) if nothing structured can be parsed.
function mapAliexpressVariants(skus, productId) {
  const parsedSkus = (skus ?? []).map((s) => ({ ...s, parsed: parseSkuAttr(s.skuAttr) }));

  const dimensions = new Map(); // optionName -> ordered Set of values
  parsedSkus.forEach(({ parsed }) => {
    parsed.forEach(({ name, value }) => {
      if (!dimensions.has(name)) dimensions.set(name, new Set());
      dimensions.get(name).add(value);
    });
  });

  if (!dimensions.size) return { options: [], variants: [] };

  const options = Array.from(dimensions.entries()).map(([name, values], i) => ({
    id: `opt-${i}`,
    name,
    values: Array.from(values),
  }));

  const variants = parsedSkus.map((s, i) => {
    const optionValues = {};
    s.parsed.forEach(({ name, value }) => { optionValues[name] = value; });
    return {
      id: `v${Date.now()}${i}`,
      optionValues,
      sku: `${productId}-${i + 1}`,
      // Blank by default — a blank variant price follows the listing price.
      price: null,
      quantity: 1,
      sourcePrice: typeof s.price === "number" ? s.price : null,
      sourceVariantId: s.skuId ?? null,
      // The SUPPLIER's stock, never ours (model A: AliExpress is where we buy).
      ...(Number.isFinite(s.stock) ? { sourceStock: s.stock } : {}),
      active: true,
    };
  });

  return { options, variants };
}

// Import a product from AliExpress — called by Chrome extension (scrapedData) or web URL paste
/** `image_urls` is a ";"-joined string in ds.product.get; older docs show {string: []}. */
function aeImageUrls(v) {
  const list = typeof v === "string" ? v.split(";") : Array.isArray(v?.string) ? v.string : Array.isArray(v) ? v : [];
  return list.map((u) => String(u).trim()).filter((u) => /^https?:\/\//.test(u));
}

const MAX_IMAGES = 12;

const numOrNull = (v) => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : null;
};

/** AliExpress `detail` is store HTML (often just <img> tags) → plain text, or "". */
function htmlToText(html) {
  return String(html || "")
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>|<\/(p|div|li|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{2,}/g, "\n").trim()
    .slice(0, 4000);
}

/** package_info_dto (cm, kg) → Wonni's inch / lb + oz fields. */
function aePackage(pkg) {
  if (!pkg) return {};
  const out = {};
  const kg = numOrNull(pkg.gross_weight);
  if (kg && kg > 0) {
    const oz = kg * 35.27396;
    out.weightLbs = Math.floor(oz / 16);
    out.weightOz = Math.round((oz - out.weightLbs * 16) * 10) / 10;
  }
  const dims = [pkg.package_length, pkg.package_width, pkg.package_height].map(numOrNull);
  if (dims.every((d) => d && d > 0)) {
    [out.lengthIn, out.widthIn, out.heightIn] = dims.map((cm) => Math.round((cm / 2.54) * 10) / 10);
  }
  return out;
}

/** ae_item_properties → { "Material": "Cotton", … } (item specifics for eBay/TikTok). */
function aeProperties(props) {
  const list = props?.ae_item_property ?? (Array.isArray(props) ? props : []);
  const out = {};
  for (const p of list) {
    const name = String(p?.attr_name ?? "").trim();
    const value = String(p?.attr_value ?? "").trim();
    if (!name || !value || out[name]) continue;
    out[name] = value.slice(0, 65);
  }
  return out;
}

/**
 * ds.product.get `result` → the `scrapedData` shape the extension sends
 * ({ productId, productUrl, title, price, images, variants }) plus what the DS
 * API alone has: description, package, itemSpecifics, currency, per-SKU stock.
 * The price is the sale price a buyer pays now (offer_sale_price), else the list price.
 */
function mapDsProduct(result, itemId, productUrl) {
  const skus = result.ae_item_sku_info_dtos?.ae_item_sku_info_d_t_o ?? [];
  const priceOf = (s) => numOrNull(s.offer_sale_price) ?? numOrNull(s.sku_price) ?? 0;
  const prices = skus.map(priceOf).filter((n) => n > 0);
  const base = result.ae_item_base_info_dto ?? {};
  return {
    productId: String(itemId),
    productUrl,
    title: base.subject ?? "",
    description: htmlToText(base.mobile_detail || base.detail),
    price: prices.length ? Math.min(...prices) : 0,
    currency: skus.find((s) => s.currency_code)?.currency_code ?? base.currency_code ?? "USD",
    images: aeImageUrls(result.ae_multimedia_info_dto?.image_urls).slice(0, MAX_IMAGES),
    package: aePackage(result.package_info_dto),
    itemSpecifics: aeProperties(result.ae_item_properties),
    variants: skus.map((s) => ({
      skuId: s.sku_id,
      skuAttr: s.sku_attr,
      price: priceOf(s),
      stock: numOrNull(s.sku_available_stock ?? s.ipm_sku_stock),
    })),
  };
}

/**
 * Cheapest US delivery option from aliexpress.ds.freight.query's result →
 * {cost, minDays, maxDays, carrier}, or null. Fee is `shipping_fee_cent` (cents)
 * or a decimal `shipping_fee_format` / `shipping_fee`; free_shipping means 0.
 */
function cheapestFreight(result) {
  const opts = result?.delivery_options?.delivery_option_d_t_o ?? result?.delivery_options ?? [];
  const priced = (Array.isArray(opts) ? opts : []).map((o) => {
    let cost = o.free_shipping === true || o.free_shipping === "true" ? 0
      : o.shipping_fee_cent != null ? numOrNull(o.shipping_fee_cent) / 100
      : numOrNull(String(o.shipping_fee_format ?? o.shipping_fee ?? "").replace(/[^0-9.]/g, ""));
    if (cost == null || !Number.isFinite(cost)) cost = null;
    return { cost, minDays: numOrNull(o.min_delivery_days), maxDays: numOrNull(o.max_delivery_days), carrier: o.company ?? o.code ?? null };
  }).filter((o) => o.cost != null);
  if (!priced.length) return null;
  priced.sort((a, b) => a.cost - b.cost || (a.maxDays ?? 99) - (b.maxDays ?? 99));
  return { ...priced[0], cost: Math.round(priced[0].cost * 100) / 100 };
}

/** Best-effort shipping quote for one unit to the US; null on any failure. */
async function fetchAliexpressFreight(itemId, skuId, uid, callApi = callAliexpressApi) {
  try {
    const response = await callApi("aliexpress.ds.freight.query", {
      queryDeliveryReq: JSON.stringify({
        quantity: 1, shipToCountry: "US", productId: String(itemId), ...(skuId ? { selectedSkuId: String(skuId) } : {}),
        language: "en_US", currency: "USD", locale: "en_US",
      }),
    }, uid);
    return cheapestFreight(response?.aliexpress_ds_freight_query_response?.result);
  } catch (e) {
    console.warn(`[aliexpress freight] ${itemId}: ${e.message}`);
    return null;
  }
}

/**
 * One DS API call → scrapedData (see mapDsProduct), plus a best-effort shipping
 * quote as `shipping`. Shared with source_links.js (a pasted AliExpress link
 * inside "textToListings"). Needs the user's AliExpress connection.
 */
/** ds.product.get → mapDsProduct, no freight quote (the daily monitor's read). */
async function mapDsProductFor(itemId, productUrl, uid, { callApi = callAliexpressApi } = {}) {
  const response = await callApi("aliexpress.ds.product.get", {
    product_id: itemId,
    ship_to_country: "US",
    local_currency: "USD",
  }, uid);
  const result = response?.aliexpress_ds_product_get_response?.result;
  if (!result) throw new HttpsError("not-found", "Product not found on AliExpress.");
  return mapDsProduct(result, itemId, productUrl);
}

async function fetchAliexpressDsProduct(itemId, productUrl, uid, { callApi = callAliexpressApi } = {}) {
  const mapped = await mapDsProductFor(itemId, productUrl, uid, { callApi });
  const cheapestSku = [...mapped.variants].sort((a, b) => (a.price || Infinity) - (b.price || Infinity))[0];
  mapped.shipping = await fetchAliexpressFreight(itemId, cheapestSku?.skuId, uid, callApi);
  return mapped;
}

exports.aliexpressImportProduct = onCall(
  // No automatic Gemini call at import (opt-in only, see comment below) — no
  // geminiApiKey secret needed here. The AliExpress keys are: callAliexpressApi
  // reads them (unbound before 2026-11-23, so every DS call would have failed).
  { secrets: AE_SECRETS, timeoutSeconds: 120, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Must be signed in.");

    const { scrapedData, productUrl } = request.data;
    let product = scrapedData;

    // URL-paste flow: fetch richer data from AliExpress DS API
    if (!product && productUrl) {
      const itemId = extractItemId(productUrl);
      if (!itemId) throw new HttpsError("invalid-argument", "Could not extract product ID from URL.");
      product = await fetchAliexpressDsProduct(itemId, productUrl, uid);
    }

    if (!product) throw new HttpsError("invalid-argument", "No product data provided.");

    const db = admin.firestore();
    const storage = admin.storage().bucket();

    // Check for existing import (idempotency)
    const existing = await db.collection("products")
      .where("userId", "==", uid)
      .where("aliexpressProductId", "==", product.productId)
      .limit(1)
      .get();
    if (!existing.empty) return { productId: existing.docs[0].id };

    // Upload images to Firebase Storage
    const storedImages = [];
    for (let i = 0; i < Math.min(product.images.length, MAX_IMAGES); i++) {
      try {
        const buf = await downloadBuffer(product.images[i]);
        const path = `dropship/${uid}/${product.productId}/${i}.jpg`;
        const file = storage.file(path);
        await file.save(buf, { contentType: "image/jpeg", public: true });
        storedImages.push(`https://storage.googleapis.com/${storage.name}/${path}`);
      } catch {
        // Skip images that fail to download
      }
    }

    // Create Firestore product document
    // iOS passes its own UUID so a phone import is a phone draft (client_product_id.js).
    const { ref: docRef, madeOn } = await newProductRef(db, request.data?.productId);
    const { options, variants } = dropSingleChoice(mapAliexpressVariants(product.variants, docRef.id));
    const finalImages = storedImages.length ? storedImages : product.images.slice(0, MAX_IMAGES);
    const sourceImages = product.images.slice(0, MAX_IMAGES); // Original AliExpress CDN URLs

    // AI enrichment is opt-in now — the user runs "AI autofill" (or it happens
    // as post-time gap-fill). No automatic Gemini call at import.

    // Build new schema product
    const newProduct = buildNewProductDoc({
      ...aliexpressExtras(product),
      userId: uid,
      source: "aliexpress",
      sourceId: product.productId,
      sourceUrl: product.productUrl ?? productUrl ?? "",
      title: product.title,
      description: product.description ?? "",
      sourcePrice: product.price,
      listingPrice: typeof product.listingPrice === "number" ? product.listingPrice : null,
      sourceImages,
      images: finalImages,
      options,
      variants,
      aliexpressProductId: product.productId,
      aliexpressUrl: product.productUrl ?? productUrl ?? "",
      importedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Server-owned fields last, so nothing from the import can override them.
    await docRef.set({ ...aliexpressDocFields(product), ...newProduct, ...madeOnFields(madeOn), userId: uid, source: "aliexpress" });
    return { productId: docRef.id };
  }
);

/** Fields the DS API gives that buildNewProductDoc doesn't take by name. */
function aliexpressExtras(product) {
  const out = {};
  const cost = finiteOrNull(product.shipping?.cost);
  if (cost != null) out.sourceShippingCost = cost;
  return out;
}

const PACKAGE_FIELDS = ["weightLbs", "weightOz", "lengthIn", "widthIn", "heightIn"];
const finiteOrNull = (v) => (typeof v === "number" && Number.isFinite(v) && v >= 0 && v < 1e6 ? v : null);
const shortStr = (v, max) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);

/**
 * The rest, written after buildNewProductDoc (its allowlist drops them).
 * `product` can be the extension's scrapedData, i.e. caller-supplied, so every
 * field is picked by name and type-checked: never spread it into the doc (a
 * `package: {userId}` would otherwise move the product into another account).
 */
function aliexpressDocFields(product) {
  const out = {};
  const pkg = product.package && typeof product.package === "object" ? product.package : {};
  for (const k of PACKAGE_FIELDS) {
    const n = finiteOrNull(pkg[k]);
    if (n != null) out[k] = n;
  }
  const currency = shortStr(product.currency, 8);
  if (currency) out.sourceCurrency = currency;
  const specs = product.itemSpecifics;
  if (specs && typeof specs === "object" && !Array.isArray(specs)) {
    const clean = {};
    for (const [k, v] of Object.entries(specs).slice(0, 50)) {
      const key = shortStr(k, 65);
      const value = shortStr(v, 200);
      if (key && value) clean[key] = value;
    }
    if (Object.keys(clean).length) out.itemSpecifics = clean;
  }
  const s = product.shipping;
  if (s && typeof s === "object") {
    const cost = finiteOrNull(s.cost);
    if (cost != null) {
      out.sourceShipping = {
        cost,
        minDays: finiteOrNull(s.minDays),
        maxDays: finiteOrNull(s.maxDays),
        carrier: shortStr(s.carrier, 80),
      };
    }
  }
  return out;
}

exports.extractItemId = extractItemId;
exports._internal = { mapDsProduct, mapDsProductFor, htmlToText, aePackage, aeProperties, cheapestFreight, fetchAliexpressFreight, fetchAliexpressDsProduct, mapAliexpressVariants, aliexpressDocFields };
exports.fetchAliexpressDsProduct = fetchAliexpressDsProduct;
