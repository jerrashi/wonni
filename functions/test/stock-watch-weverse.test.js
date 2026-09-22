/**
 * stock-watch-weverse.test.js — pure normalize() for the Weverse stock-watch
 * adapter, against fixture `sale` objects (no network). Mirrors the fields
 * mapSaleToProduct() in weverse_product.js already reads:
 *   sale.price.{salePrice,originalPrice}, sale.option.options[].{
 *     saleOptionName, optionSalePrice, isSoldOut, optionOrderLimit.maxOrderQuantity
 *   }, sale.status, sale.thumbnailImageUrls, sale.detailImages, sale.preOrder.
 */

"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");

const weverseAdapter = require("../stock_watch/weverse_adapter");

const URL = "https://shop.weverse.io/en/shop/USD/artists/255/sales/64536";

function makeRaw(sale, saleId = "64536") {
  return { sale, saleId, url: URL };
}

test("matchesUrl: recognizes Weverse sale urls, rejects others", () => {
  assert.equal(weverseAdapter.matchesUrl(URL), true);
  assert.equal(weverseAdapter.matchesUrl("https://example.com/sales/1"), false);
  assert.equal(weverseAdapter.matchesUrl("not a url"), false);
});

test("normalize: single-variant sale", () => {
  const sale = {
    name: "Photocard Set",
    status: "ON_SALE",
    price: { salePrice: 20, originalPrice: 25 },
    thumbnailImageUrls: ["https://cdn.weverseshop.io/thumb.jpg"],
    detailImages: [{ imageUrl: "https://cdn.weverseshop.io/detail.jpg", width: 800, height: 600 }],
    option: {
      options: [
        {
          saleStockId: "s1",
          saleOptionName: "1 Photocard Set",
          optionSalePrice: 20,
          isSoldOut: false,
          optionOrderLimit: { maxOrderQuantity: 5 },
        },
      ],
    },
  };

  const snapshot = weverseAdapter.normalize(makeRaw(sale), URL);

  assert.equal(snapshot.platform, "weverse");
  assert.equal(snapshot.sourceId, "64536");
  assert.equal(snapshot.url, URL);
  assert.equal(snapshot.title, "Photocard Set");
  assert.equal(snapshot.price, 20);
  assert.equal(snapshot.inStock, true);
  assert.equal(snapshot.variants.length, 1);
  assert.deepEqual(snapshot.variants[0].optionValues, { Style: "Photocard Set" });
  assert.equal(snapshot.variants[0].inStock, true);
  assert.equal(snapshot.variants[0].quantityAvailable, 5);
  assert.equal(snapshot.variants[0].price, 20);
  assert.deepEqual(snapshot.images, [
    "https://cdn.weverseshop.io/thumb.jpg",
    "https://cdn.weverseshop.io/detail.jpg",
  ]);
  assert.equal(typeof snapshot.fetchedAt, "number");
});

test("normalize: multi-variant sale with Style + Size axes", () => {
  const sale = {
    name: "RM Jersey",
    status: "ON_SALE",
    price: { salePrice: 55, originalPrice: 60 },
    thumbnailImageUrls: [],
    detailImages: [],
    option: {
      options: [
        {
          saleStockId: "st1",
          saleOptionName: "1 RM Jersey / M-L",
          optionSalePrice: 55,
          isSoldOut: false,
          optionOrderLimit: { maxOrderQuantity: 3 },
        },
        {
          saleStockId: "st2",
          saleOptionName: "2 RM Jersey / XL-XXL",
          optionSalePrice: 55,
          isSoldOut: false,
          optionOrderLimit: { maxOrderQuantity: 2 },
        },
        {
          saleStockId: "st3",
          saleOptionName: "3 Jimin Jersey / M-L",
          optionSalePrice: 55,
          isSoldOut: false,
          optionOrderLimit: { maxOrderQuantity: 4 },
        },
      ],
    },
  };

  const snapshot = weverseAdapter.normalize(makeRaw(sale), URL);

  assert.equal(snapshot.variants.length, 3);
  // Trailing "Jersey" common word stripped -> Style reads as member name only.
  assert.deepEqual(snapshot.variants[0].optionValues, { Style: "RM", Size: "M-L" });
  assert.deepEqual(snapshot.variants[1].optionValues, { Style: "RM", Size: "XL-XXL" });
  assert.deepEqual(snapshot.variants[2].optionValues, { Style: "Jimin", Size: "M-L" });
  assert.equal(snapshot.quantityAvailable, 9);
  assert.equal(snapshot.inStock, true);
});

test("normalize: a sold-out variant is reflected per-variant and can still leave the sale in stock", () => {
  const sale = {
    name: "Keyring Set",
    status: "ON_SALE",
    price: { salePrice: 10 },
    thumbnailImageUrls: [],
    detailImages: [],
    option: {
      options: [
        {
          saleStockId: "k1",
          saleOptionName: "1 RM Keyring",
          optionSalePrice: 10,
          isSoldOut: true,
          optionOrderLimit: { maxOrderQuantity: 0 },
        },
        {
          saleStockId: "k2",
          saleOptionName: "2 Jimin Keyring",
          optionSalePrice: 10,
          isSoldOut: false,
          optionOrderLimit: { maxOrderQuantity: 5 },
        },
      ],
    },
  };

  const snapshot = weverseAdapter.normalize(makeRaw(sale), URL);

  assert.equal(snapshot.variants.length, 2);
  assert.equal(snapshot.variants[0].inStock, false);
  assert.equal(snapshot.variants[1].inStock, true);
  // Sale as a whole is in stock because at least one variant is.
  assert.equal(snapshot.inStock, true);
});

test("normalize: every variant sold out -> sale is out of stock", () => {
  const sale = {
    name: "Sold Out Item",
    status: "ON_SALE",
    price: { salePrice: 15 },
    thumbnailImageUrls: [],
    detailImages: [],
    option: {
      options: [
        {
          saleStockId: "x1",
          saleOptionName: "1 Only Style",
          optionSalePrice: 15,
          isSoldOut: true,
          optionOrderLimit: { maxOrderQuantity: 0 },
        },
      ],
    },
  };

  const snapshot = weverseAdapter.normalize(makeRaw(sale), URL);
  assert.equal(snapshot.inStock, false);
});
