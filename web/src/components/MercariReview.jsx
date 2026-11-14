// Mercari sales review (mock https://claude.ai/artifact/3N5S6mWWBA36jptkxDtygP v4,
// approved 2026-11-14). What reaches this list: Mercari sales a refresh found that
// could NOT be recorded on their own — not linked to a product by its Mercari id,
// only a title-match "Suggested" product, or missing a title / price / sold date.
// Sales linked by id with complete info were already recorded by
// reviewMercariSales {autoImport}. The rows live server-side
// (users/{uid}/mercariSaleInbox), so Cancel just closes: nothing is lost.
//
// Every row opens one edit form (title, price, take-home, sold date, quantity,
// product link, Never import). "Not linked" rows import too: the sale counts, but
// no stock changes (recordMercariSalesBatch {allowUnlinked}).

import { useMemo, useState } from "react";
import { callFunction } from "../firebase";

const money = (n) => (n == null || Number.isNaN(Number(n)) ? "—" : `$${Number(n).toFixed(2)}`);

/** Mercari US fees as of 2025: 10% selling + 2.9% + $0.50 processing. An estimate only. */
export function estimateTakeHome(price) {
  const p = Number(price);
  if (!(p > 0)) return null;
  return Math.round((p - p * 0.1 - p * 0.029 - 0.5) * 100) / 100;
}

/** "11/12/26" | "2026-11-12" | ISO | epoch → "YYYY-MM-DD" for a date input. */
function toDateInput(item) {
  const raw = item.soldAt ?? item.soldDate ?? item.soldDateText;
  if (raw == null) return "";
  let d = typeof raw === "number" ? new Date(raw) : null;
  if (!d) {
    const m = String(raw).match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
    d = m ? new Date(Number(m[3].length === 2 ? `20${m[3]}` : m[3]), Number(m[1]) - 1, Number(m[2]), 12) : new Date(raw);
  }
  return Number.isNaN(d.getTime()) ? "" : d.toISOString().slice(0, 10);
}

const fmtDay = (ymd) => (ymd ? new Date(`${ymd}T12:00`).toLocaleDateString("en-US", { month: "short", day: "numeric" }) : "—");

/** Local, editable copy of one inbox row. */
function toDraft(row) {
  const it = row.item;
  return {
    id: it.mercariItemId,
    orderId: it.mercariOrderId ?? null,
    title: it.title ?? "",
    price: it.priceSoldFor ?? null,
    takeHome: it.takeHome ?? null,
    takeHomeEstimated: it.takeHome == null,
    date: toDateInput(it),
    quantity: it.quantity ?? 1,
    thumbnailUrl: it.thumbnailUrl ?? null,
    raw: it,
    // product: matched by id (server), the user's link, or the title Suggested guess
    productId: row.productId ?? row.suggestedProductId ?? null,
    variantSku: row.variantSku ?? null,
    productTitle: row.productTitle ?? row.suggestedProductTitle ?? null,
    linkKind: row.productId ? "matched" : row.suggestedProductId ? "suggested" : null,
  };
}

export function missingOf(d) {
  const out = [];
  if (!d.title.trim()) out.push("title");
  if (!(Number(d.price) > 0)) out.push("price");
  if (!d.date) out.push("date");
  return out;
}

