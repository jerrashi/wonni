import { useState, useEffect, useRef } from "react";
import { collection, query, where, orderBy, onSnapshot } from "firebase/firestore";
import { db, callFunction } from "../firebase";
import { auth } from "../firebase";
import Layout from "../components/Layout";

// ── List Modal ────────────────────────────────────────────────────────────────

function ListModal({ product, onClose, onListed }) {
  const [title, setTitle] = useState(product.title.slice(0, 255));
  const [price, setPrice] = useState(
    ((product.suggestedSellPrice ?? product.aliexpressPrice * 2.5) || 0).toFixed(2)
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
            {product.aliexpressPrice > 0 && (
              <span style={{ fontSize: 11, color: "var(--muted)" }}>
                Cost: ${product.aliexpressPrice.toFixed(2)} · Margin: ${(parseFloat(price || 0) * 0.925 - product.aliexpressPrice).toFixed(2)}
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
  const [url, setUrl] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleImport() {
    if (!url.trim()) return;
    setLoading(true);
    setError("");
    try {
      const result = await callFunction("aliexpressImportProduct")({ productUrl: url.trim() });
      setUrl("");
      onImported?.(result.data.productId);
    } catch (e) {
      setError(e.message ?? "Import failed");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="card" style={{ marginBottom: 24 }}>
      <div style={{ marginBottom: 8, fontSize: 13, color: "var(--muted)" }}>
        Paste an AliExpress product URL to import
      </div>
      <div className="input-group">
        <input
          className="input"
          placeholder="https://www.aliexpress.com/item/..."
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && handleImport()}
        />
        <button className="btn btn-primary" onClick={handleImport} disabled={loading || !url.trim()}>
          {loading ? "Importing…" : "Import"}
        </button>
      </div>
      {error && <div style={{ marginTop: 8, fontSize: 13, color: "var(--danger)" }}>{error}</div>}
    </div>
  );
}

// ── Product card ──────────────────────────────────────────────────────────────

function ProductCard({ product }) {
  const [showModal, setShowModal] = useState(false);

  const statusMap = {
    draft: "chip-draft",
    active: "chip-active",
    inactive: "chip-draft",
  };

  return (
    <>
      <div className="product-card">
        <img src={product.images?.[0] ?? ""} alt={product.title} />
        <div className="product-card-body">
          <div className="product-card-title">{product.title}</div>
          <div className="product-card-meta">
            <span>${product.aliexpressPrice?.toFixed(2) ?? "—"}</span>
            <span className={`chip ${statusMap[product.tiktokStatus ?? "draft"]}`}>
              {product.tiktokStatus ?? "draft"}
            </span>
          </div>
          <div className="product-card-actions">
            {(!product.tiktokStatus || product.tiktokStatus === "draft") && (
              <button
                className="btn btn-primary"
                style={{ width: "100%" }}
                onClick={() => setShowModal(true)}
              >
                List on TikTok Shop
              </button>
            )}
            {product.tiktokStatus === "active" && (
              <span style={{ fontSize: 12, color: "var(--success)" }}>Live on TikTok Shop</span>
            )}
          </div>
        </div>
      </div>

      {showModal && (
        <ListModal
          product={product}
          onClose={() => setShowModal(false)}
          onListed={() => setShowModal(false)}
        />
      )}
    </>
  );
}

// ── Dashboard page ────────────────────────────────────────────────────────────

export default function Dashboard() {
  const [products, setProducts] = useState([]);

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) return;
    const q = query(
      collection(db, "products"),
      where("userId", "==", uid),
      orderBy("importedAt", "desc")
    );
    return onSnapshot(q, (snap) => setProducts(snap.docs.map((d) => ({ id: d.id, ...d.data() }))));
  }, []);

  return (
    <Layout>
      <div className="page-header">
        <h1>Products</h1>
        <span style={{ fontSize: 13, color: "var(--muted)" }}>{products.length} imported</span>
      </div>
      <ImportBar />
      {products.length === 0 ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>📦</div>
          <p>No products yet. Import from AliExpress above or use the Chrome extension.</p>
        </div>
      ) : (
        <div className="product-grid">
          {products.map((p) => <ProductCard key={p.id} product={p} />)}
        </div>
      )}
    </Layout>
  );
}
