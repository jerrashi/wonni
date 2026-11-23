import { useState, useEffect, useRef, useMemo } from "react";
import { collection, doc, deleteDoc, query, where, orderBy, onSnapshot, updateDoc, serverTimestamp } from "firebase/firestore";
import { useNavigate } from "react-router-dom";
import { db, callFunction } from "../firebase";
import { auth } from "../firebase";
import Layout from "../components/Layout";
import CreateDraftModal from "../components/CreateDraftModal";
import PostModal from "../components/PostModal";
import BulkPostModal from "../components/BulkPostModal";
import BulkTagModal from "../components/BulkTagModal";
import WeverseShopImportModal from "../components/WeverseShopImportModal";
import TextToListingsModal from "../components/TextToListingsModal";
import OverflowMenu from "../components/OverflowMenu";
import { getPlatformListingUrl } from "../lib/platformLinks";
import { productCost, suggestedListingPrice } from "../lib/pricing";
import { deleteProductEverywhere, isLiveOnMercari } from "../lib/deleteProduct";

// ── List Modal ────────────────────────────────────────────────────────────────

function ListModal({ product, onClose, onListed }) {
  const [title, setTitle] = useState(product.title.slice(0, 255));
  // Prefill from the canonical list price only — never from cost fields.
  const [price, setPrice] = useState(
    Number(product.listingPrice) > 0 ? Number(product.listingPrice).toFixed(2) : ""
  );
  const [categories, setCategories] = useState([]);
  const [loadingCats, setLoadingCats] = useState(true);
  const [catSearch, setCatSearch] = useState("");
  const [selectedCat, setSelectedCat] = useState(null);
  const [listing, setListing] = useState(false);
  const [error, setError] = useState("");
  const listRef = useRef(null);
  const priceInputRef = useRef(null);
  const priceValid = parseFloat(price) > 0;

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
    if (!(parseFloat(price) > 0)) {
      setError("Required field: Price is empty");
      priceInputRef.current?.focus();
      return;
    }
    setListing(true);
    setError("");
    try {
      // `listingPrice` is the one cross-platform price — persist it, then the
      // backend reads it (no per-call price argument any more).
      await updateDoc(doc(db, "products", product.id), {
        listingPrice: parseFloat(price),
        updatedAt: serverTimestamp(),
      });
      await callFunction("tiktokCreateListing")({
        productId: product.id,
        title: title.slice(0, 255),
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
            <label>Listing price (USD) <span style={{ color: "var(--danger)" }}>*</span></label>
            {!priceValid && suggestedListingPrice(product) != null && (
              <div style={{ marginBottom: 4, fontSize: 11, color: "var(--accent)", display: "flex", gap: 6, alignItems: "center" }}>
                <span title="2× source price ÷ 0.9">✨ suggested: ${suggestedListingPrice(product)}</span>
                <button className="btn btn-ghost" style={{ fontSize: 11, padding: "1px 6px" }} onClick={() => setPrice(String(suggestedListingPrice(product)))}>Use</button>
              </div>
            )}
            <input
              ref={priceInputRef}
              className="input"
              type="number"
              step="0.01"
              min="0"
              required
              value={price}
              onChange={(e) => setPrice(e.target.value)}
              style={!priceValid && error ? { borderColor: "var(--danger)" } : undefined}
            />
            {productCost(product) != null && (
              <span style={{ fontSize: 11, color: "var(--muted)" }}>
                Cost: ${productCost(product).toFixed(2)} · Margin: ${(parseFloat(price || 0) * 0.925 - productCost(product)).toFixed(2)}
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
          {!priceValid && (
            <span style={{ fontSize: 12, color: "var(--danger)", marginRight: "auto" }}>Required field: Price is empty</span>
          )}
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button
            className="btn btn-primary"
            style={priceValid ? undefined : { opacity: 0.5 }}
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
  const [text, setText] = useState("");
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const [shopModalUrl, setShopModalUrl] = useState(null);
  const [textModal, setTextModal] = useState(null);

  // One box for everything (2026-10-15): Weverse / AliExpress product links keep
  // their importers (variants, duplicate checks); a Weverse shop or artist
  // section link opens its preview; anything else — plain text, Amazon / eBay /
  // other links, or a mix — goes to textToListings (TextToListingsModal).
  const lines = text.split(/\n+/).map((s) => s.trim()).filter(Boolean);
  const urls = text.match(/https?:\/\/[^\s<>"'`\])}]+/gi) || [];
  const isUrlLine = (line) => /^https?:\/\/\S+$/i.test(line);
  const isWeverseSale = (u) => u.includes("shop.weverse.io") && /\/sales\/\d+/.test(u);
  const isAliexpress = (u) => /aliexpress\.(com|us|ru)\//i.test(u) && (/\/item\/\d+/.test(u) || /[?&]id=\d+/.test(u));
  const isShopSectionUrl = lines.length === 1 && isUrlLine(lines[0]) && lines[0].includes("shop.weverse.io") && !/\/sales\/\d+/.test(lines[0]);
  const onlyImporterLinks = lines.length > 0 && lines.every((l) => isUrlLine(l) && (isWeverseSale(l) || isAliexpress(l)));

  const hint = isShopSectionUrl
    ? "That's a shop/artist section — preview its items before importing"
    : onlyImporterLinks
      ? `${lines.length} ${lines.length === 1 ? "product link" : "product links"} · imports with variants`
      : lines.length
        ? `${lines.length} line${lines.length === 1 ? "" : "s"}${urls.length ? ` · ${urls.length} link${urls.length === 1 ? "" : "s"}` : ""}`
        : "Paste product links or describe what you're selling. Weverse and AliExpress links import as before; Amazon, eBay and other links, and plain text, become drafts.";

  async function handleImport() {
    if (!lines.length) return;
    if (isShopSectionUrl) { setShopModalUrl(lines[0]); return; }
    if (!onlyImporterLinks) { setTextModal(text); return; }

    setLoading(true);
    setError("");
    setStatus("Importing…");
    try {
      if (lines.length === 1) {
        const url = lines[0];
        const fn = url.includes("shop.weverse.io") ? "weverseImportProduct" : "aliexpressImportProduct";
        const result = await callFunction(fn)({ productUrl: url });
        setText("");
        setStatus("");
        onImported?.(result.data.productId);
      } else if (lines.every(isWeverseSale)) {
        const response = await callFunction("weverseBulkImportProducts")({ items: lines.map((url) => ({ productUrl: url })) });
        const res = response?.data;
        setText("");
        const errors = res?.errors ?? [];
        setStatus(`Bulk import complete! ${res?.importedCount ?? 0} imported, ${res?.existingCount ?? 0} already existing.`);
        if (errors.length) {
          const preview = errors.slice(0, 3).map((e) => `${e.title ?? "Item"}: ${e.error}`).join("; ");
          setError(`${errors.length} item${errors.length === 1 ? "" : "s"} failed — ${preview}${errors.length > 3 ? "…" : ""}`);
        }
        onImported?.(res?.productIds?.[0]);
      } else {
        // Several AliExpress links (or a mix): one importer call each, in order.
        let imported = 0;
        const failures = [];
        for (const url of lines) {
          try {
            const fn = url.includes("shop.weverse.io") ? "weverseImportProduct" : "aliexpressImportProduct";
            await callFunction(fn)({ productUrl: url });
            imported++;
          } catch (e) {
            failures.push(`${url}: ${e.message ?? "failed"}`);
          }
        }
        setText("");
        setStatus(`${imported} imported.`);
        if (failures.length) setError(failures.slice(0, 3).join("; "));
        onImported?.();
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
      <div style={{ fontSize: 13, color: "var(--muted)", marginBottom: 8 }}>{hint}</div>

      <div className="input-group" style={{ flexDirection: "column", gap: 8 }}>
        <textarea
          className="input"
          rows={lines.length > 1 || urls.length ? 4 : 2}
          placeholder={"iphone 18 pro case https://www.amazon.com/dp/B0CHX1W1XY\namazing spider man issues 211-215, bagged and boarded\nhttps://shop.weverse.io/en/shop/USD/artists/.../sales/..."}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) handleImport(); }}
        />
        <button
          className="btn btn-primary"
          style={{ alignSelf: "flex-end" }}
          onClick={handleImport}
          disabled={loading || !text.trim()}
        >
          {loading ? "Importing…" : isShopSectionUrl ? "Preview Items" : "Import"}
        </button>
      </div>

      {status && <div style={{ marginTop: 8, fontSize: 13, color: "var(--success)" }}>{status}</div>}
      {error && <div style={{ marginTop: 8, fontSize: 13, color: "var(--danger)" }}>{error}</div>}

      {shopModalUrl && (
        <WeverseShopImportModal
          shopUrl={shopModalUrl}
          onClose={() => setShopModalUrl(null)}
          onImported={(productIds) => {
            setText("");
            productIds.forEach((id) => onImported?.(id));
          }}
        />
      )}
      {textModal != null && (
        <TextToListingsModal
          text={textModal}
          onClose={() => setTextModal(null)}
          onCreated={(ids) => { setText(""); ids.forEach((id) => onImported?.(id)); }}
        />
      )}
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

  // Capsule per platform with a status dot (green live, orange incomplete);
  // clicking opens the live listing.
  const short = { "TikTok Shop": "TikTok" };
  return (
    <div className="platform-badges">
      {platforms.map((p) => {
        const listingUrl = getPlatformListingUrl(p.id, product);
        const incomplete = p.status === "incomplete";
        return (
          <button
            type="button"
            key={p.id}
            className="platform-badge"
            title={p.name + (incomplete ? " (incomplete)" : "") + (listingUrl ? " · open live listing" : "")}
            disabled={!listingUrl}
            onClick={(e) => {
              e.stopPropagation();
              if (!listingUrl) return;
              if (listingUrl.startsWith("http")) window.open(listingUrl, "_blank", "noopener,noreferrer");
              else window.location.href = listingUrl;
            }}
          >
            <span className="platform-dot" style={{ background: incomplete ? "var(--warning)" : "var(--success)" }} />
            {short[p.name] ?? p.name}
          </button>
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
  const [markingOutOfStock, setMarkingOutOfStock] = useState(false);

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

  // Same callable ProductDetail's "Mark as out of stock" menu item uses.
  async function handleMarkOutOfStock() {
    if (!window.confirm("Mark this listing as out of stock? Quantity will be set to 0 everywhere it's posted, but listings stay live.")) return;
    setMarkingOutOfStock(true);
    try {
      await callFunction("markSoldOutAndCascade")({ productId: product.id });
    } catch (e) {
      window.alert(e.message ?? "Failed to mark out of stock.");
    } finally {
      setMarkingOutOfStock(false);
    }
  }

  return (
    <>
      <div className={`product-card ${selected ? "product-card-selected" : ""}`} style={{ position: "relative" }}>
        {/* Upper-right actions submenu */}
        <div className="product-card-menu" onClick={(e) => e.stopPropagation()}>
          <OverflowMenu
            items={[
              ...(product?.saleStatus !== "sold" ? [{
                label: markingOutOfStock ? "⏳ Marking…" : "📭 Mark as out of stock",
                onClick: handleMarkOutOfStock,
                disabled: markingOutOfStock,
              }] : []),
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
          onClick={() => (selectMode ? onSelect(!selected) : navigate(`/sell/products/${product.id}`))}
        >
          {primaryImage ? (
            <img src={primaryImage} alt={product.title} />
          ) : (
            <div className="product-card-placeholder">No image</div>
          )}

          {/* Status badge - upper left: Sold Out wins over Draft; live shows nothing
              (the platform badges below already say where it is). */}
          {isSourceSoldOut ? (
            <span className="product-card-badge" style={{ color: "var(--danger)" }}>Sold Out</span>
          ) : !isLive ? (
            <span className="product-card-badge" style={{ color: "var(--warning)" }}>Draft</span>
          ) : null}

          {/* Select circle - only in select mode (iOS checkmark.circle) */}
          {selectMode && (
            <span className={`select-circle ${selected ? "on" : ""}`} aria-hidden="true">
              {selected && (
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3.5"><path d="M5 12l5 5 9-10" /></svg>
              )}
            </span>
          )}
        </button>

        <div className="product-card-body">
          <button
            className="product-card-title-button"
            aria-pressed={selectMode ? selected : undefined}
            onClick={() => (selectMode ? onSelect(!selected) : navigate(`/sell/products/${product.id}`))}
          >
            <div className="product-card-title">{product.title}</div>
          </button>

          <div className="product-card-price-row">
            <span className="product-card-price">
              {typeof product.listingPrice === "number" ? `$${product.listingPrice.toFixed(2)}` : "No price"}
            </span>
            {(product.quantity ?? 1) > 1 && <span className="product-card-qty">Qty {product.quantity}</span>}
          </div>

          <div className="product-card-footer">
            <PostedPlatforms product={product} />
            <button className="btn btn-ghost btn-sm" onClick={() => setShowPostModal(true)}>
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
  const [bulkDeleting, setBulkDeleting] = useState(false);
  const [bulkMarkingOOS, setBulkMarkingOOS] = useState(false);

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

  // Same cascade-delete rule as ProductDetail's single delete (see
  // deleteProduct.js): each product's live eBay/Etsy/TikTok listings go
  // first, then the Firestore doc. One confirm for the whole batch rather
  // than one per product.
  async function handleBulkDelete() {
    const selected = regularProducts.filter((p) => selectedIds.has(p.id));
    if (!selected.length) return;

    const anyLiveOnMercari = selected.some(isLiveOnMercari);
    const countNote = selected.length === 1 ? `"${selected[0].title}"` : `${selected.length} products`;
    if (!window.confirm(`Delete ${countNote}? This will also remove any live eBay/Etsy/TikTok listings for them. This can't be undone.`)) return;
    if (anyLiveOnMercari && !window.confirm("Some selected products are live on Mercari, which has no automatic delete yet — you'll need to remove those listings manually on Mercari. Continue deleting from Wonni?")) return;

    setBulkDeleting(true);
    setError("");
    const failures = [];
    for (const product of selected) {
      const result = await deleteProductEverywhere(product, callFunction);
      if (!result.ok) failures.push(result.error);
    }
    setBulkDeleting(false);
    setSelectedIds(new Set());
    if (failures.length) setError(failures.join(" "));
  }

  // Same callable ProductDetail's "Mark as out of stock" menu item uses
  // (markSoldOutAndCascade) — zeroes quantity respecting quantityVariesByVariant
  // and cascade-pushes to every live platform, without withdrawing any listing.
  async function handleBulkMarkOutOfStock() {
    const selected = regularProducts.filter((p) => selectedIds.has(p.id));
    if (!selected.length) return;

    const countNote = selected.length === 1 ? `"${selected[0].title}"` : `${selected.length} products`;
    if (!window.confirm(`Mark ${countNote} as out of stock? Quantity will be set to 0 everywhere posted, but listings stay live.`)) return;

    setBulkMarkingOOS(true);
    setError("");
    const failures = [];
    for (const product of selected) {
      try {
        await callFunction("markSoldOutAndCascade")({ productId: product.id });
      } catch (e) {
        failures.push(`Couldn't mark "${product.title}" out of stock: ${e.message}`);
      }
    }
    setBulkMarkingOOS(false);
    setSelectedIds(new Set());
    if (failures.length) setError(failures.join(" "));
  }

  return (
    <Layout>
      {/* iOS top bar: (Select | Done · Select All) · actions trailing. Once
          something is selected the trailing side becomes the selection actions. */}
      <div className="page-toolbar">
        <button
          className="btn btn-plain"
          onClick={() => { setSelectMode(!selectMode); setSelectedIds(new Set()); }}
        >
          {selectMode ? "Done" : "Select"}
        </button>
        {selectMode && (
          <button className="btn btn-plain" onClick={toggleSelectAll}>
            {allSelected ? "Deselect All" : "Select All"}
          </button>
        )}
        <span className="spacer" />
        {selectMode && someSelected ? (
          <>
            <span className="page-subtitle">{selectedIds.size} selected</span>
            <button className="btn btn-ghost" onClick={() => setShowBulkTagModal(true)}>Tag</button>
            <button className="btn btn-ghost" onClick={handleBulkMarkOutOfStock} disabled={bulkMarkingOOS}>
              {bulkMarkingOOS ? "Marking…" : "Mark Out of Stock"}
            </button>
            <button className="btn btn-ghost-danger" onClick={handleBulkDelete} disabled={bulkDeleting}>
              {bulkDeleting ? "Deleting…" : "Delete"}
            </button>
            <button className="btn btn-primary" onClick={() => setShowBulkPostModal(true)}>
              Post to Platforms
            </button>
          </>
        ) : !selectMode ? (
          <button className="btn btn-primary" onClick={() => setShowCreateModal(true)}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
            Draft from Photo
          </button>
        ) : null}
      </div>

      <div className="page-header">
        <div>
          <h1>Products</h1>
          <span className="page-subtitle">
            {regularProducts.length} total · {regularProducts.filter(isLive).length} live
          </span>
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
          {/* Segmented status filter + one scrolling row of tag chips. */}
          <div className="filter-bar">
            <div className="segmented" role="group" aria-label="Filter products">
              {[
                ["all", "All", regularProducts.length],
                ["draft", "Drafts", regularProducts.filter((p) => !isLive(p)).length],
                ["live", "Live", regularProducts.filter(isLive).length],
              ].map(([f, label, count]) => (
                <button
                  key={f}
                  className={filter === f ? "active" : ""}
                  aria-pressed={filter === f}
                  onClick={() => { setFilter(f); setSelectedIds(new Set()); }}
                >
                  {label} {count}
                </button>
              ))}
            </div>

            {allTags.length > 0 && (
              <div className="chip-row" role="group" aria-label="Filter by tag">
                <button
                  className={`chip-filter ${selectedTag === null ? "active" : ""}`}
                  aria-pressed={selectedTag === null}
                  onClick={() => { setSelectedTag(null); setSelectedIds(new Set()); }}
                >
                  All tags
                </button>
                {allTags.map((tag) => (
                  <button
                    key={tag}
                    className={`chip-filter ${selectedTag === tag ? "active" : ""}`}
                    aria-pressed={selectedTag === tag}
                    onClick={() => { setSelectedTag(selectedTag === tag ? null : tag); setSelectedIds(new Set()); }}
                  >
                    {tag}
                  </button>
                ))}
              </div>
            )}
          </div>

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
