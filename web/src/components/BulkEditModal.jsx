import { useState } from "react";
import { doc, updateDoc, serverTimestamp } from "firebase/firestore";
import { db, callFunction } from "../firebase";
import { bulkEditPatch, hasAnyEdit, hasVariantPriceOverrides, adjustQuantity, quantityWarning, HANDLING_DAYS } from "../lib/bulkEdit";

// Bulk Edit (2026-11-24): the web port of iOS BulkEditSheet (mock
// https://claude.ai/artifact/BDdEGHAbyNDsxjj52FWopG, approved without the preview).
// Saves each products/{id}, then pushProductEdits updates every live eBay / Etsy /
// TikTok listing. Marking out of stock goes through markSoldOutAndCascade instead, and
// Quantity (Remove / Set / Add, mock https://claude.ai/artifact/8Z2t5BCtMsWaeuMw4iJS9t)
// through adjustQuantityAndCascade: 0 = sold out, from 0 = restock, pushed everywhere.

const PLATFORM = { ebay: "eBay", etsy: "Etsy", tiktok: "TikTok", mercari: "Mercari" };
const CONDITIONS = [["new", "New"], ["likenew", "Like new"], ["good", "Good"], ["fair", "Fair"], ["poor", "Poor"]];

export default function BulkEditModal({ products, onClose, onDone }) {
  const [e, setE] = useState({
    titlePrepend: "", titleAppend: "", descPrepend: "", descAppend: "",
    price: { mode: null, unit: "pct", amount: "", limit: "" },
    changeVariantPrices: null, // asked only when some variant has its own price
    condition: "", shipping: "", handling: "",
    weightLbs: "", weightOz: "", lengthIn: "", widthIn: "", heightIn: "",
    quantity: { mode: null, amount: "" },
    markOutOfStock: false,
  });
  const [progress, setProgress] = useState(null); // "Saving 2 of 5…"
  const [result, setResult] = useState(null);     // { lines: [], failures: [] }

  const set = (k) => (ev) => setE({ ...e, [k]: ev.target.value });
  const setPrice = (patch) => setE({ ...e, price: { ...e.price, ...patch } });
  const toggleMode = (mode) => setPrice({ mode: e.price.mode === mode ? null : mode });
  // Picking a quantity turns off "Mark as out of stock", and the other way round.
  const setQty = (patch) => setE({ ...e, markOutOfStock: false, quantity: { ...e.quantity, ...patch } });
  const toggleQty = (mode) => setQty({ mode: e.quantity.mode === mode ? null : mode });
  const qtyActive = adjustQuantity(0, e.quantity) != null;
  const qtyWarning = qtyActive ? quantityWarning(products, e.quantity) : "";

  const priceActive = Boolean(e.price.mode) && e.price.amount !== "";
  const variantQuestion = priceActive && products.some(hasVariantPriceOverrides);
  const needsVariantAnswer = variantQuestion && e.changeVariantPrices == null;
  const canApply = hasAnyEdit(e) && !needsVariantAnswer && !progress;

  async function apply() {
    const edits = { ...e, changeVariantPrices: variantQuestion && e.changeVariantPrices === true };
    const failures = [];
    const pushedTo = {};
    const manual = new Set();
    const qtyCounts = {};
    let saved = 0;

    for (let i = 0; i < products.length; i++) {
      const p = products[i];
      setProgress(`Saving ${i + 1} of ${products.length}…`);
      const patch = bulkEditPatch(p, edits);
      try {
        if (patch) {
          await updateDoc(doc(db, "products", p.id), { ...patch, updatedAt: serverTimestamp() });
          saved++;
        }
        if (e.markOutOfStock) {
          // Ends/hides it everywhere; pushing the field edits first would be wasted.
          await callFunction("markSoldOutAndCascade")({ productId: p.id });
        } else {
          if (patch) {
            const res = await callFunction("pushProductEdits", { timeout: 300000 })({ productId: p.id });
            for (const pl of res.data?.updated ?? []) pushedTo[pl] = (pushedTo[pl] ?? 0) + 1;
            for (const f of res.data?.failed ?? []) failures.push(`${p.title}: ${PLATFORM[f.platform] ?? f.platform} said "${f.error}"`);
            for (const m of res.data?.manualUpdate ?? []) manual.add(m);
          }
          if (qtyActive) {
            const res = await callFunction("adjustQuantityAndCascade", { timeout: 300000 })({
              productId: p.id, mode: e.quantity.mode, amount: Number(e.quantity.amount),
            });
            const outcome = res.data?.outcome;
            if (outcome && outcome !== "unchanged") qtyCounts[outcome] = (qtyCounts[outcome] ?? 0) + 1;
            for (const [pl, err] of Object.entries(res.data?.errors ?? {})) failures.push(`${p.title}: ${PLATFORM[pl] ?? pl} said "${err}"`);
          }
        }
      } catch (err) {
        failures.push(`${p.title}: ${err?.message ?? err}`);
      }
    }

    const lines = [];
    if (saved) lines.push(`Updated ${saved} product${saved === 1 ? "" : "s"}.`);
    if (e.markOutOfStock) lines.push(`Marked ${products.length} out of stock.`);
    const qn = (k) => qtyCounts[k] ?? 0;
    if (qn("updated")) lines.push(`Changed the quantity of ${qn("updated")}.`);
    if (qn("sold-out")) lines.push(`Marked ${qn("sold-out")} out of stock.`);
    if (qn("restocked")) lines.push(`Restocked ${qn("restocked")}.`);
    const pushed = Object.entries(pushedTo).map(([pl, n]) => `${PLATFORM[pl] ?? pl} for ${n}`);
    if (pushed.length) lines.push(`Updated the live listings on ${pushed.join(", ")}.`);
    if (manual.has("mercari")) lines.push("Mercari listings don't update automatically. Edit them on Mercari or with the extension.");
    setProgress(null);
    setResult({ lines, failures });
    onDone?.();
  }

  const handleClose = () => { if (!progress) onClose(); };

  return (
    <div className="modal-overlay" onClick={handleClose}>
      <div className="modal" style={{ maxWidth: 620 }} onClick={(ev) => ev.stopPropagation()} role="dialog" aria-labelledby="bulk-edit-title">
        <div className="modal-header">
          <h2 id="bulk-edit-title">Bulk Edit ({products.length})</h2>
          <button className="btn btn-plain" onClick={handleClose} disabled={!!progress}>{result ? "Done" : "Cancel"}</button>
        </div>

        {result ? (
          <div className="modal-body" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {result.lines.map((l) => <p key={l} style={{ margin: 0 }}>{l}</p>)}
            {result.failures.length > 0 && (
              <div role="alert" style={{ fontSize: 13, color: "var(--danger)" }}>
                <b>{result.failures.length} didn't go through:</b>
                <ul style={{ margin: "6px 0 0", paddingLeft: 18 }}>{result.failures.map((f) => <li key={f}>{f}</li>)}</ul>
              </div>
            )}
          </div>
        ) : (
          <div className="modal-body" style={{ display: "flex", flexDirection: "column", gap: 18 }}>
            <section>
              <div className="form-group-header">Text</div>
              <div className="form-rows">
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-title-pre">Title</label>
                  <input id="be-title-pre" className="input" placeholder="Add to start" value={e.titlePrepend} onChange={set("titlePrepend")} />
                  <input id="be-title-app" className="input" placeholder="Add to end" aria-label="Add to end of title" value={e.titleAppend} onChange={set("titleAppend")} />
                </div>
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-desc-pre">Description</label>
                  <input id="be-desc-pre" className="input" placeholder="Add to start" value={e.descPrepend} onChange={set("descPrepend")} />
                  <input id="be-desc-app" className="input" placeholder="Add to end" aria-label="Add to end of description" value={e.descAppend} onChange={set("descAppend")} />
                </div>
              </div>
              <div className="form-group-footer">Title text is joined with a space, description text with a blank line.</div>
            </section>

            <section>
              <div className="form-group-header">Price</div>
              <div className="form-rows">
                <div className="form-row">
                  <div className="segmented" role="group" aria-label="Price change" style={{ flex: 1 }}>
                    <button type="button" className={e.price.mode === "decrease" ? "active" : ""} aria-pressed={e.price.mode === "decrease"} onClick={() => toggleMode("decrease")}>− Decrease</button>
                    <button type="button" className={e.price.mode === "set" ? "active" : ""} aria-pressed={e.price.mode === "set"} onClick={() => toggleMode("set")}>Set price</button>
                    <button type="button" className={e.price.mode === "increase" ? "active" : ""} aria-pressed={e.price.mode === "increase"} onClick={() => toggleMode("increase")}>+ Increase</button>
                  </div>
                </div>
                {e.price.mode && (
                  <div className="form-row">
                    {e.price.mode !== "set" && (
                      <div className="segmented" role="group" aria-label="Unit">
                        <button type="button" className={e.price.unit === "pct" ? "active" : ""} aria-pressed={e.price.unit === "pct"} onClick={() => setPrice({ unit: "pct" })}>%</button>
                        <button type="button" className={e.price.unit === "usd" ? "active" : ""} aria-pressed={e.price.unit === "usd"} onClick={() => setPrice({ unit: "usd" })}>$</button>
                      </div>
                    )}
                    <input className="input" type="number" min="0" step="0.01" inputMode="decimal" id="be-amount"
                      aria-label={e.price.mode === "set" ? "New price" : "Amount"} placeholder={e.price.mode === "set" ? "New price" : "Amount"}
                      value={e.price.amount} onChange={(ev) => setPrice({ amount: ev.target.value })} />
                  </div>
                )}
                {(e.price.mode === "increase" || e.price.mode === "decrease") && (
                  <div className="form-row">
                    <label className="form-row-label" htmlFor="be-limit">{e.price.mode === "decrease" ? "Min price" : "Max price"}</label>
                    <input id="be-limit" className="input" type="number" min="0" step="0.01" inputMode="decimal" placeholder="No limit"
                      value={e.price.limit} onChange={(ev) => setPrice({ limit: ev.target.value })} />
                  </div>
                )}
                {variantQuestion && (
                  <div className="form-row">
                    <span className="form-row-label">Variant prices</span>
                    <div className="segmented" role="group" aria-label="Variant prices" style={{ flex: 1 }}>
                      <button type="button" className={e.changeVariantPrices === false ? "active" : ""} aria-pressed={e.changeVariantPrices === false} onClick={() => setE({ ...e, changeVariantPrices: false })}>Keep</button>
                      <button type="button" className={e.changeVariantPrices === true ? "active" : ""} aria-pressed={e.changeVariantPrices === true} onClick={() => setE({ ...e, changeVariantPrices: true })}>Change too</button>
                    </div>
                  </div>
                )}
              </div>
              <div className="form-group-footer">
                {variantQuestion
                  ? "Some of these products have variants with their own price. Keep them as they are, or give them the same change?"
                  : "Changes the listing price. Variants that follow the listing price follow it."}
              </div>
            </section>

            <section>
              <div className="form-group-header">Quantity</div>
              <div className="form-rows">
                <div className="form-row">
                  <div className="segmented" role="group" aria-label="Quantity change" style={{ flex: 1 }}>
                    <button type="button" className={e.quantity.mode === "remove" ? "active" : ""} aria-pressed={e.quantity.mode === "remove"} onClick={() => toggleQty("remove")}>− Remove</button>
                    <button type="button" className={e.quantity.mode === "set" ? "active" : ""} aria-pressed={e.quantity.mode === "set"} onClick={() => toggleQty("set")}>Set</button>
                    <button type="button" className={e.quantity.mode === "add" ? "active" : ""} aria-pressed={e.quantity.mode === "add"} onClick={() => toggleQty("add")}>+ Add</button>
                  </div>
                </div>
                {e.quantity.mode && (
                  <div className="form-row">
                    <input className="input" type="number" min="0" step="1" inputMode="numeric" id="be-qty" aria-label="Quantity" placeholder="Amount"
                      value={e.quantity.amount} onChange={(ev) => setQty({ amount: ev.target.value })} />
                  </div>
                )}
              </div>
              {e.quantity.mode && <div className="form-group-footer">Products that track quantity per variant get the change on every variant.</div>}
              {qtyWarning && <div className="form-group-footer" style={{ color: "var(--warning)" }}>{qtyWarning}</div>}
            </section>

            <section>
              <div className="form-group-header">Details</div>
              <div className="form-rows">
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-cond">Condition</label>
                  <select id="be-cond" className="input" value={e.condition} onChange={set("condition")}>
                    <option value="">Unchanged</option>
                    {CONDITIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                  </select>
                </div>
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-ship">Shipping</label>
                  <select id="be-ship" className="input" value={e.shipping} onChange={set("shipping")}>
                    <option value="">Unchanged</option>
                    <option value="buyer">Buyer pays</option>
                    <option value="free">Free shipping</option>
                  </select>
                </div>
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-handling">Handling time</label>
                  <select id="be-handling" className="input" value={e.handling} onChange={set("handling")}>
                    <option value="">Unchanged</option>
                    {HANDLING_DAYS.map((d) => <option key={d} value={d}>{d} {d === 1 ? "day" : "days"}</option>)}
                    <option value="reset">Reset to default</option>
                  </select>
                </div>
              </div>
            </section>

            <section>
              <div className="form-group-header">Package</div>
              <div className="form-rows">
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-lb">Weight</label>
                  <input id="be-lb" className="input" type="number" min="0" placeholder="0" value={e.weightLbs} onChange={set("weightLbs")} style={{ width: 70 }} />
                  <span style={{ color: "var(--muted)" }}>lb</span>
                  <input className="input" type="number" min="0" max="15.9" step="0.1" placeholder="0" aria-label="Ounces" value={e.weightOz} onChange={set("weightOz")} style={{ width: 70 }} />
                  <span style={{ color: "var(--muted)" }}>oz</span>
                </div>
                <div className="form-row">
                  <label className="form-row-label" htmlFor="be-l">L × W × H</label>
                  <input id="be-l" className="input" type="number" min="0" placeholder="L" value={e.lengthIn} onChange={set("lengthIn")} style={{ width: 60 }} />
                  <span style={{ color: "var(--muted)" }}>×</span>
                  <input className="input" type="number" min="0" placeholder="W" aria-label="Width" value={e.widthIn} onChange={set("widthIn")} style={{ width: 60 }} />
                  <span style={{ color: "var(--muted)" }}>×</span>
                  <input className="input" type="number" min="0" placeholder="H" aria-label="Height" value={e.heightIn} onChange={set("heightIn")} style={{ width: 60 }} />
                  <span style={{ color: "var(--muted)" }}>in</span>
                </div>
              </div>
              <div className="form-group-footer">Leave blank to keep each product's own weight and size. Size applies only when all three are filled.</div>
            </section>

            <section>
              <div className="form-group-header">Availability</div>
              <div className="form-rows">
                <label className="form-row" htmlFor="be-oos" style={{ cursor: "pointer" }}>
                  <span style={{ flex: 1 }}>Mark as out of stock</span>
                  <input id="be-oos" type="checkbox" checked={e.markOutOfStock} onChange={(ev) => setE({ ...e, markOutOfStock: ev.target.checked, quantity: ev.target.checked ? { mode: null, amount: "" } : e.quantity })} />
                </label>
              </div>
              <div className="form-group-footer">Sets quantity to 0 and updates eBay, Etsy and TikTok, same as Mark Out of Stock.</div>
            </section>
          </div>
        )}

        <div className="modal-footer">
          {result ? (
            <button className="btn btn-primary" onClick={onClose}>Done</button>
          ) : (
            <>
              <span className="page-subtitle" style={{ flex: 1 }}>
                {progress ?? (needsVariantAnswer ? "Choose what happens to variant prices." : "")}
              </span>
              <button className="btn btn-plain" onClick={handleClose} disabled={!!progress}>Cancel</button>
              <button className="btn btn-primary" onClick={apply} disabled={!canApply}>
                {progress ? "Applying…" : `Apply to ${products.length}`}
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
