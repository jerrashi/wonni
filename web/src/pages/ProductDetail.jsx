import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { doc, onSnapshot, serverTimestamp, updateDoc } from "firebase/firestore";
import { useNavigate, useParams } from "react-router-dom";
import { auth, db, callFunction, uploadImageBlob } from "../firebase";
import Layout from "../components/Layout";

// ─── helpers ──────────────────────────────────────────────────────────────────

function money(value) {
  if (typeof value !== "number" || Number.isNaN(value)) return "—";
  return `$${value.toFixed(2)}`;
}

function formatDate(value) {
  if (!value?.toDate) return "—";
  return new Intl.DateTimeFormat("en", {
    month: "short", day: "numeric", year: "numeric",
    hour: "numeric", minute: "2-digit",
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
    id: `${url}-${index}`, url, sourceUrl: url, width: null, height: null, kind: "catalog",
  }));
}

function moveItem(list, from, to) {
  const next = [...list];
  const [item] = next.splice(from, 1);
  next.splice(to, 0, item);
  return next;
}

// Draw an image from a URL onto an offscreen canvas and return the canvas
function loadImageOntoCanvas(url, targetWidth, targetHeight) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => {
      const w = targetWidth ?? img.naturalWidth;
      const h = targetHeight ?? img.naturalHeight;
      const canvas = document.createElement("canvas");
      canvas.width = w;
      canvas.height = h;
      canvas.getContext("2d").drawImage(img, 0, 0, w, h);
      resolve({ canvas, naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight });
    };
    img.onerror = reject;
    img.src = url;
  });
}

// ─── CropEditor ───────────────────────────────────────────────────────────────

