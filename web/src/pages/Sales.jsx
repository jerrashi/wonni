import { useState, useEffect, useMemo } from "react";
import { collection, query, where, orderBy, onSnapshot, doc, deleteDoc } from "firebase/firestore";
import { db, auth } from "../firebase";
import Layout from "../components/Layout";
import LogSaleModal from "../components/LogSaleModal";

const PLATFORM_LABELS = {
  mercari: { label: "Mercari", color: "#e11d48", icon: "🔴" },
  ebay: { label: "eBay", color: "#0064d2", icon: "🔵" },
  etsy: { label: "Etsy", color: "#f97316", icon: "🟠" },
  wonni: { label: "Wonni", color: "#8b5cf6", icon: "🟣" },
  manual: { label: "In Person", color: "#64748b", icon: "⚪" },
};

export default function Sales() {
  const [sales, setSales] = useState([]);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [showLogModal, setShowLogModal] = useState(false);
  const [platformFilter, setPlatformFilter] = useState("all");
  const [tagFilter, setTagFilter] = useState("all");
  const [searchQuery, setSearchQuery] = useState("");
  const [deletingId, setDeletingId] = useState(null);

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) {
      setLoading(false);
      return;
    }
    setLoading(true);

    // Fetch user products for auto-matching and tagging
    const prodQ = query(collection(db, "products"), where("userId", "==", uid));
    const unsubProd = onSnapshot(prodQ, (snap) => {
      setProducts(snap.docs.map((d) => ({ id: d.id, ...d.data() })));
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
        }).filter((s) => !s.isDeleted);
        // Sort in memory by soldAt or createdAt
        items.sort((a, b) => {
          const tA = a.soldAt?.toDate?.()?.getTime() || a.createdAt?.toDate?.()?.getTime() || 0;
          const tB = b.soldAt?.toDate?.()?.getTime() || b.createdAt?.toDate?.()?.getTime() || 0;
          return tB - tA;
        });
        setSales(items);
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
      unsubSales();
    };
  }, []);

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

  // Aggregate Metrics
  const metrics = useMemo(() => {
    let totalRevenue = 0;
    let totalUnits = 0;

    sales.forEach((s) => {
      const price = typeof s.salePrice === "number" ? s.salePrice : 0;
      const qty = typeof s.quantity === "number" ? s.quantity : 1;
      totalRevenue += price * qty;
      totalUnits += qty;
    });

    const avgOrderValue = totalUnits > 0 ? totalRevenue / totalUnits : 0;

    // Platform breakdown
    const platformBreakdown = {};
    // Tag breakdown
    const tagBreakdown = {};
    // Product breakdown
    const productBreakdown = {};

    sales.forEach((s) => {
      const qty = typeof s.quantity === "number" ? s.quantity : 1;
      const rev = (typeof s.salePrice === "number" ? s.salePrice : 0) * qty;

      // Platform
      const plat = s.platform || "manual";
      if (!platformBreakdown[plat]) platformBreakdown[plat] = { count: 0, revenue: 0 };
      platformBreakdown[plat].count += qty;
      platformBreakdown[plat].revenue += rev;

      // Tags
      const tags = Array.isArray(s.productTags) && s.productTags.length > 0 ? s.productTags : ["Untagged"];
      tags.forEach((t) => {
        if (!tagBreakdown[t]) tagBreakdown[t] = { count: 0, revenue: 0 };
        tagBreakdown[t].count += qty;
        tagBreakdown[t].revenue += rev;
      });

      // Product
      const pTitle = s.productTitle || "Other Product";
      if (!productBreakdown[pTitle]) productBreakdown[pTitle] = { count: 0, revenue: 0, image: s.productImageUrl };
      productBreakdown[pTitle].count += qty;
      productBreakdown[pTitle].revenue += rev;
    });

    return {
      totalRevenue,
      totalUnits,
      avgOrderValue,
      platformBreakdown,
      tagBreakdown,
      productBreakdown,
    };
  }, [sales]);

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

  async function handleDeleteSale(saleId) {
    if (!window.confirm("Are you sure you want to delete this sale record?")) return;
    setDeletingId(saleId);
    try {
      await deleteDoc(doc(db, "sales", saleId));
    } catch (e) {
      alert("Failed to delete sale: " + e.message);
    } finally {
      setDeletingId(null);
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
        <button className="btn btn-primary" onClick={() => setShowLogModal(true)}>
          💰 Log Sale
        </button>
      </div>

      {error && <div className="card" style={{ marginBottom: 20, color: "var(--danger)" }}>{error}</div>}

      {/* Top Metrics Cards */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 16, marginBottom: 24 }}>
        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Total Revenue
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4, color: "var(--success)" }}>
            ${metrics.totalRevenue.toFixed(2)}
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Total Units Sold
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4 }}>
            {metrics.totalUnits} items
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Avg Unit Price
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4 }}>
            ${metrics.avgOrderValue.toFixed(2)}
          </div>
        </div>

        <div className="card" style={{ padding: 16 }}>
          <div style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Top Platform
          </div>
          <div style={{ fontSize: 18, fontWeight: 700, marginTop: 8 }}>
            {Object.entries(metrics.platformBreakdown).sort((a, b) => b[1].revenue - a[1].revenue)[0]
              ? `${PLATFORM_LABELS[Object.entries(metrics.platformBreakdown).sort((a, b) => b[1].revenue - a[1].revenue)[0][0]]?.label || "None"} ($${Object.entries(metrics.platformBreakdown).sort((a, b) => b[1].revenue - a[1].revenue)[0][1].revenue.toFixed(0)})`
              : "—"}
          </div>
        </div>
      </div>

      {/* Analytics Breakdown Grid: By Tag & By Product */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))", gap: 16, marginBottom: 24 }}>
        {/* Tag Breakdown */}
        <div className="card" style={{ padding: 16 }}>
          <h3 style={{ margin: "0 0 12px 0", fontSize: 14 }}>🏷️ Sales by Tag</h3>
          {Object.keys(metrics.tagBreakdown).length === 0 ? (
            <div style={{ fontSize: 13, color: "var(--muted)" }}>No tagged sales recorded yet.</div>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {Object.entries(metrics.tagBreakdown)
                .sort((a, b) => b[1].revenue - a[1].revenue)
                .map(([tag, data]) => (
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
                      {data.count} sold · <strong>${data.revenue.toFixed(2)}</strong>
                    </span>
                  </div>
                ))}
            </div>
          )}
        </div>

        {/* Platform Breakdown */}
        <div className="card" style={{ padding: 16 }}>
          <h3 style={{ margin: "0 0 12px 0", fontSize: 14 }}>🌐 Sales by Platform</h3>
          {Object.keys(metrics.platformBreakdown).length === 0 ? (
            <div style={{ fontSize: 13, color: "var(--muted)" }}>No platform sales recorded yet.</div>
          ) : (
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {Object.entries(metrics.platformBreakdown)
                .sort((a, b) => b[1].revenue - a[1].revenue)
                .map(([plat, data]) => (
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
                      {data.count} sold · <strong>${data.revenue.toFixed(2)}</strong>
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

      {/* Sales Table */}
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

                    <td style={{ padding: "12px 16px", textAlign: "right" }}>
                      <button
                        className="btn btn-ghost"
                        style={{ padding: "4px 8px", fontSize: 12, color: "var(--danger)" }}
                        disabled={deletingId === s.id}
                        onClick={() => handleDeleteSale(s.id)}
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

      {showLogModal && (
        <LogSaleModal
          products={products}
          onClose={() => setShowLogModal(false)}
          onSaleLogged={() => {}}
        />
      )}
    </Layout>
  );
}
