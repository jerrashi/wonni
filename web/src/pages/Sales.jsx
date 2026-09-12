import { useState, useEffect, useMemo } from "react";
import { collection, query, where, onSnapshot, doc, updateDoc, serverTimestamp } from "firebase/firestore";
import { db, auth, callFunction } from "../firebase";
import Layout from "../components/Layout";
import LogSaleModal from "../components/LogSaleModal";
import EditSaleModal from "../components/EditSaleModal";
import { aggregate, trend } from "../lib/salesMetrics";
import { BUILT_IN_SALE_STAGES, BUILT_IN_CHIP_CLASS } from "../lib/saleStages";

const PLATFORM_LABELS = {
  mercari: { label: "Mercari", color: "#e11d48", icon: "🔴" },
  ebay: { label: "eBay", color: "#0064d2", icon: "🔵" },
  etsy: { label: "Etsy", color: "#f97316", icon: "🟠" },
  wonni: { label: "Wonni", color: "#8b5cf6", icon: "🟣" },
  manual: { label: "In Person", color: "#64748b", icon: "⚪" },
};

const VIEW_STORAGE_KEY = "wonni.sales.view";

function TrendChart({ points }) {
  if (points.length === 0) return null;
  const w = 640, h = 120, padL = 36, padB = 20, padT = 8;
  const plotW = w - padL - 8;
  const plotH = h - padT - padB;
  const maxRevenue = Math.max(1, ...points.map((p) => p.revenue));
  const barW = plotW / points.length;

  return (
    <svg viewBox={`0 0 ${w} ${h}`} style={{ width: "100%", height: "auto", display: "block" }}>
      {/* gridline at 0 */}
      <line x1={padL} y1={h - padB} x2={w - 4} y2={h - padB} stroke="var(--border)" strokeWidth="1" />
      {[0.5, 1].map((frac) => (
        <text key={frac} x={padL - 6} y={h - padB - frac * plotH + 3} textAnchor="end" fontSize="9" fill="var(--muted)">
          ${Math.round(maxRevenue * frac)}
        </text>
      ))}
      {points.map((p, i) => {
        const barH = (p.revenue / maxRevenue) * plotH;
        const x = padL + i * barW + barW * 0.15;
        const bw = barW * 0.7;
        const y = h - padB - barH;
        const netY = h - padB - (Math.max(p.net, 0) / maxRevenue) * plotH;
        const d = new Date(p.periodStart);
        const label = `${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
        return (
          <g key={p.periodStart}>
            <rect x={x} y={y} width={bw} height={Math.max(barH, 0.5)} rx="2" fill="var(--accent)" opacity="0.35">
              <title>{`${label}: $${p.revenue.toFixed(2)} revenue, ${p.count} sale${p.count === 1 ? "" : "s"}`}</title>
            </rect>
            <circle cx={x + bw / 2} cy={netY} r="2.5" fill="var(--success)">
              <title>{`${label}: $${p.net.toFixed(2)} net`}</title>
            </circle>
            <text x={x + bw / 2} y={h - 6} textAnchor="middle" fontSize="9" fill="var(--muted)">{label}</text>
          </g>
        );
      })}
    </svg>
  );
}

export default function Sales() {
  const [allSales, setAllSales] = useState([]);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [showLogModal, setShowLogModal] = useState(false);
  const [editingSale, setEditingSale] = useState(null);
  const [platformFilter, setPlatformFilter] = useState("all");
  const [tagFilter, setTagFilter] = useState("all");
  const [searchQuery, setSearchQuery] = useState("");
  const [deletingId, setDeletingId] = useState(null);
  const [syncing, setSyncing] = useState(false);
  const [syncNote, setSyncNote] = useState("");
  const [showDeleted, setShowDeleted] = useState(false);
  const [undoToast, setUndoToast] = useState(null); // { saleId, title }
  const [saleStages, setSaleStages] = useState(BUILT_IN_SALE_STAGES);
  const [view, setView] = useState(() => {
    try { return localStorage.getItem(VIEW_STORAGE_KEY) || "spreadsheet"; } catch { return "spreadsheet"; }
  });
  const [movingSaleId, setMovingSaleId] = useState(null);
  const [dragOverKey, setDragOverKey] = useState(null);

  function switchView(next) {
    setView(next);
    try { localStorage.setItem(VIEW_STORAGE_KEY, next); } catch { /* private-browsing, non-fatal */ }
  }

  const stageLabel = (key) => saleStages.find((s) => s.key === key)?.label ?? key;
  const stageChipClass = (key) => BUILT_IN_CHIP_CLASS[key] ?? "chip-draft";

  async function handleSync() {
    setSyncing(true);
    setSyncNote("");
    setError("");
    try {
      const res = await callFunction("syncSales")({});
      const { imported = 0, skipped = 0, errors = [] } = res.data || {};
      const parts = [`${imported} new`];
      if (skipped) parts.push(`${skipped} already logged`);
      for (const e of errors) parts.push(`${e.platform}: ${e.message}`);
      setSyncNote(parts.join(" · "));
      // The sales onSnapshot listener picks up any new rows automatically.
    } catch (e) {
      setError("Sync failed: " + (e?.message ?? e));
    } finally {
      setSyncing(false);
    }
  }

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) {
      setLoading(false);
      return;
    }
    setLoading(true);

    // Fetch user products for auto-matching, tagging, and cost lookup
    const prodQ = query(collection(db, "products"), where("userId", "==", uid));
    const unsubProd = onSnapshot(prodQ, (snap) => {
      setProducts(snap.docs.map((d) => ({ id: d.id, ...d.data() })));
    });

    // Board columns / status dropdown options — mirrors sale_stages.js's
    // loadSaleStages fallback (empty/missing → the 6 built-ins).
    const unsubUser = onSnapshot(doc(db, "users", uid), (snap) => {
      const stored = snap.data()?.saleStages;
      setSaleStages(Array.isArray(stored) && stored.length > 0 ? stored : BUILT_IN_SALE_STAGES);
    });

    // Real-time sales listener (syncs across desktop & mobile)
    const salesQ = query(
      collection(db, "sales"),
      where("userId", "==", uid)
    );

    const unsubSales = onSnapshot(
      salesQ,
      (snap) => {
        const items = snap.docs.map((d) => {
          const x = { id: d.id, ...d.data() };
          // Canonical SaleDoc (functions/contracts/sales.js) renamed a few
          // fields; keep the old names populated so this view works for both
          // pre-migration docs and new recordSale-written ones.
          return {
            ...x,
            salePrice: typeof x.priceSoldFor === "number" ? x.priceSoldFor : x.salePrice,
            productTitle: x.listingTitle ?? x.productTitle,
            productImageUrl: x.thumbnailUrl ?? x.productImageUrl,
            isDeleted: x.isDeleted === true,
          };
        });
        items.sort((a, b) => {
          const tA = a.soldAt?.toDate?.()?.getTime() || a.createdAt?.toDate?.()?.getTime() || 0;
          const tB = b.soldAt?.toDate?.()?.getTime() || b.createdAt?.toDate?.()?.getTime() || 0;
          return tB - tA;
        });
        setAllSales(items);
        setLoading(false);
      },
      (err) => {
        console.error("Sales snapshot error:", err);
        setError(err?.message ?? "Could not load sales.");
        setLoading(false);
      }
    );

    return () => {
      unsubProd();
      unsubUser();
      unsubSales();
    };
  }, []);

  const sales = useMemo(() => allSales.filter((s) => !s.isDeleted), [allSales]);
  const deletedSales = useMemo(() => allSales.filter((s) => s.isDeleted), [allSales]);
  const productsById = useMemo(() => Object.fromEntries(products.map((p) => [p.id, p])), [products]);

  // Collect all unique tags across sales and products
  const allTags = useMemo(() => {
    const tagsSet = new Set();
    sales.forEach((s) => {
      if (Array.isArray(s.productTags)) {
        s.productTags.forEach((t) => tagsSet.add(t));
      }
    });
    products.forEach((p) => {
      if (Array.isArray(p.tags)) {
        p.tags.forEach((t) => tagsSet.add(t));
      }
    });
    return Array.from(tagsSet);
  }, [sales, products]);

  // Profit/aggregation math — functions/sales_metrics.js mirror.
  const byPlatform = useMemo(() => aggregate(sales, productsById, { groupBy: "platform" }), [sales, productsById]);
  const byTag = useMemo(() => aggregate(sales, productsById, { groupBy: "tag" }), [sales, productsById]);
  const totals = byPlatform.totals; // same overall totals regardless of grouping
  const trendPoints = useMemo(() => {
    const pts = trend(sales, { bucket: "week", productsById });
    return pts.slice(-8);
  }, [sales, productsById]);

  const topPlatform = byPlatform.groups[0];

  // Filtered Sales
  const filteredSales = useMemo(() => {
    return sales.filter((s) => {
      if (platformFilter !== "all" && s.platform !== platformFilter) return false;
      if (tagFilter !== "all") {
        if (!Array.isArray(s.productTags) || !s.productTags.includes(tagFilter)) return false;
      }
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase();
        const titleMatch = (s.productTitle || "").toLowerCase().includes(q);
        const skuMatch = (s.variantSku || "").toLowerCase().includes(q);
        const notesMatch = (s.notes || "").toLowerCase().includes(q);
        if (!titleMatch && !skuMatch && !notesMatch) return false;
      }
      return true;
    });
  }, [sales, platformFilter, tagFilter, searchQuery]);

  async function handleDeleteSale(sale) {
    setDeletingId(sale.id);
    try {
      await updateDoc(doc(db, "sales", sale.id), {
        isDeleted: true,
        deletedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      });
      setUndoToast({ saleId: sale.id, title: sale.productTitle || "Sale" });
      setTimeout(() => setUndoToast((t) => (t?.saleId === sale.id ? null : t)), 5000);
    } catch (e) {
      alert("Failed to delete sale: " + e.message);
    } finally {
      setDeletingId(null);
    }
  }

  async function handleUndoDelete(saleId) {
    setUndoToast(null);
    try {
      await updateDoc(doc(db, "sales", saleId), { isDeleted: false, deletedAt: null, updatedAt: serverTimestamp() });
    } catch (e) {
      alert("Failed to undo delete: " + e.message);
    }
  }

  // The one path a user has to move a sale between buckets (board drag or
  // spreadsheet dropdown) — routes through updateSaleStatus so the server
  // validates the target key against this user's saleStages and, on a move
  // into cancelled/returned, auto re-fetches the real take-home
  // (docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §4/§6).
  async function handleStatusChange(saleId, status) {
    setMovingSaleId(saleId);
    try {
      await callFunction("updateSaleStatus")({ saleId, status });
    } catch (e) {
      alert("Failed to move sale: " + (e?.message ?? e));
    } finally {
      setMovingSaleId(null);
    }
  }

  return (
    <Layout>
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1 style={{ margin: 0 }}>📊 Sales Tracker</h1>
          <span style={{ fontSize: 13, color: "var(--muted)" }}>
            Cross-platform sales sync for Mercari, eBay, Etsy, & Wonni
          </span>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          {syncNote && <span style={{ fontSize: 12, color: "var(--muted)" }}>{syncNote}</span>}
          <button className="btn" onClick={handleSync} disabled={syncing}>
            {syncing ? "Syncing…" : "🔄 Sync eBay / Etsy"}
          </button>
          <button className="btn btn-primary" onClick={() => setShowLogModal(true)}>
            💰 Log Sale
          </button>
        </div>
      </div>

      {error && <div className="card" style={{ marginBottom: 20, color: "var(--danger)" }}>{error}</div>}

      {/* Top Metrics Cards */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))", gap: 16, marginBottom: 24 }}>
        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Total Revenue
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4, color: "var(--success)" }}>
            ${totals.revenue.toFixed(2)}
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Net Profit{totals.netIsEstimate ? " ~" : ""}
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4 }} title={totals.netIsEstimate ? "Some sales are missing a real take-home; estimated from platform fee %" : "Real take-home minus cost of goods"}>
            ${totals.net.toFixed(2)}
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Est. Margin
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4 }}>
            {totals.revenue > 0 ? `${((totals.net / totals.revenue) * 100).toFixed(0)}%` : "—"}
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Cost of Goods
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4 }}>
            ${totals.cost.toFixed(2)}
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Total Units Sold
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4 }}>
            {totals.units} items
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Top Platform
          </div>
          <div style={{ fontSize: 18, fontWeight: 700, marginTop: 8 }}>
            {topPlatform
              ? `${PLATFORM_LABELS[topPlatform.key]?.label || topPlatform.key} ($${topPlatform.totals.revenue.toFixed(0)})`
              : "—"}
          </div>
        </div>
      </div>

      {/* 8-Week Trend */}
      {trendPoints.length > 0 && (
        <div className="card" style={{ padding: 16, marginBottom: 24 }}>
          <h3 style={{ margin: "0 0 12px 0", fontSize: 14 }}>
            📈 8-Week Trend <span style={{ fontWeight: 400, color: "var(--muted)", fontSize: 12 }}>(bars = revenue, dots = net)</span>
          </h3>
          <TrendChart points={trendPoints} />
        </div>
      )}

      {/* Analytics Breakdown Grid: By Tag & By Product */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))", gap: 16, marginBottom: 24 }}>
        {/* Tag Breakdown */}
        <div className="card" style={{ padding: 16 }}>
          <h3 style={{ margin: "0 0 12px 0", fontSize: 14 }}>🏷️ Sales by Tag</h3>
          {byTag.groups.length === 0 ? (
            <div style={{ fontSize: 13, color: "var(--muted)" }}>No tagged sales recorded yet.</div>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {byTag.groups.map(({ key: tag, totals: t }) => (
                <div
                  key={tag}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    padding: "8px 12px",
                    background: "var(--surface-high)",
                    borderRadius: "var(--radius)",
                    cursor: "pointer",
                    border: tagFilter === tag ? "1px solid var(--accent)" : "none",
                  }}
                  onClick={() => setTagFilter(tagFilter === tag ? "all" : tag)}
                >
                  <span style={{ fontWeight: 600, fontSize: 13, color: "var(--accent)" }}>
                    {tag}
                  </span>
                  <span style={{ fontSize: 12, color: "var(--text)" }}>
                    {t.units} sold · <strong>${t.revenue.toFixed(2)}</strong>
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Platform Breakdown */}
        <div className="card" style={{ padding: 16 }}>
          <h3 style={{ margin: "0 0 12px 0", fontSize: 14 }}>🌐 Sales by Platform</h3>
          {byPlatform.groups.length === 0 ? (
            <div style={{ fontSize: 13, color: "var(--muted)" }}>No platform sales recorded yet.</div>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {byPlatform.groups.map(({ key: plat, totals: t }) => (
                <div
                  key={plat}
                  style={{
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    padding: "8px 12px",
                    background: "var(--surface-high)",
                    borderRadius: "var(--radius)",
                    cursor: "pointer",
                    border: platformFilter === plat ? "1px solid var(--primary)" : "none",
                  }}
                  onClick={() => setPlatformFilter(platformFilter === plat ? "all" : plat)}
                >
                  <span style={{ display: "flex", alignItems: "center", gap: 6, fontWeight: 600, fontSize: 13 }}>
                    {PLATFORM_LABELS[plat]?.icon} {PLATFORM_LABELS[plat]?.label || plat}
                  </span>
                  <span style={{ fontSize: 12 }}>
                    {t.units} sold · <strong>${t.revenue.toFixed(2)}</strong>
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Filter and Search Bar */}
      <div className="card" style={{ marginBottom: 20, padding: 16 }}>
        <div style={{ display: "flex", gap: 12, flexWrap: "wrap", alignItems: "center", justifyContent: "space-between" }}>
          {/* Platform Filters */}
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>
            <span style={{ fontSize: 12, fontWeight: 600, color: "var(--muted)" }}>Platform:</span>
            <button
              className={`chip ${platformFilter === "all" ? "chip-primary" : "chip-draft"}`}
              onClick={() => setPlatformFilter("all")}
            >
              All
            </button>
            {Object.keys(PLATFORM_LABELS).map((k) => (
              <button
                key={k}
                className={`chip ${platformFilter === k ? "chip-primary" : "chip-draft"}`}
                onClick={() => setPlatformFilter(k)}
              >
                {PLATFORM_LABELS[k].icon} {PLATFORM_LABELS[k].label}
              </button>
            ))}
          </div>

          {/* Search Box */}
          <div style={{ minWidth: 220 }}>
            <input
              className="input"
              type="text"
              placeholder="Search sales or SKU…"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              style={{ fontSize: 12, padding: "6px 12px" }}
            />
          </div>
        </div>

        {/* Tag Filters */}
        {allTags.length > 0 && (
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center", marginTop: 12, paddingTop: 12, borderTop: "var(--border-thin) solid var(--border)" }}>
            <span style={{ fontSize: 12, fontWeight: 600, color: "var(--muted)" }}>Filter Tag:</span>
            <button
              className={`chip ${tagFilter === "all" ? "chip-primary" : "chip-draft"}`}
              onClick={() => setTagFilter("all")}
            >
              All Tags
            </button>
            {allTags.map((t) => (
              <button
                key={t}
                className={`chip ${tagFilter === t ? "chip-primary" : "chip-draft"}`}
                onClick={() => setTagFilter(tagFilter === t ? "all" : t)}
              >
                🏷️ {t}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* View toggle */}
      <div style={{ display: "flex", gap: 6, marginBottom: 12 }}>
        <button
          className={`chip ${view === "board" ? "chip-primary" : "chip-draft"}`}
          onClick={() => switchView("board")}
        >
          🗂️ Board
        </button>
        <button
          className={`chip ${view === "spreadsheet" ? "chip-primary" : "chip-draft"}`}
          onClick={() => switchView("spreadsheet")}
        >
          📋 Spreadsheet
        </button>
      </div>

      {/* Sales Board */}
      {!loading && view === "board" && (
        <div style={{ display: "flex", gap: 12, overflowX: "auto", paddingBottom: 8, marginBottom: 20 }}>
          {saleStages.map((stage) => {
            const stageSales = filteredSales.filter((s) => s.status === stage.key);
            return (
              <div
                key={stage.key}
                onDragOver={(e) => { e.preventDefault(); setDragOverKey(stage.key); }}
                onDragLeave={() => setDragOverKey((k) => (k === stage.key ? null : k))}
                onDrop={(e) => {
                  e.preventDefault();
                  setDragOverKey(null);
                  const saleId = e.dataTransfer.getData("text/sale-id");
                  if (saleId) handleStatusChange(saleId, stage.key);
                }}
                className="card"
                style={{
                  minWidth: 220, maxWidth: 260, flex: "0 0 auto", padding: 10,
                  background: dragOverKey === stage.key ? "var(--surface-high)" : "var(--surface)",
                  border: dragOverKey === stage.key ? "var(--border-thick) dashed var(--accent)" : undefined,
                }}
              >
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                  <span style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.03em", color: "var(--muted)" }}>
                    {stage.label}
                  </span>
                  <span style={{ fontSize: 11, color: "var(--muted)" }}>{stageSales.length}</span>
                </div>
                <div style={{ display: "flex", flexDirection: "column", gap: 8, minHeight: 40 }}>
                  {stageSales.map((s) => {
                    const plat = PLATFORM_LABELS[s.platform] || PLATFORM_LABELS.manual;
                    const total = ((s.salePrice || 0) * (s.quantity || 1)).toFixed(2);
                    return (
                      <div
                        key={s.id}
                        draggable
                        onDragStart={(e) => e.dataTransfer.setData("text/sale-id", s.id)}
                        onClick={() => setEditingSale(s)}
                        style={{
                          padding: 8, borderRadius: "var(--radius)", background: "var(--surface-high)",
                          border: "var(--border-thin) solid var(--border)", cursor: "grab",
                          opacity: movingSaleId === s.id ? 0.5 : 1,
                        }}
                        title="Drag to move · click to edit"
                      >
                        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                          {s.productImageUrl && (
                            <img src={s.productImageUrl} alt="" style={{ width: 24, height: 24, borderRadius: 3, objectFit: "cover" }} />
                          )}
                          <span style={{ fontSize: 12, fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                            {s.productTitle || "Manual sale"}
                          </span>
                        </div>
                        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 6 }}>
                          <span style={{ fontSize: 11 }}>{plat.icon} {plat.label}</span>
                          <span style={{ fontSize: 12, fontWeight: 700, color: "var(--success)" }}>${total}</span>
                        </div>
                      </div>
                    );
                  })}
                  {stageSales.length === 0 && (
                    <div style={{ fontSize: 11, color: "var(--muted)", textAlign: "center", padding: "12px 0" }}>drop here</div>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Sales Table */}
      {view === "spreadsheet" && (<>
      {loading ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>⏳</div>
          <p>Loading sales history…</p>
        </div>
      ) : filteredSales.length === 0 ? (
        <div className="empty-state card">
          <div style={{ fontSize: 32 }}>🛍️</div>
          <p>No sales recorded yet. Click "Log Sale" to add a Mercari, eBay, or in-person sale.</p>
          <button className="btn btn-primary" style={{ marginTop: 12 }} onClick={() => setShowLogModal(true)}>
            💰 Log Sale
          </button>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: "auto" }}>
          <table className="table" style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ borderBottom: "var(--border-thin) solid var(--border)", textAlign: "left" }}>
                <th style={{ padding: "12px 16px" }}>Date</th>
                <th style={{ padding: "12px 16px" }}>Product</th>
                <th style={{ padding: "12px 16px" }}>Platform</th>
                <th style={{ padding: "12px 16px" }}>Variant / SKU</th>
                <th style={{ padding: "12px 16px" }}>Qty</th>
                <th style={{ padding: "12px 16px" }}>Total Price</th>
                <th style={{ padding: "12px 16px" }}>Status</th>
                <th style={{ padding: "12px 16px" }}>Tags</th>
                <th style={{ padding: "12px 16px", textAlign: "right" }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {filteredSales.map((s) => {
                const dateStr = s.soldAt?.toDate?.()
                  ? s.soldAt.toDate().toLocaleDateString()
                  : s.createdAt?.toDate?.()
                  ? s.createdAt.toDate().toLocaleDateString()
                  : "—";
                const plat = PLATFORM_LABELS[s.platform] || PLATFORM_LABELS.manual;
                const total = ((s.salePrice || 0) * (s.quantity || 1)).toFixed(2);
                // A sale can carry a status that isn't (or no longer is) one of
                // this user's saleStages — e.g. a bucket got deleted, or a poller
                // wrote a status ahead of stages loading. Show it anyway as an
                // extra option so the dropdown never silently blanks.
                const hasCurrentStage = saleStages.some((st) => st.key === s.status);
                const stageOptions = hasCurrentStage || !s.status
                  ? saleStages
                  : [...saleStages, { key: s.status, label: stageLabel(s.status) }];

                return (
                  <tr key={s.id} style={{ borderBottom: "var(--border-thin) solid var(--border)" }}>
                    <td style={{ padding: "12px 16px", fontSize: 12, color: "var(--muted)", whiteSpace: "nowrap" }}>
                      {dateStr}
                    </td>

                    <td style={{ padding: "12px 16px" }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                        {s.productImageUrl && (
                          <img
                            src={s.productImageUrl}
                            alt=""
                            style={{ width: 32, height: 32, borderRadius: 4, objectFit: "cover" }}
                          />
                        )}
                        <div>
                          <div style={{ fontWeight: 600, fontSize: 13 }}>{s.productTitle}</div>
                          {s.externalUrl && (
                            <a
                              href={s.externalUrl}
                              target="_blank"
                              rel="noreferrer"
                              style={{ fontSize: 11, color: "var(--accent)", textDecoration: "underline" }}
                            >
                              View Listing ↗
                            </a>
                          )}
                        </div>
                      </div>
                    </td>

                    <td style={{ padding: "12px 16px" }}>
                      <span className="chip" style={{ fontSize: 11, background: "var(--surface-high)" }}>
                        {plat.icon} {plat.label}
                      </span>
                    </td>

                    <td style={{ padding: "12px 16px", fontSize: 12 }}>
                      {s.variantSku ? <span style={{ fontFamily: "monospace" }}>{s.variantSku}</span> : "—"}
                      {s.variantOptionValues && (
                        <div style={{ fontSize: 11, color: "var(--muted)" }}>
                          {Object.entries(s.variantOptionValues).map(([k, v]) => `${k}: ${v}`).join(", ")}
                        </div>
                      )}
                    </td>

                    <td style={{ padding: "12px 16px", fontSize: 13, fontWeight: 500 }}>
                      {s.quantity || 1}
                    </td>

                    <td style={{ padding: "12px 16px", fontSize: 13, fontWeight: 700, color: "var(--success)" }}>
                      ${total}
                    </td>

                    <td style={{ padding: "12px 16px" }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                        <span className={`chip ${stageChipClass(s.status)}`} style={{ fontSize: 11 }}>
                          {stageLabel(s.status)}
                        </span>
                        <select
                          className="input"
                          style={{ fontSize: 11, padding: "2px 6px", width: "auto" }}
                          value={s.status || ""}
                          disabled={movingSaleId === s.id}
                          onChange={(e) => handleStatusChange(s.id, e.target.value)}
                          title="Move to a different stage"
                        >
                          {stageOptions.map((st) => (
                            <option key={st.key} value={st.key}>{st.label}</option>
                          ))}
                        </select>
                      </div>
                    </td>

                    <td style={{ padding: "12px 16px" }}>
                      {Array.isArray(s.productTags) && s.productTags.length > 0 ? (
                        <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                          {s.productTags.map((t) => (
                            <span
                              key={t}
                              style={{
                                fontSize: 10,
                                padding: "2px 6px",
                                borderRadius: 4,
                                background: "rgba(99, 102, 241, 0.15)",
                                color: "var(--accent)",
                                border: "1px solid var(--accent)",
                              }}
                            >
                              {t}
                            </span>
                          ))}
                        </div>
                      ) : (
                        <span style={{ fontSize: 12, color: "var(--muted)" }}>—</span>
                      )}
                    </td>

                    <td style={{ padding: "12px 16px", textAlign: "right", whiteSpace: "nowrap" }}>
                      <button
                        className="btn btn-ghost"
                        style={{ padding: "4px 8px", fontSize: 12 }}
                        onClick={() => setEditingSale(s)}
                        title="Edit Sale"
                      >
                        ✏️
                      </button>
                      <button
                        className="btn btn-ghost"
                        style={{ padding: "4px 8px", fontSize: 12, color: "var(--danger)" }}
                        disabled={deletingId === s.id}
                        onClick={() => handleDeleteSale(s)}
                        title="Delete Sale Record"
                      >
                        ✕
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      </>)}

      {/* Deleted Section */}
      {deletedSales.length > 0 && (
        <div style={{ marginTop: 20 }}>
          <button
            className="btn btn-ghost"
            style={{ fontSize: 12, color: "var(--muted)" }}
            onClick={() => setShowDeleted((v) => !v)}
          >
            {showDeleted ? "▾" : "▸"} Deleted ({deletedSales.length})
          </button>
          {showDeleted && (
            <div className="card" style={{ padding: 0, overflowX: "auto", marginTop: 8, opacity: 0.7 }}>
              <table className="table" style={{ width: "100%", borderCollapse: "collapse" }}>
                <tbody>
                  {deletedSales.map((s) => (
                    <tr key={s.id} style={{ borderBottom: "var(--border-thin) solid var(--border)" }}>
                      <td style={{ padding: "8px 16px", fontSize: 13 }}>{s.productTitle || "Manual sale"}</td>
                      <td style={{ padding: "8px 16px", fontSize: 12, color: "var(--muted)" }}>
                        ${(s.salePrice || 0).toFixed(2)}
                      </td>
                      <td style={{ padding: "8px 16px", textAlign: "right" }}>
                        <button className="btn btn-ghost" style={{ fontSize: 12 }} onClick={() => handleUndoDelete(s.id)}>
                          ↩ Restore
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {/* Undo Toast */}
      {undoToast && (
        <div
          style={{
            position: "fixed",
            bottom: 24,
            left: "50%",
            transform: "translateX(-50%)",
            background: "var(--surface-high)",
            border: "var(--border-thin) solid var(--border)",
            borderRadius: "var(--radius)",
            padding: "10px 16px",
            display: "flex",
            alignItems: "center",
            gap: 12,
            boxShadow: "0 4px 16px rgba(0,0,0,0.2)",
            zIndex: 1000,
          }}
        >
          <span style={{ fontSize: 13 }}>“{undoToast.title}” deleted</span>
          <button className="btn btn-primary" style={{ fontSize: 12, padding: "4px 10px" }} onClick={() => handleUndoDelete(undoToast.saleId)}>
            Undo
          </button>
        </div>
      )}

      {showLogModal && (
        <LogSaleModal
          products={products}
          onClose={() => setShowLogModal(false)}
          onSaleLogged={() => {}}
        />
      )}

      {editingSale && (
        <EditSaleModal
          sale={editingSale}
          onClose={() => setEditingSale(null)}
          onSaved={() => {}}
        />
      )}
    </Layout>
  );
}
