/**
 * stock_watch/registry.js — adapter registry + dispatcher.
 *
 * Each adapter exposes { platform, matchesUrl(url), fetch(url), normalize(raw, url) }.
 * Adding a new source (Costco, Best Buy, ...) means writing one more adapter
 * module with that same shape and registering it below — nothing else in the
 * watcher (diffSnapshot, the scheduled function) needs to change.
 */

"use strict";

const weverseAdapter = require("./weverse_adapter");

const ADAPTERS = [weverseAdapter];

function getAdapter({ platform, url }) {
  if (platform) {
    const adapter = ADAPTERS.find((a) => a.platform === platform);
    if (!adapter) throw new Error(`No stock-watch adapter registered for platform "${platform}".`);
    return adapter;
  }
  if (url) {
    const adapter = ADAPTERS.find((a) => a.matchesUrl(url));
    if (!adapter) throw new Error(`No stock-watch adapter recognizes url "${url}".`);
    return adapter;
  }
  throw new Error("watchStock requires a platform or a url.");
}

// watchStock({ platform, url }) -> StockSnapshot
// Looks up the adapter (by platform, or by url via matchesUrl), then runs its
// fetch() + normalize() steps in sequence.
async function watchStock({ platform, url }) {
  if (!url) throw new Error("watchStock requires a url.");
  const adapter = getAdapter({ platform, url });
  const raw = await adapter.fetch(url);
  return adapter.normalize(raw, url);
}

module.exports = {
  ADAPTERS,
  getAdapter,
  watchStock,
};