function CropEditor({ image, productId, onSave, onCancel, saving }) {
  const canvasRef = useRef(null);
  const [sel, setSel] = useState(null);       // { x, y, w, h } in canvas px
  const [dragging, setDragging] = useState(null); // { startX, startY, initSel, handle }
  const [naturalSize, setNaturalSize] = useState(null);
  const [status, setStatus] = useState("");

  // Draw the image + selection overlay
  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    const img = canvas._img;
    if (!img) return;

    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

    if (!sel) return;
    const { x, y, w, h } = sel;

    // Dark overlay outside selection
    ctx.fillStyle = "rgba(0,0,0,0.55)";
    ctx.fillRect(0, 0, canvas.width, y);
    ctx.fillRect(0, y + h, canvas.width, canvas.height - y - h);
    ctx.fillRect(0, y, x, h);
    ctx.fillRect(x + w, y, canvas.width - x - w, h);

    // Selection border
    ctx.strokeStyle = "#ff6b35";
    ctx.lineWidth = 2;
    ctx.strokeRect(x, y, w, h);

    // Corner handles
    const hs = 8;
    ctx.fillStyle = "#ff6b35";
    [[x, y], [x + w, y], [x, y + h], [x + w, y + h]].forEach(([cx, cy]) => {
      ctx.fillRect(cx - hs / 2, cy - hs / 2, hs, hs);
    });

    // Rule-of-thirds guide lines
    ctx.strokeStyle = "rgba(255,255,255,0.25)";
    ctx.lineWidth = 1;
    [1, 2].forEach((n) => {
      ctx.beginPath(); ctx.moveTo(x + (w * n) / 3, y); ctx.lineTo(x + (w * n) / 3, y + h); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x, y + (h * n) / 3); ctx.lineTo(x + w, y + (h * n) / 3); ctx.stroke();
    });
  }, [sel]);

  // Load image into canvas
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !image?.url) return;
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => {
      canvas._img = img;
      setNaturalSize({ w: img.naturalWidth, h: img.naturalHeight });
      // Default selection = full image minus 10%
      const pad = Math.floor(Math.min(canvas.width, canvas.height) * 0.05);
      setSel({ x: pad, y: pad, w: canvas.width - pad * 2, h: canvas.height - pad * 2 });
    };
    img.src = image.url;
  }, [image?.url]);

  useEffect(() => { draw(); }, [draw, sel]);

  // Clamp selection to canvas bounds
  function clampSel(s, cw, ch) {
    const x = Math.max(0, Math.min(s.x, cw - 10));
    const y = Math.max(0, Math.min(s.y, ch - 10));
    const w = Math.max(10, Math.min(s.w, cw - x));
    const h = Math.max(10, Math.min(s.h, ch - y));
    return { x, y, w, h };
  }

  function getHandle(px, py) {
    if (!sel) return null;
    const { x, y, w, h } = sel;
    const corners = { tl: [x, y], tr: [x + w, y], bl: [x, y + h], br: [x + w, y + h] };
    const hs = 14;
    for (const [name, [cx, cy]] of Object.entries(corners)) {
      if (Math.abs(px - cx) < hs && Math.abs(py - cy) < hs) return name;
    }
    if (px > x && px < x + w && py > y && py < y + h) return "move";
    return "new";
  }

  function canvasPos(e) {
    const rect = canvasRef.current.getBoundingClientRect();
    const scaleX = canvasRef.current.width / rect.width;
    const scaleY = canvasRef.current.height / rect.height;
    return { px: (e.clientX - rect.left) * scaleX, py: (e.clientY - rect.top) * scaleY };
  }

  function onMouseDown(e) {
    const { px, py } = canvasPos(e);
    const handle = getHandle(px, py);
    setDragging({ startX: px, startY: py, initSel: sel ? { ...sel } : null, handle });
  }

  function onMouseMove(e) {
    if (!dragging) return;
    const canvas = canvasRef.current;
    const { px, py } = canvasPos(e);
    const dx = px - dragging.startX;
    const dy = py - dragging.startY;
    const is = dragging.initSel;

    let next;
    if (dragging.handle === "new") {
      const x = Math.min(dragging.startX, px);
      const y = Math.min(dragging.startY, py);
      const w = Math.abs(px - dragging.startX);
      const h = Math.abs(py - dragging.startY);
      next = { x, y, w, h };
    } else if (dragging.handle === "move") {
      next = { ...is, x: is.x + dx, y: is.y + dy };
    } else {
      next = { ...is };
      if (dragging.handle.includes("r")) { next.w = is.w + dx; }
      if (dragging.handle.includes("l")) { next.x = is.x + dx; next.w = is.w - dx; }
      if (dragging.handle.includes("b")) { next.h = is.h + dy; }
      if (dragging.handle.includes("t")) { next.y = is.y + dy; next.h = is.h - dy; }
    }
    setSel(clampSel(next, canvas.width, canvas.height));
  }

  function onMouseUp() { setDragging(null); }

  async function applyCrop() {
    if (!sel || !naturalSize) return;
    const canvas = canvasRef.current;
    const scaleX = naturalSize.w / canvas.width;
    const scaleY = naturalSize.h / canvas.height;
    const srcX = Math.round(sel.x * scaleX);
    const srcY = Math.round(sel.y * scaleY);
    const srcW = Math.round(sel.w * scaleX);
    const srcH = Math.round(sel.h * scaleY);

    const offscreen = document.createElement("canvas");
    offscreen.width = srcW;
    offscreen.height = srcH;
    const ctx = offscreen.getContext("2d");
    const img = canvas._img;
    ctx.drawImage(img, srcX, srcY, srcW, srcH, 0, 0, srcW, srcH);

    setStatus("Uploading…");
    try {
      const blob = await new Promise((res) => offscreen.toBlob(res, "image/jpeg", 0.92));
      const uid = auth.currentUser?.uid;
      const url = await uploadImageBlob(uid, productId, blob, "-crop");
      await onSave({ url, width: srcW, height: srcH, kind: "crop" });
    } catch (err) {
      setStatus(err.message ?? "Upload failed.");
    }
  }

  return (
    <div className="img-editor-body">
      <p className="img-editor-hint">Drag to select a crop area. Drag corners to resize.</p>
      <div className="crop-canvas-wrap">
        <canvas
          ref={canvasRef}
          width={600}
          height={500}
          className="crop-canvas"
          onMouseDown={onMouseDown}
          onMouseMove={onMouseMove}
          onMouseUp={onMouseUp}
          onMouseLeave={onMouseUp}
          style={{ cursor: dragging ? (dragging.handle === "move" ? "grabbing" : "crosshair") : "crosshair" }}
        />
      </div>
      {status && <div className="img-editor-status">{status}</div>}
      <div className="img-edit-popover-actions">
        <button className="btn btn-primary" onClick={applyCrop} disabled={saving || !sel}>
          Apply crop
        </button>
        <button className="btn btn-ghost" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ─── IdentifyEditor ───────────────────────────────────────────────────────────

const BOX_COLORS = ["#2dd4bf", "#fbbf24", "#f472b6", "#60a5fa", "#a78bfa", "#34d399"];

function IdentifyEditor({ image, productId, onSave, onCancel, saving }) {
  const canvasRef = useRef(null);
  const [boxes, setBoxes] = useState(null);   // null = loading, [] = none found
  const [loadError, setLoadError] = useState("");
  const [naturalSize, setNaturalSize] = useState(null);
  const [dragging, setDragging] = useState(null); // { boxId, handle, startX, startY, initBox }
  const [status, setStatus] = useState("");

  // Call Cloud Function on mount
  useEffect(() => {
    let cancelled = false;
    callFunction("identifyProductsInImage")({ productId, imageUrl: image.url })
      .then((res) => {
        if (cancelled) return;
        setBoxes(res.data.objects ?? []);
      })
      .catch((err) => {
        if (!cancelled) setLoadError(err.message ?? "Identification failed.");
      });
    return () => { cancelled = true; };
  }, [image.url, productId]);

  // Measure the natural image size once
  useEffect(() => {
    if (!image?.url) return;
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => setNaturalSize({ w: img.naturalWidth, h: img.naturalHeight });
    img.src = image.url;
  }, [image?.url]);

  // Convert normalised 0-1000 box to canvas pixels
  function boxToPx(box, cw, ch) {
    const [ymin, xmin, ymax, xmax] = box;
    return {
      x: (xmin / 1000) * cw,
      y: (ymin / 1000) * ch,
      w: ((xmax - xmin) / 1000) * cw,
      h: ((ymax - ymin) / 1000) * ch,
    };
  }

  // Draw all boxes on the canvas overlay
  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas || !boxes) return;
    const cw = canvas.width;
    const ch = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, cw, ch);

    boxes.forEach((box, i) => {
      const color = BOX_COLORS[i % BOX_COLORS.length];
      const { x, y, w, h } = boxToPx(box.box, cw, ch);
      const hs = 8;

      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.strokeRect(x, y, w, h);

      // Label badge
      ctx.fillStyle = color;
      const pad = 4;
      ctx.font = "bold 12px -apple-system, sans-serif";
      const tw = ctx.measureText(box.label).width;
      ctx.fillRect(x, y - 20, tw + pad * 2, 20);
      ctx.fillStyle = "#000";
      ctx.fillText(box.label, x + pad, y - 5);

      // Corner handles
      ctx.fillStyle = color;
      [[x, y], [x + w, y], [x, y + h], [x + w, y + h]].forEach(([cx, cy]) => {
        ctx.fillRect(cx - hs / 2, cy - hs / 2, hs, hs);
      });
    });
  }, [boxes]);

  useEffect(() => { draw(); }, [draw]);

  function canvasPos(e) {
    const rect = canvasRef.current.getBoundingClientRect();
    const canvas = canvasRef.current;
    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    return { px: (e.clientX - rect.left) * scaleX, py: (e.clientY - rect.top) * scaleY };
  }

  function getBoxHandle(px, py, cw, ch) {
    const hs = 14;
    for (let i = (boxes?.length ?? 0) - 1; i >= 0; i--) {
      const { x, y, w, h } = boxToPx(boxes[i].box, cw, ch);
      const corners = { tl: [x, y], tr: [x + w, y], bl: [x, y + h], br: [x + w, y + h] };
      for (const [name, [cx, cy]] of Object.entries(corners)) {
        if (Math.abs(px - cx) < hs && Math.abs(py - cy) < hs) return { id: boxes[i].id, handle: name };
      }
      if (px > x && px < x + w && py > y && py < y + h) return { id: boxes[i].id, handle: "move" };
    }
    return null;
  }

  function normBox(x, y, w, h, cw, ch) {
    return [
      Math.round((y / ch) * 1000),
      Math.round((x / cw) * 1000),
      Math.round(((y + h) / ch) * 1000),
      Math.round(((x + w) / cw) * 1000),
    ].map((v) => Math.max(0, Math.min(1000, v)));
  }

  function onMouseDown(e) {
    const canvas = canvasRef.current;
    const { px, py } = canvasPos(e);
    const hit = getBoxHandle(px, py, canvas.width, canvas.height);
    if (!hit) return;
    const box = boxes.find((b) => b.id === hit.id);
    const { x, y, w, h } = boxToPx(box.box, canvas.width, canvas.height);
    setDragging({ boxId: hit.id, handle: hit.handle, startX: px, startY: py, initRect: { x, y, w, h } });
  }

  function onMouseMove(e) {
    if (!dragging) return;
    const canvas = canvasRef.current;
    const { px, py } = canvasPos(e);
    const dx = px - dragging.startX;
    const dy = py - dragging.startY;
    const { x: ix, y: iy, w: iw, h: ih } = dragging.initRect;
    let nx = ix, ny = iy, nw = iw, nh = ih;

    if (dragging.handle === "move") { nx = ix + dx; ny = iy + dy; }
    else {
      if (dragging.handle.includes("r")) nw = iw + dx;
      if (dragging.handle.includes("l")) { nx = ix + dx; nw = iw - dx; }
      if (dragging.handle.includes("b")) nh = ih + dy;
      if (dragging.handle.includes("t")) { ny = iy + dy; nh = ih - dy; }
    }

    const cw = canvas.width, ch = canvas.height;
    nx = Math.max(0, Math.min(nx, cw - 10));
    ny = Math.max(0, Math.min(ny, ch - 10));
    nw = Math.max(10, Math.min(nw, cw - nx));
    nh = Math.max(10, Math.min(nh, ch - ny));

    setBoxes((prev) => prev.map((b) =>
      b.id === dragging.boxId
        ? { ...b, box: normBox(nx, ny, nw, nh, cw, ch) }
        : b
    ));
  }

  function onMouseUp() { setDragging(null); }

  function deleteBox(id) {
    setBoxes((prev) => prev.filter((b) => b.id !== id));
  }

  async function confirmBoxes() {
    if (!boxes?.length || !naturalSize) return;
    setStatus("Cropping and uploading…");
    const uid = auth.currentUser?.uid;
    const results = [];

    for (let i = 0; i < boxes.length; i++) {
      const box = boxes[i];
      const [ymin, xmin, ymax, xmax] = box.box;
      const srcX = Math.round((xmin / 1000) * naturalSize.w);
      const srcY = Math.round((ymin / 1000) * naturalSize.h);
      const srcW = Math.round(((xmax - xmin) / 1000) * naturalSize.w);
      const srcH = Math.round(((ymax - ymin) / 1000) * naturalSize.h);

      try {
        const { canvas } = await loadImageOntoCanvas(image.url, naturalSize.w, naturalSize.h);
        const offscreen = document.createElement("canvas");
        offscreen.width = srcW;
        offscreen.height = srcH;
        offscreen.getContext("2d").drawImage(canvas, srcX, srcY, srcW, srcH, 0, 0, srcW, srcH);
        const blob = await new Promise((res) => offscreen.toBlob(res, "image/jpeg", 0.92));
        const url = await uploadImageBlob(uid, productId, blob, `-identify-${i}`);
        results.push({ url, width: srcW, height: srcH, kind: "identified", label: box.label });
      } catch (err) {
        setStatus(`Failed on "${box.label}": ${err.message}`);
        return;
      }
    }

    setStatus("");
    await onSave(results);
  }

  const canvasSize = { width: 600, height: 480 };

  return (
    <div className="img-editor-body">
      {loadError ? (
        <div className="img-editor-status" style={{ color: "var(--danger)" }}>{loadError}</div>
      ) : !boxes ? (
        <div className="img-editor-status">Identifying products with Gemini…</div>
      ) : boxes.length === 0 ? (
        <div className="img-editor-status">No products detected. Try a clearer image.</div>
      ) : (
        <>
          <p className="img-editor-hint">
            Drag boxes to reposition · Drag corners to resize · Click × to delete.
            Confirm crops one image per box.
          </p>
          <div className="identify-canvas-wrap">
            <img src={image.url} alt="product" className="identify-base-img" />
            <canvas
              ref={canvasRef}
              width={canvasSize.width}
              height={canvasSize.height}
              className="identify-canvas-overlay"
              onMouseDown={onMouseDown}
              onMouseMove={onMouseMove}
              onMouseUp={onMouseUp}
              onMouseLeave={onMouseUp}
              style={{ cursor: dragging ? "grabbing" : "default" }}
            />
            {/* Delete buttons positioned over each box */}
            {boxes.map((box, i) => {
              const color = BOX_COLORS[i % BOX_COLORS.length];
              // Position delete btn at top-right of each box in CSS % terms
              const [ymin, xmin, , xmax] = box.box;
              return (
                <button
                  key={box.id}
                  className="identify-box-delete"
                  style={{
                    top: `${ymin / 10}%`,
                    left: `${xmax / 10}%`,
                    background: color,
                  }}
                  onClick={() => deleteBox(box.id)}
                  title={`Remove "${box.label}" box`}
                >
                  ×
                </button>
              );
            })}
          </div>
          <div className="identify-box-list">
            {boxes.map((box, i) => (
              <span key={box.id} className="identify-box-chip" style={{ borderColor: BOX_COLORS[i % BOX_COLORS.length] }}>
                {box.label}
              </span>
            ))}
          </div>
        </>
      )}
      {status && <div className="img-editor-status">{status}</div>}
      <div className="img-edit-popover-actions">
        {boxes?.length > 0 && (
          <button className="btn btn-primary" onClick={confirmBoxes} disabled={saving || !boxes.length}>
            {saving ? "Saving…" : `Confirm & crop ${boxes.length} image${boxes.length === 1 ? "" : "s"}`}
          </button>
        )}
        <button className="btn btn-ghost" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ─── SplitPreview ─────────────────────────────────────────────────────────────

function SplitPreview({ image, onConfirm, onCancel, saving }) {
  const isTall = typeof image.height === "number" && typeof image.width === "number"
    ? image.height / image.width > 1.6 : false;
  const sliceHeight = image.height ? Math.max(1200, Math.min(1800, Math.floor(image.height / 2))) : 1800;
  const sliceCount = image.height ? Math.ceil(image.height / sliceHeight) : "?";

  // Visual: draw cut lines as horizontal dashes overlaid on the image
  const lines = [];
  if (typeof image.height === "number" && image.height > 0) {
    for (let y = sliceHeight; y < image.height; y += sliceHeight) {
      lines.push(((y / image.height) * 100).toFixed(1));
    }
  }

  return (
    <div className="img-editor-body">
      <p className="img-editor-hint">
        {isTall
          ? `This image is tall (${image.width}×${image.height}px). It will be cut into ${sliceCount} slices of ~${sliceHeight}px each.`
          : `Split will cut this image horizontally into equal slices (~${sliceHeight}px each).`}
      </p>
      <div className="split-preview-wrap">
        <img src={image.url} alt="preview" className="split-preview-img" />
        {lines.map((pct) => (
          <div key={pct} className="split-cut-line" style={{ top: `${pct}%` }} />
        ))}
      </div>
      <div className="img-edit-popover-actions">
        <button className="btn btn-primary" onClick={onConfirm} disabled={saving}>
          {saving ? "Splitting…" : `✂ Split into ${sliceCount} images`}
        </button>
        <button className="btn btn-ghost" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ─── ImageStrip ───────────────────────────────────────────────────────────────

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

  function handleDragEnd() { setDragIndex(null); setDropTarget(null); }

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
            <span className="img-thumb-handle" title="Drag to reorder">⠿</span>
            <img src={image.url} alt={`Image ${index + 1}`} />
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

// ─── ImageEditModal ────────────────────────────────────────────────────────────
// mode: "menu" | "crop" | "identify" | "split"

function ImageEditModal({ image, index, total, productId, onClose, onSplit, onDelete, onSetCover, onSaveCrop, onSaveIdentify, saving }) {
  const [mode, setMode] = useState("menu");
  const ref = useRef(null);

  // Close on outside click only in menu mode (editors handle their own cancel)
  useEffect(() => {
    if (mode !== "menu") return;
    function handler(e) {
      if (ref.current && !ref.current.contains(e.target)) onClose();
    }
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [mode, onClose]);

  function header(title) {
    return (
      <div className="img-edit-popover-header">
        {mode !== "menu" && (
          <button className="btn btn-ghost" style={{ padding: "4px 10px", fontSize: 13 }} onClick={() => setMode("menu")}>
            ← Back
          </button>
        )}
        <span style={{ fontWeight: 600, fontSize: 14 }}>{title}</span>
        <button className="btn btn-ghost" style={{ padding: "4px 10px", fontSize: 13, marginLeft: "auto" }} onClick={onClose}>✕</button>
      </div>
    );
  }

  return (
    <div className="modal-overlay" onClick={mode === "menu" ? onClose : undefined}>
      <div
        ref={ref}
        className={`img-edit-popover${mode !== "menu" ? " img-edit-popover-wide" : ""}`}
        onClick={(e) => e.stopPropagation()}
      >
        {mode === "menu" && (
          <>
            {header(`Image ${index + 1} of ${total}`)}
            <div className="img-edit-popover-preview">
              <img src={image.url} alt={`Image ${index + 1}`} />
            </div>
            <div className="img-edit-popover-meta">
              {image.width && image.height ? `${image.width}×${image.height}px · ` : ""}
              {image.kind && image.kind !== "catalog" ? image.kind : "catalog"}
            </div>
            <div className="img-edit-popover-actions">
              {index !== 0 && (
                <button className="btn btn-ghost" onClick={onSetCover} disabled={saving}>⭐ Set as cover</button>
              )}
              <button className="btn btn-ghost" onClick={() => setMode("crop")} disabled={saving}>✂ Crop</button>
              <button className="btn btn-ghost" onClick={() => setMode("identify")} disabled={saving}>🔍 Identify products</button>
              <button className="btn btn-ghost" onClick={() => setMode("split")} disabled={saving}>⚡ Split</button>
              <button className="btn btn-danger" onClick={onDelete} disabled={saving}>Delete</button>
            </div>
          </>
        )}

        {mode === "crop" && (
          <>
            {header("Crop image")}
            <CropEditor
              image={image}
              productId={productId}
              onSave={onSaveCrop}
              onCancel={() => setMode("menu")}
              saving={saving}
            />
          </>
        )}

        {mode === "identify" && (
          <>
            {header("Identify products")}
            <IdentifyEditor
              image={image}
              productId={productId}
              onSave={onSaveIdentify}
              onCancel={() => setMode("menu")}
              saving={saving}
            />
          </>
        )}

        {mode === "split" && (
          <>
            {header("Split image")}
            <SplitPreview
              image={image}
              onConfirm={onSplit}
              onCancel={() => setMode("menu")}
              saving={saving}
            />
          </>
        )}
      </div>
    </div>
  );
}

// ─── ProductDetail page ───────────────────────────────────────────────────────

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
    if (!productId) { setError("Missing product ID."); setLoading(false); return; }
    setLoading(true);
    setError("");
    const ref = doc(db, "products", productId);
    return onSnapshot(ref,
      (snap) => {
        if (!snap.exists()) { setProduct(null); setError("Product not found."); setLoading(false); return; }
        const next = { id: snap.id, ...snap.data() };
        setProduct(next);
        setTitle(next.title ?? "");
        setDescription(next.description ?? "");
        setImages(normalizeImageAssets(next));
        setPreviewIndex(0);
        setLoading(false);
      },
      (err) => { setError(err?.message ?? "Could not load product."); setLoading(false); }
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
      if (!slices.length) { setMediaError("That image did not return any slices."); return; }
      const splitImages = slices.map((slice, i) => ({
        id: `${slice.url}-${i}`, url: slice.url,
        sourceUrl: image.sourceUrl ?? image.url,
        width: slice.width ?? null, height: slice.height ?? null, kind: "split",
      }));
      await saveMedia([...images.slice(0, index), ...splitImages, ...images.slice(index + 1)]);
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

  // Called by CropEditor: replace original image with the cropped version
  async function handleSaveCrop(cropResult) {
    const index = editingIndex;
    if (index === null) return;
    const newImage = {
      id: `${cropResult.url}-crop`,
      url: cropResult.url,
      sourceUrl: images[index]?.url ?? cropResult.url,
      width: cropResult.width ?? null,
      height: cropResult.height ?? null,
      kind: "crop",
    };
    const nextImages = images.map((img, i) => (i === index ? newImage : img));
    await saveMedia(nextImages);
    setEditingIndex(null);
  }

  // Called by IdentifyEditor: replace original image with all cropped boxes
  async function handleSaveIdentify(results) {
    const index = editingIndex;
    if (index === null) return;
    const newImages = results.map((r, i) => ({
      id: `${r.url}-id-${i}`,
      url: r.url,
      sourceUrl: images[index]?.url ?? r.url,
      width: r.width ?? null,
      height: r.height ?? null,
      kind: "identified",
    }));
    const nextImages = [
      ...images.slice(0, index),
      ...newImages,
      ...images.slice(index + 1),
    ];
    await saveMedia(nextImages);
    setEditingIndex(null);
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
                  <div className="img-preview-badge">{safePreviewIndex + 1} / {images.length}</div>
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

              {mediaError && <div style={{ color: "var(--danger)", fontSize: 13, marginTop: 4 }}>{mediaError}</div>}
              {savingMedia && <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 4 }}>Saving…</div>}
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
                  <div><span>Imported</span><strong>{formatDate(product.importedAt)}</strong></div>
                  <div><span>Images</span><strong>{imageCountLabel}</strong></div>
                  <div><span>Variants</span><strong>{variants.length}</strong></div>
                  <div><span>Source price</span><strong>{money(product.sourcePrice ?? product.aliexpressPrice)}</strong></div>
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
                  <textarea className="input" rows={8} value={description} onChange={(e) => setDescription(e.target.value)} />
                </div>
                <div style={{ display: "flex", gap: 12, alignItems: "center", marginTop: 12 }}>
                  <button className="btn btn-primary" onClick={saveTextFields} disabled={savingText}>
                    {savingText ? "Saving…" : "Save text"}
                  </button>
                  <span style={{ fontSize: 12, color: "var(--muted)" }}>Listings use these as the base catalog fields.</span>
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
                        <div style={{ minWidth: 180 }}><strong>{row.label}</strong></div>
                        <div style={{ flex: 1 }}><span style={{ whiteSpace: "pre-wrap" }}>{row.value}</span></div>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              {preorder && (
                <div className="detail-section">
                  <h2>Pre-order</h2>
                  <div className="detail-grid">
                    <div><span>Enabled</span><strong>{product.preOrder ? "Yes" : "No"}</strong></div>
                    <div><span>Delivery start</span><strong>{preorder.deliveryStartAt ?? "—"}</strong></div>
                    <div><span>Delivery end</span><strong>{preorder.deliveryEndAt ?? "—"}</strong></div>
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
              <a href={product.sourceUrl} target="_blank" rel="noreferrer">{product.sourceUrl}</a>
            </div>
          )}
        </div>
      ) : null}

      {/* Image edit modal */}
      {editingIndex !== null && images[editingIndex] && (
        <ImageEditModal
          image={images[editingIndex]}
          index={editingIndex}
          total={images.length}
          productId={productId}
          onClose={() => setEditingIndex(null)}
          onSplit={() => handleSplitImage(editingIndex)}
          onDelete={() => handleDeleteImage(editingIndex)}
          onSetCover={() => handleSetCover(editingIndex)}
          onSaveCrop={handleSaveCrop}
          onSaveIdentify={handleSaveIdentify}
          saving={savingMedia}
        />
      )}
    </Layout>
  );
}
