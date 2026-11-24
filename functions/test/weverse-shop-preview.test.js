const test = require("node:test");
const assert = require("node:assert/strict");
const { mapSaleToPreview } = require("../weverse_shop.js");

// Shape copied from a live shop.weverse.io artist page (2026-11-24).
const productCard = {
  saleId: 75379,
  status: "TO_BE_SOLD",
  thumbnailImageUrl: "https://cdn-contents.weverseshop.io/public/shop/efbf9a20bad2825afd43cbb0c66915fb.jpg",
  labelArtistId: 255,
  artistName: "CORTIS",
  name: "[COER 1st Anniv]CORTIS Official Light Stick Cradle",
  price: { originalPrice: 19.14, salePrice: 19.14 },
};

test("regression: shop-grid productCards use a single thumbnailImageUrl", () => {
  const preview = mapSaleToPreview(productCard, "255");
  assert.equal(preview.thumbnailUrl, productCard.thumbnailImageUrl);
  assert.equal(preview.artistName, "CORTIS");
  assert.equal(preview.price, 19.14);
});

test("sale objects with a thumbnailImageUrls array still work", () => {
  const preview = mapSaleToPreview(
    { saleId: 1, name: "x", thumbnailImageUrls: ["http://evil.test/a.jpg", "https://cdn.weverseshop.io/b.jpg"] },
    "1",
  );
  assert.equal(preview.thumbnailUrl, "https://cdn.weverseshop.io/b.jpg");
});

test("a non-Weverse thumbnail is dropped", () => {
  const preview = mapSaleToPreview({ saleId: 2, name: "y", thumbnailImageUrl: "https://evil.test/a.jpg" }, "1");
  assert.equal(preview.thumbnailUrl, null);
});