/** The row as MercariScrapeItemSchema wants it, with the user's edits. */
function scrapeItem(d) {
  const item = {
    mercariItemId: d.id,
    title: d.title.trim(),
    priceSoldFor: Number(d.price),
    soldAt: new Date(`${d.date}T12:00:00`).toISOString(),
    quantity: Number(d.quantity) || 1,
  };
  if (d.orderId) item.mercariOrderId = d.orderId;
  if (d.takeHome != null && d.takeHome !== "") item.takeHome = Number(d.takeHome);
  if (/^https?:\/\//.test(d.thumbnailUrl || "")) item.thumbnailUrl = d.thumbnailUrl;
  for (const k of ["shippingRevenue", "buyerName", "trackingNumber"]) if (d.raw?.[k] != null) item[k] = d.raw[k];
  return item;
}

export function MercariSalesBanner({ count, onReview }) {
  if (!count) return null;
  return (
    <div className="card" style={{ marginBottom: 16, padding: "10px 14px", display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap", borderColor: "var(--warning)" }}>
      <span><b>{count} Mercari sale{count === 1 ? "" : "s"}</b> waiting for review</span>
      <button className="btn btn-primary" onClick={onReview}>Review</button>
    </div>
  );
}

export default function MercariReviewModal({ inbox, products, onClose, onInbox, onToast }) {
  const [drafts, setDrafts] = useState(() => inbox.pending.map(toDraft));
  const [unchecked, setUnchecked] = useState(() => new Set());
  const [editing, setEditing] = useState(null);      // draft id, or null
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const needs = drafts.filter((d) => missingOf(d).length);
  const ready = drafts.filter((d) => !missingOf(d).length);
  const selected = ready.filter((d) => !unchecked.has(d.id));

  async function discard(d, on) {
    setError("");
    try {
      await callFunction("setMercariSalesDiscarded")({
        items: [{ mercariItemId: d.id, mercariOrderId: d.orderId, title: d.title || null, priceSoldFor: Number(d.price) > 0 ? Number(d.price) : null }],
        discarded: on,
      });
      const res = await callFunction("listMercariSaleInbox")({});
      onInbox(res.data);
      if (on) {
        setDrafts((ds) => ds.filter((x) => x.id !== d.id));
        setEditing(null);
        onToast(`Won't import: ${d.title || d.id}`, "Undo", () => discard(d, false));
      } else {
        // Restored: back on the list from the server's copy
        const back = res.data.pending.find((r) => r.item.mercariItemId === d.id);
        if (back) setDrafts((ds) => (ds.some((x) => x.id === d.id) ? ds : [toDraft(back), ...ds]));
      }
    } catch (e) {
      setError(e?.message ?? String(e));
    }
  }

  async function doImport() {
    setBusy(true);
    setError("");
    try {
      const links = {};
      for (const d of selected) {
        if (d.productId && d.linkKind !== "matched") links[d.id] = { productId: d.productId, ...(d.variantSku ? { variantSku: d.variantSku } : {}) };
      }
      const res = await callFunction("recordMercariSalesBatch")({ items: selected.map(scrapeItem), links, allowUnlinked: true });
      const { recorded = 0, duplicates = 0, results = [] } = res.data || {};
      const failed = results.filter((r) => r.outcome === "parse-failed");
      const inboxRes = await callFunction("listMercariSaleInbox")({});
      onInbox(inboxRes.data);
      const left = inboxRes.data.pending.length;
      const linked = results.filter((r) => r.outcome === "recorded" && r.productId).length;
      onToast(
        `${recorded + duplicates} Mercari sale${recorded + duplicates === 1 ? "" : "s"} recorded`
          + (linked ? ` · stock lowered on ${linked}` : "")
          + (left ? ` · ${left} still waiting` : "")
          + (failed.length ? ` · ${failed.length} failed` : ""),
      );
      if (failed.length) setError(failed.map((f) => `${f.mercariItemId}: ${f.warning}`).join("\n"));
      else onClose();
      setDrafts((ds) => ds.filter((d) => !selected.includes(d) || failed.some((f) => f.mercariItemId === d.id)));
    } catch (e) {
      setError(e?.message ?? String(e));
    } finally {
      setBusy(false);
    }
  }

  const editingDraft = drafts.find((d) => d.id === editing);
  if (editingDraft) {
    return (
      <SaleEditForm
        draft={editingDraft}
        products={products}
        onBack={() => setEditing(null)}
        onSave={(next) => {
          setDrafts((ds) => ds.map((d) => (d.id === next.id ? next : d)));
          setUnchecked((u) => { const n = new Set(u); n.delete(next.id); return n; });
          setEditing(null);
        }}
        onNeverImport={() => discard(editingDraft, true)}
      />
    );
  }

  const row = (d) => {
    const miss = missingOf(d);
    const on = !miss.length && !unchecked.has(d.id);
    let status;
    if (miss.length) status = <span className="chip" style={chip("danger")}>Needs {miss.join(" + ")}</span>;
    else if (d.productId) status = <><span className="chip" style={chip(d.linkKind === "suggested" ? "warning" : "success")}>{d.linkKind === "suggested" ? "Suggested" : d.linkKind === "matched" ? "Matched" : "Linked"}</span> {d.productTitle}</>;
    else status = <><span className="chip" style={chip("warning")}>Not linked</span> stock won't change</>;
    return (
      <div key={d.id} onClick={() => setEditing(d.id)} style={{ display: "grid", gridTemplateColumns: "22px 40px minmax(0,1fr) auto", gap: 10, alignItems: "center", padding: "10px 16px", borderBottom: "var(--border-thin) solid var(--border)", cursor: "pointer", opacity: on || miss.length ? 1 : 0.55 }}>
        <input type="checkbox" checked={on} disabled={!!miss.length} aria-label={`Import ${d.title || d.id}`}
          onClick={(e) => e.stopPropagation()}
          onChange={() => setUnchecked((u) => { const n = new Set(u); n.has(d.id) ? n.delete(d.id) : n.add(d.id); return n; })} />
        {d.thumbnailUrl ? <img src={d.thumbnailUrl} alt="" style={{ width: 40, height: 40, objectFit: "cover", borderRadius: 6 }} /> : <div style={{ width: 40, height: 40, borderRadius: 6, background: "var(--surface-high)" }} />}
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{d.title || d.id}</div>
          <div style={{ fontSize: 12, color: "var(--muted)", display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>{status} · {fmtDay(d.date)}{d.quantity > 1 ? ` · Qty ${d.quantity}` : ""}</div>
        </div>
        <div style={{ textAlign: "right", fontWeight: 600 }}>{money(d.price)}<div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 400 }}>{money(d.takeHome ?? estimateTakeHome(d.price))}</div></div>
      </div>
    );
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-content" style={{ maxWidth: 620, padding: 0 }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "14px 16px", borderBottom: "var(--border-thin) solid var(--border)" }}>
          <h3 style={{ margin: 0 }}>{drafts.length} Mercari sale{drafts.length === 1 ? "" : "s"}</h3>
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
        </div>
        <div style={{ maxHeight: "60vh", overflowY: "auto" }}>
          {needs.length > 0 && <Section label={`Needs info (${needs.length})`} />}
          {needs.map(row)}
          {ready.length > 0 && <Section label={`Ready (${ready.length})`} />}
          {ready.map(row)}
          {inbox.discarded.length > 0 && <Section label={`Never import (${inbox.discarded.length})`} />}
          {inbox.discarded.map((r) => (
            <div key={r.item.mercariItemId} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, padding: "10px 16px", borderBottom: "var(--border-thin) solid var(--border)" }}>
              <div style={{ minWidth: 0 }}>
                <div style={{ fontWeight: 600 }}>{r.item.title || r.item.mercariItemId}</div>
                <div style={{ fontSize: 12, color: "var(--muted)" }}>Won't be imported or shown again</div>
              </div>
              <button className="btn btn-ghost" onClick={() => discard(toDraft(r), false)}>Restore</button>
            </div>
          ))}
          {!drafts.length && <div style={{ padding: 24, textAlign: "center", color: "var(--muted)" }}>Nothing left to review.</div>}
        </div>
        {error && <div style={{ color: "var(--danger)", padding: "8px 16px", whiteSpace: "pre-wrap", fontSize: 13 }}>{error}</div>}
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, padding: "12px 16px", borderTop: "var(--border-thin) solid var(--border)" }}>
          <span style={{ fontSize: 12, color: "var(--muted)" }}>Click a row to edit it · {selected.length} selected</span>
          <button className="btn btn-primary" disabled={!selected.length || busy} onClick={doImport}>
            {busy ? "Importing…" : `Import ${selected.length}`}
          </button>
        </div>
      </div>
    </div>
  );
}

