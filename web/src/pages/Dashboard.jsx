import { useState, useEffect } from "react";
import { collection, query, where, orderBy, onSnapshot } from "firebase/firestore";
import { db, callFunction } from "../firebase";
import { auth } from "../firebase";
import Layout from "../components/Layout";

function ImportBar({ onImported }) {
  const [url, setUrl] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleImport() {
    if (!url.trim()) return;
    setLoading(true);
    setError("");
    try {
      const fn = callFunction("aliexpressImportProduct");
      const result = await fn({ productUrl: url.trim() });
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

function ProductCard({ product }) {
  const [listing, setListing] = useState(false);
  const [error, setError] = useState("");

  async function handleList() {
    setListing(true);
    setError("");
    try {
      await callFunction("tiktokCreateListing")({ productId: product.id });
    } catch (e) {
      setError(e.message ?? "Failed to list");
    } finally {
      setListing(false);
    }
  }

  const statusMap = {
    draft: "chip-draft",
    active: "chip-active",
    inactive: "chip-draft",
  };

  return (
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
        {error && <div style={{ fontSize: 12, color: "var(--danger)" }}>{error}</div>}
        <div className="product-card-actions">
          {(!product.tiktokStatus || product.tiktokStatus === "draft") && (
            <button className="btn btn-primary" style={{ width: "100%" }} onClick={handleList} disabled={listing}>
              {listing ? "Listing…" : "List on TikTok Shop"}
            </button>
          )}
          {product.tiktokStatus === "active" && (
            <span style={{ fontSize: 12, color: "var(--success)" }}>Live on TikTok Shop</span>
          )}
        </div>
      </div>
    </div>
  );
}

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
