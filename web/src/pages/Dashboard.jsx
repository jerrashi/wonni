import { useState, useEffect, useRef, useMemo } from "react";
import { collection, doc, deleteDoc, query, where, orderBy, onSnapshot } from "firebase/firestore";
import { useNavigate } from "react-router-dom";
import { db, callFunction } from "../firebase";
import { auth } from "../firebase";
import Layout from "../components/Layout";
import CreateDraftModal from "../components/CreateDraftModal";
import PostModal from "../components/PostModal";
import BulkPostModal from "../components/BulkPostModal";
import BulkTagModal from "../components/BulkTagModal";
import OverflowMenu from "../components/OverflowMenu";
import { getPlatformListingUrl } from "../lib/platformLinks";

// ── List Modal ────────────────────────────────────────────────────────────────

function ListModal({ product, onClose, onListed }) {
  const [title, setTitle] = useState(product.title.slice(0, 255));
  const [price, setPrice] = useState(
    ((product.listingPrice ?? (product.sourceCost ?? product.aliexpressPrice ?? 0) * 2.5) || 0).toFixed(2)
  );
  const [categories, setCategories] = useState([]);
  const [loadingCats, setLoadingCats] = useState(true);
  const [catSearch, setCatSearch] = useState("");
  const [selectedCat, setSelectedCat] = useState(null);
  const [listing, setListing] = useState(false);
  const [error, setError] = useState("");
  const listRef = useRef(null);

  useEffect(() => {
    callFunction("getTiktokCategories")({})
      .then((r) => setCategories(r.data.categories ?? []))
      .catch(() => setError("Could not load TikTok categories. Is TikTok Shop connected?"))
      .finally(() => setLoadingCats(false));
  }, []);

  const filtered = catSearch
    ? categories.filter((c) => c.name.toLowerCase().includes(catSearch.toLowerCase()))
    : categories;

  async function handleSubmit() {
    if (!selectedCat) { setError("Select a category to continue."); return; }
    setListing(true);
    setError("");
    try {
      await callFunction("tiktokCreateListing")({
        productId: product.id,
        title: title.slice(0, 255),
        sellPrice: parseFloat(price),
        categoryId: selectedCat.id,
      });
      onListed?.();
      onClose();
    } catch (e) {
      setError(e.message ?? "Listing failed.");
    } finally {
      setListing(false);
    }
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>List on TikTok Shop</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
        </div>

        <div className="modal-body">
          <div className="modal-field">
            <label>Title</label>
            <input className="input" value={title} onChange={(e) => setTitle(e.target.value)} maxLength={255} />
            <span style={{ fontSize: 11, color: "var(--muted)" }}>{title.length}/255</span>
          </div>

          <div className="modal-field">
            <label>Sell Price (USD)</label>
            <input
              className="input"
              type="number"
              step="0.01"
              min="0"
              value={price}
              onChange={(e) => setPrice(e.target.value)}
            />
            {(product.sourceCost ?? product.aliexpressPrice) > 0 && (
              <span style={{ fontSize: 11, color: "var(--muted)" }}>
                Cost: ${(product.sourceCost ?? product.aliexpressPrice).toFixed(2)} · Margin: ${(parseFloat(price || 0) * 0.925 - (product.sourceCost ?? product.aliexpressPrice)).toFixed(2)}
              </span>
            )}
          </div>

          <div className="modal-field">
            <label>Category</label>
            <input
              className="input"
              placeholder={loadingCats ? "Loading categories…" : "Search categories…"}
              value={catSearch}
              disabled={loadingCats}
              onChange={(e) => { setCatSearch(e.target.value); setSelectedCat(null); }}
            />
            {!loadingCats && catSearch && (
              <div className="category-dropdown" ref={listRef}>
                {filtered.length === 0 ? (
                  <div className="category-item" style={{ color: "var(--muted)" }}>No matches</div>
                ) : (
                  filtered.slice(0, 60).map((c) => (
                    <div
                      key={c.id}
                      className={`category-item ${selectedCat?.id === c.id ? "selected" : ""}`}
                      onClick={() => { setSelectedCat(c); setCatSearch(c.name); }}
                    >
                      {c.name}
                    </div>
                  ))
                )}
              </div>
            )}
            {selectedCat && (
              <span style={{ fontSize: 11, color: "var(--success)" }}>
                ✓ {selectedCat.name} (ID: {selectedCat.id})
              </span>
            )}
          </div>

          {error && <div style={{ fontSize: 13, color: "var(--danger)" }}>{error}</div>}
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button
            className="btn btn-primary"
            onClick={handleSubmit}
            disabled={listing || !selectedCat}
          >
            {listing ? "Listing…" : "List Product"}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── Import bar ────────────────────────────────────────────────────────────────

function ImportBar({ onImported }) {
  const [urlText, setUrlText] = useState("");
  const [isBulk, setIsBulk] = useState(false);
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");

  async function handleImport() {
    const rawLines = urlText.split(/[\n,]+/).map((s) => s.trim()).filter(Boolean);
    if (!rawLines.length) return;

    setLoading(true);
    setError("");
    setStatus("Importing…");

    try {
      if (rawLines.length === 1) {
        const url = rawLines[0];
        const fn = url.includes("shop.weverse.io") ? "weverseImportProduct" : "aliexpressImportProduct";
        const result = await callFunction(fn)({ productUrl: url });
        setUrlText("");
        setStatus("");
        onImported?.(result.data.productId);
      } else {
        // Multi-URL batch import via weverseBulkImportProducts (Weverse URLs only)
        const items = rawLines.map((url) => ({ productUrl: url }));
        const response = await callFunction("weverseBulkImportProducts")({ items });
        const res = response?.data;
        setUrlText("");
        const errors = res?.errors ?? [];
        setStatus(`Bulk import complete! ${res?.importedCount ?? 0} imported, ${res?.existingCount ?? 0} already existing.`);
        if (errors.length) {
          const preview = errors.slice(0, 3).map((e) => `${e.title ?? "Item"}: ${e.error}`).join("; ");
          setError(`${errors.length} item${errors.length === 1 ? "" : "s"} failed — ${preview}${errors.length > 3 ? "…" : ""}`);
        }
        onImported?.(res?.productIds?.[0]);
      }
    } catch (e) {
      setError(e.message ?? "Import failed");
      setStatus("");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="card" style={{ marginBottom: 24 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
        <div style={{ fontSize: 13, color: "var(--muted)" }}>
          {isBulk ? "Paste multiple Weverse Shop URLs (one per line)" : "Paste a Weverse Shop or AliExpress product URL"}
        </div>
        <button
          className="btn btn-ghost"
          style={{ fontSize: 12, padding: "2px 8px" }}
          onClick={() => { setIsBulk(!isBulk); setError(""); setStatus(""); }}
        >
          {isBulk ? "Switch to single URL" : "Paste multiple URLs"}
        </button>
      </div>

      <div className="input-group" style={{ flexDirection: isBulk ? "column" : "row", gap: 8 }}>
        {isBulk ? (
          <textarea
            className="input"
            rows={4}
            placeholder="https://shop.weverse.io/en/shop/USD/artists/1/sales/101&#10;https://shop.weverse.io/en/shop/USD/artists/1/sales/102"
            value={urlText}
            onChange={(e) => setUrlText(e.target.value)}
          />
        ) : (
          <input
            className="input"
            placeholder="https://shop.weverse.io/en/shop/USD/artists/.../sales/..."
            value={urlText}
            onChange={(e) => setUrlText(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleImport()}
          />
        )}
        <button
          className="btn btn-primary"
          style={{ alignSelf: isBulk ? "flex-end" : "auto" }}
          onClick={handleImport}
          disabled={loading || !urlText.trim()}
        >
          {loading ? "Importing…" : isBulk ? "Import All URLs" : "Import"}
        </button>
      </div>

      {status && <div style={{ marginTop: 8, fontSize: 13, color: "var(--success)" }}>{status}</div>}
      {error && <div style={{ marginTop: 8, fontSize: 13, color: "var(--danger)" }}>{error}</div>}
    </div>
  );
}


// ── Posted Platforms Display ──────────────────────────────────────────────────

function PostedPlatforms({ product }) {
  const platforms = [];

  if (product.crossPostStatus?.wonni === "active") {
    platforms.push({ id: "wonni", name: "Wonni", logo: "W", status: "active" });
  }
  if (product.crossPostStatus?.tiktok === "active") {
    platforms.push({ id: "tiktok", name: "TikTok Shop", logo: "TT", status: "active" });
  }
  if (product.crossPostStatus?.ebay === "active" || product.crossPostStatus?.ebay === "posted") {
    platforms.push({ id: "ebay", name: "eBay", logo: "EB", status: "active" });
  }
  if (product.crossPostStatus?.etsy === "active" || product.crossPostStatus?.etsy === "posted") {
    platforms.push({ id: "etsy", name: "Etsy", logo: "ET", status: "active" });
  }

  // Mercari: variant-aware logic
  const variants = Array.isArray(product.variants) ? product.variants : [];
  const inStockVariants = product.hasVariants
    ? variants.filter((v) => v.active && (v.quantity ?? 0) > 0)
    : [];

  if (product.hasVariants && inStockVariants.length > 0) {
    const postedCount = inStockVariants.filter((v) => v.mercariUrl).length;
    if (postedCount === inStockVariants.length) {
      platforms.push({ id: "mercari", name: "Mercari", logo: "MR", status: "active" });
    } else if (postedCount > 0) {
      platforms.push({ id: "mercari", name: "Mercari", logo: "MR", status: "incomplete" });
    }
  } else if (product.crossPostStatus?.mercari === "active") {
    platforms.push({ id: "mercari", name: "Mercari", logo: "MR", status: "active" });
  }

  if (platforms.length === 0) return null;

  return (
    <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
      {platforms.map((p) => {
        const listingUrl = getPlatformListingUrl(p.id, product);
        return (
          <div
            key={p.id}
            title={p.name + (p.status === "incomplete" ? " (incomplete)" : "") + (listingUrl ? ` - Click to open live listing` : "")}
            onClick={(e) => {
              e.stopPropagation();
              if (listingUrl) {
                if (listingUrl.startsWith("http")) {
                  window.open(listingUrl, "_blank", "noopener,noreferrer");
                } else {
                  window.location.href = listingUrl;
                }
              }
            }}
            style={{
              width: 32,
              height: 32,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              background: p.status === "incomplete" ? "var(--surface-high)" : "var(--surface-high)",
              border: p.status === "incomplete" ? "1px solid var(--warning)" : "var(--border-thin) solid var(--primary)",
              borderRadius: "var(--radius)",
              fontSize: 11,
              fontWeight: 700,
              color: p.status === "incomplete" ? "var(--warning)" : "var(--primary)",
              cursor: listingUrl ? "pointer" : "default",
              fontFamily: "'Space Mono', monospace",
              textTransform: "uppercase",
              letterSpacing: "0.05em",
              transition: "transform 0.15s ease, box-shadow 0.15s ease",
            }}
            onMouseEnter={(e) => {
              if (listingUrl) e.currentTarget.style.transform = "scale(1.1)";
            }}
            onMouseLeave={(e) => {
              if (listingUrl) e.currentTarget.style.transform = "scale(1)";
            }}
          >
            {p.logo}
          </div>
        );
      })}
    </div>
  );
}

// ── Product card ──────────────────────────────────────────────────────────────

function ProductCard({ product, selected = false, onSelect = null, selectMode = false }) {
  const navigate = useNavigate();
  const [showPostModal, setShowPostModal] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const primaryImage = product.images?.[0] ?? "";
  const isSourceSoldOut = product.hasVariants
    && Array.isArray(product.variants)
    && product.variants.length > 0
    && product.variants.every((v) => v.active === false);

  const isLive =
    product.crossPostStatus?.wonni === "active" ||
    product.crossPostStatus?.tiktok === "active" ||
    product.crossPostStatus?.ebay === "active" ||
    product.crossPostStatus?.ebay === "posted" ||
    product.crossPostStatus?.etsy === "active" ||
    product.crossPostStatus?.etsy === "posted" ||
    product.crossPostStatus?.mercari === "active";

  async function handleDelete() {
    if (!window.confirm(`Delete "${product.title}"? This can't be undone.`)) return;
    setDeleting(true);
    try {
      await deleteDoc(doc(db, "products", product.id));
    } catch (e) {
      setDeleting(false);
      window.alert(e.message ?? "Delete failed.");
    }
  }

  return (
    <>
      <div className="product-card" style={{ position: "relative" }}>
        {/* Upper-right actions submenu */}
        <div
          style={{
            position: "absolute",
            top: 8,
            right: 8,
            zIndex: 20,
            background: "rgba(20, 20, 25, 0.75)",
            backdropFilter: "blur(6px)",
            borderRadius: "var(--radius)",
            border: "1px solid rgba(255, 255, 255, 0.1)",
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <OverflowMenu
            items={[
              {
                label: deleting ? "Deleting…" : "Delete Product",
                danger: true,
                disabled: deleting,
                onClick: handleDelete,
              },
            ]}
          />
        </div>

        {/* Image with badges */}
        <button
          className="product-card-image"
          style={{ position: "relative" }}
          onClick={() => navigate(`/sell/products/${product.id}`)}
        >
          {primaryImage ? (
            <img src={primaryImage} alt={product.title} />
          ) : (
            <div className="product-card-placeholder">No image</div>
          )}

          {/* Sold Out badge - lower left */}
          {isSourceSoldOut && (
            <span
              style={{
                position: "absolute",
                bottom: 8,
                left: 8,
                background: "var(--danger)",
                color: "white",
                fontSize: 11,
                fontWeight: 700,
                padding: "6px 10px",
                borderRadius: "var(--radius)",
                fontFamily: "'Space Mono', monospace",
                textTransform: "uppercase",
                letterSpacing: "0.05em"
              }}
            >
              Sold Out
            </span>
          )}

          {/* Live/Draft badge - lower right */}
          <span
            style={{
              position: "absolute",
              bottom: 8,
              right: 8,
              background: isLive ? "var(--primary)" : "var(--surface-high)",
              color: isLive ? "var(--on-primary)" : "var(--text)",
              border: isLive ? "none" : `var(--border-thin) solid var(--border)`,
              fontSize: 11,
              fontWeight: 700,
              padding: "6px 10px",
              borderRadius: "var(--radius)",
              fontFamily: "'Space Mono', monospace",
              textTransform: "uppercase",
              letterSpacing: "0.05em"
            }}
          >
            {isLive ? "Live" : "Draft"}
          </span>

          {/* Select checkbox - only in select mode */}
          {selectMode && (
            <div style={{ position: "absolute", top: 8, left: 8, zIndex: 10 }}>
              <input
                type="checkbox"
                checked={selected}
                onChange={() => onSelect(!selected)}
                style={{
                  width: 20,
                  height: 20,
                  cursor: "pointer",
                  accentColor: "var(--primary)"
                }}
              />
            </div>
          )}
        </button>

        <div className="product-card-body">
          {/* Title */}
          <button className="product-card-title-button" onClick={() => navigate(`/sell/products/${product.id}`)}>
            <div className="product-card-title">{product.title}</div>
          </button>

          {/* Metadata */}
          <div className="product-card-meta">
            <span>{typeof product.listingPrice === "number" ? `$${product.listingPrice.toFixed(2)}` : "—"}</span>
          </div>

          {/* Description preview */}
          <div className="product-card-preview">
            {product.description?.trim()
              ? product.description.trim().slice(0, 85)
              : `${product.images?.length ?? 0} images${product.variants?.length ? ` · ${product.variants.length} variants` : ""}`}
          </div>

          {/* Tag badges */}
          {Array.isArray(product.tags) && product.tags.length > 0 && (
            <div style={{ display: "flex", flexWrap: "wrap", gap: 4, marginTop: 8, marginBottom: 2 }}>
              {product.tags.map((tag) => (
                <span
                  key={tag}
                  style={{
                    fontSize: 10,
                    padding: "2px 6px",
                    background: "var(--surface-high)",
                    border: "var(--border-thin) solid var(--border)",
                    borderRadius: 4,
                    color: "var(--text-secondary)",
                    fontFamily: "'Space Mono', monospace",
                    whiteSpace: "nowrap",
                  }}
                >
                  🏷️ {tag}
                </span>
              ))}
            </div>
          )}

          {/* Bottom section: Platforms + Post button */}
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, marginTop: "auto", paddingTop: 12 }}>
            {/* Platform logos */}
            <PostedPlatforms product={product} />

            {/* Spacer */}
            <div style={{ flex: 1 }} />

            {/* Post button */}
            <button
              className="btn btn-primary"
              style={{ padding: "10px 16px", whiteSpace: "nowrap" }}
              onClick={() => setShowPostModal(true)}
            >
              Post
            </button>
          </div>
        </div>
      </div>

      {showPostModal && (
        <PostModal
          product={product}
          onClose={() => setShowPostModal(false)}
        />
      )}
    </>
  );
}

// ── Dashboard page ────────────────────────────────────────────────────────────

export default function Dashboard() {
  const [products, setProducts] = useState([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [mobileDraftsExpanded, setMobileDraftsExpanded] = useState(false);
  const [filter, setFilter] = useState("all"); // "all", "draft", "live"
  const [selectedTag, setSelectedTag] = useState(null); // null (All) or specific tag string
  const [selectedIds, setSelectedIds] = useState(new Set());
  const [showBulkPostModal, setShowBulkPostModal] = useState(false);
  const [showBulkTagModal, setShowBulkTagModal] = useState(false);
  const [selectMode, setSelectMode] = useState(false);

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError("");
    const q = query(
      collection(db, "products"),
      where("userId", "==", uid),
      orderBy("importedAt", "desc")
    );
    return onSnapshot(
      q,
      (snap) => {
        setProducts(snap.docs.map((d) => ({ id: d.id, ...d.data() })));
        setLoading(false);
      },
      (err) => {
        setError(
          err?.code === "failed-precondition"
            ? "Firestore needs the products index before this dashboard can load. Deploy firestore.indexes.json, then refresh."
            : err?.message ?? "Could not load products."
        );
        setLoading(false);
      }
    );
  }, []);

  const mobileDrafts = products.filter((p) => p.source === "ios" && p.isDraft !== false);
  const regularProducts = products.filter((p) => !(p.source === "ios" && p.isDraft !== false));

  // Collect all unique tags across user's products
  const allTags = useMemo(() => {
    const tagSet = new Set();
    products.forEach((p) => {
      if (Array.isArray(p.tags)) {
        p.tags.forEach((t) => {
          if (typeof t === "string" && t.trim()) tagSet.add(t.trim());
        });
      }
    });
    return Array.from(tagSet).sort((a, b) => a.localeCompare(b));
  }, [products]);

  const isLive = (p) =>
    p.crossPostStatus?.wonni === "active" ||
    p.crossPostStatus?.tiktok === "active" ||
    p.crossPostStatus?.ebay === "active" ||
    p.crossPostStatus?.ebay === "posted" ||
    p.crossPostStatus?.etsy === "active" ||
    p.crossPostStatus?.etsy === "posted" ||
    p.crossPostStatus?.mercari === "active";

  let filteredProducts =
    filter === "live"
      ? regularProducts.filter(isLive)
      : filter === "draft"
      ? regularProducts.filter((p) => !isLive(p))
      : regularProducts;

  if (selectedTag) {
    filteredProducts = filteredProducts.filter(
      (p) => Array.isArray(p.tags) && p.tags.includes(selectedTag)
    );
  }

  const allSelected = filteredProducts.length > 0 && filteredProducts.every((p) => selectedIds.has(p.id));
  const someSelected = filteredProducts.some((p) => selectedIds.has(p.id));

  const toggleSelectAll = () => {
    const newSelected = new Set(selectedIds);
    if (allSelected) {
      filteredProducts.forEach((p) => newSelected.delete(p.id));
    } else {
      filteredProducts.forEach((p) => newSelected.add(p.id));
    }
    setSelectedIds(newSelected);
  };

  const toggleSelect = (productId) => {
    const newSelected = new Set(selectedIds);
    if (newSelected.has(productId)) {
      newSelected.delete(productId);
    } else {
      newSelected.add(productId);
    }
    setSelectedIds(newSelected);
  };

  return (
    <Layout>
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1 style={{ margin: 0 }}>Products</h1>
          <span style={{ fontSize: 13, color: "var(--muted)" }}>
            {regularProducts.length} total · {regularProducts.filter(isLive).length} live
          </span>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <button
            className={`btn ${selectMode ? "btn-primary" : "btn-ghost"}`}
            onClick={() => { setSelectMode(!selectMode); setSelectedIds(new Set()); }}
          >
            {selectMode ? "✓ Select Mode" : "Select"}
          </button>
          <button className="btn btn-primary" onClick={() => setShowCreateModal(true)}>
            📷 Create Draft from Photo
          </button>
        </div>
      </div>

      <ImportBar onImported={() => setFilter("all")} />

      {error && <div className="card" style={{ marginBottom: 20, color: "var(--danger)" }}>{error}</div>}

      {mobileDrafts.length > 0 && (
        <div className="card" style={{ marginBottom: 20 }}>
          <button
            onClick={() => setMobileDraftsExpanded((v) => !v)}
            style={{
              width: "100%", display: "flex", alignItems: "center", justifyContent: "space-between",
              background: "none", border: "none", cursor: "pointer", padding: 0, font: "inherit", color: "inherit",
            }}
          >
            <span style={{ display: "flex", alignItems: "center", gap: 8, fontWeight: 600 }}>
              📱 Mobile Drafts <span className="chip chip-draft">{mobileDrafts.length}</span>
            </span>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>{mobileDraftsExpanded ? "▲ Collapse" : "▼ Expand"}</span>
          </button>
          {mobileDraftsExpanded && (
            <div className="product-grid" style={{ marginTop: 16 }}>
              {mobileDrafts.map((p) => <ProductCard key={p.id} product={p} />)}
            </div>
          )}
        </div>
      )}

      {loading ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>⏳</div>
          <p>Loading your products…</p>
        </div>
      ) : regularProducts.length === 0 ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>📦</div>
          <p>No products yet. Import from Weverse, AliExpress, or create a draft from a photo.</p>
          <button className="btn btn-primary" style={{ marginTop: 12 }} onClick={() => setShowCreateModal(true)}>
            📷 Create Draft from Photo
          </button>
        </div>
      ) : (
        <>
          <div style={{ display: "flex", gap: 8, marginBottom: 16, alignItems: "center", flexWrap: "wrap" }}>
            <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
              <span style={{ fontSize: 13, color: "var(--muted)", fontWeight: 500 }}>Filter:</span>
              {["all", "draft", "live"].map((f) => (
                <button
                  key={f}
                  className={`btn ${filter === f ? "btn-primary" : "btn-ghost"}`}
                  style={{ fontSize: 12, padding: "6px 12px" }}
                  onClick={() => { setFilter(f); setSelectedIds(new Set()); }}
                >
                  {f.charAt(0).toUpperCase() + f.slice(1)}
                </button>
              ))}
            </div>

            {selectMode && someSelected && (
              <div style={{ display: "flex", gap: 8, alignItems: "center", marginLeft: "auto" }}>
                <span style={{ fontSize: 12, color: "var(--muted)" }}>
                  {selectedIds.size} selected
                </span>
                <button
                  className="btn btn-secondary"
                  style={{ fontSize: 12, padding: "8px 12px" }}
                  onClick={() => setShowBulkTagModal(true)}
                >
                  🏷️ Tag Selected
                </button>
                <button
                  className="btn btn-primary"
                  style={{ fontSize: 12, padding: "8px 12px" }}
                  onClick={() => setShowBulkPostModal(true)}
                >
                  Post to Platforms
                </button>
              </div>
            )}
          </div>

          {/* Tag filter bar */}
          {allTags.length > 0 && (
            <div style={{ display: "flex", gap: 6, alignItems: "center", marginBottom: 16, flexWrap: "wrap" }}>
              <span style={{ fontSize: 12, color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em", marginRight: 4 }}>
                🏷️ Tags:
              </span>
              <button
                className={`btn ${selectedTag === null ? "btn-primary" : "btn-ghost"}`}
                style={{ fontSize: 11, padding: "4px 10px", borderRadius: 14 }}
                onClick={() => { setSelectedTag(null); setSelectedIds(new Set()); }}
              >
                All
              </button>
              {allTags.map((tag) => (
                <button
                  key={tag}
                  className={`btn ${selectedTag === tag ? "btn-primary" : "btn-ghost"}`}
                  style={{ fontSize: 11, padding: "4px 10px", borderRadius: 14 }}
                  onClick={() => { setSelectedTag(selectedTag === tag ? null : tag); setSelectedIds(new Set()); }}
                >
                  🏷️ {tag}
                </button>
              ))}
            </div>
          )}

          {selectMode && (
            <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 16 }}>
              <input
                type="checkbox"
                checked={allSelected}
                onChange={toggleSelectAll}
                style={{ width: 20, height: 20, cursor: "pointer", accentColor: "var(--primary)" }}
                title={allSelected ? "Deselect all" : "Select all"}
              />
              <span style={{ fontSize: 12, color: "var(--muted)" }}>
                Select All ({filteredProducts.length})
              </span>
            </div>
          )}

          <div className="product-grid">
            {filteredProducts.map((p) => (
              <ProductCard
                key={p.id}
                product={p}
                selectMode={selectMode}
                selected={selectMode && selectedIds.has(p.id)}
                onSelect={selectMode ? () => toggleSelect(p.id) : null}
              />
            ))}
          </div>
        </>
      )}

      {showCreateModal && (
        <CreateDraftModal
          onClose={() => setShowCreateModal(false)}
          onCreated={() => setShowCreateModal(false)}
        />
      )}

      {showBulkPostModal && selectedIds.size > 0 && (
        <BulkPostModal
          productIds={Array.from(selectedIds)}
          products={regularProducts.filter((p) => selectedIds.has(p.id))}
          onClose={() => {
            setShowBulkPostModal(false);
            setSelectedIds(new Set());
          }}
        />
      )}

      {showBulkTagModal && selectedIds.size > 0 && (
        <BulkTagModal
          products={regularProducts.filter((p) => selectedIds.has(p.id))}
          allUserTags={allTags}
          onClose={() => {
            setShowBulkTagModal(false);
          }}
          onUpdated={() => {
            setShowBulkTagModal(false);
            setSelectedIds(new Set());
          }}
        />
      )}
    </Layout>
  );
}
