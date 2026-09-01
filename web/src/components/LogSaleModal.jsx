import { useState, useEffect } from "react";
import { collection, addDoc, doc, updateDoc, serverTimestamp, Timestamp } from "firebase/firestore";
import { db, auth } from "../firebase";

const PLATFORMS = [
  { id: "mercari", label: "Mercari", icon: "🔴" },
  { id: "ebay", label: "eBay", icon: "🔵" },
  { id: "etsy", label: "Etsy", icon: "🟠" },
  { id: "wonni", label: "Wonni", icon: "🟣" },
  { id: "manual", label: "In Person / Other", icon: "⚪" },
];

export default function LogSaleModal({ products = [], onClose, onSaleLogged }) {
  const [platform, setPlatform] = useState("mercari");
  const [urlInput, setUrlInput] = useState("");
  const [selectedProductId, setSelectedProductId] = useState("");
  const [selectedVariantSku, setSelectedVariantSku] = useState("");
  const [salePrice, setSalePrice] = useState("");
  const [quantity, setQuantity] = useState(1);
  const [soldDate, setSoldDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [notes, setNotes] = useState("");
  const [decrementStock, setDecrementStock] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [productSearch, setProductSearch] = useState("");

  const selectedProduct = products.find((p) => p.id === selectedProductId);
  const variants = Array.isArray(selectedProduct?.variants) ? selectedProduct.variants : [];

  // When Mercari URL is typed or pasted, attempt to match an existing product
  useEffect(() => {
    if (!urlInput.trim()) return;
    const url = urlInput.trim();
    
    // Check if URL matches a product's mercariUrl or mercariListingId
    const matched = products.find((p) => {
      if (p.mercariUrl && url.includes(p.mercariUrl)) return true;
      if (p.mercariListingId && url.includes(p.mercariListingId)) return true;
      if (Array.isArray(p.variants)) {
        return p.variants.some((v) => v.mercariUrl && url.includes(v.mercariUrl));
      }
      return false;
    });

    if (matched) {
      setSelectedProductId(matched.id);
      setProductSearch(matched.title || "");
      if (matched.listingPrice && !salePrice) {
        setSalePrice(String(matched.listingPrice));
      }
    }
  }, [urlInput, products]);

  // When product changes, prefill price if empty
  useEffect(() => {
    if (selectedProduct && !salePrice) {
      if (typeof selectedProduct.listingPrice === "number") {
        setSalePrice(String(selectedProduct.listingPrice));
      }
    }
    if (variants.length > 0 && !selectedVariantSku) {
      setSelectedVariantSku(variants[0].sku || "");
    }
  }, [selectedProduct]);

  const filteredProducts = products.filter((p) =>
    (p.title || "").toLowerCase().includes(productSearch.toLowerCase()) ||
    (p.tags || []).some((t) => t.toLowerCase().includes(productSearch.toLowerCase()))
  );

  async function handleSubmit(e) {
    e.preventDefault();
    const uid = auth.currentUser?.uid;
    if (!uid) {
      setError("You must be signed in to log a sale.");
      return;
    }

    const priceNum = parseFloat(salePrice);
    if (isNaN(priceNum) || priceNum < 0) {
      setError("Please enter a valid sale price.");
      return;
    }

    setSaving(true);
    setError("");

    try {
      const selectedVariant = variants.find((v) => v.sku === selectedVariantSku);
      const productTags = Array.isArray(selectedProduct?.tags) ? selectedProduct.tags : [];
      const imageUrl =
        (Array.isArray(selectedProduct?.images) && selectedProduct.images[0]) ||
        (Array.isArray(selectedProduct?.imageAssets) && selectedProduct.imageAssets[0]?.url) ||
        "";

      const soldDateObj = new Date(soldDate + "T12:00:00");

      const saleData = {
        userId: uid,
        platform,
        productId: selectedProductId || null,
        productTitle: selectedProduct?.title || productSearch.trim() || "Manual Sale",
        productImageUrl: imageUrl,
        productTags,
        variantSku: selectedVariantSku || null,
        variantOptionValues: selectedVariant?.optionValues || null,
        salePrice: priceNum,
        quantity: parseInt(quantity, 10) || 1,
        externalUrl: urlInput.trim() || null,
        notes: notes.trim() || null,
        soldAt: Timestamp.fromDate(soldDateObj),
        createdAt: serverTimestamp(),
      };

      await addDoc(collection(db, "sales"), saleData);

      // Decrement stock in Firestore if requested
      if (decrementStock && selectedProduct) {
        if (variants.length > 0 && selectedVariantSku) {
          const updatedVariants = variants.map((v) => {
            if (v.sku === selectedVariantSku) {
              const currentQty = v.quantity ?? 1;
              return { ...v, quantity: Math.max(0, currentQty - (parseInt(quantity, 10) || 1)) };
            }
            return v;
          });
          await updateDoc(doc(db, "products", selectedProduct.id), {
            variants: updatedVariants,
            updatedAt: serverTimestamp(),
          });
        }
      }

      onSaleLogged?.();
      onClose();
    } catch (err) {
      setError(err?.message ?? "Failed to save sale.");
      setSaving(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-content" style={{ maxWidth: 540 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <h2 style={{ margin: 0, fontSize: 18 }}>💰 Log Sale</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
        </div>

        <form onSubmit={handleSubmit}>
          <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: "16px 0" }}>
            {/* Platform Selector */}
            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 6 }}>
                Platform
              </label>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                {PLATFORMS.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    className={`btn ${platform === p.id ? "btn-primary" : "btn-ghost"}`}
                    style={{ fontSize: 12, padding: "6px 12px" }}
                    onClick={() => setPlatform(p.id)}
                  >
                    {p.icon} {p.label}
                  </button>
                ))}
              </div>
            </div>

            {/* Mercari / External Listing URL */}
            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                {platform === "mercari" ? "Mercari Item URL (Auto-Match Product)" : "Listing or Receipt URL (Optional)"}
              </label>
              <input
                className="input"
                type="url"
                placeholder={platform === "mercari" ? "https://www.mercari.com/us/item/m12345678901/" : "https://..."}
                value={urlInput}
                onChange={(e) => setUrlInput(e.target.value)}
              />
              <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 4 }}>
                Pastes from mobile or desktop sync instantly to your account.
              </div>
            </div>

            {/* Associated Product Selection */}
            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                Associated Product
              </label>
              <input
                className="input"
                type="text"
                placeholder="Search products by title or tag…"
                value={productSearch}
                onChange={(e) => {
                  setProductSearch(e.target.value);
                  if (selectedProductId && e.target.value !== selectedProduct?.title) {
                    setSelectedProductId("");
                  }
                }}
              />
              {productSearch && !selectedProductId && (
                <div
                  style={{
                    maxHeight: 150,
                    overflowY: "auto",
                    background: "var(--surface-high)",
                    border: "var(--border-thin) solid var(--border)",
                    borderRadius: "var(--radius)",
                    marginTop: 4,
                  }}
                >
                  {filteredProducts.length === 0 ? (
                    <div style={{ padding: "8px 12px", fontSize: 12, color: "var(--muted)" }}>
                      No matching products. (Will record as custom item)
                    </div>
                  ) : (
                    filteredProducts.slice(0, 8).map((p) => (
                      <div
                        key={p.id}
                        style={{
                          padding: "8px 12px",
                          fontSize: 13,
                          cursor: "pointer",
                          display: "flex",
                          alignItems: "center",
                          gap: 8,
                          borderBottom: "var(--border-thin) solid var(--border)",
                        }}
                        onClick={() => {
                          setSelectedProductId(p.id);
                          setProductSearch(p.title);
                        }}
                      >
                        {p.images?.[0] && (
                          <img src={p.images[0]} alt="" style={{ width: 24, height: 24, borderRadius: 4, objectFit: "cover" }} />
                        )}
                        <span style={{ flex: 1, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                          {p.title}
                        </span>
                        {p.tags?.length > 0 && (
                          <span style={{ fontSize: 10, color: "var(--accent)", border: "1px solid var(--accent)", padding: "1px 4px", borderRadius: 4 }}>
                            {p.tags[0]}
                          </span>
                        )}
                      </div>
                    ))
                  )}
                </div>
              )}
            </div>

            {/* Variant Selector if product has variations */}
            {variants.length > 0 && (
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                  Variant / Size Sold
                </label>
                <select
                  className="input"
                  value={selectedVariantSku}
                  onChange={(e) => setSelectedVariantSku(e.target.value)}
                >
                  {variants.map((v, i) => (
                    <option key={v.sku || i} value={v.sku}>
                      {v.sku ? `[${v.sku}] ` : ""}
                      {v.optionValues ? Object.entries(v.optionValues).map(([k, val]) => `${k}: ${val}`).join(" · ") : `Variant #${i + 1}`}
                      {v.quantity != null ? ` (${v.quantity} in stock)` : ""}
                    </option>
                  ))}
                </select>
              </div>
            )}

            {/* Sale Price & Quantity */}
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                  Sale Price ($) *
                </label>
                <input
                  className="input"
                  type="number"
                  step="0.01"
                  min="0"
                  required
                  placeholder="0.00"
                  value={salePrice}
                  onChange={(e) => setSalePrice(e.target.value)}
                />
              </div>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                  Quantity Sold
                </label>
                <input
                  className="input"
                  type="number"
                  min="1"
                  required
                  value={quantity}
                  onChange={(e) => setQuantity(parseInt(e.target.value, 10) || 1)}
                />
              </div>
            </div>

            {/* Date Sold */}
            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                Sale Date
              </label>
              <input
                className="input"
                type="date"
                value={soldDate}
                onChange={(e) => setSoldDate(e.target.value)}
              />
            </div>

            {/* Stock Decrement Checkbox */}
            {selectedProduct && (
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={decrementStock}
                  onChange={(e) => setDecrementStock(e.target.checked)}
                />
                <span>Automatically decrement product stock in Wonni</span>
              </label>
            )}

            {/* Notes */}
            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                Notes (Optional)
              </label>
              <input
                className="input"
                type="text"
                placeholder="e.g. Bundled with tour photocard, buyer requested standard shipping"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
              />
            </div>

            {error && <div style={{ fontSize: 12, color: "var(--danger)" }}>{error}</div>}
          </div>

          <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: 8, borderTop: "var(--border-thin) solid var(--border)", paddingTop: 12 }}>
            <button type="button" className="btn btn-ghost" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary" disabled={saving || !salePrice}>
              {saving ? "Saving…" : "Save Sale"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
