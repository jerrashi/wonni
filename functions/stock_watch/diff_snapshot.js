/**
 * stock_watch/diff_snapshot.js — pure diff between two StockSnapshots.
 *
 * No network / DB access here on purpose: this is the piece that has to be
 * unit-testable with plain fixtures. `previous` and `current` are expected to
 * refer to the same platform+sourceId; the caller (the scheduled function)
 * is responsible for loading the right `previous` snapshot before calling this.
 */

"use strict";

// Stable key for a variant's option combo, e.g. { Style: "RM", Size: "M" }
// -> 'Size=M|Style=RM' (keys sorted so key order never matters).
function variantKey(variant) {
  const values = variant?.optionValues ?? {};
  return Object.keys(values)
    .sort()
    .map((k) => `${k}=${values[k]}`)
    .join("|");
}

function baseEvent(type, current) {
  return {
    type,
    platform: current.platform,
    sourceId: current.sourceId,
    url: current.url,
    title: current.title,
  };
}

// diffSnapshot(previous, current) -> Array<event>
// previous may be null/undefined (nothing on record yet -> "new-item").
function diffSnapshot(previous, current) {
  const events = [];

  if (!previous) {
    events.push(baseEvent("new-item", current));
    return events;
  }

  if (previous.inStock === false && current.inStock === true) {
    events.push(baseEvent("back-in-stock", current));
  }
  if (previous.inStock === true && current.inStock === false) {
    events.push(baseEvent("sold-out", current));
  }

  if (
    typeof previous.price === "number" &&
    typeof current.price === "number" &&
    previous.price !== current.price
  ) {
    events.push({
      ...baseEvent("price-changed", current),
      previousPrice: previous.price,
      price: current.price,
    });
  }

  const previousVariantKeys = new Set((previous.variants ?? []).map(variantKey));
  for (const variant of current.variants ?? []) {
    if (!previousVariantKeys.has(variantKey(variant))) {
      events.push({
        ...baseEvent("variant-added", current),
        optionValues: variant.optionValues,
      });
    }
  }

  return events;
}

module.exports = {
  diffSnapshot,
  _internal: { variantKey },
};
