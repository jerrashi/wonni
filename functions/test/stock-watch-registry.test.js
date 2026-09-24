/**
 * stock-watch-registry.test.js — watchStock() dispatch: platform lookup,
 * matchesUrl() inference, and fetch() -> normalize() sequencing. Uses a fake
 * in-process adapter, no network.
 *
 * A live-network smoke test for the real adapters is intentionally NOT here
 * (and gated with describe.skip below) so CI never depends on Weverse being
 * reachable / unchanged.
 */

"use strict";

const { test, describe } = require("node:test");
const assert = require("node:assert/strict");

const { watchStock, getAdapter, ADAPTERS } = require("../stock_watch/registry");
const weverseAdapter = require("../stock_watch/weverse_adapter");

test("getAdapter: resolves by explicit platform", () => {
  const adapter = getAdapter({ platform: "weverse" });
  assert.equal(adapter, weverseAdapter);
});

test("getAdapter: unknown platform throws", () => {
  assert.throws(() => getAdapter({ platform: "costco" }), /No stock-watch adapter registered/);
});

test("getAdapter: infers adapter from url via matchesUrl when platform is omitted", () => {
  const adapter = getAdapter({ url: "https://shop.weverse.io/en/shop/USD/artists/255/sales/64536" });
  assert.equal(adapter, weverseAdapter);
});

test("getAdapter: url matching no adapter throws", () => {
  assert.throws(() => getAdapter({ url: "https://example.com/whatever" }), /No stock-watch adapter recognizes/);
});

test("watchStock: calls the adapter's fetch() then normalize(), in order", async () => {
  const calls = [];
  const fakeAdapter = {
    platform: "fake-source",
    matchesUrl: (url) => url.includes("fake-source.test"),
    fetch: async (url) => {
      calls.push(["fetch", url]);
      return { raw: true, url };
    },
    normalize: (raw, url) => {
      calls.push(["normalize", raw, url]);
      return {
        platform: "fake-source",
        url,
        sourceId: "abc",
        title: "Fake",
        description: "",
        images: [],
        inStock: true,
        quantityAvailable: null,
        price: null,
        currency: null,
        variants: [],
        fetchedAt: 0,
      };
    },
  };

  ADAPTERS.push(fakeAdapter);
  try {
    const snapshot = await watchStock({ url: "https://fake-source.test/item/1" });
    assert.equal(snapshot.platform, "fake-source");
    assert.equal(snapshot.sourceId, "abc");
    assert.deepEqual(
      calls.map((c) => c[0]),
      ["fetch", "normalize"]
    );
  } finally {
    ADAPTERS.pop();
  }
});

// Gated live-network smoke test placeholder — never runs in CI.
describe.skip("weverse adapter (live network smoke test)", () => {
  test("fetch() + normalize() against a real Weverse sale url", async () => {
    if (!process.env.STOCK_WATCH_LIVE_SMOKE_URL) return;
    const url = process.env.STOCK_WATCH_LIVE_SMOKE_URL;
    const raw = await weverseAdapter.fetch(url);
    const snapshot = weverseAdapter.normalize(raw, url);
    assert.ok(snapshot.title);
  });
});
