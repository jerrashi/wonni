/**
 * stock_watch/weverse_adapter.js — Weverse Shop adapter for the stock watcher.
 *
 * Built on top of the existing `parseWeverseUrl` / `fetchWeverseSale` from
 * `weverse_product.js` (the network + __NEXT_DATA__ extraction already lives
 * there — this file does not reimplement it) and `mapWeverseVariantsToOptions`
 * for the "55 RM Jersey / M-L" → { Style, Size } parsing.
 *
 * `fetch()` and `normalize()` are kept as two separate functions on purpose:
 * `normalize()` is pure (raw sale object in, StockSnapshot out) so it can be
 * unit-tested against fixtures with no network involved.
 */

"use strict";

const {
  parseWeverseUrl,
  fetchWeverseSale,
  mapWeverseVariantsToOptions,
} = require("../weverse_product");

const platform = "weverse";

function matchesUrl(url) {
  return Boolean(parseWeverseUrl(url));
}

// fetch(url) -> raw adapter shape (the Weverse `sale` object, plus the
// resolved saleId/url so normalize() doesn't need to re-parse the url).
async function fetchRaw(url) {
  const parsed = parseWeverseUrl(url);
  if (!parsed) throw new Error(`Not a Weverse Shop sale URL: ${url}`);
  const sale = await fetchWeverseSale(parsed.url, parsed.saleId);
  return { sale, saleId: parsed.saleId, url: parsed.url };
}

// normalize(raw, url) -> StockSnapshot. Pure function, no network.
function normalize(raw, url) {
  const { sale, saleId } = raw;
  const price = sale.price?.salePrice ?? sale.price?.originalPrice ?? null;
  const currency = sale.price?.currency ?? sale.currency ?? null;

  const images = [
    ...(sale.thumbnailImageUrls ?? []),
    ...(sale.detailImages ?? []).map((img) => img.imageUrl).filter(Boolean),
  ].filter(Boolean);

  const description =
    [sale.description, sale.shortDescription, sale.longDescription, sale.detailDescription, sale.productDescription]
      .find((v) => typeof v === "string" && v.trim())
      ?.trim() ?? "";

  const rawVariants = (sale.option?.options ?? []).map((opt) => ({
    stockId: opt.saleStockId,
    name: opt.saleOptionName,
    price: opt.optionSalePrice ?? price,
    addPrice: opt.optionAddPrice ?? 0,
    soldOut: Boolean(opt.isSoldOut),
    maxOrderQuantity: opt.optionOrderLimit?.maxOrderQuantity ?? null,
  }));
  const { variants: mappedVariants } = mapWeverseVariantsToOptions(rawVariants);

  const variants = mappedVariants.map((v, i) => ({
    optionValues: v.optionValues,
    sku: v.sku ?? null,
    inStock: v.active !== false,
    quantityAvailable: typeof v.quantity === "number" ? v.quantity : null,
    price: typeof v.sourcePrice === "number" ? v.sourcePrice : (typeof price === "number" ? price : null),
  }));

  // Whole-sale in-stock: true unless every variant is sold out (or, with no
  // variants at all, unless the sale's own status says otherwise).
  const inStock = variants.length
    ? variants.some((v) => v.inStock)
    : String(sale.status ?? "").toUpperCase() !== "SOLD_OUT";

  const quantityAvailable = variants.length
    ? variants.reduce((sum, v) => (typeof v.quantityAvailable === "number" ? sum + v.quantityAvailable : sum), 0) || null
    : null;

  return {
    platform,
    url,
    sourceId: String(saleId),
    title: sale.name ?? "",
    description,
    images,
    inStock,
    quantityAvailable,
    price: typeof price === "number" ? price : null,
    currency,
    variants,
    fetchedAt: Date.now(),
  };
}

module.exports = {
  platform,
  matchesUrl,
  fetch: fetchRaw,
  normalize,
};
