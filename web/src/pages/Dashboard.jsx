import { useState, useEffect, useRef } from "react";
import { collection, query, where, orderBy, onSnapshot } from "firebase/firestore";
import { useNavigate } from "react-router-dom";
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
        // Multi-URL batch import via weverseBulkImportProducts
        const items = rawLines.map((url) => ({ productUrl: url }));
        const response = await callFunction("weverseBulkImportProducts")({ items });
        const res = response?.data;
        setUrlText("");
        setStatus(`Bulk import complete! ${res?.importedCount ?? 0} imported, ${res?.existingCount ?? 0} already existing.`);
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
          {isBulk ? "Paste multiple Weverse or AliExpress URLs (one per line)" : "Paste a Weverse Shop or AliExpress product URL"}
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


// ── Product card ──────────────────────────────────────────────────────────────

function ProductCard({ product }) {
  const navigate = useNavigate();
  const [showModal, setShowModal] = useState(false);
  const [ebayState, setEbayState] = useState({ listing: false, error: "" });
  const primaryImage = product.images?.[0] ?? "";
  const sourceLabel = product.source === "weverse" ? "Weverse" : "AliExpress";

  async function listOnEbay() {
    const suggested = (product.suggestedSellPrice ?? Math.ceil((product.aliexpressPrice * 1.35 + 8) * 100) / 100).toFixed(2);
    const input = window.prompt("eBay sell price (USD):", suggested);
    if (input === null) return;
    setEbayState({ listing: true, error: "" });
    try {
      await callFunction("ebayCreateListing")({
        productId: product.id,
        sellPrice: parseFloat(input) || undefined,
      });
      setEbayState({ listing: false, error: "" });
    } catch (e) {
      setEbayState({ listing: false, error: e.message ?? "eBay listing failed." });
    }
  }

  const statusMap = {
    draft: "chip-draft",
    active: "chip-active",
    inactive: "chip-draft",
  };

  return (
    <>
      <div className="product-card">
        <button className="product-card-image" onClick={() => navigate(`/products/${product.id}`)}>
          {primaryImage ? (
            <img src={primaryImage} alt={product.title} />
          ) : (
            <div className="product-card-placeholder">No image</div>
          )}
        </button>
        <div className="product-card-body">
          <button className="product-card-title-button" onClick={() => navigate(`/products/${product.id}`)}>
            <div className="product-card-title">{product.title}</div>
          </button>
          <div className="product-card-subtitle">
            <span>{sourceLabel}</span>
            {product.artistName && <span>{product.artistName}</span>}
          </div>
          <div className="product-card-meta">
            <span>${product.aliexpressPrice?.toFixed(2) ?? "—"}</span>
            <span className={`chip ${statusMap[product.tiktokStatus ?? "draft"]}`}>
              {product.tiktokStatus ?? "draft"}
            </span>
          </div>
          <div className="product-card-preview">
            {product.description?.trim()
              ? product.description.trim().slice(0, 110)
              : `Scraped ${product.images?.length ?? 0} images${product.variants?.length ? ` · ${product.variants.length} variants` : ""}`}
          </div>
          <div className="product-card-actions">
            <button className="btn btn-ghost" style={{ width: "100%" }} onClick={() => navigate(`/products/${product.id}`)}>
              View details
            </button>
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
            {product.ebayStatus === "active" ? (
              <span style={{ fontSize: 12, color: "var(--success)" }}>Live on eBay</span>
            ) : (
              <button
                className="btn btn-ghost"
                style={{ width: "100%" }}
                onClick={listOnEbay}
                disabled={ebayState.listing}
              >
                {ebayState.listing ? "Listing on eBay…" : "List on eBay"}
              </button>
            )}
            {ebayState.error && (
              <span style={{ fontSize: 11, color: "var(--danger)" }}>{ebayState.error}</span>
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
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

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

  return (
    <Layout>
      <div className="page-header">
        <h1>Products</h1>
        <span style={{ fontSize: 13, color: "var(--muted)" }}>{products.length} imported</span>
      </div>
      <ImportBar />
      {error && <div className="card" style={{ marginBottom: 20, color: "var(--danger)" }}>{error}</div>}
      {loading ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>⏳</div>
          <p>Loading your imported products…</p>
        </div>
      ) : products.length === 0 ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>📦</div>
          <p>No products yet. Import from Weverse, AliExpress, or use the Chrome extension.</p>
        </div>
      ) : (
        <div className="product-grid">
          {products.map((p) => <ProductCard key={p.id} product={p} />)}
        </div>
      )}
    </Layout>
  );
}
