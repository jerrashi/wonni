import { useEffect, useMemo, useRef, useState } from "react";
import { doc, onSnapshot, serverTimestamp, updateDoc } from "firebase/firestore";
import { useNavigate, useParams } from "react-router-dom";
import { db, callFunction } from "../firebase";
import Layout from "../components/Layout";

function money(value) {
  if (typeof value !== "number" || Number.isNaN(value)) return "—";
  return `$${value.toFixed(2)}`;
}

function formatDate(value) {
  if (!value?.toDate) return "—";
  return new Intl.DateTimeFormat("en", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(value.toDate());
}

function badgeLabel(source) {
  if (source === "weverse") return "Weverse";
  if (source === "aliexpress") return "AliExpress";
  return source ?? "Imported";
}

function normalizeImageAssets(product) {
  if (Array.isArray(product?.imageAssets) && product.imageAssets.length) {
    return product.imageAssets.map((image, index) => ({
      id: image.id ?? `${image.url}-${index}`,
      url: image.url,
      sourceUrl: image.sourceUrl ?? image.url,
      width: image.width ?? null,
      height: image.height ?? null,
      kind: image.kind ?? "catalog",
    }));
  }

  return (product?.images ?? []).map((url, index) => ({
    id: `${url}-${index}`,
    url,
    sourceUrl: url,
    width: null,
    height: null,
    kind: "catalog",
  }));
}

function moveItem(list, from, to) {
  const next = [...list];
  const [item] = next.splice(from, 1);
  next.splice(to, 0, item);
  return next;
}

// ── Thumbnail strip ──────────────────────────────────────────────────────────
function ImageStrip({ images, activeIndex, onHover, onDrop, onEdit, savingMedia }) {
  const [dragIndex, setDragIndex] = useState(null);
  const [dropTarget, setDropTarget] = useState(null);

  function handleDragStart(e, index) {
    setDragIndex(index);
    e.dataTransfer.effectAllowed = "move";
  }

  function handleDragOver(e, index) {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    if (index !== dragIndex) setDropTarget(index);
  }

  function handleDrop(e, index) {
    e.preventDefault();
    if (dragIndex !== null && dragIndex !== index) onDrop(dragIndex, index);
    setDragIndex(null);
    setDropTarget(null);
  }

  function handleDragEnd() {
    setDragIndex(null);
    setDropTarget(null);
  }

  return (
    <div className="img-strip">
      {images.map((image, index) => {
        const isActive = index === activeIndex;
        const isDragging = index === dragIndex;
        const isDropTarget = index === dropTarget;
        return (
          <div
            key={image.id}
            className={`img-thumb${isActive ? " img-thumb-active" : ""}${isDragging ? " img-thumb-dragging" : ""}${isDropTarget ? " img-thumb-drop" : ""}`}
            draggable={!savingMedia}
            onMouseEnter={() => onHover(index)}
            onDragStart={(e) => handleDragStart(e, index)}
            onDragOver={(e) => handleDragOver(e, index)}
            onDrop={(e) => handleDrop(e, index)}
            onDragEnd={handleDragEnd}
          >
            {/* drag handle */}
            <span className="img-thumb-handle" title="Drag to reorder">⠿</span>

            <img src={image.url} alt={`Image ${index + 1}`} />

            {/* edit button */}
            <button
              className="img-thumb-edit"
              title="Edit image"
              onClick={(e) => { e.stopPropagation(); onEdit(index); }}
              disabled={savingMedia}
            >
              ✏
            </button>

            {isActive && <span className="img-thumb-cover-dot" />}
          </div>
        );
      })}
    </div>
  );
}

// ── Per-image edit popover ───────────────────────────────────────────────────
function ImageEditPopover({ image, index, total, onClose, onSplit, onDelete, onSetCover, saving }) {
  const ref = useRef(null);
  const isTall = typeof image.height === "number" && typeof image.width === "number"
    ? image.height / image.width > 1.6
    : false;

  // Close on outside click
  useEffect(() => {
    function handler(e) {
      if (ref.current && !ref.current.contains(e.target)) onClose();
    }
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [onClose]);

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div
        ref={ref}
        className="img-edit-popover"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="img-edit-popover-preview">
          <img src={image.url} alt={`Image ${index + 1}`} />
        </div>
        <div className="img-edit-popover-meta">
          Image {index + 1} of {total}
          {image.width && image.height ? ` · ${image.width}×${image.height}px` : ""}
          {image.kind && image.kind !== "catalog" ? ` · ${image.kind}` : ""}
        </div>
        <div className="img-edit-popover-actions">
          {index !== 0 && (
            <button className="btn btn-ghost" onClick={onSetCover} disabled={saving}>
              ★ Set as cover
            </button>
          )}
          {isTall && (
            <button className="btn btn-primary" onClick={onSplit} disabled={saving}>
              {saving ? "Splitting…" : "✂ Split tall image"}
            </button>
          )}
          <button className="btn btn-danger" onClick={onDelete} disabled={saving}>
            Delete
          </button>
          <button className="btn btn-ghost" onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

export default function ProductDetail() {
  const { productId } = useParams();
  const navigate = useNavigate();
  const [product, setProduct] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [images, setImages] = useState([]);
  const [previewIndex, setPreviewIndex] = useState(0);
  const [editingIndex, setEditingIndex] = useState(null);
  const [savingText, setSavingText] = useState(false);
  const [savingMedia, setSavingMedia] = useState(false);
  const [mediaError, setMediaError] = useState("");

  useEffect(() => {
    if (!productId) {
      setError("Missing product ID.");
      setLoading(false);
      return;
    }

    setLoading(true);
    setError("");

    const ref = doc(db, "products", productId);
    return onSnapshot(
      ref,
      (snap) => {
        if (!snap.exists()) {
          setProduct(null);
          setError("Product not found.");
          setLoading(false);
          return;
        }
        const next = { id: snap.id, ...snap.data() };
        setProduct(next);
        setTitle(next.title ?? "");
        setDescription(next.description ?? "");
        setImages(normalizeImageAssets(next));
        setPreviewIndex(0);
        setLoading(false);
      },
      (err) => {
        setError(err?.message ?? "Could not load product.");
        setLoading(false);
      }
    );
  }, [productId]);

  const variants = product?.variants ?? [];
  const preorder = product?.preOrder;
  const infoTable = product?.weverseInfoTable ?? [];
  const safePreviewIndex = Math.min(previewIndex, Math.max(0, images.length - 1));
  const previewImage = images[safePreviewIndex]?.url ?? "";
  const imageCountLabel = useMemo(() => {
    if (!images.length) return "No images";
    return `${images.length} image${images.length === 1 ? "" : "s"}`;
  }, [images.length]);

  async function saveTextFields() {
    if (!productId) return;
    setSavingText(true);
    try {
      await updateDoc(doc(db, "products", productId), {
        title: title.trim(),
        description: description.trim(),
        updatedAt: serverTimestamp(),
      });
    } finally {
      setSavingText(false);
    }
  }

  async function saveMedia(nextImages) {
    if (!productId) return;
    setSavingMedia(true);
    setMediaError("");
    setImages(nextImages);
    try {
      const payload = nextImages.map((image, index) => ({
        id: image.id ?? `${image.url}-${index}`,
        url: image.url,
        sourceUrl: image.sourceUrl ?? image.url,
        width: image.width ?? null,
        height: image.height ?? null,
        kind: image.kind ?? "catalog",
      }));
      await updateDoc(doc(db, "products", productId), {
        images: payload.map((image) => image.url),
        imageAssets: payload,
        listingImages: payload.map((image) => image.url),
        updatedAt: serverTimestamp(),
      });
    } catch (err) {
      setMediaError(err?.message ?? "Could not save image changes.");
    } finally {
      setSavingMedia(false);
    }
  }

  async function handleSplitImage(index) {
    const image = images[index];
    if (!image?.url) return;

    setSavingMedia(true);
    setMediaError("");
    try {
      const response = await callFunction("splitProductImage")({
        productId,
        imageUrl: image.url,
        sliceHeight: image.height ? Math.max(1200, Math.min(1800, Math.floor(image.height / 2))) : 1800,
      });

      const slices = response?.data?.slices ?? [];
      if (!slices.length) {
        setMediaError("That image did not return any slices.");
        return;
      }

      const splitImages = slices.map((slice, sliceIndex) => ({
        id: `${slice.url}-${sliceIndex}`,
        url: slice.url,
        sourceUrl: image.sourceUrl ?? image.url,
        width: slice.width ?? null,
        height: slice.height ?? null,
        kind: "split",
      }));

      const nextImages = [...images.slice(0, index), ...splitImages, ...images.slice(index + 1)];
      await saveMedia(nextImages);
      setEditingIndex(null);
    } catch (err) {
      setMediaError(err?.message ?? "Could not split image.");
    } finally {
      setSavingMedia(false);
    }
  }

  async function handleDeleteImage(index) {
    const nextImages = images.filter((_, i) => i !== index);
    await saveMedia(nextImages);
    setEditingIndex(null);
    setPreviewIndex((prev) => Math.min(prev, Math.max(0, nextImages.length - 1)));
  }

  async function handleSetCover(index) {
    if (index === 0) return;
    const nextImages = moveItem(images, index, 0);
    await saveMedia(nextImages);
    setPreviewIndex(0);
    setEditingIndex(null);
  }

  async function handleDropReorder(from, to) {
    if (from === to) return;
    const nextImages = moveItem(images, from, to);
    await saveMedia(nextImages);
    setPreviewIndex(to);
  }

  return (
    <Layout>
      <div className="page-header">
        <div>
          <button className="btn btn-ghost" style={{ marginBottom: 12 }} onClick={() => navigate(-1)}>
            ← Back
          </button>
          <h1>{product?.title ?? "Product detail"}</h1>
          <div style={{ marginTop: 6, fontSize: 13, color: "var(--muted)" }}>
            {product?.artistName ? `${product.artistName} · ` : ""}
            {badgeLabel(product?.source)}
          </div>
        </div>
        {product?.sourceUrl && (
          <a href={product.sourceUrl} target="_blank" rel="noreferrer" className="btn btn-ghost">
            Open source listing
          </a>
        )}
      </div>

      {error && <div className="card" style={{ marginBottom: 20, color: "var(--danger)" }}>{error}</div>}

      {loading ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>⏳</div>
          <p>Loading imported item details…</p>
        </div>
      ) : product ? (
        <div className="product-detail">
          <div className="card product-detail-hero">
            {/* ── Left: image viewer ── */}
            <div className="product-detail-gallery">
              <div className="product-detail-main-image">
                {previewImage ? (
                  <img src={previewImage} alt={product.title} />
                ) : (
                  <div className="product-detail-placeholder">No image</div>
                )}
                {images.length > 0 && (
                  <div className="img-preview-badge">
                    {safePreviewIndex + 1} / {images.length}
                  </div>
                )}
              </div>

              {images.length > 0 && (
                <ImageStrip
                  images={images}
                  activeIndex={safePreviewIndex}
                  onHover={setPreviewIndex}
                  onDrop={handleDropReorder}
                  onEdit={setEditingIndex}
                  savingMedia={savingMedia}
                />
              )}

              {mediaError && (
                <div style={{ color: "var(--danger)", fontSize: 13, marginTop: 4 }}>{mediaError}</div>
              )}
              {savingMedia && (
                <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 4 }}>Saving…</div>
              )}
            </div>

            {/* ── Right: info panel ── */}
            <div className="product-detail-panel">
              <div className="detail-badges">
                <span className="chip chip-draft">{badgeLabel(product.source)}</span>
                <span className={`chip ${product.tiktokStatus === "active" ? "chip-active" : "chip-draft"}`}>
                  {product.tiktokStatus ?? "draft"}
                </span>
                {product.saleStatus && <span className="chip chip-pending">{product.saleStatus}</span>}
              </div>

              <div className="product-detail-price">{money(product.aliexpressPrice)}</div>

              <div className="detail-section">
                <h2>Scraped summary</h2>
                <div className="detail-grid">
                  <div>
                    <span>Imported</span>
                    <strong>{formatDate(product.importedAt)}</strong>
                  </div>
                  <div>
                    <span>Images</span>
                    <strong>{imageCountLabel}</strong>
                  </div>
                  <div>
                    <span>Variants</span>
                    <strong>{variants.length}</strong>
                  </div>
                  <div>
                    <span>Source price</span>
                    <strong>{money(product.sourcePrice ?? product.aliexpressPrice)}</strong>
                  </div>
                </div>
              </div>

              <div className="detail-section">
                <h2>Edit catalog text</h2>
                <div className="modal-field" style={{ marginBottom: 12 }}>
                  <label>Title</label>
                  <input className="input" value={title} onChange={(e) => setTitle(e.target.value)} />
                </div>
                <div className="modal-field">
                  <label>Description</label>
                  <textarea
                    className="input"
                    rows={8}
                    value={description}
                    onChange={(e) => setDescription(e.target.value)}
                  />
                </div>
                <div style={{ display: "flex", gap: 12, alignItems: "center", marginTop: 12 }}>
                  <button className="btn btn-primary" onClick={saveTextFields} disabled={savingText}>
                    {savingText ? "Saving…" : "Save text"}
                  </button>
                  <span style={{ fontSize: 12, color: "var(--muted)" }}>
                    Listings use these as the base catalog fields.
                  </span>
                </div>
              </div>

              <div className="detail-section">
                <h2>Structured Weverse info table</h2>
                {infoTable.length === 0 ? (
                  <p className="detail-copy">No structured info table was exposed in the payload.</p>
                ) : (
                  <div className="variant-list">
                    {infoTable.map((row, index) => (
                      <div key={`${row.label}-${index}`} className="variant-row" style={{ gap: 16 }}>
                        <div style={{ minWidth: 180 }}>
                          <strong>{row.label}</strong>
                        </div>
                        <div style={{ flex: 1 }}>
                          <span style={{ whiteSpace: "pre-wrap" }}>{row.value}</span>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              {preorder && (
                <div className="detail-section">
                  <h2>Pre-order</h2>
                  <div className="detail-grid">
                    <div>
                      <span>Enabled</span>
                      <strong>{product.preOrder ? "Yes" : "No"}</strong>
                    </div>
                    <div>
                      <span>Delivery start</span>
                      <strong>{preorder.deliveryStartAt ?? "—"}</strong>
                    </div>
                    <div>
                      <span>Delivery end</span>
                      <strong>{preorder.deliveryEndAt ?? "—"}</strong>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>

          <div className="card detail-section">
            <h2>Variants</h2>
            {variants.length === 0 ? (
              <p className="detail-copy">No variants were exposed in the import.</p>
            ) : (
              <div className="variant-list">
                {variants.map((variant) => (
                  <div key={variant.stockId ?? variant.name} className="variant-row">
                    <div>
                      <strong>{variant.name || "Unnamed variant"}</strong>
                      <span>{variant.stockId ?? "No stock ID"}</span>
                    </div>
                    <div>
                      <strong>{money(variant.price)}</strong>
                      <span>{variant.soldOut ? "Sold out" : "Available"}</span>
                    </div>
                    <div>
                      <strong>{variant.addPrice ? `+${money(variant.addPrice)}` : "No add-on"}</strong>
                      <span>{variant.maxOrderQuantity ? `Max ${variant.maxOrderQuantity}` : "No limit"}</span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {product.sourceUrl && (
            <div className="card detail-section">
              <h2>Source</h2>
              <a href={product.sourceUrl} target="_blank" rel="noreferrer">
                {product.sourceUrl}
              </a>
            </div>
          )}
        </div>
      ) : null}

      {/* Edit popover */}
      {editingIndex !== null && images[editingIndex] && (
        <ImageEditPopover
          image={images[editingIndex]}
          index={editingIndex}
          total={images.length}
          onClose={() => setEditingIndex(null)}
          onSplit={() => handleSplitImage(editingIndex)}
          onDelete={() => handleDeleteImage(editingIndex)}
          onSetCover={() => handleSetCover(editingIndex)}
          saving={savingMedia}
        />
      )}
    </Layout>
  );
}