const Section = ({ label }) => (
  <div style={{ padding: "8px 16px", background: "var(--surface-low)", color: "var(--muted)", fontSize: 12, textTransform: "uppercase", letterSpacing: "0.06em" }}>{label}</div>
);

function chip(tone) {
  return { fontSize: 11, padding: "1px 8px", borderRadius: 999, border: `var(--border-thin) solid var(--${tone})`, color: `var(--${tone})` };
}

/** The edit form for one review row. */
function SaleEditForm({ draft, products, onBack, onSave, onNeverImport }) {
  const [d, setD] = useState(draft);
  const [picking, setPicking] = useState(false);
  const miss = missingOf(d);
  const set = (patch) => setD((x) => ({ ...x, ...patch }));

  if (picking) {
    return (
      <ProductPicker
        title={d.title}
        price={d.price}
        products={products}
        onBack={() => setPicking(false)}
        onPick={(p, variant) => {
          set({ productId: p.id, productTitle: variant ? `${p.title}, ${variant.label}` : p.title, variantSku: variant?.sku ?? null, linkKind: "linked" });
          setPicking(false);
        }}
      />
    );
  }

  const field = { display: "grid", gap: 4, fontSize: 13 };
  const input = (bad) => ({ padding: "8px 10px", borderRadius: 8, border: `var(--border-thin) solid ${bad ? "var(--danger)" : "var(--border)"}`, background: "var(--surface-low)", color: "inherit", font: "inherit" });
  return (
    <div className="modal-backdrop" onClick={onBack}>
      <div className="modal-content" style={{ maxWidth: 520, padding: 0 }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, padding: "14px 16px", borderBottom: "var(--border-thin) solid var(--border)" }}>
          <button className="btn btn-ghost" onClick={onBack}>Back</button>
          <h3 style={{ margin: 0 }}>Edit sale</h3>
          <button className="btn btn-primary" disabled={!!miss.length} onClick={() => onSave(d)}>Done</button>
        </div>
        <div style={{ display: "grid", gap: 12, padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)" }}>
            Mercari item {d.id} · <a href={`https://www.mercari.com/us/item/${d.id}/`} target="_blank" rel="noreferrer">Open on Mercari ↗</a>
          </div>
          <label style={field}><span>Title <b style={{ color: "var(--danger)" }}>*</b></span>
            <input style={input(!d.title.trim())} value={d.title} placeholder="What sold" onChange={(e) => set({ title: e.target.value })} />
          </label>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <label style={field}><span>Sale price <b style={{ color: "var(--danger)" }}>*</b></span>
              <input style={input(!(Number(d.price) > 0))} inputMode="decimal" value={d.price ?? ""} placeholder="$0.00"
                onChange={(e) => {
                  const price = e.target.value === "" ? null : e.target.value;
                  set(d.takeHomeEstimated ? { price, takeHome: estimateTakeHome(price) } : { price });
                }} />
            </label>
            <label style={field}><span>Take-home {d.takeHomeEstimated && d.takeHome != null ? <i style={{ color: "var(--muted)" }}>(estimated)</i> : null}</span>
              <input style={input(false)} inputMode="decimal" value={d.takeHome ?? ""} placeholder="after fees"
                onChange={(e) => set({ takeHome: e.target.value === "" ? null : e.target.value, takeHomeEstimated: false })} />
            </label>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <label style={field}><span>Sold on <b style={{ color: "var(--danger)" }}>*</b></span>
              <input type="date" style={input(!d.date)} value={d.date} onChange={(e) => set({ date: e.target.value })} />
            </label>
            <label style={field}><span>Quantity</span>
              <input type="number" min="1" style={input(false)} value={d.quantity} onChange={(e) => set({ quantity: Math.max(1, parseInt(e.target.value, 10) || 1) })} />
            </label>
          </div>
          <div style={field}><span>Product</span>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
              <span style={{ fontSize: 13, color: d.productId ? "inherit" : "var(--muted)" }}>
                {d.productId ? `${d.linkKind === "suggested" ? "Suggested: " : ""}${d.productTitle}` : "Not linked. The sale still counts in your totals, but no stock changes."}
              </span>
              {d.linkKind === "matched"
                ? <span style={{ fontSize: 12, color: "var(--muted)" }}>Matched by Mercari id</span>
                : <button className="btn btn-ghost" onClick={() => setPicking(true)}>{d.productId ? "Change" : "Link…"}</button>}
            </div>
            {d.productId && d.linkKind !== "matched" && <button className="btn btn-ghost" style={{ justifySelf: "start", fontSize: 12 }} onClick={() => set({ productId: null, productTitle: null, variantSku: null, linkKind: null })}>Unlink</button>}
          </div>
          <button className="btn btn-ghost" style={{ justifySelf: "start", color: "var(--danger)" }} onClick={onNeverImport}>Never import this sale</button>
          {miss.length > 0 && <div style={{ color: "var(--danger)", fontSize: 13 }}>Fill in {miss.join(", ")} to import this sale.</div>}
        </div>
      </div>
    </div>
  );
}

