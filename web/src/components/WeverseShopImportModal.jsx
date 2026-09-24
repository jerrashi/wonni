import { useEffect, useState } from "react";
import { callFunction } from "../firebase";

// Preview a Weverse shop/artist section, let the user pick items in a
// tile grid, then import only the selected ones. See weverseShopPreview /
// weverseBulkImportProducts (functions/weverse_shop.js, weverse_bulk_import.js).
//
// The import step (handleImport, below) runs a multi-stage pipeline before
// ever calling weverseBulkImportProducts — see runShippingEstimatePipeline's
// own comment for why, and functions/weverse_shipping_estimate.js for the
// server-side per-(user, itemType) lookup table this pipeline feeds.
export default function WeverseShopImportModal({ shopUrl, onClose, onImported }) {
  const [items, setItems] = useState([]);
  const [selected, setSelected] = useState(new Set());
  const [loading, setLoading] = useState(true);
  const [importing, setImporting] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");

  // ── Item-type confirmation sub-screen state ───────────────────────────
  // Populated when classifyWeverseItemTypes couldn't confidently classify
  // one or more selected items — see runShippingEstimatePipeline.
  const [pendingConfirm, setPendingConfirm] = useState(null); // { unresolved: [item], knownTypes: [string] } | null
  const [typeChoices, setTypeChoices] = useState({}); // saleId -> chosen type string
  const [newTypeDrafts, setNewTypeDrafts] = useState({}); // saleId -> in-progress "+ Add new" text

  // ── Missing-Weverse-address sub-screen state ──────────────────────────
  // Populated when a probe comes back errorCode "MISSING_ADDRESS" — see
  // runShippingEstimatePipeline.
  const [missingAddress, setMissingAddress] = useState(null); // { resume: () => void } | null

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError("");
    callFunction("weverseShopPreview")({ shopUrl })
      .then((res) => {
        if (cancelled) return;
        const previewItems = res.data?.items ?? [];
        setItems(previewItems);
        // Nothing pre-selected — the user picks what they actually want.
        setSelected(new Set());
      })
      .catch((e) => {
        if (!cancelled) setError(e.message ?? "Could not load that shop section.");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, [shopUrl]);

  function toggle(saleId) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(saleId)) next.delete(saleId);
      else next.add(saleId);
      return next;
    });
  }

  function toggleAll() {
    setSelected((prev) =>
      prev.size === items.length ? new Set() : new Set(items.map((it) => it.saleId))
    );
  }

  async function handleImport() {
    const chosen = items.filter((it) => selected.has(it.saleId));
    if (!chosen.length) return;

    setImporting(true);
    setError("");

    try {
      const itemsWithTypeAndShipping = await runShippingEstimatePipeline(chosen, {
        setStatus,
        confirmTypes: (unresolved, knownTypes) =>
          new Promise((resolve) => {
            setTypeChoices({});
            setNewTypeDrafts({});
            setPendingConfirm({ unresolved, knownTypes, resolve });
          }),
        askForAddress: () =>
          new Promise((resolve) => {
            setMissingAddress({ resolve });
          }),
      });

      setStatus(`Importing ${itemsWithTypeAndShipping.length} item${itemsWithTypeAndShipping.length === 1 ? "" : "s"}…`);
      const response = await callFunction("weverseBulkImportProducts")({
        items: itemsWithTypeAndShipping.map((it) => ({
          productUrl: it.productUrl,
          saleId: it.saleId,
          title: it.title,
          itemType: it.itemType ?? null,
          shippingCost: it.shippingCost,
        })),
      });
      const res = response?.data;
      const errors = res?.errors ?? [];
      setStatus(
        `Imported ${res?.importedCount ?? 0}${errors.length ? `, ${errors.length} failed` : ""}.`
      );
      onImported?.(res?.productIds ?? []);
      if (!errors.length) {
        setTimeout(onClose, 700);
      } else {
        const preview = errors.slice(0, 3).map((e) => `${e.title ?? "Item"}: ${e.error}`).join("; ");
        setError(`${errors.length} item${errors.length === 1 ? "" : "s"} failed — ${preview}${errors.length > 3 ? "…" : ""}`);
      }
    } catch (e) {
      setError(e.message ?? "Import failed");
      setStatus("");
    } finally {
      setImporting(false);
      setPendingConfirm(null);
      setMissingAddress(null);
    }
  }

  function submitTypeConfirmation() {
    if (!pendingConfirm) return;
    const resolved = pendingConfirm.unresolved.map((item) => {
      const choice = typeChoices[item.saleId];
      const finalType = choice === "__new__" ? (newTypeDrafts[item.saleId] ?? "").trim() : choice;
      return { saleId: item.saleId, itemType: finalType || "Other" };
    });
    pendingConfirm.resolve(resolved);
    setPendingConfirm(null);
  }

  const allTypesChosen = pendingConfirm?.unresolved.every((item) => {
    const choice = typeChoices[item.saleId];
    if (!choice) return false;
    if (choice === "__new__") return (newTypeDrafts[item.saleId] ?? "").trim().length > 0;
    return true;
  }) ?? false;

  const allSelected = items.length > 0 && selected.size === items.length;

  // ── Sub-screen: confirm item type for items Gemini couldn't classify ───
  if (pendingConfirm) {
    return (
      <div className="modal-overlay">
        <div className="modal" style={{ maxWidth: 480 }} onClick={(e) => e.stopPropagation()}>
          <div className="modal-header">
            <h2 style={{ margin: 0, fontSize: 18 }}>Confirm Item Type</h2>
          </div>
          <div className="modal-body">
            <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 12 }}>
              We couldn't automatically classify {pendingConfirm.unresolved.length} item
              {pendingConfirm.unresolved.length === 1 ? "" : "s"} — this groups similar items so we
              only need to check shipping cost once per type.
            </div>
            {pendingConfirm.unresolved.map((item) => (
              <div key={item.saleId} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 0", borderBottom: "1px solid var(--border)" }}>
                {item.thumbnailUrl && (
                  <img src={item.thumbnailUrl} alt="" style={{ width: 36, height: 36, borderRadius: 6, objectFit: "cover", flexShrink: 0 }} />
                )}
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 12, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.title}</div>
                  <select
                    value={typeChoices[item.saleId] ?? ""}
                    onChange={(e) => setTypeChoices((prev) => ({ ...prev, [item.saleId]: e.target.value }))}
                    style={{ marginTop: 4, fontSize: 12, padding: "3px 6px", width: "100%" }}
                  >
                    <option value="" disabled>Confirm item type…</option>
                    {pendingConfirm.knownTypes.map((t) => (
                      <option key={t} value={t}>{t}</option>
                    ))}
                    <option value="__new__">+ Add new…</option>
                  </select>
                  {typeChoices[item.saleId] === "__new__" && (
                    <input
                      type="text"
                      placeholder="New type name"
                      value={newTypeDrafts[item.saleId] ?? ""}
                      onChange={(e) => setNewTypeDrafts((prev) => ({ ...prev, [item.saleId]: e.target.value }))}
                      style={{ marginTop: 4, fontSize: 12, padding: "3px 6px", width: "100%" }}
                    />
                  )}
                </div>
              </div>
            ))}
          </div>
          <div className="weverse-sticky-bar">
            <div />
            <div style={{ display: "flex", gap: 10 }}>
              <button className="btn btn-primary" onClick={submitTypeConfirmation} disabled={!allTypesChosen}>
                Continue
              </button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  // ── Sub-screen: Weverse account has no saved shipping address ──────────
  if (missingAddress) {
    return (
      <div className="modal-overlay">
        <div className="modal" style={{ maxWidth: 420 }} onClick={(e) => e.stopPropagation()}>
          <div className="modal-header">
            <h2 style={{ margin: 0, fontSize: 18 }}>Add a Shipping Address</h2>
          </div>
          <div className="modal-body">
            <div style={{ fontSize: 13 }}>
              Weverse needs a saved shipping address on your account before it can quote a
              delivery fee. Add one on Weverse, then come back and continue.
            </div>
          </div>
          <div className="weverse-sticky-bar">
            <div />
            <div style={{ display: "flex", gap: 10 }}>
              <button
                className="btn btn-ghost"
                onClick={() => { missingAddress.resolve("skip"); setMissingAddress(null); }}
              >
                Skip Estimate
              </button>
              <button
                className="btn btn-ghost"
                onClick={() => window.wonniExtension?.openWeverseAddressPage?.()}
              >
                Open Weverse
              </button>
              <button
                className="btn btn-primary"
                onClick={() => { missingAddress.resolve("retry"); setMissingAddress(null); }}
              >
                I've Added It — Retry
              </button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="modal-overlay" onClick={importing ? undefined : onClose}>
      <div className="modal" style={{ maxWidth: 760 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <div>
            <h2 style={{ margin: 0, fontSize: 18 }}>Import Shop Section</h2>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>
              {loading ? "Loading preview…" : `${items.length} item${items.length === 1 ? "" : "s"} found`}
            </span>
          </div>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose} disabled={importing}>✕</button>
        </div>

        <div className="modal-body">
          {loading && (
            <div style={{ padding: "32px 0", textAlign: "center", color: "var(--muted)", fontSize: 13 }}>
              Fetching items from Weverse…
            </div>
          )}

          {!loading && !error && items.length === 0 && (
            <div style={{ padding: "32px 0", textAlign: "center", color: "var(--muted)", fontSize: 13 }}>
              No items found on that page.
            </div>
          )}

          {!loading && items.length > 0 && (
            <>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
                <span className="label-caps" style={{ color: "var(--muted)" }}>
                  Tap items to select — nothing is imported until you confirm
                </span>
                <label style={{ display: "flex", alignItems: "center", gap: 8, fontFamily: "'Space Mono', monospace", fontSize: 12, color: "var(--text-secondary)", cursor: "pointer" }}>
                  <input type="checkbox" checked={allSelected} onChange={toggleAll} disabled={importing} />
                  Select all
                </label>
              </div>

              <div className="weverse-tile-grid">
                {items.map((it) => {
                  const isSelected = selected.has(it.saleId);
                  return (
                    <button
                      key={it.saleId}
                      type="button"
                      className={`weverse-tile${isSelected ? " selected" : ""}`}
                      onClick={() => toggle(it.saleId)}
                      disabled={importing}
                      title={it.title}
                    >
                      <div className="weverse-tile-icon">
                        {it.thumbnailUrl ? (
                          <img src={it.thumbnailUrl} alt="" loading="lazy" />
                        ) : (
                          <div style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center", color: "var(--muted)", fontSize: 11 }}>
                            No image
                          </div>
                        )}
                        <div className="weverse-tile-check">
                          <svg viewBox="0 0 16 16" fill="none">
                            <path d="M3 8.5L6.2 12L13 4" stroke="#3a3000" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
                          </svg>
                        </div>
                      </div>
                      <div className="weverse-tile-title">{it.title}</div>
                      <div className="weverse-tile-price">${Number(it.price ?? 0).toFixed(2)}</div>
                    </button>
                  );
                })}
              </div>
            </>
          )}

          {error && <div style={{ fontSize: 13, color: "var(--danger)" }}>{error}</div>}
        </div>

        <div className="weverse-sticky-bar">
          <div>
            <div style={{ fontFamily: "'Anton', sans-serif", fontSize: 18, color: "var(--primary)", textTransform: "uppercase" }}>
              {selected.size} Selected
            </div>
            <div style={{ fontSize: 11, color: "var(--muted)" }}>
              {status || "Shipping estimated per item type during import"}
            </div>
          </div>
          <div style={{ display: "flex", gap: 10 }}>
            <button className="btn btn-ghost" onClick={onClose} disabled={importing}>Cancel</button>
            <button
              className="btn btn-primary"
              onClick={handleImport}
              disabled={importing || selected.size === 0}
            >
              {importing ? "Importing…" : `Import ${selected.size} Item${selected.size === 1 ? "" : "s"}`}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Shipping-estimate pipeline ────────────────────────────────────────────
// Only ever runs against items the user actually selected to import — never
// wastes a classification/probe on an unselected preview tile.
//
// 1. Classify every chosen item into an itemType (functions/weverse_shipping_
//    estimate.js's classifyWeverseItemTypes, Gemini-backed). Items Gemini
//    can't confidently place go through the `confirmTypes` UI callback.
// 2. Group by itemType. Probe only the FIRST item of each type (via the
//    browser extension's window.wonniExtension.estimateShipping — see
//    extension/dashboard_bridge_content.js / weverse_content.js's
//    probeShippingCost). On an OUT_OF_STOCK probe failure, try the next item
//    of that same type instead of giving up on the whole type. On
//    MISSING_ADDRESS, pause and run the `askForAddress` UI callback, then
//    retry the same item once the user says they've added one (or give up on
//    that type if they choose to skip).
// 3. Return items with `itemType` set on every item, and `shippingCost` set
//    ONLY on the one item per type whose probe actually succeeded — the
//    server (weverseBulkImportProducts) resolves the final per-type value
//    and applies it to every item of that type, probed or not.
async function runShippingEstimatePipeline(chosenItems, { setStatus, confirmTypes, askForAddress }) {
  setStatus("Checking item types…");

  const hasExtensionBridge = typeof window !== "undefined" && !!window.wonniExtension?.estimateShipping;

  let itemTypeBySaleId = {};
  try {
    const classifyResponse = await callFunction("classifyWeverseItemTypes")({
      items: chosenItems.map((it) => ({ saleId: it.saleId, title: it.title, thumbnailUrl: it.thumbnailUrl })),
    });
    const { knownTypes = [], classifications = {} } = classifyResponse?.data ?? {};
    itemTypeBySaleId = { ...classifications };

    const unresolved = chosenItems.filter((it) => !itemTypeBySaleId[it.saleId]);
    if (unresolved.length) {
      const manualChoices = await confirmTypes(unresolved, knownTypes);
      for (const { saleId, itemType } of manualChoices) {
        itemTypeBySaleId[saleId] = itemType;
      }
    }
  } catch (err) {
    // Classification is best-effort — items still import without shipping
    // estimates if it fails outright (e.g. Gemini unreachable).
    console.error("[WeverseShopImportModal] classifyWeverseItemTypes failed", err);
  }

  if (!hasExtensionBridge) {
    setStatus("Wonni Drop extension not detected — importing without a shipping estimate.");
    return chosenItems.map((it) => ({ ...it, itemType: itemTypeBySaleId[it.saleId] ?? null }));
  }

  // Group selected items by resolved type, preserving selection order —
  // that order is what "try the next item on out-of-stock" walks through.
  const itemsByType = new Map();
  for (const item of chosenItems) {
    const itemType = itemTypeBySaleId[item.saleId] ?? "Other";
    if (!itemsByType.has(itemType)) itemsByType.set(itemType, []);
    itemsByType.get(itemType).push(item);
  }

  const probedShippingBySaleId = {};
  let typeIndex = 0;
  const totalTypes = itemsByType.size;

  for (const [itemType, itemsOfType] of itemsByType) {
    typeIndex += 1;
    setStatus(`Estimating shipping for "${itemType}" (${typeIndex}/${totalTypes})…`);

    let succeeded = false;
    for (const candidate of itemsOfType) {
      try {
        const shippingCost = await window.wonniExtension.estimateShipping(candidate.productUrl);
        probedShippingBySaleId[candidate.saleId] = shippingCost;
        succeeded = true;
        break;
      } catch (err) {
        const errorCode = err?.errorCode ?? "UNKNOWN";
        console.warn(`[WeverseShopImportModal] shipping probe failed for "${candidate.title}" (${itemType}):`, errorCode, err?.message);

        if (errorCode === "OUT_OF_STOCK") {
          continue; // try the next item of this same type
        }

        if (errorCode === "MISSING_ADDRESS") {
          const choice = await askForAddress();
          if (choice === "retry") {
            try {
              const shippingCost = await window.wonniExtension.estimateShipping(candidate.productUrl);
              probedShippingBySaleId[candidate.saleId] = shippingCost;
              succeeded = true;
            } catch (retryErr) {
              console.warn(`[WeverseShopImportModal] retry after address prompt still failed for "${candidate.title}":`, retryErr?.message);
            }
          }
          break; // either resolved, or the user chose to skip — either way, stop trying this type
        }

        // Unrecognized failure — don't keep hammering this type, move on.
        break;
      }
    }

    if (!succeeded) {
      console.warn(`[WeverseShopImportModal] no shipping estimate for type "${itemType}" this batch — falling back to any previously-stored estimate.`);
    }
  }

  return chosenItems.map((it) => {
    const itemType = itemTypeBySaleId[it.saleId] ?? "Other";
    const result = { ...it, itemType };
    if (Object.prototype.hasOwnProperty.call(probedShippingBySaleId, it.saleId)) {
      result.shippingCost = probedShippingBySaleId[it.saleId];
    }
    return result;
  });
}
