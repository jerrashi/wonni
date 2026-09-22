import { useEffect, useState } from "react";
import { callFunction } from "../firebase";

// Preview a Weverse shop/artist section, let the user pick items in a
// tile grid, then import only the selected ones. See weverseShopPreview /
// weverseBulkImportProducts (functions/weverse_shop.js, weverse_bulk_import.js).
export default function WeverseShopImportModal({ shopUrl, onClose, onImported }) {
  const [items, setItems] = useState([]);
  const [selected, setSelected] = useState(new Set());
  const [loading, setLoading] = useState(true);
  const [importing, setImporting] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");

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
    setStatus(`Importing ${chosen.length} item${chosen.length === 1 ? "" : "s"}…`);

    try {
      // Shipping cost per item is estimated by the browser extension (it
      // runs inside the user's authenticated Weverse session) before each
      // item is written. If the extension isn't installed, items still
      // import — just without a shippingCost, same as pasting a single URL.
      const withShipping = await estimateShippingForItems(chosen, setStatus);

      const response = await callFunction("weverseBulkImportProducts")({
        items: withShipping.map((it) => ({
          productUrl: it.productUrl,
          saleId: it.saleId,
          title: it.title,
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
    }
  }

  const allSelected = items.length > 0 && selected.size === items.length;

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
              {status || "Shipping estimated per item during import"}
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

// Ask the browser extension (if installed) to estimate shipping cost for
// each selected item by adding it to cart with the user's address and
// reading the checkout total — see extension/weverse_content.js's
// ESTIMATE_SHIPPING handler. Falls back to no shippingCost when the
// extension isn't present, so import still works without it.
async function estimateShippingForItems(chosenItems, setStatus) {
  if (typeof window === "undefined" || !window.wonniExtension?.estimateShipping) {
    return chosenItems;
  }

  const results = [];
  for (let i = 0; i < chosenItems.length; i++) {
    const it = chosenItems[i];
    setStatus(`Estimating shipping ${i + 1}/${chosenItems.length}…`);
    try {
      const shippingCost = await window.wonniExtension.estimateShipping(it.productUrl);
      results.push({ ...it, shippingCost });
    } catch {
      results.push(it);
    }
  }
  return results;
}