function variantLabel(v) {
  const values = v?.optionValues && typeof v.optionValues === "object" ? Object.values(v.optionValues).filter(Boolean) : [];
  return values.length ? values.join(" / ") : v?.sku;
}

/** Search products, then pick the version that sold when the product has variants. */
function ProductPicker({ title, price, products, onBack, onPick }) {
  const [q, setQ] = useState(() => (title || "").split(/\s+/).slice(0, 2).join(" "));
  const [chosen, setChosen] = useState(null);
  const list = useMemo(() => {
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    return products
      .filter((p) => p.title && p.isDeleted !== true)
      .filter((p) => words.every((w) => p.title.toLowerCase().includes(w)))
      .slice(0, 50);
  }, [q, products]);
  const variants = chosen ? (chosen.variants || []).filter((v) => v && v.sku && v.active !== false) : [];
  const opt = { display: "block", width: "100%", textAlign: "left", padding: "10px 16px", background: "none", border: 0, borderBottom: "var(--border-thin) solid var(--border)", color: "inherit", font: "inherit", cursor: "pointer" };

  return (
    <div className="modal-backdrop" onClick={onBack}>
      <div className="modal-content" style={{ maxWidth: 520, padding: 0 }} onClick={(e) => e.stopPropagation()}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "14px 16px", borderBottom: "var(--border-thin) solid var(--border)" }}>
          <button className="btn btn-ghost" onClick={() => (chosen ? setChosen(null) : onBack())}>Back</button>
          <h3 style={{ margin: 0 }}>{chosen ? "Which version sold?" : "Link to product"}</h3>
          <span style={{ width: 60 }} />
        </div>
        <div style={{ padding: "10px 16px", borderBottom: "var(--border-thin) solid var(--border)" }}>
          <b>{title || "Untitled sale"}</b> · {money(price)}
        </div>
        <div style={{ maxHeight: "50vh", overflowY: "auto" }}>
          {chosen ? variants.map((v) => (
            <button key={v.sku} style={opt} onClick={() => onPick(chosen, { sku: v.sku, label: variantLabel(v) })}>{variantLabel(v)}</button>
          )) : (
            <>
              <div style={{ padding: "10px 16px" }}>
                <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search your products" aria-label="Search products"
                  style={{ width: "100%", boxSizing: "border-box", padding: "8px 10px", borderRadius: 8, border: "var(--border-thin) solid var(--border)", background: "var(--surface-low)", color: "inherit", font: "inherit" }} />
              </div>
              {list.map((p) => {
                const hasVariants = (p.variants || []).some((v) => v && v.sku && v.active !== false);
                return (
                  <button key={p.id} style={opt} onClick={() => (hasVariants ? setChosen(p) : onPick(p, null))}>
                    {p.title}{hasVariants ? " ›" : ""}
                  </button>
                );
              })}
              {!list.length && <div style={{ padding: 20, textAlign: "center", color: "var(--muted)" }}>No products match.</div>}
            </>
          )}
        </div>
        <div style={{ padding: "10px 16px", fontSize: 12, color: "var(--muted)" }}>
          The Mercari id is saved on this product, so the next refresh records its sales on its own.
        </div>
      </div>
    </div>
  );
}
