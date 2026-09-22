/**
 * stock_watch/index.js — public surface of the stock watcher module.
 */

"use strict";

const { watchStock, getAdapter, ADAPTERS } = require("./registry");
const { diffSnapshot } = require("./diff_snapshot");
const { watchStockSourcesScheduled } = require("./scheduled");

module.exports = {
  watchStock,
  getAdapter,
  ADAPTERS,
  diffSnapshot,
  watchStockSourcesScheduled,
};
