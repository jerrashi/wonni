import { useCallback, useEffect, useMemo, useRef, useState, Component, Fragment } from "react";
import { collection, deleteField, doc, deleteDoc, onSnapshot, query, serverTimestamp, updateDoc, where } from "firebase/firestore";
import { useBlocker, useNavigate, useParams } from "react-router-dom";
import { auth, db, callFunction, uploadImageBlob } from "../firebase";
import Layout from "../components/Layout";
import UnsavedChangesModal from "../components/UnsavedChangesModal";
import PostModal from "../components/PostModal";
import OverflowMenu from "../components/OverflowMenu";
import ApplyMercariEditsModal from "../components/ApplyMercariEditsModal";
import ApplyEbayEditsModal from "../components/ApplyEbayEditsModal";
import { useDebouncedCallback } from "../hooks/useDebouncedCallback";
import { normalizeImageAssets, buildImagePayload } from "../lib/media";
import { useMediaJobQueue } from "../lib/mediaJobQueue";
import { getPlatformListingUrl } from "../lib/platformLinks";

// ─── helpers ──────────────────────────────────────────────────────────────────

// Per-platform caps on how many photos get sent in a listing payload — mirrors
// functions/platform_adapters.js (toEbayInventoryProduct's imageLimit default,
// used via ebay_listing.js; listingImagesFor(product, 9) for TikTok). All
// photos are always stored regardless of these caps — they only trim what
// gets posted to each platform.
const PLATFORM_IMAGE_LIMITS = { "TikTok Shop": 9, eBay: 12 };

function money(value) {
  const num = typeof value === "number" ? value : parseFloat(value);
  if (typeof num !== "number" || Number.isNaN(num)) return "$0.00";
  return `$${num.toFixed(2)}`;
}

// Text input (not type="number") so the browser's native spin buttons and
// scroll-to-change-value behavior don't silently alter a price while the
// user is scrolling the page. `value`/`onChangeText` carry the raw string
// while typing (so a trailing "." or partial decimal isn't stripped on every
// keystroke); `onCommit` receives that raw string on blur to parse and save.
function DollarInput({ value, onChangeText, onCommit, disabled, placeholder = "(not set)", style }) {
  return (
    <div style={{ position: "relative", ...style }}>
      <span
        style={{
          position: "absolute", left: 10, top: "50%", transform: "translateY(-50%)",
          color: "var(--muted)", fontSize: 14, pointerEvents: "none",
        }}
      >
        $
      </span>
      <input
        className="input"
        type="text"
        inputMode="decimal"
        placeholder={placeholder}
        style={{ paddingLeft: 22 }}
        value={value}
        onChange={(e) => {
          const raw = e.target.value;
          if (raw === "" || /^\d*\.?\d*$/.test(raw)) onChangeText(raw);
        }}
        onBlur={() => onCommit(value)}
        disabled={disabled}
      />
    </div>
  );
}

function formatDate(value) {
  if (!value?.toDate) return "Just now";
  return new Intl.DateTimeFormat("en", {
    month: "short", day: "numeric", year: "numeric",
    hour: "numeric", minute: "2-digit",
  }).format(value.toDate());
}

function badgeLabel(source) {
  if (source === "weverse") return "Weverse";
  if (source === "aliexpress") return "AliExpress";
  if (source === "photo_upload" || source === "photo_upload_split" || source === "manual" || source === "image") return "Photo Upload";
  return source ? source.charAt(0).toUpperCase() + source.slice(1) : "Photo Upload";
}

function moveItem(list, from, to) {
  const next = [...list];
  const [item] = next.splice(from, 1);
  next.splice(to, 0, item);
  return next;
}

export function normalizeOptions(product) {
  return Array.isArray(product?.options)
    ? product.options.map((opt, i) => ({
        id: opt.id ?? `opt-${i}`,
        name: opt.name ?? "",
        values: Array.isArray(opt.values) ? opt.values : [],
      }))
    : [];
}

export function normalizeVariants(product) {
  return Array.isArray(product?.variants)
    ? product.variants.map((v) => ({
        id: v.id,
        optionValues: v.optionValues ?? {},
        sku: v.sku ?? null,
        price: typeof v.price === "number" ? v.price : null,
        quantity: typeof v.quantity === "number" ? v.quantity : 1,
        sourcePrice: typeof v.sourcePrice === "number" ? v.sourcePrice : null,
        sourceVariantId: v.sourceVariantId ?? null,
        active: v.active !== false,
        needsReview: Boolean(v.needsReview),
        // Per-variant Mercari listing state — pass through as-is (not editable
        // via the variants table itself) so re-normalizing on every snapshot
        // update, or a variants-table Save, never drops/clobbers it.
        mercariStatus: v.mercariStatus ?? null,
        mercariListingId: v.mercariListingId ?? null,
        mercariUrl: v.mercariUrl ?? null,
        mercariError: v.mercariError ?? null,
        mercariSyncedTitle: v.mercariSyncedTitle ?? null,
        mercariSyncedPrice: typeof v.mercariSyncedPrice === "number" ? v.mercariSyncedPrice : null,
        mercariSyncedImages: Array.isArray(v.mercariSyncedImages) ? v.mercariSyncedImages : null,
        mercariPhotoRemovedUrls: Array.isArray(v.mercariPhotoRemovedUrls) ? v.mercariPhotoRemovedUrls : [],
      }))
    : [];
}

// A variant carries real (imported or user-entered) data worth protecting,
// as opposed to a blank placeholder row auto-generated by regenerateVariants.
// A price that's just following the shared listing price (never explicitly
// overridden for this variant) doesn't count as "populated" — deleting that
// row loses nothing a user actually entered.
function isPopulatedVariant(v, listingPrice) {
  return v.sourceVariantId != null || v.sourcePrice != null || (v.price != null && v.price !== listingPrice);
}

// A raw variant object counts as legacy if it carries old opaque Weverse
// fields (name/stockId) but no optionValues — i.e. it predates the
// options/variants schema (or was written outside these Cloud Functions).
// normalizeVariants would otherwise render it as a blank row that clicking
// Save could clobber, so it's detected and migrated client-side (mirroring
// functions/weverse_product.js's mapWeverseVariantsToOptions) before ever
// reaching the editor. Nothing is written to Firestore until Save is clicked.
function isLegacyShapedVariant(v) {
  return (v?.name != null || v?.stockId != null || v?.price != null) && v?.optionValues == null;
}

function migrateLegacyVariants(rawVariants) {
  const values = [...new Set(rawVariants.map((v) => v.name || "Default").filter(Boolean))];
  if (!values.length) return { options: [], variants: [] };

  const options = [{ id: "opt-0", name: "Option", values }];
  const variants = rawVariants.map((v, i) => ({
    id: v.id ?? `v${Date.now()}${i}`,
    optionValues: { Option: v.name || "Default" },
    sku: v.sku ?? (v.stockId ? `w-${v.stockId}` : `w-${i + 1}`),
    price: typeof v.price === "number" ? v.price + (v.addPrice ?? 0) : (typeof v.costPrice === "number" ? v.costPrice * 2 : null),
    quantity: typeof v.maxOrderQuantity === "number" ? v.maxOrderQuantity : 1,
    sourcePrice: typeof v.costPrice === "number" ? v.costPrice : (typeof v.price === "number" ? v.price : null),
    sourceVariantId: v.stockId ?? null,
    active: v.soldOut !== true,
    needsReview: false,
  }));

  return { options, variants };
}

// Shared by the onSnapshot hydration and handleDiscard's revert-to-live-values
// path so both apply the exact same legacy-shape detection/migration —
// calling normalizeOptions/normalizeVariants directly on a legacy-shaped
// product silently drops every variant's optionValues instead of migrating.
function deriveOptionsAndVariants(productLike) {
  const rawVariants = Array.isArray(productLike?.variants) ? productLike.variants : [];
  const hasNoOptions = !Array.isArray(productLike?.options) || productLike.options.length === 0;
  const isLegacy = hasNoOptions && rawVariants.length > 0 && rawVariants.every(isLegacyShapedVariant);
  if (isLegacy) {
    const migrated = migrateLegacyVariants(rawVariants);
    return { options: migrated.options, variants: migrated.variants, isLegacy: true };
  }
  return { options: normalizeOptions(productLike), variants: normalizeVariants(productLike), isLegacy: false };
}

// Cartesian product of every option's values, as an array of { optionName: value } combos.
// Options with no values yet are ignored rather than collapsing the whole
// result to zero combos — otherwise the instant you click "+ Add option"
// (which appends an option with values: []), every existing variant would
// look orphaned until you finish typing that option's values.
function cartesianOptionValues(options) {
  const withValues = options.filter((opt) => opt.values.length > 0);
  if (!withValues.length) return [{}];
  return withValues.reduce(
    (combos, opt) => combos.flatMap((combo) => opt.values.map((value) => ({ ...combo, [opt.name]: value }))),
    [{}]
  );
}

function generateVariantId() {
  return `v${Date.now()}${Math.random().toString(36).slice(2, 8)}`;
}

function blankVariant(productId, skuIndex, optionValues) {
  return {
    id: generateVariantId(),
    optionValues,
    sku: `${productId}-${skuIndex}`,
    price: null,
    quantity: 1,
    sourcePrice: null,
    sourceVariantId: null,
    active: true,
    needsReview: false,
  };
}

// Relabels existing variants' optionValues to reflect a pure rename (option
// dimension name and/or individual value text edited in place, via the
// "edit" pencil in ManageVariationsModal) — a typo fix shouldn't touch
// price/SKU data the way deleting-and-re-adding a value would.
function applyOptionRename(existingVariants, renameInfo) {
  if (!renameInfo?.optionName) return existingVariants;
  const { optionName, newOptionName, valueRenames } = renameInfo;
  if (optionName === newOptionName && !valueRenames.length) return existingVariants;
  const renameMap = new Map(valueRenames);
  return existingVariants.map((v) => {
    if (!(optionName in v.optionValues)) return v;
    const oldValue = v.optionValues[optionName];
    const { [optionName]: _dropped, ...rest } = v.optionValues;
    return { ...v, optionValues: { ...rest, [newOptionName]: renameMap.get(oldValue) ?? oldValue } };
  });
}

// Hard-deletes every variant row for one or more removed values of
// `optionName`. Explicit deletions are irreversible by design — there's no
// "unmatched, needs review" quarantine here, because there's nothing to
// guess at: the user picked exactly which value(s) to remove.
function removeOptionValues(existingVariants, optionName, removedValues) {
  if (!removedValues.length) return existingVariants;
  const removedSet = new Set(removedValues);
  return existingVariants.filter((v) => !removedSet.has(v.optionValues[optionName]));
}

// Hard-deletes every variant row that carries `optionName` at all — used
// when the whole option dimension is deleted via the trash icon.
function removeOptionEntirely(existingVariants, optionName) {
  return existingVariants.filter((v) => !(optionName in v.optionValues));
}

// Adds new blank rows for one or more brand-new values of an *already
// existing* option dimension — one new row per combination of the other
// dimensions' current values. Existing rows are untouched, so a pure
// addition can never orphan anything.
function addOptionValues(existingVariants, otherOptions, optionName, addedValues, productId) {
  const otherCombos = cartesianOptionValues(otherOptions);
  let nextSkuIndex = existingVariants.length + 1;
  const added = [];
  for (const addedValue of addedValues) {
    for (const combo of otherCombos) {
      added.push(blankVariant(productId, nextSkuIndex++, { ...combo, [optionName]: addedValue }));
    }
  }
  return [...existingVariants, ...added];
}

// Adds a brand-new option dimension (the product had none yet, or had one
// and is gaining a second). Existing active rows don't gain a blank sibling
// for every new value — they *become* the first value (keeping their
// id/price/SKU), and only the remaining values generate fresh blank rows.
// e.g. "V Jersey" becomes "V Jersey, M-L", and "V Jersey, XL-XXL" is added
// alongside it, rather than both starting blank and orphaning the old row.
function addNewOptionDimension(existingVariants, optionName, values, productId) {
  const [firstValue, ...restValues] = values;
  let nextSkuIndex = existingVariants.length + 1;
  const activeExisting = existingVariants.filter((v) => v.active);

  // No prior per-variant rows to carry data over from (e.g. going straight
  // from a single-SKU listing to having variations) — every value is blank.
  if (!activeExisting.length) {
    const blanks = values.map((val) => blankVariant(productId, nextSkuIndex++, { [optionName]: val }));
    return [...existingVariants, ...blanks];
  }

  const result = [];
  for (const v of existingVariants) {
    if (!v.active) { result.push(v); continue; }
    result.push({ ...v, optionValues: { ...v.optionValues, [optionName]: firstValue } });
    for (const val of restValues) {
      result.push(blankVariant(productId, nextSkuIndex++, { ...v.optionValues, [optionName]: val }));
    }
  }
  return result;
}

// A photo with no variantTags is shared across every variant.
export function sharedPhotos(imageAssets) {
  return imageAssets.filter((img) => !(img.variantTags?.length));
}

// A photo belongs to a variant when every one of its tags matches that
// variant's optionValues — a single tag like { optionName: "Style", value: "A" }
// matches every combo where Style=A, regardless of other dimensions.
export function variantPhotos(variant, imageAssets) {
  return imageAssets.filter(
    (img) =>
      img.variantTags?.length > 0 &&
      img.variantTags.every((tag) => variant.optionValues[tag.optionName] === tag.value)
  );
}

// ── Mercari per-variant listing template ────────────────────────────────────
// Mercari has no variant concept — each active variant becomes its own,
// independently posted listing. The "master template" (mercariTitleTokens /
// mercariPhotoTemplate, stored once on the product) describes how to build
// each variant's title and photo carousel; resolving it per variant is what
// actually gets sent to the extension.

// Defaults when a product hasn't set up a template yet — one title token per
// option dimension (in their existing order) followed by the base title, and
// every shared photo in its current order with one variation-photo slot
// appended at the end. Lets the feature work immediately without forcing the
// user through setup first; dragging/deleting in the UI is what persists a
// real choice to Firestore.
export function defaultMercariTitleTokens(options) {
  return [...options.map((opt) => ({ type: "option", optionName: opt.name })), { type: "baseTitle" }];
}

export function defaultMercariPhotoTemplate(imageAssets) {
  return [...sharedPhotos(imageAssets).map((a) => ({ type: "shared", url: a.url })), { type: "variationSlot" }];
}

// Free text lives in `gaps` — one slot before/between/after each draggable
// chip (tokens.length + 1 of them) — kept separate from the chip order so
// only option/baseTitle chips are draggable, matching the plain "type
// directly into the row" UX. Always re-padded/truncated to the current chip
// count so a stale gaps array (from before a chip was added/removed) can't
// desync — the extra slot just reads as "".
export function normalizeMercariTitleGaps(gaps, tokensLength) {
  const g = Array.isArray(gaps) ? [...gaps] : [];
  while (g.length < tokensLength + 1) g.push("");
  return g.slice(0, tokensLength + 1);
}

export function resolveMercariTitle(tokens, gaps, product, variant) {
  const normalizedGaps = normalizeMercariTitleGaps(gaps, tokens.length);
  const parts = [];
  tokens.forEach((t, i) => {
    if (normalizedGaps[i]) parts.push(normalizedGaps[i]);
    const chipValue = t.type === "baseTitle" ? product.title : variant.optionValues?.[t.optionName];
    if (chipValue) parts.push(chipValue);
  });
  if (normalizedGaps[tokens.length]) parts.push(normalizedGaps[tokens.length]);
  return parts.join(" ").slice(0, 80); // Mercari's title cap, matching eBay's existing 80-char truncation
}

export function resolveMercariPhotos(photoTemplate, variant, imageAssets) {
  const own = variantPhotos(variant, imageAssets).map((a) => a.url);
  const resolved = photoTemplate.flatMap((entry) => (entry.type === "variationSlot" ? own : [entry.url]));
  const removed = new Set(variant.mercariPhotoRemovedUrls ?? []);
  return resolved.filter((url) => !removed.has(url));
}

// Shared drag/resize-box mechanics used by CropEditor and IdentifyEditor.
function canvasPos(canvasEl, e) {
  const rect = canvasEl.getBoundingClientRect();
  const scaleX = canvasEl.width / rect.width;
  const scaleY = canvasEl.height / rect.height;
  return { px: (e.clientX - rect.left) * scaleX, py: (e.clientY - rect.top) * scaleY };
}

// Hit-test corner handles / body of a single rect { x, y, w, h } in canvas px.
function hitTestHandle(rect, px, py, hs = 14) {
  if (!rect) return null;
  const { x, y, w, h } = rect;
  const corners = { tl: [x, y], tr: [x + w, y], bl: [x, y + h], br: [x + w, y + h] };
  for (const [name, [cx, cy]] of Object.entries(corners)) {
    if (Math.abs(px - cx) < hs && Math.abs(py - cy) < hs) return name;
  }
  if (px > x && px < x + w && py > y && py < y + h) return "move";
  return null;
}

// Apply a drag delta to an initial rect based on which handle is being dragged.
function applyHandleDelta(initRect, handle, dx, dy) {
  if (handle === "move") return { ...initRect, x: initRect.x + dx, y: initRect.y + dy };
  const next = { ...initRect };
  if (handle.includes("r")) next.w = initRect.w + dx;
  if (handle.includes("l")) { next.x = initRect.x + dx; next.w = initRect.w - dx; }
  if (handle.includes("b")) next.h = initRect.h + dy;
  if (handle.includes("t")) { next.y = initRect.y + dy; next.h = initRect.h - dy; }
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

function CropEditor({ image, productId, onSave, onCancel, saving, onBusyChange }) {
  const canvasRef = useRef(null);
  const [sel, setSel] = useState(null);       // { x, y, w, h } in canvas px
  const [dragging, setDragging] = useState(null); // { startX, startY, initSel, handle }
  const [naturalSize, setNaturalSize] = useState(null);
  const [status, setStatus] = useState("");
  const [uploading, setUploading] = useState(false);

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
    setStatus("");
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => {
      canvas._img = img;
      setNaturalSize({ w: img.naturalWidth, h: img.naturalHeight });
      // Default selection = full image minus 10%
      const pad = Math.floor(Math.min(canvas.width, canvas.height) * 0.05);
      setSel({ x: pad, y: pad, w: canvas.width - pad * 2, h: canvas.height - pad * 2 });
    };
    // A blocked cross-origin load (e.g. missing CORS on the image host)
    // never fires onload — without this the canvas just stays blank forever
    // with no indication anything went wrong.
    img.onerror = () => setStatus("Could not load this image for cropping — it may be blocked by the image host's CORS policy.");
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

  function onMouseDown(e) {
    const { px, py } = canvasPos(canvasRef.current, e);
    const handle = hitTestHandle(sel, px, py) ?? "new";
    setDragging({ startX: px, startY: py, initSel: sel ? { ...sel } : null, handle });
  }

  function onMouseMove(e) {
    if (!dragging) return;
    const canvas = canvasRef.current;
    const { px, py } = canvasPos(canvas, e);
    const dx = px - dragging.startX;
    const dy = py - dragging.startY;

    let next;
    if (dragging.handle === "new") {
      const x = Math.min(dragging.startX, px);
      const y = Math.min(dragging.startY, py);
      const w = Math.abs(px - dragging.startX);
      const h = Math.abs(py - dragging.startY);
      next = { x, y, w, h };
    } else {
      next = applyHandleDelta(dragging.initSel, dragging.handle, dx, dy);
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

    const uid = auth.currentUser?.uid;
    if (!uid) {
      setStatus("You're signed out — please refresh and try again.");
      return;
    }

    setStatus("Uploading…");
    setUploading(true);
    onBusyChange?.(true);
    try {
      const blob = await new Promise((res) => offscreen.toBlob(res, "image/jpeg", 0.92));
      const url = await uploadImageBlob(uid, productId, blob, "-crop");
      await onSave({ url, width: srcW, height: srcH, kind: "crop" });
    } catch (err) {
      setStatus(err.message ?? "Upload failed.");
    } finally {
      setUploading(false);
      onBusyChange?.(false);
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
        <button className="btn btn-primary" onClick={applyCrop} disabled={saving || uploading || !sel}>
          Apply crop
        </button>
        <button className="btn btn-ghost" onClick={onCancel} disabled={uploading}>Cancel</button>
      </div>
    </div>
  );
}

// ─── IdentifyEditor ───────────────────────────────────────────────────────────

const BOX_COLORS = ["#2dd4bf", "#fbbf24", "#f472b6", "#60a5fa", "#a78bfa", "#34d399"];

function IdentifyEditor({ image, productId, onSave, onCancel, saving, onBusyChange }) {
  const canvasRef = useRef(null);
  const [boxes, setBoxes] = useState(null);   // null = loading, [] = none found
  const [loadError, setLoadError] = useState("");
  const [naturalSize, setNaturalSize] = useState(null);
  const [dragging, setDragging] = useState(null); // { boxId, handle, startX, startY, initBox }
  const [status, setStatus] = useState("");
  const [uploading, setUploading] = useState(false);

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
    // A blocked cross-origin load (e.g. missing CORS on the image host) never
    // fires onload — without this the canvas overlay just stays blank forever.
    img.onerror = () => setLoadError("Could not load this image for editing — it may be blocked by the image host's CORS policy.");
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

  function getBoxHandle(px, py, cw, ch) {
    for (let i = (boxes?.length ?? 0) - 1; i >= 0; i--) {
      const rect = boxToPx(boxes[i].box, cw, ch);
      const handle = hitTestHandle(rect, px, py);
      if (handle) return { id: boxes[i].id, handle };
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
    const { px, py } = canvasPos(canvas, e);
    const hit = getBoxHandle(px, py, canvas.width, canvas.height);
    if (!hit) return;
    const box = boxes.find((b) => b.id === hit.id);
    const initRect = boxToPx(box.box, canvas.width, canvas.height);
    setDragging({ boxId: hit.id, handle: hit.handle, startX: px, startY: py, initRect });
  }

  function onMouseMove(e) {
    if (!dragging) return;
    const canvas = canvasRef.current;
    const { px, py } = canvasPos(canvas, e);
    const dx = px - dragging.startX;
    const dy = py - dragging.startY;
    const next = applyHandleDelta(dragging.initRect, dragging.handle, dx, dy);

    const cw = canvas.width, ch = canvas.height;
    const nx = Math.max(0, Math.min(next.x, cw - 10));
    const ny = Math.max(0, Math.min(next.y, ch - 10));
    const nw = Math.max(10, Math.min(next.w, cw - nx));
    const nh = Math.max(10, Math.min(next.h, ch - ny));

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
    const uid = auth.currentUser?.uid;
    if (!uid) {
      setStatus("You're signed out — please refresh and try again.");
      return;
    }

    setStatus("Cropping and uploading…");
    setUploading(true);
    onBusyChange?.(true);
    const results = [];

    try {
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
    } finally {
      setUploading(false);
      onBusyChange?.(false);
    }
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
          <button className="btn btn-primary" onClick={confirmBoxes} disabled={saving || uploading || !boxes.length}>
            {saving ? "Saving…" : `Confirm & crop ${boxes.length} image${boxes.length === 1 ? "" : "s"}`}
          </button>
        )}
        <button className="btn btn-ghost" onClick={onCancel} disabled={uploading}>Cancel</button>
      </div>
    </div>
  );
}

// ─── SplitEditor ──────────────────────────────────────────────────────────────
// Click the image to add a cut line. Drag lines to reposition. × to remove.
// On confirm, slices the full-resolution image client-side at each line.

function SplitEditor({ image, productId, onSave, onCancel, saving }) {
  const [splitMethod, setSplitMethod] = useState("custom"); // "custom" | "grid" | "horizontal"
  const [gridRows, setGridRows] = useState(3);
  const [gridCols, setGridCols] = useState(3);
  const [boxes, setBoxes] = useState([]);
  const [horizontalCutPcts, setHorizontalCutPcts] = useState([]);
  const [selectedLineIndex, setSelectedLineIndex] = useState(null);
  const [evenSliceCount, setEvenSliceCount] = useState(2);
  const [selectedBoxId, setSelectedBoxId] = useState(null);
  const [drawingBox, setDrawingBox] = useState(null);
  const [dragState, setDragState] = useState(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [error, setError] = useState("");

  const canvasRef = useRef(null);
  const imgRef = useRef(null);

  // Keyboard shortcut listener to delete active box or cut line
  useEffect(() => {
    function handleKeyDown(e) {
      if (
        (e.key === "Delete" || e.key === "Backspace") &&
        !["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName)
      ) {
        if (splitMethod === "horizontal" && selectedLineIndex !== null) {
          setHorizontalCutPcts((prev) => prev.filter((_, idx) => idx !== selectedLineIndex));
          setSelectedLineIndex(null);
        } else if (selectedBoxId) {
          setBoxes((prev) => prev.filter((b) => b.id !== selectedBoxId));
          setSelectedBoxId(null);
        }
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [selectedBoxId, selectedLineIndex, splitMethod]);

  function generateGridBoxes(r, c) {
    const rows = Math.max(1, parseInt(r, 10) || 1);
    const cols = Math.max(1, parseInt(c, 10) || 1);
    const newBoxes = [];
    const cellW = Math.floor(1000 / cols);
    const cellH = Math.floor(1000 / rows);

    let count = 1;
    for (let i = 0; i < rows; i++) {
      for (let j = 0; j < cols; j++) {
        const ymin = i * cellH;
        const xmin = j * cellW;
        const ymax = i === rows - 1 ? 1000 : (i + 1) * cellH;
        const xmax = j === cols - 1 ? 1000 : (j + 1) * cellW;
        newBoxes.push({
          id: `box-${i}-${j}-${Date.now()}`,
          label: `Item #${count++}`,
          box: [ymin, xmin, ymax, xmax],
        });
      }
    }
    setBoxes(newBoxes);
    setSelectedBoxId(null);
  }

  async function runAiDetection() {
    setAiLoading(true);
    setError("");
    try {
      const res = await callFunction("identifyProductsInImage")({
        productId,
        imageUrl: image.url,
      });
      const detected = res.data?.objects ?? [];
      if (!detected.length) {
        setError("AI could not identify items in this image. Try grid split instead.");
        return;
      }
      setBoxes(detected);
      setSelectedBoxId(detected[0]?.id ?? null);
    } catch (e) {
      setError(e.message ?? "AI detection failed.");
    } finally {
      setAiLoading(false);
    }
  }

  function addBox() {
    const id = `box-${Date.now()}`;
    const newBox = {
      id,
      label: `Item #${boxes.length + 1}`,
      box: [250, 250, 750, 750],
    };
    setBoxes((prev) => [...prev, newBox]);
    setSelectedBoxId(id);
  }

  function addCutLine() {
    setHorizontalCutPcts((prev) => [...prev, 50].sort((a, b) => a - b));
  }

  // Draw Canvas content with CORS Fallback
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");

    let img = new Image();

    function renderCanvas() {
      if (!img.naturalWidth || !img.naturalHeight) return;
      canvas.width = img.naturalWidth || 800;
      canvas.height = img.naturalHeight || 600;
      imgRef.current = img;

      const w = canvas.width;
      const h = canvas.height;

      ctx.clearRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);

      if (splitMethod === "horizontal") {
        const sortedPcts = [0, ...horizontalCutPcts.slice().sort((a, b) => a - b), 100];
        for (let i = 0; i < sortedPcts.length - 1; i++) {
          const topY = (sortedPcts[i] / 100) * h;
          const botY = (sortedPcts[i + 1] / 100) * h;
          ctx.fillStyle = i % 2 === 0 ? "rgba(99, 102, 241, 0.08)" : "rgba(16, 185, 129, 0.08)";
          ctx.fillRect(0, topY, w, botY - topY);
          ctx.fillStyle = "#ffffff";
          ctx.font = "bold 12px sans-serif";
          ctx.fillText(`Slice #${i + 1}`, 12, topY + (botY - topY) / 2 + 4);
        }

        horizontalCutPcts.forEach((pct, idx) => {
          const y = (pct / 100) * h;
          const isSelected = idx === selectedLineIndex;

          ctx.strokeStyle = isSelected ? "#3b82f6" : "#ef4444";
          ctx.lineWidth = isSelected ? 3 : 2;
          ctx.setLineDash(isSelected ? [] : [6, 4]);
          ctx.beginPath();
          ctx.moveTo(0, y);
          ctx.lineTo(w, y);
          ctx.stroke();
          ctx.setLineDash([]);

          ctx.fillStyle = isSelected ? "#3b82f6" : "#ef4444";
          ctx.fillRect(w / 2 - 40, y - 10, 80, 20);
          ctx.fillStyle = "#ffffff";
          ctx.font = "bold 11px sans-serif";
          ctx.textAlign = "center";
          ctx.fillText(`✂ Cut #${idx + 1} (${pct.toFixed(0)}%)`, w / 2, y + 4);

          ctx.fillStyle = "#ef4444";
          ctx.fillRect(w - 24, y - 10, 24, 20);
          ctx.fillStyle = "#ffffff";
          ctx.font = "bold 12px sans-serif";
          ctx.fillText("✕", w - 12, y + 4);
          ctx.textAlign = "left";
        });
      } else {
        boxes.forEach((item) => {
          const [ymin, xmin, ymax, xmax] = item.box;
          const boxX = (xmin / 1000) * w;
          const boxY = (ymin / 1000) * h;
          const boxW = ((xmax - xmin) / 1000) * w;
          const boxH = ((ymax - ymin) / 1000) * h;
          const isSelected = item.id === selectedBoxId;

          ctx.fillStyle = isSelected ? "rgba(99, 102, 241, 0.25)" : "rgba(59, 130, 246, 0.12)";
          ctx.fillRect(boxX, boxY, boxW, boxH);
          ctx.strokeStyle = isSelected ? "#4f46e5" : "#3b82f6";
          ctx.lineWidth = isSelected ? 3 : 2;
          ctx.setLineDash(isSelected ? [] : [4, 4]);
          ctx.strokeRect(boxX, boxY, boxW, boxH);
          ctx.setLineDash([]);

          ctx.fillStyle = isSelected ? "#4f46e5" : "#3b82f6";
          ctx.fillRect(boxX, boxY, Math.min(100, boxW), 20);
          ctx.fillStyle = "#ffffff";
          ctx.font = "bold 11px sans-serif";
          ctx.fillText(item.label.slice(0, 14), boxX + 6, boxY + 14);

          if (isSelected) {
            const handles = [
              [boxX, boxY],
              [boxX + boxW, boxY],
              [boxX, boxY + boxH],
              [boxX + boxW, boxY + boxH],
            ];
            handles.forEach(([hx, hy]) => {
              ctx.fillStyle = "#ffffff";
              ctx.strokeStyle = "#4f46e5";
              ctx.lineWidth = 2;
              ctx.beginPath();
              ctx.arc(hx, hy, 5, 0, Math.PI * 2);
              ctx.fill();
              ctx.stroke();
            });

            ctx.fillStyle = "#ef4444";
            ctx.fillRect(boxX + boxW - 20, boxY, 20, 20);
            ctx.fillStyle = "#ffffff";
            ctx.font = "bold 12px sans-serif";
            ctx.textAlign = "center";
            ctx.fillText("✕", boxX + boxW - 10, boxY + 14);
            ctx.textAlign = "left";
          }
        });

        if (drawingBox) {
          const drawX = Math.min(drawingBox.startX, drawingBox.currentX);
          const drawY = Math.min(drawingBox.startY, drawingBox.currentY);
          const drawW = Math.abs(drawingBox.currentX - drawingBox.startX);
          const drawH = Math.abs(drawingBox.currentY - drawingBox.startY);
          ctx.fillStyle = "rgba(16, 185, 129, 0.2)";
          ctx.fillRect(drawX, drawY, drawW, drawH);
          ctx.strokeStyle = "#10b981";
          ctx.lineWidth = 2;
          ctx.setLineDash([4, 4]);
          ctx.strokeRect(drawX, drawY, drawW, drawH);
          ctx.setLineDash([]);
        }
      }
    }

    img.onload = renderCanvas;
    img.onerror = () => {
      if (img.crossOrigin) {
        // Retry loading without crossOrigin attribute if blocked by host CORS policy
        const fallbackImg = new Image();
        fallbackImg.onload = () => {
          img = fallbackImg;
          renderCanvas();
        };
        fallbackImg.src = image.url;
      }
    };

    img.crossOrigin = "anonymous";
    img.src = image.url;
  }, [image.url, boxes, horizontalCutPcts, splitMethod, selectedBoxId, drawingBox]);

  function getCanvasCoords(e) {
    const canvas = canvasRef.current;
    if (!canvas) return { x: 0, y: 0 };
    const rect = canvas.getBoundingClientRect();
    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    return {
      x: (e.clientX - rect.left) * scaleX,
      y: (e.clientY - rect.top) * scaleY,
    };
  }

  function testBoxHit(b, x, y, w, h, isSelected) {
    const [ymin, xmin, ymax, xmax] = b.box;
    const boxX = (xmin / 1000) * w;
    const boxY = (ymin / 1000) * h;
    const boxW = ((xmax - xmin) / 1000) * w;
    const boxH = ((ymax - ymin) / 1000) * h;

    if (isSelected && x >= boxX + boxW - 24 && x <= boxX + boxW + 4 && y >= boxY - 4 && y <= boxY + 24) {
      return { type: "delete", boxId: b.id };
    }

    const hs = isSelected ? 16 : 12;
    const corners = {
      tl: [boxX, boxY],
      tr: [boxX + boxW, boxY],
      bl: [boxX, boxY + boxH],
      br: [boxX + boxW, boxY + boxH],
    };

    for (const [name, [cx, cy]] of Object.entries(corners)) {
      if (Math.abs(x - cx) <= hs && Math.abs(y - cy) <= hs) {
        return { type: "handle", handle: name, boxId: b.id, box: [...b.box] };
      }
    }

    if (x >= boxX && x <= boxX + boxW && y >= boxY && y <= boxY + boxH) {
      return { type: "body", handle: "move", boxId: b.id, box: [...b.box] };
    }

    return null;
  }

  function handleCanvasMouseDown(e) {
    const { x, y } = getCanvasCoords(e);
    const canvas = canvasRef.current;
    if (!canvas) return;
    const w = canvas.width;
    const h = canvas.height;

    if (splitMethod === "horizontal") {
      for (let i = 0; i < horizontalCutPcts.length; i++) {
        const lineY = (horizontalCutPcts[i] / 100) * h;
        if (Math.abs(y - lineY) <= 14) {
          if (x >= w - 30) {
            setHorizontalCutPcts((prev) => prev.filter((_, idx) => idx !== i));
            setSelectedLineIndex(null);
            return;
          }
          setSelectedLineIndex(i);
          setDragState({ type: "line", lineIndex: i });
          return;
        }
      }
      const newPct = Math.max(1, Math.min(99, (y / h) * 100));
      let newIdx = 0;
      setHorizontalCutPcts((prev) => {
        const next = [...prev, newPct].sort((a, b) => a - b);
        newIdx = next.indexOf(newPct);
        return next;
      });
      setSelectedLineIndex(newIdx);
      setDragState({ type: "line", lineIndex: newIdx });
      return;
    }

    const activeBox = selectedBoxId ? boxes.find((b) => b.id === selectedBoxId) : null;
    if (activeBox) {
      const activeHit = testBoxHit(activeBox, x, y, w, h, true);
      if (activeHit) {
        if (activeHit.type === "delete") {
          setBoxes((prev) => prev.filter((b) => b.id !== activeHit.boxId));
          setSelectedBoxId(null);
          return;
        }
        setDragState({
          boxId: activeHit.boxId,
          handle: activeHit.handle,
          startX: x,
          startY: y,
          startBox: activeHit.box,
        });
        return;
      }
    }

    for (let i = boxes.length - 1; i >= 0; i--) {
      const b = boxes[i];
      if (b.id === selectedBoxId) continue;
      const hit = testBoxHit(b, x, y, w, h, false);
      if (hit) {
        setSelectedBoxId(b.id);
        setDragState({
          boxId: hit.boxId,
          handle: hit.handle,
          startX: x,
          startY: y,
          startBox: hit.box,
        });
        return;
      }
    }

    setSelectedBoxId(null);
    setDrawingBox({ startX: x, startY: y, currentX: x, currentY: y });
  }

  function handleCanvasMouseMove(e) {
    if (!canvasRef.current) return;
    const { x, y } = getCanvasCoords(e);
    const canvas = canvasRef.current;
    const w = canvas.width;
    const h = canvas.height;

    if (dragState?.type === "line") {
      const newPct = Math.max(1, Math.min(99, (y / h) * 100));
      setHorizontalCutPcts((prev) => {
        const next = [...prev];
        next[dragState.lineIndex] = newPct;
        return next;
      });
      return;
    }

    if (drawingBox) {
      setDrawingBox((prev) => ({ ...prev, currentX: x, currentY: y }));
      return;
    }

    if (!dragState) return;

    const dx = x - dragState.startX;
    const dy = y - dragState.startY;

    const [startYmin, startXmin, startYmax, startXmax] = dragState.startBox;

    const pxXmin = (startXmin / 1000) * w;
    const pxXmax = (startXmax / 1000) * w;
    const pxYmin = (startYmin / 1000) * h;
    const pxYmax = (startYmax / 1000) * h;

    let nXmin = pxXmin;
    let nXmax = pxXmax;
    let nYmin = pxYmin;
    let nYmax = pxYmax;

    if (dragState.handle === "move") {
      nXmin = pxXmin + dx;
      nXmax = pxXmax + dx;
      nYmin = pxYmin + dy;
      nYmax = pxYmax + dy;
    } else {
      if (dragState.handle.includes("l")) nXmin = pxXmin + dx;
      if (dragState.handle.includes("r")) nXmax = pxXmax + dx;
      if (dragState.handle.includes("t")) nYmin = pxYmin + dy;
      if (dragState.handle.includes("b")) nYmax = pxYmax + dy;
    }

    const nxMin = Math.max(0, Math.min(1000, (nXmin / w) * 1000));
    const nxMax = Math.max(0, Math.min(1000, (nXmax / w) * 1000));
    const nyMin = Math.max(0, Math.min(1000, (nYmin / h) * 1000));
    const nyMax = Math.max(0, Math.min(1000, (nYmax / h) * 1000));

    setBoxes((prev) =>
      prev.map((b) =>
        b.id === dragState.boxId
          ? { ...b, box: [Math.round(nyMin), Math.round(nxMin), Math.round(nyMax), Math.round(nxMax)] }
          : b
      )
    );
  }

  function handleCanvasMouseUp() {
    if (dragState?.type === "line") {
      setHorizontalCutPcts((prev) => [...prev].sort((a, b) => a - b));
      setDragState(null);
      return;
    }
    if (drawingBox && canvasRef.current) {
      const canvas = canvasRef.current;
      const w = canvas.width;
      const h = canvas.height;

      const pxX1 = Math.min(drawingBox.startX, drawingBox.currentX);
      const pxX2 = Math.max(drawingBox.startX, drawingBox.currentX);
      const pxY1 = Math.min(drawingBox.startY, drawingBox.currentY);
      const pxY2 = Math.max(drawingBox.startY, drawingBox.currentY);

      if (pxX2 - pxX1 > 12 && pxY2 - pxY1 > 12) {
        const xmin = Math.round((pxX1 / w) * 1000);
        const xmax = Math.round((pxX2 / w) * 1000);
        const ymin = Math.round((pxY1 / h) * 1000);
        const ymax = Math.round((pxY2 / h) * 1000);

        const newId = `box-${Date.now()}`;
        const newBox = {
          id: newId,
          label: `Item #${boxes.length + 1}`,
          box: [ymin, xmin, ymax, xmax],
        };
        setBoxes((prev) => [...prev, newBox]);
        setSelectedBoxId(newId);
      }
      setDrawingBox(null);
    }
    setDragState(null);
  }

  function confirmSplit() {
    onSave({
      splitMethod,
      lines: horizontalCutPcts,
      boxes,
      imgElement: imgRef.current,
      imageUrl: image.url,
    });
  }

  const sliceCount = splitMethod === "horizontal" ? horizontalCutPcts.length + 1 : boxes.length;

  return (
    <div className="img-editor-body" style={{ width: "100%", maxWidth: 850 }}>
      {/* Method tabs and controls */}
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", marginBottom: 12 }}>
        <div style={{ display: "flex", gap: 6 }}>
          <button
            className={`btn ${splitMethod === "custom" ? "btn-primary" : "btn-ghost"}`}
            style={{ fontSize: 12, padding: "4px 10px" }}
            onClick={() => setSplitMethod("custom")}
          >
            📦 Custom Boxes
          </button>
          <button
            className={`btn ${splitMethod === "grid" ? "btn-primary" : "btn-ghost"}`}
            style={{ fontSize: 12, padding: "4px 10px" }}
            onClick={() => {
              setSplitMethod("grid");
              generateGridBoxes(gridRows, gridCols);
            }}
          >
            田 Uniform Grid
          </button>
          <button
            className={`btn ${splitMethod === "horizontal" ? "btn-primary" : "btn-ghost"}`}
            style={{ fontSize: 12, padding: "4px 10px" }}
            onClick={() => setSplitMethod("horizontal")}
          >
            ✂ Horizontal Slice
          </button>
        </div>

        {splitMethod !== "horizontal" && (
          <div style={{ display: "flex", gap: 6 }}>
            <button className="btn btn-ghost" style={{ fontSize: 11, padding: "3px 8px" }} onClick={addBox}>
              + Add Box
            </button>
            {boxes.length > 0 && (
              <button
                className="btn btn-ghost"
                style={{ fontSize: 11, padding: "3px 8px", color: "var(--danger)" }}
                onClick={() => { setBoxes([]); setSelectedBoxId(null); }}
              >
                Clear All
              </button>
            )}
          </div>
        )}

        {splitMethod === "grid" && (
          <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12 }}>
            <span>Grid:</span>
            <input
              type="number"
              min="1"
              max="10"
              value={gridRows}
              style={{ width: 40, padding: 4 }}
              className="input"
              onChange={(e) => {
                const r = e.target.value;
                setGridRows(r);
                generateGridBoxes(r, gridCols);
              }}
            />
            <span>rows ×</span>
            <input
              type="number"
              min="1"
              max="10"
              value={gridCols}
              style={{ width: 40, padding: 4 }}
              className="input"
              onChange={(e) => {
                const c = e.target.value;
                setGridCols(c);
                generateGridBoxes(gridRows, c);
              }}
            />
            <span>cols</span>
          </div>
        )}

        {splitMethod === "horizontal" && (() => {
          const hasCuts = horizontalCutPcts.length > 0;
          const idealPcts = hasCuts
            ? Array.from(
                { length: horizontalCutPcts.length },
                (_, i) => ((i + 1) / (horizontalCutPcts.length + 1)) * 100
              )
            : [];
          const isOffCenter = hasCuts && horizontalCutPcts.some((pct, i) => Math.abs(pct - idealPcts[i]) > 0.5);
          return (
            <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12 }}>
              <span>Split into:</span>
              <input
                type="number"
                min="2"
                max="20"
                placeholder="Custom"
                value={hasCuts ? horizontalCutPcts.length + 1 : ""}
                style={{ width: 58, padding: 4 }}
                className="input"
                onChange={(e) => {
                  const val = e.target.value;
                  if (!val || parseInt(val, 10) < 2) {
                    setHorizontalCutPcts([]);
                    return;
                  }
                  const n = Math.max(2, Math.min(20, parseInt(val, 10) || 2));
                  const newPcts = Array.from({ length: n - 1 }, (_, i) => ((i + 1) / n) * 100);
                  setHorizontalCutPcts(newPcts);
                }}
              />
              <span>slices</span>
              {isOffCenter && (
                <button
                  className="btn btn-ghost"
                  style={{ fontSize: 12, padding: "4px 8px", color: "var(--primary)", borderColor: "var(--primary)" }}
                  onClick={() => setHorizontalCutPcts(idealPcts)}
                  title="Re-space cut lines back into equal slices"
                >
                  ⚡ Evenly slice
                </button>
              )}
              {hasCuts && (
                <button
                  className="btn btn-ghost"
                  style={{ fontSize: 12, padding: "4px 8px", color: "var(--danger)" }}
                  onClick={() => {
                    setHorizontalCutPcts([]);
                    setSelectedLineIndex(null);
                  }}
                >
                  Clear Lines
                </button>
              )}
            </div>
          );
        })()}

        <div style={{ marginLeft: "auto" }}>
          <button
            className="btn btn-ghost"
            style={{ fontSize: 12, padding: "4px 10px", borderColor: "var(--primary)", color: "var(--primary)" }}
            onClick={runAiDetection}
            disabled={aiLoading}
          >
            {aiLoading ? "⚡ AI Detecting…" : "⚡ AI Auto-Detect Items"}
          </button>
        </div>
      </div>

      {error && <div style={{ color: "var(--danger)", fontSize: 12, marginBottom: 8 }}>{error}</div>}

      {/* Canvas container */}
      <div style={{ textAlign: "center", position: "relative", marginBottom: 12 }}>
        <div style={{ display: "inline-block", position: "relative", border: "1px solid var(--border)", maxWidth: "100%", overflow: "hidden" }}>
          <canvas
            ref={canvasRef}
            onMouseDown={handleCanvasMouseDown}
            onMouseMove={handleCanvasMouseMove}
            onMouseUp={handleCanvasMouseUp}
            style={{ cursor: dragState ? "grabbing" : "crosshair", display: "block", maxWidth: "100%", height: "auto" }}
          />
        </div>
        <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 6 }}>
          {splitMethod === "custom"
            ? "Click & drag anywhere on the photo to draw a custom box, or click a box to resize/delete."
            : splitMethod === "grid"
            ? "Boxes start aligned in a grid but can be independently dragged, resized, or deleted."
            : "Horizontal cut lines slice long images vertically into separate images."}
        </div>
      </div>

      <div className="img-edit-popover-actions">
        {sliceCount > 0 ? (
          <button className="btn btn-primary" onClick={confirmSplit} disabled={saving}>
            {saving ? "Splitting…" : `✂ Split into ${sliceCount} images`}
          </button>
        ) : (
          <span className="img-editor-hint">Add at least one item box to split.</span>
        )}
        <button className="btn btn-ghost" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ─── ImageStrip ───────────────────────────────────────────────────────────────

function ImageStrip({ images, activeIndex, onHover, onDrop, onEdit, savingMedia, onAddPhotos }) {
  const [dragIndex, setDragIndex] = useState(null);
  const [dropTarget, setDropTarget] = useState(null);
  const [limitInfoOpen, setLimitInfoOpen] = useState(false);

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

  // Platforms this photo's position exceeds the cap for (still stored, just
  // never sent to that platform's listing payload) — sorted so a photo past
  // eBay's higher cap also shows as past TikTok's lower one.
  function overLimitPlatforms(index) {
    return Object.entries(PLATFORM_IMAGE_LIMITS)
      .filter(([, limit]) => index >= limit)
      .sort(([, a], [, b]) => a - b)
      .map(([name]) => name);
  }

  const tightestLimit = Math.min(...Object.values(PLATFORM_IMAGE_LIMITS));
  const overLimitCount = images.length - tightestLimit;

  return (
    <div>
      <div className="img-strip">
        {images.map((image, index) => {
          const isActive = index === activeIndex;
          const isDragging = index === dragIndex;
          const isDropTarget = index === dropTarget;
          const tagLabels = (image.variantTags ?? []).map((t) => `${t.optionName}: ${t.value}`);
          const overLimit = overLimitPlatforms(index);
          return (
            <div
              key={image.id}
              className={`img-thumb${isActive ? " img-thumb-active" : ""}${isDragging ? " img-thumb-dragging" : ""}${isDropTarget ? " img-thumb-drop" : ""}${overLimit.length ? " img-thumb-over-limit" : ""}`}
              title={overLimit.length ? `Photo #${index + 1} is stored but won't be posted to ${overLimit.join(" or ")}.` : undefined}
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
              {tagLabels.length > 0 && (
                <span className="img-thumb-tags" title={tagLabels.join(", ")}>
                  {tagLabels.join(", ")}
                </span>
              )}
              {isActive && <span className="img-thumb-cover-dot" />}
            </div>
          );
        })}

        {/* '+' Add Photo button at end of thumbnail carousel */}
        <label
          className="img-thumb"
          style={{
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            justifyContent: "center",
            border: "2px dashed var(--border)",
            background: "rgba(255, 255, 255, 0.03)",
            cursor: savingMedia ? "not-allowed" : "pointer",
            width: 72,
            height: 72,
            borderRadius: 8,
            flexShrink: 0,
            transition: "all 0.15s ease",
            margin: 0,
          }}
          title="Add photo to listing"
        >
          <input
            type="file"
            accept="image/*"
            multiple
            disabled={savingMedia}
            style={{ display: "none" }}
            onChange={(e) => {
              const files = Array.from(e.target.files ?? []);
              if (files.length > 0 && onAddPhotos) {
                onAddPhotos(files);
              }
              e.target.value = "";
            }}
          />
          <span style={{ fontSize: 24, fontWeight: "bold", color: "var(--primary)", lineHeight: 1 }}>+</span>
          <span style={{ fontSize: 10, color: "var(--muted)", marginTop: 2, fontWeight: 500 }}>Add Photo</span>
        </label>
      </div>
      {overLimitCount > 0 && (
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
          <p className="detail-copy" style={{ fontSize: 12, color: "var(--muted)", margin: 0 }}>
            Extra photos may not be posted.
          </p>
          <button
            className="btn btn-ghost"
            style={{ padding: "2px 8px", fontSize: 12 }}
            onClick={() => setLimitInfoOpen(true)}
          >
            More info
          </button>
        </div>
      )}
      {limitInfoOpen && (
        <div className="modal-overlay" onClick={() => setLimitInfoOpen(false)}>
          <div className="modal" style={{ maxWidth: 360 }} onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <h2>Per-platform photo limits</h2>
              <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={() => setLimitInfoOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              <p className="detail-copy" style={{ fontSize: 12, color: "var(--muted)", marginTop: 0 }}>
                All photos are always stored here. Only the first N (per platform, in the order shown
                above) are included when a listing is posted.
              </p>
              <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
                <tbody>
                  {Object.entries(PLATFORM_IMAGE_LIMITS).map(([platform, limit]) => (
                    <tr key={platform} style={{ borderTop: "1px solid var(--border)" }}>
                      <td style={{ padding: "6px 4px" }}>{platform}</td>
                      <td style={{ padding: "6px 4px", textAlign: "right" }}>{limit}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="modal-footer">
              <button className="btn btn-primary" onClick={() => setLimitInfoOpen(false)}>Done</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── ImageEditModal ────────────────────────────────────────────────────────────
// mode: "menu" | "crop" | "identify" | "split"

function ImageEditModal({ image, index, total, productId, onClose, onDelete, onSetCover, onSaveCrop, onSaveIdentify, onSaveSplit, saving, splitInProgress }) {
  const [mode, setMode] = useState("menu");
  const [busy, setBusy] = useState(false); // true while an editor has an upload in flight
  const ref = useRef(null);

  // Close on outside click in any mode, unless an upload is in flight.
  useEffect(() => {
    if (busy) return;
    function handler(e) {
      if (ref.current && !ref.current.contains(e.target)) onClose();
    }
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [busy, onClose]);

  function header(title) {
    return (
      <div className="img-edit-popover-header">
        {mode !== "menu" && (
          <button className="btn btn-ghost" style={{ padding: "4px 10px", fontSize: 13 }} onClick={() => setMode("menu")} disabled={busy}>
            ← Back
          </button>
        )}
        <span style={{ fontWeight: 600, fontSize: 14 }}>{title}</span>
        <button className="btn btn-ghost" style={{ padding: "4px 10px", fontSize: 13, marginLeft: "auto" }} onClick={onClose} disabled={busy}>✕</button>
      </div>
    );
  }

  return (
    <div className="modal-overlay" onClick={busy ? undefined : onClose}>
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
              <button className="btn btn-ghost" onClick={() => setMode("split")} disabled={saving || splitInProgress}>
                {splitInProgress ? "⚡ Splitting…" : "⚡ Split"}
              </button>
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
              onBusyChange={setBusy}
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
              onBusyChange={setBusy}
              saving={saving}
            />
          </>
        )}

        {mode === "split" && (
          <>
            {header("Split image")}
            <SplitEditor
              image={image}
              productId={productId}
              onSave={onSaveSplit}
              onCancel={() => setMode("menu")}
              onBusyChange={setBusy}
              saving={saving}
            />
          </>
        )}
      </div>
    </div>
  );
}

// ─── VariantsEditor ────────────────────────────────────────────────────────────

const MAX_VARIATION_DIMENSIONS = 2; // matches Etsy's cap; eBay supports more —
// see roadmap-variations-crosspost-sales.md for the >2-dimension follow-up.

// Groups active, matched variant rows by the first option's value — used for
// the primary-level table view (one row per Style, e.g.) and for bulk-editing
// price/qty across every sub-variation under a primary value.
function groupVariantsByPrimary(activeVariants, primaryName) {
  const order = [];
  const groups = new Map();
  for (const v of activeVariants) {
    const key = v.optionValues?.[primaryName] ?? "—";
    if (!groups.has(key)) {
      groups.set(key, []);
      order.push(key);
    }
    groups.get(key).push(v);
  }
  return order.map((key) => ({ key, rows: groups.get(key) }));
}

const SKIP_BULK_EDIT_WARNING_KEY = "wonni_skip_primary_bulk_edit_warning";

// ─── ManageVariationsModal ──────────────────────────────────────────────────
// Etsy-style structure editor: add/edit/delete option dimensions and their
// ordered values. Doesn't touch price/qty/SKU — that's the table below.
function ManageVariationsModal({ options, onChange, onClose, error, initialView }) {
  const isSingleStyle = options.length === 0 || (options.length === 1 && options[0].values.length <= 1);
  const startView = initialView || (isSingleStyle ? "edit" : "list");
  const [view, setView] = useState(startView);

  const [draftId, setDraftId] = useState(() => {
    if (startView === "edit") {
      if (options.length === 1 && options[0].values.length <= 1) {
        return options[0].id;
      }
      return generateVariantId();
    }
    return null;
  });
  const [draftName, setDraftName] = useState(() => {
    if (startView === "edit" && options.length === 1 && options[0].values.length <= 1) {
      return options[0].name || "";
    }
    return "";
  });
  const [originalName, setOriginalName] = useState(() => {
    if (startView === "edit" && options.length === 1 && options[0].values.length <= 1) {
      return options[0].name || null;
    }
    return null;
  });
  // Snapshot of the option's values when editing began, in order — diffed
  // against draftValues at save time to find which ones were removed
  // outright (as opposed to renamed in place).
  const [originalValues, setOriginalValues] = useState(() => {
    if (startView === "edit" && options.length === 1 && options[0].values.length <= 1) {
      return options[0].values || [];
    }
    return [];
  });
  // Each entry is { id, text, original }. `original` is the value's text when
  // editing began (null for freshly-added values) — used at save time to tell
  // "renamed this value" apart from "removed one, added another", so existing
  // variant rows can be relabeled in place instead of orphaned.
  const [draftValues, setDraftValues] = useState(() => {
    if (startView === "edit" && options.length === 1 && options[0].values.length <= 1) {
      return (options[0].values || []).map((v) => ({ id: generateVariantId(), text: v, original: v }));
    }
    return [];
  });
  const [newValueText, setNewValueText] = useState("");
  // Every structural change here writes straight to Firestore via onChange
  // (unlike the price/SKU/qty table, which batches behind its own Save
  // button) — this tracks that in-flight write so buttons can't double-fire.
  const [saving, setSaving] = useState(false);

  function openEdit(option) {
    setDraftId(option.id);
    setDraftName(option.name);
    setOriginalName(option.name);
    setOriginalValues(option.values);
    setDraftValues(option.values.map((v) => ({ id: generateVariantId(), text: v, original: v })));
    setNewValueText("");
    setView("edit");
  }

  function openAdd() {
    setDraftId(generateVariantId());
    setDraftName("");
    setOriginalName(null);
    setOriginalValues([]);
    setDraftValues([]);
    setNewValueText("");
    setView("edit");
  }

  function addDraftValue() {
    const v = newValueText.trim();
    if (!v || draftValues.some((d) => d.text === v)) return;
    setDraftValues((prev) => [...prev, { id: generateVariantId(), text: v, original: null }]);
    setNewValueText("");
  }

  function removeDraftValue(id) {
    setDraftValues((prev) => prev.filter((d) => d.id !== id));
  }

  function editDraftValue(id, text) {
    setDraftValues((prev) => prev.map((d) => (d.id === id ? { ...d, text } : d)));
  }

  async function saveDraft() {
    const name = draftName.trim();
    const values = draftValues.map((d) => d.text.trim());
    if (!name || !values.length || values.some((v) => !v)) return;
    // Typing one value's text to match another's would silently collapse two
    // combos into one and orphan a variant — block it instead of guessing.
    if (new Set(values).size !== values.length) return;
    const exists = options.some((o) => o.id === draftId);
    const nextOptions = exists
      ? options.map((o) => (o.id === draftId ? { ...o, name, values } : o))
      : [...options, { id: draftId, name, values }];
    // Renames: same slot, different text. Additions: freshly-typed values
    // with no `original`. Removals: original values no longer represented by
    // any current draft value (deleted via its Remove button).
    const valueRenames = draftValues
      .filter((d) => d.original !== null && d.original !== d.text.trim())
      .map((d) => [d.original, d.text.trim()]);
    const addedValues = draftValues.filter((d) => d.original === null).map((d) => d.text.trim());
    const removedValues = originalValues.filter((ov) => !draftValues.some((d) => d.original === ov));
    const changeInfo = exists
      ? { optionName: originalName, newOptionName: name, valueRenames, addedValues, removedValues }
      // Brand-new option: every value is "added", in entry order — the first
      // is what carries over onto existing rows (see addNewOptionDimension).
      : { isNewOption: true, newOptionName: name, addedValues: values };
    // Only leave the edit view if the parent actually applied *and persisted*
    // the change — if the user declined a delete confirm, or the Firestore
    // write failed, flipping to the list view here would show stale/unchanged
    // data and look like the edit was silently reverted, even though the
    // draft itself is still intact.
    setSaving(true);
    const applied = await onChange(nextOptions, changeInfo);
    setSaving(false);
    if (applied) {
      if (isSingleStyle) {
        onClose();
      } else {
        setView("list");
      }
    }
  }

  async function deleteOption(id) {
    const opt = options.find((o) => o.id === id);
    setSaving(true);
    await onChange(options.filter((o) => o.id !== id), { removeOption: opt?.name });
    setSaving(false);
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>{view === "edit" ? (options.some((o) => o.id === draftId) ? "Edit variation" : "Add variation") : "Manage variations"}</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose} disabled={saving}>✕</button>
        </div>

        <div className="modal-body">
          {view === "list" ? (
            <>
              {/* A single option with at most one value is no real choice —
                  nothing to distinguish, nothing worth presenting as an
                  editable "variation". Treat it the same as no options at
                  all: just offer to add a real one. Self-resolves the
                  moment a second dimension gets added (options.length
                  stops being 1), or if that lone option ever gains a
                  second value through some other path. */}
              {options.length === 0 || (options.length === 1 && options[0].values.length <= 1) ? (
                <p className="detail-copy" style={{ fontSize: 12, color: "var(--muted)" }}>
                  No variations yet — this is a single-SKU listing.
                </p>
              ) : (
                options.map((opt) => (
                  <div key={opt.id} className="variation-summary-card">
                    <div>
                      <div style={{ fontWeight: 600 }}>{opt.name || "(unnamed)"}</div>
                      <div style={{ fontSize: 12, color: "var(--muted)" }}>
                        {opt.values.length} option{opt.values.length === 1 ? "" : "s"}
                      </div>
                      <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 6 }}>
                        {opt.values.map((v) => (
                          <span key={v} className="chip chip-draft">{v}</span>
                        ))}
                      </div>
                    </div>
                    <div style={{ display: "flex", gap: 6, flexShrink: 0 }}>
                      <button className="btn btn-ghost" title="Edit" onClick={() => openEdit(opt)} disabled={saving}>✏</button>
                      <button className="btn btn-danger" title="Delete" onClick={() => deleteOption(opt.id)} disabled={saving}>🗑</button>
                    </div>
                  </div>
                ))
              )}
              {options.length < MAX_VARIATION_DIMENSIONS && (
                <button className="btn btn-ghost" onClick={openAdd} disabled={saving}>+ Add a variation</button>
              )}
            </>
          ) : (
            <>
              <div className="modal-field">
                <label>Name</label>
                <input
                  className="input"
                  placeholder="e.g. Style"
                  value={draftName}
                  onChange={(e) => setDraftName(e.target.value)}
                  disabled={saving}
                />
              </div>
              <div className="modal-field">
                <label>Options ({draftValues.length})</label>
                <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                  {draftValues.map((d) => (
                    <div
                      key={d.id}
                      style={{
                        display: "flex", alignItems: "center", gap: 8, padding: "4px 8px",
                        border: "1px solid var(--border)", borderRadius: 6,
                      }}
                    >
                      <input
                        className="input"
                        style={{ flex: 1, border: "none", padding: "2px 4px" }}
                        value={d.text}
                        onChange={(e) => editDraftValue(d.id, e.target.value)}
                        disabled={saving}
                      />
                      <button
                        className="btn btn-ghost"
                        style={{ padding: "2px 8px" }}
                        onClick={() => removeDraftValue(d.id)}
                        disabled={saving}
                      >
                        Remove
                      </button>
                    </div>
                  ))}
                </div>
                <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                  <input
                    className="input"
                    placeholder="Enter an option…"
                    value={newValueText}
                    onChange={(e) => setNewValueText(e.target.value)}
                    onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); addDraftValue(); } }}
                    disabled={saving}
                  />
                  <button className="btn btn-ghost" onClick={addDraftValue} disabled={saving}>Add</button>
                </div>
              </div>
            </>
          )}
          {error && (
            <p className="detail-copy" style={{ fontSize: 12, color: "var(--danger, #d33)", marginTop: 8 }}>
              {error}
            </p>
          )}
        </div>

        <div className="modal-footer">
          {view === "edit" ? (
            <>
              <button className="btn btn-ghost" onClick={() => (isSingleStyle ? onClose() : setView("list"))} disabled={saving}>Cancel</button>
              <button
                className="btn btn-primary"
                disabled={saving || !draftName.trim() || !draftValues.length}
                onClick={saveDraft}
              >
                {saving ? "Saving…" : "Done"}
              </button>
            </>
          ) : (
            <button className="btn btn-primary" onClick={onClose} disabled={saving}>
              {saving ? "Saving…" : "Done"}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── SelectPhotoModal ────────────────────────────────────────────────────────
// Multi-select photo picker scoped to one primary-option value — pre-checks
// whichever images already carry that value's tag.
function SelectPhotoModal({ images, optionName, value, onClose, onSave }) {
  const [selected, setSelected] = useState(
    () => new Set(
      images
        .filter((img) => (img.variantTags ?? []).some((t) => t.optionName === optionName && t.value === value))
        .map((img) => img.id)
    )
  );

  function toggle(id) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>Photos for "{value}"</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
        </div>
        <div className="modal-body">
          {images.length === 0 ? (
            <p className="detail-copy">No photos on this listing yet.</p>
          ) : (
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(72px, 1fr))", gap: 8 }}>
              {images.map((img) => {
                const isSelected = selected.has(img.id);
                return (
                  <button
                    key={img.id}
                    type="button"
                    onClick={() => toggle(img.id)}
                    style={{
                      position: "relative", padding: 0, cursor: "pointer", background: "none",
                      border: isSelected ? "2px solid var(--accent, #ff6b35)" : "2px solid transparent",
                      borderRadius: 8, overflow: "hidden",
                    }}
                  >
                    <img src={img.url} alt="" style={{ width: "100%", height: 72, objectFit: "cover", display: "block" }} />
                    {isSelected && (
                      <span
                        style={{
                          position: "absolute", top: 4, right: 4, background: "var(--accent, #ff6b35)",
                          color: "#fff", borderRadius: "50%", width: 18, height: 18, fontSize: 12,
                          display: "flex", alignItems: "center", justifyContent: "center",
                        }}
                      >
                        ✓
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          )}
        </div>
        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={() => onSave([...selected])}>Save</button>
        </div>
      </div>
    </div>
  );
}

// ─── Mercari per-variant listing template ──────────────────────────────────
// Master template for how each active variant's Mercari listing gets built:
// a reorderable/deletable set of title tokens (one per option dimension, plus
// the base title) and a reorderable/deletable photo carousel with one
// "Variation Photos" slot marking where each variant's own photos land.
// Drag mechanics mirror ImageStrip's existing pattern (dragIndex/dropTarget +
// moveItem) rather than a new library.

function MercariVariantTemplate({
  product, options, images, tokens, gaps, photoTemplate, previewVariant,
  onTokensChange, onGapsChange, onPhotoTemplateChange, onSettingsChange,
}) {
  const [dragTokenIndex, setDragTokenIndex] = useState(null);
  const [tokenDropTarget, setTokenDropTarget] = useState(null);
  const [dragTileIndex, setDragTileIndex] = useState(null);
  const [tileDropTarget, setTileDropTarget] = useState(null);
  const [moreOpen, setMoreOpen] = useState(false);

  const normalizedGaps = normalizeMercariTitleGaps(gaps, tokens.length);

  function tokenLabel(token) {
    return token.type === "baseTitle" ? "Base Title" : token.optionName;
  }

  function moveToken(from, to) {
    if (from === to) return;
    onTokensChange(moveItem(tokens, from, to));
  }

  function removeToken(index) {
    onTokensChange(tokens.filter((_, i) => i !== index));
    // Drop the gap that sat right after the removed chip — the one before it
    // (often the more deliberately-placed piece of text) stays put.
    onGapsChange(normalizedGaps.filter((_, i) => i !== index + 1));
  }

  function setGap(index, value) {
    const next = [...normalizedGaps];
    next[index] = value;
    onGapsChange(next);
  }

  const unusedOptionNames = options
    .map((o) => o.name)
    .filter((name) => !tokens.some((t) => t.type === "option" && t.optionName === name));

  function addToken(optionName) {
    const baseIdx = tokens.findIndex((t) => t.type === "baseTitle");
    const nextTokens = [...tokens];
    const insertAt = baseIdx === -1 ? nextTokens.length : baseIdx;
    nextTokens.splice(insertAt, 0, { type: "option", optionName });
    // A new gap slot opens up at the same position for the new chip.
    const nextGaps = [...normalizedGaps];
    nextGaps.splice(insertAt, 0, "");
    onTokensChange(nextTokens);
    onGapsChange(nextGaps);
  }

  function moveTile(from, to) {
    if (from === to) return;
    onPhotoTemplateChange(moveItem(photoTemplate, from, to));
  }

  function removeTile(index) {
    onPhotoTemplateChange(photoTemplate.filter((_, i) => i !== index));
  }

  const preview = previewVariant
    ? resolveMercariTitle(tokens, normalizedGaps, product, previewVariant)
    : null;

  // A tiny auto-sizing text input that sits inline between/around the chips —
  // sized to its own content so typed text reads as part of the row, not a
  // separate boxed field.
  function GapInput({ index }) {
    const value = normalizedGaps[index] ?? "";
    return (
      <input
        value={value}
        onChange={(e) => setGap(index, e.target.value)}
        placeholder="type text…"
        style={{
          border: "none", outline: "none", background: "transparent", fontSize: 12,
          color: "var(--text)", width: `${Math.max(8, value.length + 1)}ch`, padding: "5px 2px",
        }}
      />
    );
  }

  return (
    <div className="card detail-section" style={{ marginBottom: 16 }}>
      <h2 style={{ fontSize: 14, marginBottom: 4 }}>List on Mercari — per-variant template</h2>
      <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 12 }}>
        Drag the chips to reorder, click ✕ to remove. Type directly before,
        between, or after them to add your own text. Each active variant gets
        its own Mercari listing built from this template.
      </div>

      <div style={{ marginBottom: 14 }}>
        <label style={{ fontSize: 12, fontWeight: 600 }}>Listing Titles</label>
        <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 4, marginTop: 6 }}>
          <GapInput index={0} />
          {tokens.map((token, index) => {
            const isOption = token.type === "option";
            return (
              <Fragment key={`${token.type}-${token.optionName ?? "base"}`}>
                <div
                  draggable
                  onDragStart={(e) => { setDragTokenIndex(index); e.dataTransfer.effectAllowed = "move"; }}
                  onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; if (index !== dragTokenIndex) setTokenDropTarget(index); }}
                  onDrop={(e) => { e.preventDefault(); if (dragTokenIndex !== null && dragTokenIndex !== index) moveToken(dragTokenIndex, index); setDragTokenIndex(null); setTokenDropTarget(null); }}
                  onDragEnd={() => { setDragTokenIndex(null); setTokenDropTarget(null); }}
                  style={{
                    display: "flex", alignItems: "center", gap: 6, padding: "5px 10px", borderRadius: 999,
                    fontSize: 12, cursor: "grab", userSelect: "none",
                    background: isOption ? "#ff6b35" : "var(--surface-hover)",
                    color: isOption ? "#fff" : "var(--text)",
                    border: index === tokenDropTarget ? "2px dashed var(--primary)" : "1px solid transparent",
                    opacity: index === dragTokenIndex ? 0.5 : 1,
                  }}
                >
                  <span title="Drag to reorder">⠿</span>
                  <span>{tokenLabel(token)}</span>
                  {isOption && (
                    <button
                      onClick={() => removeToken(index)}
                      style={{ background: "none", border: "none", color: "inherit", cursor: "pointer", padding: 0, fontWeight: 700 }}
                      title="Remove from title"
                    >
                      ✕
                    </button>
                  )}
                </div>
                <GapInput index={index + 1} />
              </Fragment>
            );
          })}
          {unusedOptionNames.map((name) => (
            <button
              key={name}
              className="btn btn-ghost"
              style={{ fontSize: 11, padding: "4px 8px", borderRadius: 999 }}
              onClick={() => addToken(name)}
            >
              + {name}
            </button>
          ))}
        </div>
        {preview && (
          <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 6 }}>Preview: {preview}</div>
        )}
      </div>

      <div style={{ marginBottom: 8 }}>
        <label style={{ fontSize: 12, fontWeight: 600 }}>Listing Photos</label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 6 }}>
          {photoTemplate.map((entry, index) => {
            const isSlot = entry.type === "variationSlot";
            return (
              <div
                key={isSlot ? "variation-slot" : entry.url}
                draggable
                onDragStart={(e) => { setDragTileIndex(index); e.dataTransfer.effectAllowed = "move"; }}
                onDragOver={(e) => { e.preventDefault(); e.dataTransfer.dropEffect = "move"; if (index !== dragTileIndex) setTileDropTarget(index); }}
                onDrop={(e) => { e.preventDefault(); if (dragTileIndex !== null && dragTileIndex !== index) moveTile(dragTileIndex, index); setDragTileIndex(null); setTileDropTarget(null); }}
                onDragEnd={() => { setDragTileIndex(null); setTileDropTarget(null); }}
                style={{
                  position: "relative", width: 72, height: 72, borderRadius: 8, cursor: "grab",
                  display: "flex", alignItems: "center", justifyContent: "center", textAlign: "center",
                  background: isSlot ? "#22c55e" : "#ff6b35", color: "#fff", fontSize: 11, fontWeight: 600,
                  border: index === tileDropTarget ? "2px dashed var(--primary)" : "2px solid transparent",
                  opacity: index === dragTileIndex ? 0.5 : 1, overflow: "hidden",
                }}
              >
                {isSlot ? (
                  <span>Variation<br />Photos</span>
                ) : (
                  <img src={entry.url} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} />
                )}
                {!isSlot && (
                  <button
                    onClick={() => removeTile(index)}
                    style={{ position: "absolute", top: 2, right: 2, background: "rgba(0,0,0,0.6)", color: "#fff", border: "none", borderRadius: "50%", width: 18, height: 18, cursor: "pointer", fontSize: 11, lineHeight: 1 }}
                    title="Remove from template"
                  >
                    ✕
                  </button>
                )}
              </div>
            );
          })}
        </div>
      </div>

      <button className="btn btn-ghost" style={{ fontSize: 12 }} onClick={() => setMoreOpen((v) => !v)}>
        More Options {moreOpen ? "▲" : "▼"}
      </button>
      {moreOpen && (
        <div style={{ display: "flex", gap: 16, alignItems: "center", marginTop: 10, flexWrap: "wrap" }}>
          <div className="modal-field" style={{ maxWidth: 200 }}>
            <label style={{ fontSize: 11 }}>Item Condition</label>
            <select
              className="input"
              value={product.mercariCondition ?? "good"}
              onChange={(e) => onSettingsChange({ mercariCondition: e.target.value })}
            >
              <option value="new">New (Unopened / Brand New)</option>
              <option value="likenew">Like New (Mint / Unused)</option>
              <option value="good">Good (Minor wear)</option>
              <option value="fair">Fair (Visible wear)</option>
              <option value="poor">Poor (For parts / Heavy wear)</option>
            </select>
          </div>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={product.mercariBuyerPaysShipping ?? true}
              onChange={(e) => onSettingsChange({ mercariBuyerPaysShipping: e.target.checked })}
            />
            Buyer pays shipping
          </label>
          <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={product.mercariShipOnOwn ?? false}
              onChange={(e) => onSettingsChange({ mercariShipOnOwn: e.target.checked })}
            />
            Ship on your own (SOYO)
          </label>
        </div>
      )}
    </div>
  );
}

// One variant's linked-Mercari-listing tile — thumbnail + label + status +
// actions. Replaces a plain "Post to Mercari" button with something that
// actually shows what's linked, once it exists. Expandable to see/edit the
// resolved photo carousel. Kept as its own component since `expanded` is
// local state that shouldn't reset when a sibling tile re-renders.
function VariantMercariTile({
  variant, label, product, mercariTitleTokens, mercariTitleGaps, mercariPhotoTemplate, images,
  onPost, onSync, onDelete, onRemovePhoto, onLink, onCheckPullSync,
}) {
  const [expanded, setExpanded] = useState(false);
  const [showLinkModal, setShowLinkModal] = useState(false);
  const [linkInput, setLinkInput] = useState("");
  const [linkError, setLinkError] = useState("");
  const [linkLoading, setLinkLoading] = useState(false);
  const status = variant.mercariStatus ?? "draft";
  const title = resolveMercariTitle(mercariTitleTokens, mercariTitleGaps, product, variant);
  const photoUrls = resolveMercariPhotos(mercariPhotoTemplate, variant, images);
  const thumbnail = photoUrls[0];

  async function handleLink() {
    setLinkError("");
    setLinkLoading(true);
    try {
      await onLink(variant, linkInput);
      setShowLinkModal(false);
      setLinkInput("");
    } catch (err) {
      setLinkError(err.message ?? "Failed to link listing.");
    } finally {
      setLinkLoading(false);
    }
  }

  const isOutOfStock = (variant.quantity ?? 0) === 0;
  return (
    <div style={{ width: 150, border: isOutOfStock ? "2px solid var(--warning)" : "1px solid var(--border)", borderRadius: 8, padding: 8, fontSize: 12, opacity: isOutOfStock ? 0.7 : 1 }}>
      <button
        onClick={() => setExpanded((v) => !v)}
        style={{ display: "block", width: "100%", height: 90, border: "none", padding: 0, borderRadius: 6, overflow: "hidden", background: isOutOfStock ? "var(--surface-hover)" : "var(--surface-hover)", cursor: "pointer", opacity: isOutOfStock ? 0.8 : 1 }}
        title="Click to view/edit photos"
      >
        {thumbnail ? (
          <img src={thumbnail} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} />
        ) : (
          <span style={{ color: "var(--muted)" }}>No photo</span>
        )}
      </button>
      <div style={{ marginTop: 6, fontWeight: 600, display: "flex", justifyContent: "space-between", alignItems: "start", gap: 4 }}>
        <span>{label}</span>
        {isOutOfStock && <span style={{ fontSize: 10, color: "var(--warning)", whiteSpace: "nowrap" }}>⚠️ OOS</span>}
      </div>
      <div style={{ color: "var(--muted)", fontSize: 11, marginBottom: 6 }}>{title}</div>

      {status === "active" ? (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
          <a href={variant.mercariUrl || "#"} target="_blank" rel="noreferrer" style={{ color: "#22c55e", fontSize: 11 }}>
            ✓ Live
          </a>
          <button className="btn btn-ghost" style={{ fontSize: 10, padding: "1px 6px" }} onClick={() => onSync(variant)}>
            🔄 Sync
          </button>
          <a
            href={`https://www.mercari.com/sell/edit/${variant.mercariListingId}/`}
            target="_blank" rel="noreferrer"
            className="btn btn-ghost" style={{ fontSize: 10, padding: "1px 6px" }}
          >
            ✏️ Edit
          </a>
          <button className="btn btn-ghost" style={{ fontSize: 10, padding: "1px 6px" }} onClick={() => onCheckPullSync(variant)}>
            ⬇️ Pull
          </button>
          <button className="btn btn-ghost" style={{ fontSize: 10, padding: "1px 6px" }} onClick={() => onDelete(variant)}>
            🗑 Delete
          </button>
        </div>
      ) : status === "posting" || status === "updating" ? (
        <span style={{ color: "var(--muted)" }}>{status === "posting" ? "⏳ Posting…" : "⏳ Syncing…"}</span>
      ) : (
        <>
          <div style={{ display: "flex", gap: 4, flexDirection: "column" }}>
            <button className="btn btn-primary" style={{ fontSize: 11, padding: "3px 8px" }} onClick={() => onPost(variant)}>
              Post to Mercari
            </button>
            <button className="btn btn-ghost" style={{ fontSize: 11, padding: "3px 8px" }} onClick={() => setShowLinkModal(true)}>
              🔗 Link existing
            </button>
          </div>
          {status === "failed" && variant.mercariError && (
            <div style={{ color: "var(--danger)", fontSize: 10, marginTop: 4 }}>{variant.mercariError}</div>
          )}
        </>
      )}

      {/* Mercari URL field - shown when active or when link modal is open */}
      {(status === "active" || showLinkModal) && (
        <div style={{ marginTop: 8, borderTop: "1px solid var(--border)", paddingTop: 6 }}>
          <div style={{ fontSize: 11 }}>
            <label style={{ fontSize: 10, color: "var(--muted)", display: "flex", alignItems: "center", gap: 4 }}>
              ✏️ Mercari URL
            </label>
            <input
              type="text"
              className="input"
              placeholder="Paste URL or item ID (e.g., m123abc...)"
              value={linkInput || variant.mercariUrl || ""}
              onChange={(e) => {
                setLinkInput(e.target.value);
                setLinkError("");
              }}
              onBlur={() => {
                if (linkInput && linkInput !== (variant.mercariUrl || "")) {
                  handleLink();
                }
              }}
              style={{ fontSize: 11, marginBottom: 4 }}
            />
            {linkError && (
              <div style={{ color: "var(--danger)", fontSize: 10, marginBottom: 4 }}>{linkError}</div>
            )}
            {showLinkModal && (
              <div style={{ display: "flex", gap: 4 }}>
                <button className="btn btn-primary" style={{ fontSize: 10, padding: "2px 6px", flex: 1 }} onClick={handleLink} disabled={linkLoading || !linkInput.trim()}>
                  {linkLoading ? "Linking…" : "Link"}
                </button>
                <button className="btn btn-ghost" style={{ fontSize: 10, padding: "2px 6px", flex: 1 }} onClick={() => { setShowLinkModal(false); setLinkInput(""); setLinkError(""); }}>
                  Cancel
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {expanded && (
        <div style={{ marginTop: 8, borderTop: "1px solid var(--border)", paddingTop: 6 }}>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
            {photoUrls.map((url) => (
              <div key={url} style={{ position: "relative", width: 40, height: 40 }}>
                <img src={url} alt="" style={{ width: "100%", height: "100%", objectFit: "cover", borderRadius: 4 }} />
                <button
                  onClick={() => onRemovePhoto(variant, url)}
                  style={{ position: "absolute", top: 1, right: 1, background: "rgba(0,0,0,0.6)", color: "#fff", border: "none", borderRadius: "50%", width: 14, height: 14, cursor: "pointer", fontSize: 9, lineHeight: 1 }}
                  title="Remove from this variant's Mercari listing"
                >
                  ✕
                </button>
              </div>
            ))}
            {photoUrls.length === 0 && <span style={{ color: "var(--muted)" }}>No photos resolved.</span>}
          </div>
        </div>
      )}
    </div>
  );
}

function VariantsEditor({
  options,
  variants,
  images,
  listingPrice,
  onOptionsChange,
  onVariantFieldChange,
  onBulkFieldChange,
  onBulkSetActive,
  onMergeUnmatched,
  onDiscardUnmatched,
  onReactivateVariant,
  onDeleteVariantPermanently,
  onOpenPhotoPicker,
  onCommit,
  saving,
  error,
}) {
  const activeVariants = variants.filter((v) => v.active);
  const unmatchedVariants = variants.filter((v) => !v.active && v.needsReview);
  const quietInactiveVariants = variants.filter((v) => !v.active && !v.needsReview);
  const quietInactiveCount = quietInactiveVariants.length;
  const [inactiveExpanded, setInactiveExpanded] = useState(false);
  // Only offer blank (unpopulated) active rows as merge targets — merging
  // real data onto a row that already has its own would silently overwrite it.
  const mergeTargets = activeVariants.filter((v) => !isPopulatedVariant(v, listingPrice));

  const hasSubVariation = options.length === 2;
  const [tableView, setTableView] = useState("primary"); // "primary" | "secondary"
  const [manageOpen, setManageOpen] = useState(false);
  const [selectedIds, setSelectedIds] = useState(() => new Set());
  const [mergeTargetByUnmatched, setMergeTargetByUnmatched] = useState({});
  // { primaryValue, field, value } awaiting confirmation, or null.
  const [pendingBulkEdit, setPendingBulkEdit] = useState(null);
  const [resetToken, setResetToken] = useState(0);

  function toggleSelected(id) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function handleBulkAction(action) {
    const ids = [...selectedIds];
    if (!ids.length) return;
    onBulkSetActive(ids, action === "activate");
    setSelectedIds(new Set());
  }

  function handleMerge(unmatchedId) {
    const targetId = mergeTargetByUnmatched[unmatchedId];
    if (!targetId) return;
    onMergeUnmatched(unmatchedId, targetId);
    setMergeTargetByUnmatched((prev) => {
      const next = { ...prev };
      delete next[unmatchedId];
      return next;
    });
  }

  // Editing a primary-level row's price/qty applies to every sub-variation
  // under that primary value — confirm first (unless the user's opted out)
  // since it's easy to mistake for a single-row edit.
  function commitPrimaryFieldEdit(primaryValue, field, value) {
    if (localStorage.getItem(SKIP_BULK_EDIT_WARNING_KEY) === "1") {
      onBulkFieldChange(primaryValue, field, value);
      return;
    }
    setPendingBulkEdit({ primaryValue, field, value });
  }

  function confirmBulkEdit(remember) {
    if (!pendingBulkEdit) return;
    onBulkFieldChange(pendingBulkEdit.primaryValue, pendingBulkEdit.field, pendingBulkEdit.value);
    if (remember) localStorage.setItem(SKIP_BULK_EDIT_WARNING_KEY, "1");
    setPendingBulkEdit(null);
  }

  function cancelBulkEdit() {
    setPendingBulkEdit(null);
    setResetToken((t) => t + 1); // remount the bulk-edit inputs back to their real values
  }

  function renderRow(v) {
    const optValues = v.optionValues ?? {};
    const primaryName = options[0]?.name;
    const secondaryName = options[1]?.name;
    const subValue = hasSubVariation && secondaryName ? optValues[secondaryName] : null;
    const subPhotoCount = hasSubVariation && secondaryName && subValue
      ? images.filter((img) => (img.variantTags ?? []).some((t) => t.optionName === secondaryName && t.value === subValue)).length
      : 0;
    return (
      <div key={v.id ?? Math.random()} className="variants-table-row variants-table-row-checkbox">
        <input type="checkbox" checked={selectedIds.has(v.id)} onChange={() => toggleSelected(v.id)} />
        {hasSubVariation && primaryName && secondaryName ? (
          <span>
            <div>{optValues[primaryName] ?? "—"}</div>
            <div style={{ fontSize: 11, color: "var(--muted)" }}>{subValue ?? "—"}</div>
            <button
              className="btn btn-ghost"
              style={{ padding: "2px 6px", fontSize: 11, marginTop: 2 }}
              onClick={() => onOpenPhotoPicker(secondaryName, subValue)}
            >
              {subPhotoCount > 0 ? `📷 ${subPhotoCount}` : "Select photo"}
            </button>
          </span>
        ) : (
          <span>
            <div>
              {Object.keys(optValues).length > 0
                ? Object.entries(optValues).map(([k, val]) => `${k}: ${val}`).join(" · ")
                : v.name || "Default"}
            </div>
            {options.length === 1 && primaryName && (
              <button
                className="btn btn-ghost"
                style={{ padding: "2px 6px", fontSize: 11, marginTop: 2 }}
                onClick={() => onOpenPhotoPicker(primaryName, optValues[primaryName])}
              >
                Select photo
              </button>
            )}
          </span>
        )}
        <input
          className="input"
          value={v.sku ?? ""}
          onChange={(e) => onVariantFieldChange(v.id, "sku", e.target.value)}
          onBlur={onCommit}
        />
        <input
          className="input"
          type="number"
          step="0.01"
          placeholder="listing price"
          value={v.price === listingPrice ? "" : v.price ?? ""}
          onChange={(e) => onVariantFieldChange(v.id, "price", e.target.value === "" ? listingPrice ?? null : Number(e.target.value))}
          onBlur={onCommit}
        />
        <input
          className="input"
          type="number"
          min="0"
          value={v.quantity}
          onChange={(e) => onVariantFieldChange(v.id, "quantity", Number(e.target.value) || 0)}
          onBlur={onCommit}
        />
        {v.mercariUrl ? (
          <a
            href={v.mercariUrl}
            target="_blank"
            rel="noreferrer"
            className="input"
            style={{ fontSize: 12, color: "var(--primary)", textDecoration: "underline", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", padding: "6px 8px", display: "flex", alignItems: "center" }}
            title={v.mercariUrl}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey) return;
              const url = prompt("Edit Mercari URL or item ID:", v.mercariUrl);
              if (url !== null) {
                e.preventDefault();
                onVariantFieldChange(v.id, "mercariUrl", url || null);
                onCommit();
              }
            }}
          >
            🔗 Live
          </a>
        ) : (
          <button
            type="button"
            className="input"
            style={{ fontSize: 11, padding: "6px 8px", color: "var(--muted)", textAlign: "center", cursor: "pointer" }}
            onClick={() => {
              const url = prompt("Paste Mercari URL or item ID:");
              if (url) {
                onVariantFieldChange(v.id, "mercariUrl", url);
                onCommit();
              }
            }}
          >
            + Add
          </button>
        )}
      </div>
    );
  }

  function renderPrimaryRow({ key, rows }) {
    const first = rows[0];
    const totalQty = rows.reduce((sum, r) => sum + (r.quantity || 0), 0);
    const subVariationName = options[1]?.name || "sub-variation";
    const photoCount = images.filter((img) =>
      (img.variantTags ?? []).some((t) => t.optionName === options[0].name && t.value === key)
    ).length;
    return (
      <div key={key} className="variants-table-row variants-table-row-primary">
        <span>{key}</span>
        <button className="btn btn-ghost" style={{ padding: "4px 8px", fontSize: 12 }} onClick={() => onOpenPhotoPicker(options[0].name, key)}>
          {photoCount > 0 ? `📷 ${photoCount}` : "Select photo"}
        </button>
        <span style={{ fontSize: 11, color: "var(--muted)" }}>
          Edit SKUs in the {subVariationName} view
        </span>
        <input
          key={`price-${key}-${resetToken}`}
          className="input"
          type="number"
          step="0.01"
          placeholder="listing price"
          defaultValue={first.price === listingPrice ? "" : first.price ?? ""}
          onBlur={(e) => {
            const value = e.target.value === "" ? listingPrice ?? null : Number(e.target.value);
            if (value !== (first.price ?? null)) commitPrimaryFieldEdit(key, "price", value);
          }}
        />
        {/* Sum of active sub-variation quantities — editing quantity only
            makes sense per sub-variation, so this is display-only. */}
        <span
          className="input"
          title={`Edit quantities in the ${subVariationName} view`}
          style={{ display: "flex", alignItems: "center", color: "var(--muted)", cursor: "default" }}
        >
          {totalQty}
        </span>
      </div>
    );
  }

  const primaryGroups = hasSubVariation ? groupVariantsByPrimary(activeVariants, options[0].name) : null;
  const isSingleStyle = options.length === 0 || (options.length === 1 && options[0].values.length <= 1);

  return (
    <div className="card detail-section">
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <h2>Options &amp; variants</h2>
        <button className="btn btn-ghost" onClick={() => setManageOpen(true)}>
          {isSingleStyle ? "+ Add variation" : "Manage variations"}
        </button>
      </div>

      {options.length === 0 && (
        <p className="detail-copy" style={{ fontSize: 12, color: "var(--muted)" }}>
          No variations yet — this is a single-SKU listing.
        </p>
      )}

      {manageOpen && (
        <ManageVariationsModal
          options={options}
          onChange={onOptionsChange}
          onClose={() => setManageOpen(false)}
          error={error}
        />
      )}

      {pendingBulkEdit && (
        <div className="modal-overlay">
          <div className="modal" style={{ maxWidth: 420 }}>
            <div className="modal-body" style={{ fontSize: 13 }}>
              Edits to primary variation details will apply to all sub-variation listings. Edit in
              the {options[1]?.name || "sub-variation"} view instead to apply changes to a specific SKU.
            </div>
            <div className="modal-footer">
              <button className="btn btn-ghost" onClick={cancelBulkEdit}>Undo Edit</button>
              <button className="btn btn-ghost" onClick={() => confirmBulkEdit(false)}>Ignore</button>
              <button className="btn btn-primary" onClick={() => confirmBulkEdit(true)}>Never show again</button>
            </div>
          </div>
        </div>
      )}

      {hasSubVariation && (
        <div className="variants-view-toggle">
          <button
            className={`btn btn-ghost${tableView === "primary" ? " active" : ""}`}
            onClick={() => setTableView("primary")}
          >
            By {options[0].name}
          </button>
          <button
            className={`btn btn-ghost${tableView === "secondary" ? " active" : ""}`}
            onClick={() => setTableView("secondary")}
          >
            By {options[1].name}
          </button>
        </div>
      )}

      {tableView === "secondary" && selectedIds.size > 0 && (
        <div className="variants-bulk-toolbar">
          <span>{selectedIds.size} selected</span>
          <button className="btn btn-ghost" onClick={() => handleBulkAction("activate")}>Activate</button>
          <button className="btn btn-danger" onClick={() => handleBulkAction("deactivate")}>Deactivate / delete</button>
        </div>
      )}

      {activeVariants.length > 0 && (
        <div className="variants-table">
          {hasSubVariation && tableView === "primary" ? (
            <>
              <div className="variants-table-row variants-table-header variants-table-row-primary">
                <span>{options[0].name}</span>
                <span>Photos</span>
                <span>SKU</span>
                <span>Price</span>
                <span>Qty</span>
              </div>
              {primaryGroups.map(renderPrimaryRow)}
            </>
          ) : (
            <>
              <div className="variants-table-row variants-table-header variants-table-row-checkbox">
                <span />
                <span>Variant</span>
                <span>SKU</span>
                <span>Price</span>
                <span>Qty</span>
                <span>Mercari</span>
              </div>
              {activeVariants.map(renderRow)}
            </>
          )}
        </div>
      )}

      {unmatchedVariants.length > 0 && (
        <div className="variants-unmatched">
          <h3>Unmatched — needs review</h3>
          <p className="detail-copy" style={{ fontSize: 12, color: "var(--muted)" }}>
            These variants no longer match a current option combination — their pricing/SKU data is
            preserved below. Merge each one into the correct variant, or discard it if it's no longer
            needed.
          </p>
          {unmatchedVariants.map((v) => (
            <div key={v.id} className="variants-unmatched-row">
              <span className="variants-unmatched-label">
                {Object.entries(v.optionValues).map(([k, val]) => `${k}: ${val}`).join(" · ") || "(no label)"}
              </span>
              <span className="variants-unmatched-meta">
                SKU {v.sku ?? "—"} · {v.price != null ? money(v.price) : "no price"} · qty {v.quantity}
              </span>
              <select
                className="input"
                value={mergeTargetByUnmatched[v.id] ?? ""}
                onChange={(e) => setMergeTargetByUnmatched((prev) => ({ ...prev, [v.id]: e.target.value }))}
                style={{ maxWidth: 220 }}
              >
                <option value="">Merge into…</option>
                {mergeTargets.map((t) => (
                  <option key={t.id} value={t.id}>
                    {Object.entries(t.optionValues).map(([k, val]) => `${k}: ${val}`).join(" · ")}
                  </option>
                ))}
              </select>
              <button className="btn btn-ghost" disabled={!mergeTargetByUnmatched[v.id]} onClick={() => handleMerge(v.id)}>
                Merge
              </button>
              <button className="btn btn-danger" onClick={() => onDiscardUnmatched(v.id)}>Discard</button>
            </div>
          ))}
        </div>
      )}

      {quietInactiveCount > 0 && (
        <div
          className="variants-inactive-section"
          style={{ marginTop: 16, borderTop: "1px solid var(--border)", paddingTop: 12 }}
        >
          <button
            type="button"
            className="btn btn-ghost"
            style={{
              fontSize: 13,
              color: "var(--muted)",
              display: "flex",
              alignItems: "center",
              gap: 6,
              padding: "4px 0",
            }}
            onClick={() => setInactiveExpanded((prev) => !prev)}
          >
            <span>{inactiveExpanded ? "▼" : "▶"}</span>
            <span>🗑 Inactive variations ({quietInactiveCount})</span>
          </button>

          {inactiveExpanded && (
            <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 10 }}>
              <p className="detail-copy" style={{ fontSize: 12, color: "var(--muted)", margin: 0 }}>
                These variations are currently inactive. You can restore them to active inventory or permanently delete them.
              </p>
              <div className="variants-table">
                <div
                  className="variants-table-row variants-table-header"
                  style={{ gridTemplateColumns: "minmax(0, 2fr) minmax(0, 1.2fr) minmax(0, 0.8fr) minmax(0, 0.6fr) 140px" }}
                >
                  <span>Variant</span>
                  <span>SKU</span>
                  <span>Price</span>
                  <span>Qty</span>
                  <span style={{ textAlign: "right" }}>Actions</span>
                </div>
                {quietInactiveVariants.map((v) => {
                  const label =
                    Object.entries(v.optionValues)
                      .map(([k, val]) => `${k}: ${val}`)
                      .join(" · ") || "(no label)";
                  return (
                    <div
                      key={v.id}
                      className="variants-table-row"
                      style={{
                        gridTemplateColumns: "minmax(0, 2fr) minmax(0, 1.2fr) minmax(0, 0.8fr) minmax(0, 0.6fr) 140px",
                        opacity: 0.8,
                      }}
                    >
                      <span style={{ fontWeight: 500 }}>{label}</span>
                      <span style={{ fontSize: 12, color: "var(--muted)" }}>{v.sku || "—"}</span>
                      <span style={{ fontSize: 12, color: "var(--muted)" }}>{v.price != null ? money(v.price) : "—"}</span>
                      <span style={{ fontSize: 12, color: "var(--muted)" }}>{v.quantity ?? 0}</span>
                      <div style={{ display: "flex", gap: 6, justifyContent: "flex-end" }}>
                        <button
                          type="button"
                          className="btn btn-ghost"
                          style={{ padding: "2px 8px", fontSize: 12 }}
                          title="Restore variant"
                          onClick={() => onReactivateVariant(v.id)}
                          disabled={saving}
                        >
                          ↩ Restore
                        </button>
                        <button
                          type="button"
                          className="btn btn-danger"
                          style={{ padding: "2px 8px", fontSize: 12 }}
                          title="Delete permanently"
                          onClick={() => {
                            if (window.confirm(`Permanently delete "${label}"?`)) {
                              onDeleteVariantPermanently(v.id);
                            }
                          }}
                          disabled={saving}
                        >
                          🗑
                        </button>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      )}

      {error && <div style={{ color: "var(--danger)", fontSize: 13 }}>{error}</div>}
      {saving && <span style={{ fontSize: 12, color: "var(--muted)" }}>Saving…</span>}
    </div>
  );
}

// ─── ActionToast ────────────────────────────────────────────────────────────
// Generic bottom-of-screen toast for reversible/scoped actions (photo delete,
// photo reorder). `actions` is an ordered list of { label, onClick, primary? };
// clicking any action or the ✕ dismisses the toast. Auto-dismisses after
// `autoDismissMs` (default 6s) so it never lingers forever if ignored.
export function ActionToast({ message, actions, onDismiss, autoDismissMs = 6000 }) {
  useEffect(() => {
    const t = setTimeout(onDismiss, autoDismissMs);
    return () => clearTimeout(t);
  }, [onDismiss, autoDismissMs]);

  return (
    <div
      style={{
        position: "fixed", bottom: 24, left: "50%", transform: "translateX(-50%)",
        background: "#1a1a1a", color: "#f0f0f0", padding: "10px 14px", borderRadius: 8,
        display: "flex", gap: 10, alignItems: "center", zIndex: 2000,
        boxShadow: "0 4px 16px rgba(0,0,0,0.4)", fontSize: 13, maxWidth: "90vw",
      }}
    >
      <span>{message}</span>
      {actions.map((a) => (
        <button
          key={a.label}
          className="btn btn-ghost"
          style={{ padding: "4px 10px", fontSize: 12, background: a.primary ? "#ff6b35" : undefined, color: a.primary ? "white" : undefined }}
          onClick={() => { a.onClick(); onDismiss(); }}
        >
          {a.label}
        </button>
      ))}
      <button className="btn btn-ghost" style={{ padding: "4px 8px", fontSize: 12 }} onClick={onDismiss}>✕</button>
    </div>
  );
}

// ─── ProductDetail page ───────────────────────────────────────────────────────

// ─── Mercari Cross-Post Modal ──────────────────────────────────────────────────

function MercariModal({
  product, weightLbs, weightOz, lengthIn, widthIn, heightIn, hasPendingMediaJobs, onClose, onLaunched,
  options, images, variants, mercariTitleTokens, mercariTitleGaps, mercariPhotoTemplate,
  onTokensChange, onGapsChange, onPhotoTemplateChange, onSettingsChange,
  onPostVariant, onSyncVariant, onDeleteVariant, onPostAllRemaining, postingAllVariants, onRemoveVariantPhoto,
}) {
  // With only one variant actually sellable right now, the whole multi-
  // listing template/tile UI is overkill — post it through the plain
  // single-item flow instead, just scoped to that one variant.
  const inStockVariants = product.hasVariants ? variants.filter((v) => v.active && (v.quantity ?? 0) > 0) : [];
  const singleVariant = inStockVariants.length === 1 ? inStockVariants[0] : null;
  const showVariantFlow = product.hasVariants && inStockVariants.length > 1;

  const [price, setPrice] = useState(
    singleVariant
      // listingPrice (the deliberate resale price) wins — a variant's own
      // `price` is the scraped source price at import time, not a real
      // per-variant override.
      ? String((typeof product.listingPrice === "number" ? product.listingPrice : singleVariant.price) ?? 15)
      : (product.listingPrice ?? product.suggestedSellPrice ?? product.sourceCost ?? product.aliexpressPrice * 2.2 ?? 15).toFixed(2)
  );
  const [condition, setCondition] = useState(product.mercariCondition ?? product.condition ?? "good");
  const [buyerPaysShipping, setBuyerPaysShipping] = useState(product.mercariBuyerPaysShipping ?? true);
  const [shipOnOwn, setShipOnOwn] = useState(product.mercariShipOnOwn ?? false);
  const [posting, setPosting] = useState(false);
  const [error, setError] = useState("");

  async function handleLaunch() {
    if (hasPendingMediaJobs) {
      setError("A photo change is still saving — wait for it to finish before cross-posting.");
      return;
    }
    setPosting(true);
    setError("");

    // Single in-stock variant: post it through the same variant-aware path
    // the multi-listing flow uses (so status/sync tracking stays consistent
    // if more variants come into stock later), just driven by this simpler form.
    if (singleVariant) {
      try {
        onSettingsChange({
          mercariCondition: condition,
          mercariBuyerPaysShipping: buyerPaysShipping,
          mercariShipOnOwn: shipOnOwn,
        });
        await onPostVariant(singleVariant, { priceOverride: parseFloat(price) || undefined });
        onLaunched?.();
        onClose();
      } catch (e) {
        setError(e.message ?? "Cross-post launch failed.");
      } finally {
        setPosting(false);
      }
      return;
    }

    const payload = {
      productId: product.id,
      title: product.title,
      description: product.description,
      price: parseFloat(price) || product.sourceCost || product.aliexpressPrice * 2.2 || 15,
      condition,
      brand: product.brand || product.artistName || "",
      suggestedCategory: product.category || product.artistName || product.title,
      images: product.images || [],
      weightLbs: (parseInt(weightLbs, 10) || 0) + (parseInt(weightOz, 10) || 0) / 16,
      lengthIn: parseFloat(lengthIn) || null,
      widthIn: parseFloat(widthIn) || null,
      heightIn: parseFloat(heightIn) || null,
      buyerPaysShipping,
      shipOnOwn,
    };

    try {
      await updateDoc(doc(db, "products", product.id), {
        "listingStatus.mercari": "posting",
        updatedAt: serverTimestamp(),
      });

      let sentToExtension = false;
      const extensionId = import.meta.env.VITE_EXTENSION_ID;

      if (window.chrome && chrome.runtime && chrome.runtime.sendMessage) {
        try {
          if (extensionId) {
            await new Promise((res, rej) => {
              chrome.runtime.sendMessage(extensionId, { type: "START_MERCARI_CROSS_POST", payload }, (resp) => {
                if (chrome.runtime.lastError || resp?.error) {
                  rej(new Error(resp?.error || chrome.runtime.lastError?.message || "Extension message failed"));
                } else {
                  res(resp);
                }
              });
            });
            sentToExtension = true;
          } else {
            await new Promise((res, rej) => {
              chrome.runtime.sendMessage({ type: "START_MERCARI_CROSS_POST", payload }, (resp) => {
                if (chrome.runtime.lastError || resp?.error) rej(new Error("Extension not connected"));
                else res(resp);
              });
            });
            sentToExtension = true;
          }
        } catch {
          /* Fall back */
        }
      }

      if (!sentToExtension) {
        localStorage.setItem("pendingMercariPayload", JSON.stringify(payload));
        window.open("https://www.mercari.com/sell/", "_blank");
      }

      onLaunched?.();
      onClose();
    } catch (e) {
      setError(e.message ?? "Cross-post launch failed.");
    } finally {
      setPosting(false);
    }
  }

  if (showVariantFlow) {
    const allVariants = variants;
    const activeVariants = variants.filter((v) => v.active);
    return (
      <div className="modal-overlay" onClick={onClose}>
        <div className="modal" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 720 }}>
          <div className="modal-header">
            <h2>Mercari Listings</h2>
            <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
          </div>
          <div className="modal-body">
            {mercariTitleTokens && mercariPhotoTemplate && (
              <MercariVariantTemplate
                product={product}
                options={options}
                images={images}
                tokens={mercariTitleTokens}
                gaps={mercariTitleGaps}
                photoTemplate={mercariPhotoTemplate}
                previewVariant={activeVariants[0] ?? allVariants[0] ?? null}
                onTokensChange={onTokensChange}
                onGapsChange={onGapsChange}
                onPhotoTemplateChange={onPhotoTemplateChange}
                onSettingsChange={onSettingsChange}
              />
            )}
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", margin: "12px 0 8px" }}>
              <h3 style={{ fontSize: 13, margin: 0 }}>Variant Listings</h3>
              <button className="btn btn-ghost" style={{ fontSize: 12 }} onClick={onPostAllRemaining} disabled={postingAllVariants}>
                {postingAllVariants ? "⏳ Posting…" : "Post all remaining"}
              </button>
            </div>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 10 }}>
              {mercariTitleTokens && mercariPhotoTemplate && allVariants.map((v) => (
                <VariantMercariTile
                  key={v.id}
                  variant={v}
                  label={Object.values(v.optionValues).join(" / ") || v.sku || "Variant"}
                  product={product}
                  mercariTitleTokens={mercariTitleTokens}
                  mercariTitleGaps={mercariTitleGaps}
                  mercariPhotoTemplate={mercariPhotoTemplate}
                  images={images}
                  onPost={onPostVariant}
                  onSync={onSyncVariant}
                  onDelete={onDeleteVariant}
                  onRemovePhoto={onRemoveVariantPhoto}
                  onLink={linkVariantMercariListing}
                  onCheckPullSync={checkMercariPullSyncChanges}
                />
              ))}
            </div>
          </div>
          <div className="modal-footer">
            <button className="btn btn-ghost" onClick={onClose}>Close</button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 480 }}>
        <div className="modal-header">
          <h2>Cross-Post to Mercari</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
        </div>

        <div className="modal-body">
          <div className="modal-field">
            <label>Mercari Sell Price (USD)</label>
            <input
              className="input"
              type="number"
              step="0.01"
              min="1"
              value={price}
              onChange={(e) => setPrice(e.target.value)}
            />
            {(product.sourceCost ?? product.aliexpressPrice) > 0 && (
              <span style={{ fontSize: 11, color: "var(--muted)" }}>
                Cost: ${(product.sourceCost ?? product.aliexpressPrice).toFixed(2)} · Est Proceeds: ${(parseFloat(price || 0) * 0.9).toFixed(2)}
              </span>
            )}
          </div>

          <div className="modal-field">
            <label>Item Condition</label>
            <select className="input" value={condition} onChange={(e) => setCondition(e.target.value)}>
              <option value="new">New (Unopened / Brand New)</option>
              <option value="likenew">Like New (Mint / Unused)</option>
              <option value="good">Good (Minor wear)</option>
              <option value="fair">Fair (Visible wear)</option>
              <option value="poor">Poor (For parts / Heavy wear)</option>
            </select>
          </div>

          <div className="modal-field" style={{ background: "var(--surface-hover)", padding: 10, borderRadius: 6 }}>
            <label style={{ fontSize: 12, fontWeight: 600, color: "var(--text)" }}>Package Weight & Dimensions</label>
            <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 2 }}>
              {weightLbs || weightOz ? `${weightLbs || 0} lb ${weightOz || 0} oz` : "6 oz (Default light package)"}
              {lengthIn && widthIn && heightIn ? ` · ${lengthIn}×${widthIn}×${heightIn} in` : " · Shoebox fit"}
            </div>
          </div>

          <div className="modal-field" style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 12 }}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13 }}>
              <input
                type="checkbox"
                checked={buyerPaysShipping}
                onChange={(e) => setBuyerPaysShipping(e.target.checked)}
              />
              Buyer pays shipping (Default)
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13 }}>
              <input
                type="checkbox"
                checked={shipOnOwn}
                onChange={(e) => setShipOnOwn(e.target.checked)}
              />
              Ship on your own (SOYO) instead of Mercari prepaid label
            </label>
          </div>

          {error && <div style={{ fontSize: 13, color: "var(--danger)", marginTop: 8 }}>{error}</div>}
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={handleLaunch} disabled={posting || hasPendingMediaJobs}>
            {posting ? "Launching…" : hasPendingMediaJobs ? "Waiting for photo save…" : "🚀 Launch Mercari Cross-Post"}
          </button>
        </div>
      </div>
    </div>
  );
}

function ProductDetail() {
  const { productId } = useParams();
  const navigate = useNavigate();
  const [product, setProduct] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [deletingProduct, setDeletingProduct] = useState(false);
  const [title, setTitle] = useState("");
  const [brand, setBrand] = useState("");
  const [aiSuggestedBrand, setAiSuggestedBrand] = useState(null);
  const [description, setDescription] = useState("");
  const [listingPrice, setListingPrice] = useState(null);
  const [sourcePrice, setSourcePrice] = useState(null);
  const [sourcePriceInput, setSourcePriceInput] = useState("");
  const [checkingEbaySync, setCheckingEbaySync] = useState(false);
  const [ebayPullSyncDiff, setEbayPullSyncDiff] = useState(null);
  const [importingEbayChanges, setImportingEbayChanges] = useState(false);
  const [ebaySyncMessage, setEbaySyncMessage] = useState("");
  const [checkingEtsySync, setCheckingEtsySync] = useState(false);
  const [etsyPullSyncDiff, setEtsyPullSyncDiff] = useState(null);
  const [importingEtsyChanges, setImportingEtsyChanges] = useState(false);
  const [etsySyncMessage, setEtsySyncMessage] = useState("");
  const [weightLbs, setWeightLbs] = useState("0");
  const [weightOz, setWeightOz] = useState("6");
  const [lengthIn, setLengthIn] = useState("");
  const [widthIn, setWidthIn] = useState("");
  const [heightIn, setHeightIn] = useState("");
  // Shared with iOS's own Item fields (shipping config beyond weight/dims,
  // which was already shared) — see wonni repo's UploadManager.swift.
  // Distinct from mercariBuyerPaysShipping below, which is a Mercari-
  // cross-post-specific override, not this general product-level default.
  const [buyerPaysShipping, setBuyerPaysShipping] = useState(true);
  const [handlingFee, setHandlingFee] = useState("0");
  const [estimatedShippingDays, setEstimatedShippingDays] = useState("3");
  const [handlingTimeDays, setHandlingTimeDays] = useState(1);
  const [tags, setTags] = useState([]);
  const [allUserTags, setAllUserTags] = useState([]);
  const [tagInput, setTagInput] = useState("");
  const [showTagSuggestions, setShowTagSuggestions] = useState(false);
  const [images, setImages] = useState([]);
  const imagesRef = useRef(images);
  useEffect(() => { imagesRef.current = images; }, [images]);
  const [draggingPhotoId, setDraggingPhotoId] = useState(null);
  const dragStartImagesRef = useRef(null);
  const dragHasCommittedRef = useRef(false);
  const [previewIndex, setPreviewIndex] = useState(0);
  // Tracked by stable image id, not array position — a background split of a
  // *different* image inserts a variable number of items ahead of this one,
  // which would otherwise shift this index out from under the open editor.
  const [editingImageId, setEditingImageId] = useState(null);
  const editingIndex = editingImageId === null ? null : images.findIndex((img) => img.id === editingImageId);
  const [savingMedia, setSavingMedia] = useState(false);
  const [mediaError, setMediaError] = useState("");
  // Serializes saveMedia's Firestore writes so concurrent callers (e.g.
  // several background image splits finishing close together) can't clobber
  // each other out of order — see saveMedia for the failure mode this avoids.
  const mediaSaveChainRef = useRef(Promise.resolve());
  const pendingMediaSavesRef = useRef(0);
  const postButtonRef = useRef(null);
  const [options, setOptions] = useState([]);
  const [variants, setVariants] = useState([]);
  // Mirrors `variants` for use inside the sequential Mercari-posting loop,
  // whose closures need to see live updates without re-subscribing.
  const variantsRef = useRef(variants);
  useEffect(() => { variantsRef.current = variants; }, [variants]);
  const [postingAllVariants, setPostingAllVariants] = useState(false);
  // Mercari per-variant listing template — null until hydrated from the
  // product doc (or defaulted from options/images on first load), see
  // defaultMercariTitleTokens/defaultMercariPhotoTemplate.
  const [mercariTitleTokens, setMercariTitleTokens] = useState(null);
  const [mercariTitleGaps, setMercariTitleGaps] = useState(null);
  const [mercariPhotoTemplate, setMercariPhotoTemplate] = useState(null);
  const [mercariMoreOptionsOpen, setMercariMoreOptionsOpen] = useState(false);
  const [savingVariants, setSavingVariants] = useState(false);
  const [variantsError, setVariantsError] = useState("");
  const [legacyMigrationPending, setLegacyMigrationPending] = useState(false);
  // { optionName, value } currently open in the photo picker (either the
  // primary option or a sub-variation), or null.
  const [photoPickerValue, setPhotoPickerValue] = useState(null);
  const [showMercariModal, setShowMercariModal] = useState(false);
  const [showPostModal, setShowPostModal] = useState(false);
  const [showLegacyMercariLinkModal, setShowLegacyMercariLinkModal] = useState(false);
  const [legacyMercariLinkInput, setLegacyMercariLinkInput] = useState("");
  const [legacyMercariLinkError, setLegacyMercariLinkError] = useState("");
  const [legacyMercariLinkLoading, setLegacyMercariLinkLoading] = useState(false);
  const [syncingMercari, setSyncingMercari] = useState(false);
  const [mercariSyncMessage, setMercariSyncMessage] = useState("");
  const [toast, setToast] = useState(null); // { message, actions } | null
  const [showFullscreenPhoto, setShowFullscreenPhoto] = useState(false);
  const [showAllPhotos, setShowAllPhotos] = useState(false);
  const [expandedSourceSection, setExpandedSourceSection] = useState(null); // "images" | "variants" | null
  const [sourceImages, setSourceImages] = useState([]);
  const [sourceVariants, setSourceVariants] = useState([]);
  const [lastSourceRefresh, setLastSourceRefresh] = useState(null); // timestamp
  const [sourceRefreshLoading, setSourceRefreshLoading] = useState(false);
  const [checkingMercariSold, setCheckingMercariSold] = useState(false);
  const [mercariCheckMessage, setMercariCheckMessage] = useState("");
  const [checkingMercariPullSync, setCheckingMercariPullSync] = useState(false);
  const [mercariPullSyncDiff, setMercariPullSyncDiff] = useState(null);
  const [importingMercariChanges, setImportingMercariChanges] = useState(false);
  const [showApplyMercariEditsModal, setShowApplyMercariEditsModal] = useState(false);
  const [applyingMercariEdits, setApplyingMercariEdits] = useState(false);
  const [syncingEbay, setSyncingEbay] = useState(false);
  const [deletingEbay, setDeletingEbay] = useState(false);
  const [showEbaySyncModal, setShowEbaySyncModal] = useState(false);
  const [ebayListingDetails, setEbayListingDetails] = useState(null);
  const [applyingEbaySync, setApplyingEbaySync] = useState(false);
  const [pendingNavigation, setPendingNavigation] = useState(null);
  const [aiDescLoading, setAiDescLoading] = useState(false);
  const [aiDescSuggestion, setAiDescSuggestion] = useState(null); // string | null
  const [aiDescError, setAiDescError] = useState("");
  // Import-time AI suggestions for title/price — the description one reuses
  // aiDescSuggestion above instead of a separate state (hydrated from
  // product.aiSuggestedDescription on load, see the main onSnapshot below),
  // so there's one chip per field regardless of whether the suggestion came
  // from import time or the on-demand "✨ AI Suggest" regenerate button.
  // These come from whatever produced the product (dropship's
  // gemini_identify.js at import, or iOS's own on-device Gemini call — same
  // field names either way, see UploadManager.syncProductDataAwaiting in the
  // wonni repo). Dismissed (Discard) per-suggestion, not deleted from
  // Firestore — reappears if the product doc is reloaded.
  const [aiSuggestedTitle, setAiSuggestedTitle] = useState(null);
  const [aiSuggestedPrice, setAiSuggestedPrice] = useState(null);
  // Refs, not state — read inside the onSnapshot closure below, whose effect
  // only depends on [productId] (see that useEffect's deps array). A state
  // value would be captured stale at subscription time, so clicking Discard
  // wouldn't actually stick past the next unrelated Firestore update; a ref
  // is always read fresh regardless of when the closure was created.
  const dismissedAiTitleRef = useRef(false);
  const dismissedAiPriceRef = useRef(false);
  const dismissedAiDescriptionRef = useRef(false);
  const variantsSectionRef = useRef(null);
  const { jobs: mediaJobs, enqueue: enqueueMediaJob } = useMediaJobQueue();

  // ── Autosave for text fields ────────────────────────────────────────────────
  // Holds this tab's own latest field values, used to ensure a keystroke never
  // gets clobbered by a delayed server echo. When the debounced write lands,
  // this ref is cleared so the next server snapshot (confirming the write) is
  // trusted as the canonical state.
  const localFieldsRef = useRef(null);
  const [saving, setSaving] = useState(false);
  const [lastSaveTime, setLastSaveTime] = useState(null);

  async function writeFieldsNow() {
    if (!productId) return;
    const fields = localFieldsRef.current;
    if (!fields || Object.keys(fields).length === 0) return;
    try {
      setSaving(true);
      await updateDoc(doc(db, "products", productId), {
        ...fields,
        updatedAt: serverTimestamp(),
      });
      setLastSaveTime(Date.now());
      localFieldsRef.current = null;
    } catch (err) {
      console.warn("Could not autosave field edits:", err);
    } finally {
      setSaving(false);
    }
  }
  const scheduleWriteFields = useDebouncedCallback(writeFieldsNow, 1000);

  function markFieldsDirty(patch) {
    const fields = { ...(localFieldsRef.current ?? {}), ...patch };
    localFieldsRef.current = fields;
    scheduleWriteFields();
  }

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

        // This tab's own in-flight edits (always freshest) win over the server's
        // echo. Once the debounced write lands, localFieldsRef is cleared, so the
        // next snapshot is trusted — no stale edits linger after a refresh.
        const localFields = localFieldsRef.current;
        const effectiveFields = localFields ? { ...next, ...localFields } : next;

        const nextTitle = effectiveFields.title ?? next.title ?? "";
        const nextBrand = effectiveFields.brand ?? next.brand ?? (next.artistName ?? "");
        const nextDescription = effectiveFields.description ?? next.description ?? "";
        setTitle(nextTitle);
        setBrand(nextBrand);
        setDescription(nextDescription);
        const effListingPrice = "listingPrice" in effectiveFields ? effectiveFields.listingPrice : next.listingPrice;
        const nextListingPrice = typeof effListingPrice === "number" ? effListingPrice : null;
        setListingPrice(nextListingPrice);

        // AI-suggested title/brand/description/price — only surface a chip when the
        // suggestion actually differs from the current value and the user
        // hasn't already dismissed it this session (re-dismissing on every
        // snapshot re-render would make Discard feel broken).
        setAiSuggestedTitle(
          !dismissedAiTitleRef.current
            && typeof next.aiSuggestedTitle === "string" && next.aiSuggestedTitle && next.aiSuggestedTitle !== nextTitle
            ? next.aiSuggestedTitle
            : null
        );
        setAiSuggestedBrand(
          typeof next.aiSuggestedBrand === "string" && next.aiSuggestedBrand && next.aiSuggestedBrand !== nextBrand
            ? next.aiSuggestedBrand
            : null
        );
        setAiSuggestedPrice(
          !dismissedAiPriceRef.current
            && typeof next.aiSuggestedPrice === "number" && next.aiSuggestedPrice !== nextListingPrice
            ? next.aiSuggestedPrice
            : null
        );
        if (!dismissedAiDescriptionRef.current
          && typeof next.aiSuggestedDescription === "string" && next.aiSuggestedDescription
          && next.aiSuggestedDescription !== nextDescription) {
          setAiDescSuggestion(next.aiSuggestedDescription);
        }
        {
          const effSourcePrice = "sourcePrice" in effectiveFields
            ? effectiveFields.sourcePrice
            : (typeof next.sourcePrice === "number" ? next.sourcePrice : next.aliexpressPrice);
          const sp = typeof effSourcePrice === "number" ? effSourcePrice : null;
          setSourcePrice(sp);
          setSourcePriceInput(sp != null ? String(sp) : "");
        }
        // Prefill from Gemini's import-time suggestion only until the user actually
        // saves a weight/dimension of their own (saveShippingInfo persists all five
        // fields together, so "unset" here means "never saved").
        if (!("weightLbs" in effectiveFields) && next.weightLbs == null && next.weightOz == null
          && typeof next.geminiWeightOz === "number") {
          setWeightLbs(String(Math.floor(next.geminiWeightOz / 16)));
          setWeightOz(String(next.geminiWeightOz % 16));
        } else {
          setWeightLbs(String(effectiveFields.weightLbs ?? next.weightLbs ?? 0));
          setWeightOz(String(effectiveFields.weightOz ?? next.weightOz ?? 6));
        }
        const effLengthIn = "lengthIn" in effectiveFields ? effectiveFields.lengthIn : next.lengthIn;
        const effWidthIn = "widthIn" in effectiveFields ? effectiveFields.widthIn : next.widthIn;
        const effHeightIn = "heightIn" in effectiveFields ? effectiveFields.heightIn : next.heightIn;
        if (effLengthIn == null && effWidthIn == null && effHeightIn == null
          && typeof next.geminiLengthIn === "number") {
          setLengthIn(String(next.geminiLengthIn));
          setWidthIn(String(next.geminiWidthIn));
          setHeightIn(String(next.geminiHeightIn));
        } else {
          setLengthIn(effLengthIn ? String(effLengthIn) : "");
          setWidthIn(effWidthIn ? String(effWidthIn) : "");
          setHeightIn(effHeightIn ? String(effHeightIn) : "");
        }
        // Shared with iOS's Item fields — see the plan doc's Phase 3.5.
        setBuyerPaysShipping(
          "buyerPaysShipping" in effectiveFields ? effectiveFields.buyerPaysShipping : (next.buyerPaysShipping ?? true)
        );
        setHandlingFee(String(effectiveFields.handlingFee ?? next.handlingFee ?? 0));
        setEstimatedShippingDays(String(effectiveFields.estimatedShippingDays ?? next.estimatedShippingDays ?? 3));
        const effHandlingTimeDays = "handlingTimeDays" in effectiveFields ? effectiveFields.handlingTimeDays : next.handlingTimeDays;
        setHandlingTimeDays(typeof effHandlingTimeDays === "number" ? effHandlingTimeDays : 1);
        const effTags = "tags" in effectiveFields ? effectiveFields.tags : next.tags;
        setTags(Array.isArray(effTags) ? effTags : []);

        const mergedForImages = { ...next };
        if ("images" in effectiveFields) mergedForImages.images = effectiveFields.images;
        if ("imageAssets" in effectiveFields) mergedForImages.imageAssets = effectiveFields.imageAssets;
        const nextImages = normalizeImageAssets(mergedForImages);
        setImages(nextImages);

        const mergedForVariants = { ...next };
        if ("options" in effectiveFields) mergedForVariants.options = effectiveFields.options;
        if ("variants" in effectiveFields) mergedForVariants.variants = effectiveFields.variants;
        if ("hasVariants" in effectiveFields) mergedForVariants.hasVariants = effectiveFields.hasVariants;

        const derived = deriveOptionsAndVariants(mergedForVariants);
        setOptions(derived.options);
        setVariants(derived.variants);
        setLegacyMigrationPending(derived.isLegacy);

        const effMercariTitleTokens = "mercariTitleTokens" in effectiveFields
          ? effectiveFields.mercariTitleTokens
          : next.mercariTitleTokens;
        setMercariTitleTokens(
          Array.isArray(effMercariTitleTokens) && effMercariTitleTokens.length
            ? effMercariTitleTokens
            : defaultMercariTitleTokens(derived.options)
        );
        const effMercariTitleGaps = "mercariTitleGaps" in effectiveFields
          ? effectiveFields.mercariTitleGaps
          : next.mercariTitleGaps;
        setMercariTitleGaps(Array.isArray(effMercariTitleGaps) ? effMercariTitleGaps : []);
        const effMercariPhotoTemplate = "mercariPhotoTemplate" in effectiveFields
          ? effectiveFields.mercariPhotoTemplate
          : next.mercariPhotoTemplate;
        setMercariPhotoTemplate(
          Array.isArray(effMercariPhotoTemplate) && effMercariPhotoTemplate.length
            ? effMercariPhotoTemplate
            : defaultMercariPhotoTemplate(nextImages)
        );
        setPreviewIndex(0);
        setLoading(false);
      },
      (err) => { setError(err?.message ?? "Could not load product."); setLoading(false); }
    );
  }, [productId]);

  // Background check for eBay drift when product is active on eBay
  useEffect(() => {
    if (!product || !productId) return;
    const isEbayActive = product.crossPostStatus?.ebay === "active"
      || product.crossPostStatus?.ebay === "posted";
    if (!isEbayActive) return;

    let isMounted = true;
    (async () => {
      try {
        const res = await callFunction("ebayPullSync")({ productId, credentialSet: "web" });
        if (isMounted) {
          if (res.data?.hasDrift) {
            setEbayPullSyncDiff(res.data);
          } else {
            setEbayPullSyncDiff(null);
          }
        }
      } catch (err) {
        console.debug("Background eBay sync check:", err.message);
      }
    })();

    return () => { isMounted = false; };
  }, [productId, product?.ebayStatus, product?.crossPostStatus?.ebay]);

  // Background check for Etsy drift when product is active on Etsy
  useEffect(() => {
    if (!product || !productId) return;
    const isEtsyActive = product.crossPostStatus?.etsy === "active"
      || product.crossPostStatus?.etsy === "posted";
    if (!isEtsyActive) return;

    let isMounted = true;
    (async () => {
      try {
        const res = await callFunction("etsyPullSync")({ productId, credentialSet: "web" });
        if (isMounted) {
          if (res.data?.hasDrift) {
            setEtsyPullSyncDiff(res.data);
          } else {
            setEtsyPullSyncDiff(null);
          }
        }
      } catch (err) {
        console.debug("Background Etsy sync check:", err.message);
      }
    })();

    return () => { isMounted = false; };
  }, [productId, product?.crossPostStatus?.etsy]);

  // Load all existing tags across the user's products for autocomplete suggestions
  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) return;
    const q = query(collection(db, "products"), where("userId", "==", uid));
    return onSnapshot(q, (snap) => {
      const tagSet = new Set();
      snap.docs.forEach((docSnap) => {
        const docTags = docSnap.data()?.tags;
        if (Array.isArray(docTags)) {
          docTags.forEach((t) => {
            if (typeof t === "string" && t.trim()) tagSet.add(t.trim());
          });
        }
      });
      setAllUserTags(Array.from(tagSet).sort((a, b) => a.localeCompare(b)));
    });
  }, []);

  const preorder = product?.preOrder;
  const infoTable = useMemo(() => {
    const sourceInfo = product?.sourceInfo;
    if (!sourceInfo || typeof sourceInfo !== "object") return [];

    return Object.entries(sourceInfo).map(([key, value]) => {
      const formattedLabel = key.charAt(0).toUpperCase() + key.slice(1).replace(/([A-Z])/g, " $1");
      const formattedValue = Array.isArray(value) ? value.join(", ") : String(value);
      return { label: formattedLabel, value: formattedValue };
    });
  }, [product?.sourceInfo]);
  const safePreviewIndex = Math.min(previewIndex, Math.max(0, images.length - 1));

  const mercariStatus = product?.crossPostStatus?.mercari ?? "draft";
  const mercariUrl = product?.crossPostUrls?.mercari ?? null;
  const mercariItemId = product?.crossPostListingIds?.mercari ?? null;
  const mercariError = product?.crossPostErrors?.mercari ?? null;
  // For variant products, the header button reflects aggregate progress
  // across variants instead of the (unused, for these products) top-level
  // listingStatus.mercari field — only in-stock variants count toward "done".
  // With exactly one in-stock variant it reads as a plain single-item listing
  // (no "1/1" framing) — the x/y progress label only kicks in at 2+.
  const mercariInStockVariants = variants.filter((v) => v.active && (v.quantity ?? 0) > 0);
  const mercariPostedVariants = mercariInStockVariants.filter((v) => v.mercariStatus === "active");
  const mercariAllInStockVariantsPosted = mercariInStockVariants.length > 0
    && mercariPostedVariants.length === mercariInStockVariants.length;
  const mercariSingleInStockVariant = mercariInStockVariants.length === 1 ? mercariInStockVariants[0] : null;
  const previewImage = images[safePreviewIndex]?.url ?? "";
  const imageCountLabel = useMemo(() => {
    if (!images.length) return "No images";
    return `${images.length} image${images.length === 1 ? "" : "s"}`;
  }, [images.length]);
  const activeMediaJobs = mediaJobs.filter((j) => j.productId === productId && j.status !== "done");
  const activeSplitUrls = new Set(
    activeMediaJobs.filter((j) => j.type === "split" && j.status !== "error").map((j) => j.imageUrl)
  );
  // A split/upload still in flight means product.images doesn't yet reflect the
  // final photo set — cross-posting or syncing now would send a stale/incomplete
  // snapshot (the reported "photos entirely omitted" bug).
  const hasPendingMediaJobs = activeMediaJobs.some((j) => j.status !== "error");

  // Writes straight to the LIVE image fields, bypassing the unsaved-edits
  // buffer entirely. Used only by the background photo-split pipeline
  // (handleSaveSplit), which is deliberately excluded from dirty-tracking —
  // it keeps running (and saving) after the user has navigated away, so it
  // must never be gated behind Save. Every other photo action goes through
  // stageMediaEdit below instead.
  async function saveMedia(nextImages) {
    if (!productId) return;
    setImages(nextImages);
    pendingMediaSavesRef.current += 1;
    setSavingMedia(true);
    setMediaError("");
    const payload = buildImagePayload(nextImages);
    // Serialize writes in call order. Concurrent background splits (or any
    // overlapping edit) each call saveMedia independently and race their own
    // updateDoc — without this chain, a slower-landing write built from an
    // earlier (smaller) snapshot can complete *after* a faster-landing write
    // built from a later (fuller) one, silently clobbering it in Firestore.
    // The UI still showed every photo locally (setImages already ran above)
    // until the next reload revealed the smaller persisted count.
    const run = mediaSaveChainRef.current.then(() =>
      updateDoc(doc(db, "products", productId), {
        images: payload.map((image) => image.url),
        imageAssets: payload,
        listingImages: payload.map((image) => image.url),
        updatedAt: serverTimestamp(),
      })
    );
    mediaSaveChainRef.current = run.catch(() => {}); // one failure shouldn't jam later saves
    try {
      await run;
    } catch (err) {
      setMediaError(err?.message ?? "Could not save image changes.");
    } finally {
      pendingMediaSavesRef.current -= 1;
      if (pendingMediaSavesRef.current === 0) setSavingMedia(false);
    }
  }

  // User-driven photo edits (add/delete/reorder/crop/identify/link-to-variant)
  // stage into the unsaved-edits buffer instead of writing live fields —
  // mirrors every other field's new staged-until-Save behavior.
  function stageMediaEdit(nextImages) {
    setImages(nextImages);
    const payload = buildImagePayload(nextImages);
    markFieldsDirty({
      images: payload.map((image) => image.url),
      imageAssets: payload,
      listingImages: payload.map((image) => image.url),
    });
  }

  function handleTitleChange(value) {
    setTitle(value);
    markFieldsDirty({ title: value });
  }

  function handleBrandChange(value) {
    setBrand(value);
    markFieldsDirty({ brand: value.trim() || null });
  }

  async function handleCheckEbaySync() {
    setCheckingEbaySync(true);
    setEbaySyncMessage("");
    setEbayPullSyncDiff(null);
    try {
      const res = await callFunction("ebayPullSync")({ productId, credentialSet: "web" });
      if (res.data?.hasDrift) {
        setEbayPullSyncDiff(res.data);
      } else {
        setEbaySyncMessage("✓ eBay listing is up to date (no external changes detected).");
        setTimeout(() => setEbaySyncMessage(""), 5000);
      }
    } catch (err) {
      console.error("eBay sync check failed:", err);
      setEbaySyncMessage(`Sync check failed: ${err.message}`);
    } finally {
      setCheckingEbaySync(false);
    }
  }

  async function importEbayPullSyncChanges() {
    if (!ebayPullSyncDiff?.ebayData) return;
    setImportingEbayChanges(true);
    try {
      const { title: ebayTitle, price: ebayPrice, quantity: ebayQuantity } = ebayPullSyncDiff.ebayData;
      const fieldsToUpdate = {};
      if (ebayTitle) fieldsToUpdate.title = ebayTitle;
      if (ebayPrice != null) fieldsToUpdate.price = ebayPrice;
      if (ebayQuantity != null) fieldsToUpdate.quantity = ebayQuantity;

      await callFunction("ebayImportPullSync")({ productId, fields: fieldsToUpdate });
      if (ebayTitle) setTitle(ebayTitle);
      if (ebayPrice != null) setListingPrice(ebayPrice);
      setEbayPullSyncDiff(null);
      setEbaySyncMessage("✓ Successfully applied changes from eBay!");
      setTimeout(() => setEbaySyncMessage(""), 5000);
    } catch (err) {
      console.error("Failed to import eBay changes:", err);
      setEbaySyncMessage(`Import failed: ${err.message}`);
    } finally {
      setImportingEbayChanges(false);
    }
  }

  async function handleCheckEtsySync() {
    setCheckingEtsySync(true);
    setEtsySyncMessage("");
    setEtsyPullSyncDiff(null);
    try {
      const res = await callFunction("etsyPullSync")({ productId, credentialSet: "web" });
      if (res.data?.hasDrift) {
        setEtsyPullSyncDiff(res.data);
      } else {
        setEtsySyncMessage("✓ Etsy listing is up to date (no external changes detected).");
        setTimeout(() => setEtsySyncMessage(""), 5000);
      }
    } catch (err) {
      console.error("Etsy sync check failed:", err);
      setEtsySyncMessage(`Sync check failed: ${err.message}`);
    } finally {
      setCheckingEtsySync(false);
    }
  }

  async function importEtsyPullSyncChanges() {
    if (!etsyPullSyncDiff?.etsyData) return;
    setImportingEtsyChanges(true);
    try {
      const { title: etsyTitle, price: etsyPrice, quantity: etsyQuantity } = etsyPullSyncDiff.etsyData;
      const fieldsToUpdate = {};
      if (etsyTitle) fieldsToUpdate.title = etsyTitle;
      if (etsyPrice != null) fieldsToUpdate.price = etsyPrice;
      if (etsyQuantity != null) fieldsToUpdate.quantity = etsyQuantity;

      await callFunction("etsyImportPullSync")({ productId, fields: fieldsToUpdate });
      if (etsyTitle) setTitle(etsyTitle);
      if (etsyPrice != null) setListingPrice(etsyPrice);
      setEtsyPullSyncDiff(null);
      setEtsySyncMessage("✓ Successfully applied changes from Etsy!");
      setTimeout(() => setEtsySyncMessage(""), 5000);
    } catch (err) {
      console.error("Failed to import Etsy changes:", err);
      setEtsySyncMessage(`Import failed: ${err.message}`);
    } finally {
      setImportingEtsyChanges(false);
    }
  }

  function handleDescriptionChange(value) {
    setDescription(value);
    markFieldsDirty({ description: value });
  }

  // Every variant whose price still equals the price *before this keystroke*
  // is "following" it, not a deliberate override — bump those to the new
  // value so they keep following. Anything the user already typed a
  // different number into is left untouched. Runs per-change (not just on
  // blur) so a follower tracks correctly through a whole typing sequence.
  function handleListingPriceChange(rawValue) {
    const prevPrice = listingPrice;
    const nextPrice = rawValue === "" ? null : Number(rawValue);
    const nextVariants = variants.map((v) => (v.price === prevPrice ? { ...v, price: nextPrice } : v));
    setListingPrice(nextPrice);
    setVariants(nextVariants);
    markFieldsDirty({ listingPrice: nextPrice, variants: nextVariants });
  }

  function handleWeightLbsChange(raw) {
    setWeightLbs(raw);
    markFieldsDirty({ weightLbs: parseInt(raw, 10) || 0 });
  }

  function handleWeightOzChange(raw) {
    setWeightOz(raw);
    markFieldsDirty({ weightOz: parseInt(raw, 10) || 0 });
  }

  function handleLengthInChange(raw) {
    setLengthIn(raw);
    markFieldsDirty({ lengthIn: parseFloat(raw) || null });
  }

  function handleWidthInChange(raw) {
    setWidthIn(raw);
    markFieldsDirty({ widthIn: parseFloat(raw) || null });
  }

  function handleHeightInChange(raw) {
    setHeightIn(raw);
    markFieldsDirty({ heightIn: parseFloat(raw) || null });
  }

  function handleBuyerPaysShippingChange(checked) {
    setBuyerPaysShipping(checked);
    markFieldsDirty({ buyerPaysShipping: checked });
  }

  function handleHandlingFeeChange(raw) {
    setHandlingFee(raw);
    markFieldsDirty({ handlingFee: parseFloat(raw) || 0 });
  }

  function handleEstimatedShippingDaysChange(raw) {
    setEstimatedShippingDays(raw);
    markFieldsDirty({ estimatedShippingDays: parseInt(raw, 10) || 3 });
  }

  function handleHandlingTimeDaysChange(raw) {
    const parsed = parseInt(raw, 10);
    const val = Number.isNaN(parsed) ? 1 : parsed;
    setHandlingTimeDays(val);
    markFieldsDirty({ handlingTimeDays: val });
  }

  function handleAddTag(tagToAdd) {
    const clean = (typeof tagToAdd === "string" ? tagToAdd : tagInput).trim();
    if (!clean) return;
    if (!tags.includes(clean)) {
      const nextTags = [...tags, clean];
      setTags(nextTags);
      markFieldsDirty({ tags: nextTags });
    }
    setTagInput("");
    setShowTagSuggestions(false);
  }

  function handleRemoveTag(tagToRemove) {
    const nextTags = tags.filter((t) => t !== tagToRemove);
    setTags(nextTags);
    markFieldsDirty({ tags: nextTags });
  }

  // Commits the staged buffer into the live fields and clears it — the
  // unified Save button's click handler.
  function handleSourcePriceChange(rawValue) {
    const nextPrice = rawValue === "" ? null : Number(rawValue);
    setSourcePrice(nextPrice);
    markFieldsDirty({ sourcePrice: nextPrice });
  }

  function handleSourceUrlChange(newUrl) {
    markFieldsDirty({ sourceUrl: newUrl });
  }

  // Detect Mercari drift (unapplied changes to live Mercari listings)
  function computeHasMercariDrift() {
    if (!product || !mercariStatus || mercariStatus === "draft") return false;

    // Check product-level drift
    if (!product.hasVariants && mercariStatus === "active") {
      const diff = computeMercariDiff(product);
      if (Object.keys(diff).length > 0) return true;
    }

    // Check per-variant drift
    if (product.hasVariants && variants) {
      for (const variant of variants) {
        if (variant.mercariStatus === "active") {
          const diff = computeVariantMercariDiff(variant);
          if (Object.keys(diff).length > 0) return true;
        }
      }
    }

    return false;
  }

  // Extract variant diff logic into reusable function
  function computeVariantMercariDiff(variant) {
    const diff = {};
    const title = resolveMercariTitle(mercariTitleTokens, mercariTitleGaps, product, variant);
    if (title !== (variant.mercariSyncedTitle ?? "")) diff.title = title;

    const price = typeof product.listingPrice === "number" ? product.listingPrice
      : (typeof variant.price === "number" ? variant.price : null);
    if (price != null && price !== variant.mercariSyncedPrice) diff.price = price;

    const photoUrls = resolveMercariPhotos(mercariPhotoTemplate, variant, images);
    const syncedImages = variant.mercariSyncedImages ?? [];
    const imagesChanged = photoUrls.length !== syncedImages.length
      || photoUrls.some((url, i) => url !== syncedImages[i]);
    if (imagesChanged) diff.images = photoUrls;

    return diff;
  }

  const mercariDrift = computeHasMercariDrift();

  // Navigation guard: prompt if Mercari listing has unapplied changes
  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      mercariDrift && currentLocation.pathname !== nextLocation.pathname
  );

  useEffect(() => {
    if (blocker.state === "blocked") {
      setPendingNavigation(blocker.location.pathname);
      setShowApplyMercariEditsModal(true);
    }
  }, [blocker.state, blocker.location]);

  async function handleApplyMercariEdits() {
    setApplyingMercariEdits(true);
    try {
      if (!product?.hasVariants && mercariStatus === "active") {
        await handleSyncToMercari();
      }
      if (product?.hasVariants && variants) {
        for (const variant of variants) {
          if (variant.mercariStatus === "active") {
            await syncVariantToMercari(variant);
          }
        }
      }
      setShowApplyMercariEditsModal(false);
      blocker.proceed?.();
    } catch (err) {
      console.error("Error applying Mercari edits:", err);
    } finally {
      setApplyingMercariEdits(false);
    }
  }

  function handleDontChangeMercari() {
    setShowApplyMercariEditsModal(false);
    blocker.proceed?.();
  }

  function applyAIShipping() {
    const titleLower = (title || "").toLowerCase();
    let suggestion;
    if (titleLower.includes("keyring") || titleLower.includes("photocard") || titleLower.includes("sticker") || titleLower.includes("pin")) {
      suggestion = { weightLbs: "0", weightOz: "4", lengthIn: "6", widthIn: "4", heightIn: "1" };
    } else if (titleLower.includes("hoodie") || titleLower.includes("jacket") || titleLower.includes("plush")) {
      suggestion = { weightLbs: "1", weightOz: "4", lengthIn: "12", widthIn: "10", heightIn: "4" };
    } else {
      suggestion = { weightLbs: "0", weightOz: "8", lengthIn: "9", widthIn: "6", heightIn: "3" };
    }
    handleWeightLbsChange(suggestion.weightLbs);
    handleWeightOzChange(suggestion.weightOz);
    handleLengthInChange(suggestion.lengthIn);
    handleWidthInChange(suggestion.widthIn);
    handleHeightInChange(suggestion.heightIn);
  }

  // Calls Gemini to generate a suggested product description from the title
  // and first product image. Shows the result inline with Accept/Discard.
  async function generateAIDescription() {
    setAiDescLoading(true);
    setAiDescError("");
    setAiDescSuggestion(null);
    try {
      const firstImageUrl = images[0]?.url ?? null;
      const res = await callFunction("generateProductDescription")({
        productId,
        title,
        existingDescription: description,
        imageUrl: firstImageUrl,
      });
      setAiDescSuggestion(res.data?.description ?? "");
    } catch (e) {
      setAiDescError(e.message ?? "AI description generation failed.");
    } finally {
      setAiDescLoading(false);
    }
  }

  // Stages options/variants/hasVariants into the unsaved-edits buffer
  // (rather than the `options`/`variants` state closure, which would still
  // be stale immediately after a setOptions/setVariants call) — actual
  // persistence now happens via the unified Save button (handleSave).
  function persistVariants(nextOptions, nextVariants, nextMercariTitleTokens) {
    setOptions(nextOptions);
    setVariants(nextVariants);
    setLegacyMigrationPending(false);
    if (nextMercariTitleTokens) setMercariTitleTokens(nextMercariTitleTokens);
    markFieldsDirty({
      options: nextOptions,
      variants: nextVariants,
      hasVariants: nextOptions.length > 0,
      ...(nextMercariTitleTokens ? { mercariTitleTokens: nextMercariTitleTokens } : {}),
    });
    return true;
  }

  // A hard-delete (removing a value or a whole option) is only worth
  // confirming when it would actually throw away saved price/SKU/quantity
  // data — deleting blank, never-populated rows needs no ceremony.
  function confirmHardDelete(removedRows) {
    const populatedCount = removedRows.filter((v) => isPopulatedVariant(v, listingPrice)).length;
    if (populatedCount === 0) return true;
    return window.confirm(
      `This will permanently delete ${populatedCount} variant${populatedCount === 1 ? "" : "s"} ` +
        `and its price/SKU/quantity data. This can't be undone. Continue?`
    );
  }

  // Structural edits (add/rename/delete an option or its values) come from
  // the "Manage variations" modal and save immediately — unlike the
  // price/SKU/qty table below, which stays batched behind its own "Save
  // options & variants" button. Every op here is deterministic (no fuzzy
  // matching, no "unmatched" quarantine): additions can never lose data, so
  // they never prompt; deletions are explicit user choices, so they hard-
  // delete outright (with a confirm only when real data is at stake).
  async function handleOptionsChange(nextOptions, changeInfo) {
    let nextVariants = variants;
    // Keep the Mercari title template's option tokens matching the option
    // dimensions that still exist — otherwise a rename leaves a stale token
    // referencing the old name (rendered as an orphaned chip) alongside a
    // separately-addable one for the new name.
    let nextMercariTokens = mercariTitleTokens;

    if (changeInfo?.isNewOption) {
      nextVariants = addNewOptionDimension(nextVariants, changeInfo.newOptionName, changeInfo.addedValues, productId);
    } else if (changeInfo?.removeOption) {
      const removed = nextVariants.filter((v) => changeInfo.removeOption in v.optionValues);
      if (!confirmHardDelete(removed)) return false;
      nextVariants = removeOptionEntirely(nextVariants, changeInfo.removeOption);
      if (nextMercariTokens) {
        nextMercariTokens = nextMercariTokens.filter(
          (t) => !(t.type === "option" && t.optionName === changeInfo.removeOption)
        );
      }
    } else if (changeInfo?.optionName) {
      // Relabel first so removedValues/addedValues below are keyed by the
      // option's current (possibly just-renamed) name and value text.
      nextVariants = applyOptionRename(nextVariants, changeInfo);
      if (nextMercariTokens && changeInfo.optionName !== changeInfo.newOptionName) {
        nextMercariTokens = nextMercariTokens.map((t) =>
          t.type === "option" && t.optionName === changeInfo.optionName
            ? { ...t, optionName: changeInfo.newOptionName }
            : t
        );
      }
      if (changeInfo.removedValues?.length) {
        const removedSet = new Set(changeInfo.removedValues);
        const removed = nextVariants.filter((v) => removedSet.has(v.optionValues[changeInfo.newOptionName]));
        if (!confirmHardDelete(removed)) return false;
        nextVariants = removeOptionValues(nextVariants, changeInfo.newOptionName, changeInfo.removedValues);
      }
      if (changeInfo.addedValues?.length) {
        const otherOptions = nextOptions.filter((o) => o.name !== changeInfo.newOptionName);
        nextVariants = addOptionValues(nextVariants, otherOptions, changeInfo.newOptionName, changeInfo.addedValues, productId);
      }
    }

    return persistVariants(nextOptions, nextVariants, nextMercariTokens !== mercariTitleTokens ? nextMercariTokens : undefined);
  }

  // Table edits auto-save — there's no separate "Save options & variants"
  // button. Per-keystroke fields (SKU/price/qty text inputs) update local
  // state immediately for responsive typing, then persist on blur via
  // commitVariantsNow (mirrors the primary-row bulk-price-edit pattern,
  // which already committed on blur). One-shot actions (bulk activate/
  // deactivate, merge/discard unmatched) persist immediately since there's
  // no keystroke-by-keystroke typing to batch.
  function updateVariantField(variantId, field, value) {
    setVariants((prev) => prev.map((v) => (v.id === variantId ? { ...v, [field]: value } : v)));
  }

  function commitVariantsNow() {
    persistVariants(options, variants);
  }

  function bulkSetActive(variantIds, active) {
    const nextVariants = variants.map((v) => (variantIds.includes(v.id) ? { ...v, active } : v));
    return persistVariants(options, nextVariants);
  }

  function reactivateVariant(variantId) {
    return bulkSetActive([variantId], true);
  }

  // Unlike deactivating (which just flips a flag, easily undone by
  // reactivating), this actually removes the row — irreversible, gated by a
  // confirm at the call site.
  function deleteVariantPermanently(variantId) {
    const nextVariants = variants.filter((v) => v.id !== variantId);
    return persistVariants(options, nextVariants);
  }

  // Applies a price/qty edit made on a primary-level table row to every
  // variant sharing that primary value (e.g. every Size under "RM").
  function bulkSetFieldForPrimaryValue(primaryValue, field, value) {
    const primaryName = options[0]?.name;
    if (!primaryName) return;
    const nextVariants = variants.map((v) =>
      v.optionValues[primaryName] === primaryValue ? { ...v, [field]: value } : v
    );
    return persistVariants(options, nextVariants);
  }

  // Copies an unmatched (needsReview) row's real data onto a blank target
  // row, then drops the now-redundant unmatched row, and persists both
  // changes together.
  function mergeUnmatchedInto(unmatchedId, targetId) {
    const unmatched = variants.find((v) => v.id === unmatchedId);
    if (!unmatched) return;
    const nextVariants = variants
      .filter((v) => v.id !== unmatchedId)
      .map((v) =>
        v.id === targetId
          ? {
              ...v,
              sku: unmatched.sku ?? v.sku,
              price: unmatched.price ?? v.price,
              quantity: unmatched.quantity ?? v.quantity,
              sourcePrice: unmatched.sourcePrice ?? v.sourcePrice,
              sourceVariantId: unmatched.sourceVariantId ?? v.sourceVariantId,
            }
          : v
      );
    return persistVariants(options, nextVariants);
  }

  function discardUnmatched(variantId) {
    const nextVariants = variants.filter((v) => v.id !== variantId);
    return persistVariants(options, nextVariants);
  }

  // Opens the Select Photo picker for either the primary option or a
  // sub-variation. If that value already has photos attached, confirms first
  // — the picker itself shows the current selection pre-checked, but the
  // heads-up is worth it since saving can deselect/replace them.
  function requestPhotoPicker(optionName, value) {
    const existingCount = images.filter((img) =>
      (img.variantTags ?? []).some((t) => t.optionName === optionName && t.value === value)
    ).length;
    if (existingCount > 0) {
      const ok = window.confirm(
        `"${value}" already has ${existingCount} photo${existingCount === 1 ? "" : "s"} attached. ` +
          `Overwrite existing associated photo(s)?`
      );
      if (!ok) return;
    }
    setPhotoPickerValue({ optionName, value });
  }

  // Links (or unlinks) photos to one option value (primary or sub-variation),
  // from the Select Photo picker in the variants table. Selected images get a
  // tag replacing any prior tag for this option name (so moving a photo from
  // one value to another just re-tags it); images that had exactly this tag
  // but were unchecked lose it — any other tags they carry are left alone.
  function linkPhotosToValue(optionName, value, selectedImageIds) {
    const selectedSet = new Set(selectedImageIds);
    const nextImages = images.map((img) => {
      const tags = img.variantTags ?? [];
      const hasThisTag = tags.some((t) => t.optionName === optionName && t.value === value);
      if (selectedSet.has(img.id)) {
        return { ...img, variantTags: [...tags.filter((t) => t.optionName !== optionName), { optionName, value }] };
      }
      if (hasThisTag) {
        return { ...img, variantTags: tags.filter((t) => !(t.optionName === optionName && t.value === value)) };
      }
      return img;
    });
    stageMediaEdit(nextImages);
  }

  function handleDeleteImage(index) {
    const prevImages = images;
    const nextImages = images.filter((_, i) => i !== index);
    stageMediaEdit(nextImages);
    setEditingImageId(null);
    setPreviewIndex((prev) => Math.min(prev, Math.max(0, nextImages.length - 1)));
    setToast({
      message: "Photo deleted.",
      actions: [{ label: "Undo", onClick: () => stageMediaEdit(prevImages) }],
    });
  }

  function handleSetCover(index) {
    if (index === 0) return;
    const nextImages = moveItem(images, index, 0);
    stageMediaEdit(nextImages);
    setPreviewIndex(0);
    setEditingImageId(null);
  }

  function handleDropReorder(from, to) {
    if (from === to) return;
    const nextImages = moveItem(images, from, to);
    stageMediaEdit(nextImages);
    setPreviewIndex(to);
  }

  // Called by CropEditor: replace original image with the cropped version
  function handleSaveCrop(cropResult) {
    const index = editingIndex;
    if (index === null || index === -1) return;
    const newImage = {
      id: `${cropResult.url}-crop`,
      url: cropResult.url,
      sourceUrl: images[index]?.url ?? cropResult.url,
      width: cropResult.width ?? null,
      height: cropResult.height ?? null,
      kind: "crop",
    };
    const nextImages = images.map((img, i) => (i === index ? newImage : img));
    stageMediaEdit(nextImages);
    setEditingImageId(null);
  }

  // Called by IdentifyEditor: replace original image with all cropped boxes
  function handleSaveIdentify(results) {
    const index = editingIndex;
    if (index === null || index === -1) return;
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
    stageMediaEdit(nextImages);
    setEditingImageId(null);
  }

  // Both handlers below just enqueue a background job (see
  // lib/mediaJobQueue.jsx) and return immediately — the queue lives above
  // the router, so the split/upload keeps running (and eventually persists
  // via a Firestore transaction) even if the user navigates away from this
  // listing before it finishes.

  // Called by SplitEditor: closes the modal instantly and queues the split.
  function handleSaveSplit({ splitMethod, lines, boxes, imageUrl }) {
    const index = editingIndex;
    if (index === null || index === -1) return;
    const targetImage = images[index];
    if (!targetImage?.url) return;

    setEditingImageId(null);
    enqueueMediaJob({
      type: "split",
      productId,
      title: product?.title,
      imageUrl: targetImage.url,
      targetImageId: targetImage.id,
      splitMethod,
      lines,
      boxes,
    });
  }

  function handleAddPhotos(files) {
    if (!files || !files.length) return;
    enqueueMediaJob({ type: "upload", productId, title: product?.title, files });
  }

  // Diffs the current Wonni Drop state against the last-successfully-pushed
  // Mercari snapshot (mercariSynced*, written by the extension after every
  // successful create/edit) — a sync only needs to touch fields that actually
  // changed since. Compares against product.images (the raw URL array actually
  // sent to Mercari), not the transformed gallery `images` state.
  function computeMercariDiff(prod) {
    const diff = {};
    const currentTitle = prod.title ?? "";
    const currentDescription = prod.description ?? "";
    const currentPrice = typeof prod.listingPrice === "number" ? prod.listingPrice : null;
    const currentImages = prod.images ?? [];
    const syncedImages = prod.mercariSyncedImages ?? [];

    if (currentTitle !== (prod.mercariSyncedTitle ?? "")) diff.title = currentTitle;
    if (currentDescription !== (prod.mercariSyncedDescription ?? "")) diff.description = currentDescription;
    if (currentPrice != null && currentPrice !== prod.mercariSyncedPrice) diff.price = currentPrice;
    const imagesChanged = currentImages.length !== syncedImages.length
      || currentImages.some((url, i) => url !== syncedImages[i]);
    if (imagesChanged) diff.images = currentImages;

    return diff;
  }

  async function handleSyncToMercari() {
    if (!product || !mercariItemId) return;
    if (hasPendingMediaJobs) {
      setMercariSyncMessage("A photo change is still saving — wait for it to finish before syncing.");
      return;
    }
    const diff = computeMercariDiff(product);
    if (Object.keys(diff).length === 0) {
      setMercariSyncMessage("Already up to date.");
      return;
    }

    setSyncingMercari(true);
    setMercariSyncMessage("");
    try {
      await updateDoc(doc(db, "products", product.id), {
        "listingStatus.mercari": "updating",
        updatedAt: serverTimestamp(),
      });

      const payload = {
        productId: product.id,
        mercariItemId,
        title: product.title ?? "",
        description: product.description ?? "",
        price: typeof product.listingPrice === "number" ? product.listingPrice : null,
        images: product.images ?? [],
        diff,
      };

      const extensionId = import.meta.env.VITE_EXTENSION_ID;
      if (!(window.chrome && chrome.runtime && chrome.runtime.sendMessage && extensionId)) {
        throw new Error("Wonni Drop extension not connected.");
      }
      await new Promise((res, rej) => {
        chrome.runtime.sendMessage(extensionId, { type: "START_MERCARI_EDIT", payload }, (resp) => {
          if (chrome.runtime.lastError || resp?.error) {
            rej(new Error(resp?.error || chrome.runtime.lastError?.message || "Extension message failed"));
          } else {
            res(resp);
          }
        });
      });
    } catch (e) {
      setMercariSyncMessage(e.message ?? "Sync failed to start.");
    } finally {
      setSyncingMercari(false);
    }
  }

  // Manual escape hatch, mirroring the wonni iOS app's MercariListingEditSheet:
  // if the listing was deleted on Mercari (or a sync attempt just froze because
  // its edit page no longer exists), there's otherwise no way back to a fresh
  // "Cross-post to Mercari" button — this clears the stale Mercari fields so a
  // brand-new listing can be posted.
  async function handleResetMercariListing() {
    if (!product) return;
    if (!window.confirm("Delete this Mercari listing link? This only unlinks it in Wonni Drop — to remove the listing on Mercari itself, use Edit first and delete it there.")) {
      return;
    }
    await updateDoc(doc(db, "products", product.id), {
      "listingStatus.mercari": "draft",
      "listingId.mercari": deleteField(),
      "listingUrl.mercari": deleteField(),
      "listingError.mercari": deleteField(),
      mercariSyncedTitle: deleteField(),
      mercariSyncedDescription: deleteField(),
      mercariSyncedPrice: deleteField(),
      mercariSyncedImages: deleteField(),
      updatedAt: serverTimestamp(),
    });
    setMercariSyncMessage("");
  }

  // Mercari per-variant master template — persisted immediately on every
  // drag/delete, same "no separate Save step" convention as the rest of this
  // page's Mercari settings.
  async function persistMercariTitleTokens(nextTokens) {
    setMercariTitleTokens(nextTokens);
    if (!product) return;
    await updateDoc(doc(db, "products", product.id), {
      mercariTitleTokens: nextTokens,
      updatedAt: serverTimestamp(),
    });
  }

  async function persistMercariTitleGaps(nextGaps) {
    setMercariTitleGaps(nextGaps);
    if (!product) return;
    await updateDoc(doc(db, "products", product.id), {
      mercariTitleGaps: nextGaps,
      updatedAt: serverTimestamp(),
    });
  }

  async function persistMercariPhotoTemplate(nextTemplate) {
    setMercariPhotoTemplate(nextTemplate);
    if (!product) return;
    await updateDoc(doc(db, "products", product.id), {
      mercariPhotoTemplate: nextTemplate,
      updatedAt: serverTimestamp(),
    });
  }

  async function persistMercariModalSettings(fields) {
    if (!product) return;
    await updateDoc(doc(db, "products", product.id), { ...fields, updatedAt: serverTimestamp() });
  }

  // Builds and dispatches one variant's Mercari cross-post from the master
  // template. Doesn't wait for it to finish — callers that need to serialize
  // multiple variants use waitForVariantMercariStatus below.
  async function postVariantToMercari(variant, { priceOverride } = {}) {
    if (!product) throw new Error("Product not loaded.");
    const title = resolveMercariTitle(mercariTitleTokens, mercariTitleGaps, product, variant);
    // listingPrice (the deliberate resale price) wins — variant.price is
    // populated at import time from the scraped *source* price, not a real
    // per-variant sell-price override, so it can't be trusted as authoritative.
    const price = priceOverride ?? (typeof product.listingPrice === "number" ? product.listingPrice
      : (typeof variant.price === "number" ? variant.price : null));
    const photoUrls = resolveMercariPhotos(mercariPhotoTemplate, variant, images);

    await updateDoc(doc(db, "products", product.id), {
      variants: variants.map((v) => (v.id === variant.id ? { ...v, mercariStatus: "posting" } : v)),
      updatedAt: serverTimestamp(),
    });

    const payload = {
      productId: product.id,
      variantId: variant.id,
      title,
      description: product.description ?? "",
      price,
      condition: product.mercariCondition ?? "good",
      brand: product.brand || product.artistName || "",
      suggestedCategory: product.category || product.artistName || product.title,
      images: photoUrls,
      weightLbs: (parseInt(weightLbs, 10) || 0) + (parseInt(weightOz, 10) || 0) / 16,
      lengthIn: parseFloat(lengthIn) || null,
      widthIn: parseFloat(widthIn) || null,
      heightIn: parseFloat(heightIn) || null,
      buyerPaysShipping: product.mercariBuyerPaysShipping ?? true,
      shipOnOwn: product.mercariShipOnOwn ?? false,
    };

    const extensionId = import.meta.env.VITE_EXTENSION_ID;
    if (!(window.chrome && chrome.runtime && chrome.runtime.sendMessage && extensionId)) {
      throw new Error("Wonni Drop extension not connected.");
    }
    await new Promise((res, rej) => {
      chrome.runtime.sendMessage(extensionId, { type: "START_MERCARI_CROSS_POST", payload }, (resp) => {
        if (chrome.runtime.lastError || resp?.error) {
          rej(new Error(resp?.error || chrome.runtime.lastError?.message || "Extension message failed"));
        } else {
          res(resp);
        }
      });
    });
  }

  // Resolves once this variant's live mercariStatus leaves "posting" — used to
  // serialize the "post all remaining" batch, since the extension can only
  // safely track one in-flight Mercari tab at a time.
  function waitForVariantMercariStatus(variantId, timeoutMs = 200000) {
    return new Promise((resolve) => {
      const start = Date.now();
      const check = () => {
        const v = variantsRef.current.find((x) => x.id === variantId);
        if (!v || v.mercariStatus !== "posting" || Date.now() - start > timeoutMs) {
          resolve(v);
          return;
        }
        setTimeout(check, 1000);
      };
      check();
    });
  }

  async function postAllRemainingVariants() {
    setPostingAllVariants(true);
    try {
      const remaining = variants.filter(
        (v) => v.active && v.mercariStatus !== "active" && v.mercariStatus !== "posting" && v.mercariStatus !== "updating"
      );
      for (const variant of remaining) {
        try {
          await postVariantToMercari(variant);
        } catch (e) {
          console.error(`Failed to start posting variant ${variant.id}:`, e);
          continue;
        }
        await waitForVariantMercariStatus(variant.id);
      }
    } finally {
      setPostingAllVariants(false);
    }
  }

  // Pushes only what changed since the last successful post/sync for this
  // variant — same diff-against-last-synced-snapshot approach as the
  // product-level sync-to-Mercari feature, scoped per variant.
  async function syncVariantToMercari(variant) {
    if (!product || !variant.mercariListingId) return;
    const title = resolveMercariTitle(mercariTitleTokens, mercariTitleGaps, product, variant);
    const price = typeof product.listingPrice === "number" ? product.listingPrice
      : (typeof variant.price === "number" ? variant.price : null);
    const photoUrls = resolveMercariPhotos(mercariPhotoTemplate, variant, images);

    const diff = {};
    if (title !== (variant.mercariSyncedTitle ?? "")) diff.title = title;
    if (price != null && price !== variant.mercariSyncedPrice) diff.price = price;
    const syncedImages = variant.mercariSyncedImages ?? [];
    const imagesChanged = photoUrls.length !== syncedImages.length
      || photoUrls.some((url, i) => url !== syncedImages[i]);
    if (imagesChanged) diff.images = photoUrls;
    if (Object.keys(diff).length === 0) return;

    await updateDoc(doc(db, "products", product.id), {
      variants: variants.map((v) => (v.id === variant.id ? { ...v, mercariStatus: "updating" } : v)),
      updatedAt: serverTimestamp(),
    });

    const payload = {
      productId: product.id,
      variantId: variant.id,
      mercariItemId: variant.mercariListingId,
      title,
      description: product.description ?? "",
      price,
      images: photoUrls,
      diff,
    };

    const extensionId = import.meta.env.VITE_EXTENSION_ID;
    if (!(window.chrome && chrome.runtime && chrome.runtime.sendMessage && extensionId)) {
      throw new Error("Wonni Drop extension not connected.");
    }
    await new Promise((res, rej) => {
      chrome.runtime.sendMessage(extensionId, { type: "START_MERCARI_EDIT", payload }, (resp) => {
        if (chrome.runtime.lastError || resp?.error) {
          rej(new Error(resp?.error || chrome.runtime.lastError?.message || "Extension message failed"));
        } else {
          res(resp);
        }
      });
    });
  }

  // Same manual escape hatch as handleResetMercariListing, scoped to one
  // variant — clears just that variant's Mercari fields, does not touch
  // Mercari itself.
  async function resetVariantMercariListing(variant) {
    if (!product) return;
    if (!window.confirm("Delete this variant's Mercari listing link? This only unlinks it in Wonni Drop — to remove the listing on Mercari itself, use Edit first and delete it there.")) {
      return;
    }
    await updateDoc(doc(db, "products", product.id), {
      variants: variants.map((v) => (v.id === variant.id ? {
        ...v,
        mercariStatus: "draft",
        mercariListingId: null,
        mercariUrl: null,
        mercariError: null,
        mercariSyncedTitle: null,
        mercariSyncedPrice: null,
        mercariSyncedImages: null,
      } : v)),
      updatedAt: serverTimestamp(),
    });
  }

  // Removes one resolved photo from a single variant's Mercari listing only —
  // survives template edits (mercariPhotoRemovedUrls is subtracted from the
  // template-resolved list after regenerating it).
  async function removeVariantMercariPhoto(variant, url) {
    if (!product) return;
    await updateDoc(doc(db, "products", product.id), {
      variants: variants.map((v) => (v.id === variant.id
        ? { ...v, mercariPhotoRemovedUrls: [...(v.mercariPhotoRemovedUrls ?? []), url] }
        : v)),
      updatedAt: serverTimestamp(),
    });
  }

  function parseMercariId(input) {
    const trimmed = (input ?? "").trim();
    if (!trimmed) return null;
    const itemMatch = trimmed.match(/\/item\/(m[A-Za-z0-9]+)/);
    if (itemMatch) return itemMatch[1];
    const bareMatch = trimmed.match(/^m[A-Za-z0-9]+$/);
    if (bareMatch) return bareMatch[0];
    return null;
  }

  async function linkVariantMercariListing(variant, input) {
    if (!product) return;
    const mercariId = parseMercariId(input);
    if (!mercariId) throw new Error("Invalid Mercari URL or item ID.");
    const duplicate = variants.find(
      (v) => v.id !== variant.id && v.mercariListingId === mercariId
    );
    if (duplicate) {
      throw new Error(
        `This Mercari listing is already linked to variant "${Object.values(duplicate.optionValues).join(" / ") || duplicate.sku || "Variant"}".`
      );
    }
    const url = `https://www.mercari.com/us/item/${mercariId}/`;
    await updateDoc(doc(db, "products", product.id), {
      variants: variants.map((v) => (v.id === variant.id
        ? {
          ...v,
          mercariStatus: "active",
          mercariListingId: mercariId,
          mercariUrl: url,
          mercariSyncedTitle: null,
          mercariSyncedDescription: null,
          mercariSyncedPrice: null,
          mercariSyncedImages: null,
          mercariError: null,
        }
        : v)),
      updatedAt: serverTimestamp(),
    });
  }

  async function linkLegacyMercariListing(input) {
    if (!product) return;
    const mercariId = parseMercariId(input);
    if (!mercariId) throw new Error("Invalid Mercari URL or item ID.");
    const variantDuplicate = variants.find(
      (v) => v.mercariListingId === mercariId
    );
    if (variantDuplicate) {
      throw new Error(
        `This Mercari listing is already linked to variant "${Object.values(variantDuplicate.optionValues).join(" / ") || variantDuplicate.sku || "Variant"}".`
      );
    }
    const url = `https://www.mercari.com/us/item/${mercariId}/`;
    await updateDoc(doc(db, "products", product.id), {
      "listingStatus.mercari": "active",
      "listingId.mercari": mercariId,
      "listingUrl.mercari": url,
      updatedAt: serverTimestamp(),
    });
  }

  async function checkMercariSoldItems() {
    if (!product) return;
    setCheckingMercariSold(true);
    setMercariCheckMessage("Opening Mercari in background... this may take a minute");

    try {
      const extensionId = import.meta.env.VITE_EXTENSION_ID;
      if (!extensionId || !window.chrome?.runtime?.sendMessage) {
        throw new Error("Extension not available");
      }

      // Tell extension to check for sold items (it will scrape and call recordMercariSalesBatch)
      const result = await new Promise((resolve, reject) => {
        chrome.runtime.sendMessage(extensionId, { type: "CHECK_MERCARI_SOLD" }, (response) => {
          if (chrome.runtime.lastError) {
            reject(new Error(chrome.runtime.lastError.message));
          } else {
            resolve(response);
          }
        });
      });

      if (!result || result.error) {
        throw new Error(result?.error ?? "Failed to check Mercari");
      }

      setMercariCheckMessage(
        "✓ Mercari check complete. Any sold items have been recorded and flagged for relisting. Refresh to see updates."
      );
    } catch (err) {
      setMercariCheckMessage(`Error: ${err.message}`);
    } finally {
      setCheckingMercariSold(false);
    }
  }

  async function checkMercariPullSyncChanges(variant) {
    if (!product || !variant?.mercariListingId) return;
    setCheckingMercariPullSync(true);
    setMercariPullSyncDiff(null);

    try {
      const extensionId = import.meta.env.VITE_EXTENSION_ID;
      if (!extensionId || !window.chrome?.runtime?.sendMessage) {
        throw new Error("Extension not available");
      }

      // Tell extension to scrape the live Mercari item page
      const scrapedData = await new Promise((resolve, reject) => {
        chrome.runtime.sendMessage(
          extensionId,
          { type: "CHECK_MERCARI_PULL_SYNC", mercariItemId: variant.mercariListingId },
          (response) => {
            if (chrome.runtime.lastError) {
              reject(new Error(chrome.runtime.lastError.message));
            } else {
              resolve(response);
            }
          }
        );
      });

      if (!scrapedData || scrapedData.error) {
        throw new Error(scrapedData?.error ?? "Failed to scrape Mercari listing");
      }

      // Call backend to detect diff and re-host images
      const syncedData = {
        title: variant.mercariSyncedTitle,
        description: variant.mercariSyncedDescription,
        images: variant.mercariSyncedImages || [],
      };

      const diffResult = await callFunction("detectMercariPullSyncDiff")({
        listingId: product.id,
        variantId: variant.id,
        liveData: scrapedData.data,
        syncedData,
      });

      if (diffResult.hasChanges) {
        setMercariPullSyncDiff({
          variant,
          diff: diffResult.diff,
          rehostedPhotos: diffResult.rehostedPhotos,
        });
      } else {
        setMercariPullSyncDiff({ variant, diff: diffResult.diff, noChanges: true });
      }
    } catch (err) {
      alert(`Error checking for changes: ${err.message}`);
    } finally {
      setCheckingMercariPullSync(false);
    }
  }

  async function importMercariPullSyncChanges() {
    if (!mercariPullSyncDiff) return;
    const { variant, diff, rehostedPhotos } = mercariPullSyncDiff;

    setImportingMercariChanges(true);
    try {
      const importPhotos = rehostedPhotos
        ?.filter((p) => p.rehosted)
        .map((p) => ({ original: p.original, rehosted: p.rehosted })) || [];

      await callFunction("importMercariPullSync")({
        listingId: product.id,
        variantId: variant.id,
        importTitle: diff.titleChanged ? variant.title : null,
        importDescription: diff.descriptionChanged ? variant.description : null,
        importPhotos,
      });

      setMercariPullSyncDiff(null);
      alert("✓ Changes imported successfully!");
    } catch (err) {
      alert(`Error importing changes: ${err.message}`);
    } finally {
      setImportingMercariChanges(false);
    }
  }

  async function refreshSourceData(section) {
    // Check cooldown: only refresh if 24 hours have passed since last refresh
    if (lastSourceRefresh && Date.now() - lastSourceRefresh < 24 * 60 * 60 * 1000) {
      return; // Cooldown active, don't refresh
    }

    if (!product || !product.sourceUrl || !product.source) return;

    setSourceRefreshLoading(true);
    try {
      const result = await callFunction("refreshSourceData")({
        productId: product.id,
        source: product.source,
        sourceUrl: product.sourceUrl,
        section: section, // "images" or "variants"
      });

      if (section === "images") {
        setSourceImages(result.data.images || []);
      } else if (section === "variants") {
        setSourceVariants(result.data.variants || []);
      }

      setLastSourceRefresh(Date.now());
      setExpandedSourceSection(section);
    } catch (err) {
      console.error("Failed to refresh source data:", err);
    } finally {
      setSourceRefreshLoading(false);
    }
  }

  async function handleDeleteProduct() {
    const liveOn = [
      product?.tiktokStatus === "active" ? "TikTok Shop" : null,
      (product?.ebayStatus === "active" || product?.crossPostStatus?.ebay === "active" || product?.crossPostStatus?.ebay === "posted") ? "eBay" : null,
      (product?.etsyStatus === "active" || product?.crossPostStatus?.etsy === "active" || product?.crossPostStatus?.etsy === "posted") ? "Etsy" : null,
    ].filter(Boolean);
    if (liveOn.length) {
      window.alert(
        `Can't delete "${product?.title ?? "this product"}" — it's still active on ${liveOn.join(" and ")}. Take it down there first, then delete it here.`
      );
      return;
    }
    if (!window.confirm(`Delete "${product?.title ?? "this product"}"? This can't be undone.`)) return;
    setDeletingProduct(true);
    try {
      await deleteDoc(doc(db, "products", productId));
      navigate("/");
    } catch (e) {
      setDeletingProduct(false);
      setError(e.message ?? "Delete failed.");
    }
  }

  async function handleEbaySyncListing() {
    if (!product?.crossPostListingIds?.ebay) {
      setError("No eBay listing to sync.");
      return;
    }
    setSyncingEbay(true);
    setError("");
    try {
      const details = await callFunction("ebayGetListingDetails")({ productId });
      setEbayListingDetails(details.data);
      setShowEbaySyncModal(true);
    } catch (e) {
      setError(`Failed to load eBay listing details: ${e.message}`);
    } finally {
      setSyncingEbay(false);
    }
  }

  async function handleApplyEbaySync(applyFrom) {
    if (!applyFrom) return;
    setApplyingEbaySync(true);
    setError("");
    try {
      await callFunction("ebaySyncListing")({ productId, applyFrom });
      setShowEbaySyncModal(false);
      setEbayListingDetails(null);
      setToast({ message: `Applied ${applyFrom === "wonni" ? "Wonni" : "eBay"} version to both platforms` });
    } catch (e) {
      setError(`Failed to sync: ${e.message}`);
    } finally {
      setApplyingEbaySync(false);
    }
  }

  async function handleEbayDeleteListing() {
    if (!product?.crossPostListingIds?.ebay) {
      setError("No eBay listing to delete.");
      return;
    }
    if (!window.confirm("Delete eBay listing? This will remove the listing from eBay.")) return;
    setDeletingEbay(true);
    setError("");
    try {
      await callFunction("ebayDeleteListing")({ productId });
      setToast({ message: "eBay listing deleted" });
    } catch (e) {
      setError(`Failed to delete eBay listing: ${e.message}`);
    } finally {
      setDeletingEbay(false);
    }
  }

  function scrollToVariants() {
    variantsSectionRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
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
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          {saving && <span style={{ fontSize: 12, color: "var(--muted)" }}>Saving…</span>}
          {!saving && lastSaveTime && <span style={{ fontSize: 12, color: "var(--muted)" }}>Saved</span>}
          {product && (
            <button ref={postButtonRef} className="btn btn-primary" onClick={() => setShowPostModal(true)}>
              📤 Post
            </button>
          )}
          {/* Mercari viewing/sync button - shown only when live on Mercari */}
          {!product?.hasVariants && (mercariStatus === "active" || mercariStatus === "updating") && (
            <button
              className="btn btn-ghost"
              onClick={handleSyncToMercari}
              disabled={syncingMercari || mercariStatus === "updating" || hasPendingMediaJobs}
              title="Sync title, description, price, and photos to Mercari listing"
            >
              {mercariStatus === "updating" ? "⏳ Syncing…" : "🔄 Sync"}
            </button>
          )}
          {/* Overflow menu with Delete and Check Mercari for sold items */}
          <OverflowMenu
            items={[
              {
                label: checkingMercariSold ? "⏳ Checking…" : "🔍 Check Mercari for sold items",
                onClick: checkMercariSoldItems,
                disabled: checkingMercariSold
              },
              ...(product?.crossPostListingIds?.ebay ? [{
                label: deletingEbay ? "⏳ Deleting…" : "🗑️ Delete eBay listing",
                onClick: handleEbayDeleteListing,
                disabled: deletingEbay,
                danger: true
              }] : []),
              {
                label: deletingProduct ? "Deleting…" : "Delete listing",
                onClick: handleDeleteProduct,
                disabled: deletingProduct,
                danger: true
              }
            ]}
          />
        </div>
      </div>

      {mercariStatus === "failed" && mercariError && (
        <div style={{ marginBottom: 12, fontSize: 12, color: "var(--danger)", textAlign: "right" }}>
          Mercari cross-post failed: {mercariError}
        </div>
      )}

      {mercariSyncMessage && (
        <div style={{ marginBottom: 12, fontSize: 12, color: "var(--muted)", textAlign: "right" }}>
          {mercariSyncMessage}
        </div>
      )}

      {mercariCheckMessage && (
        <div style={{ marginBottom: 12, fontSize: 12, color: "var(--info)", textAlign: "right" }}>
          {mercariCheckMessage}
        </div>
      )}

      {mercariPullSyncDiff && (
        <div className="card" style={{ marginBottom: 12, padding: 12, border: "1px solid var(--warning)" }}>
          <div style={{ fontWeight: 600, marginBottom: 8 }}>
            Mercari listing changes detected for "{Object.values(mercariPullSyncDiff.variant.optionValues).join(" / ") || mercariPullSyncDiff.variant.sku || "Variant"}"
          </div>
          {mercariPullSyncDiff.noChanges ? (
            <div style={{ fontSize: 12, color: "var(--muted)" }}>No changes found.</div>
          ) : (
            <>
              {mercariPullSyncDiff.diff.titleChanged && (
                <div style={{ fontSize: 12, marginBottom: 4 }}>📝 Title changed on Mercari</div>
              )}
              {mercariPullSyncDiff.diff.descriptionChanged && (
                <div style={{ fontSize: 12, marginBottom: 4 }}>📝 Description changed on Mercari</div>
              )}
              {mercariPullSyncDiff.diff.photosAdded.length > 0 && (
                <div style={{ fontSize: 12, marginBottom: 4 }}>
                  🖼️ {mercariPullSyncDiff.diff.photosAdded.length} new photo(s) on Mercari
                </div>
              )}
              {mercariPullSyncDiff.diff.photosRemoved.length > 0 && (
                <div style={{ fontSize: 12, marginBottom: 4 }}>
                  🗑️ {mercariPullSyncDiff.diff.photosRemoved.length} photo(s) removed on Mercari
                </div>
              )}
              <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                <button
                  className="btn btn-primary"
                  onClick={importMercariPullSyncChanges}
                  disabled={importingMercariChanges}
                  style={{ fontSize: 11 }}
                >
                  {importingMercariChanges ? "⏳ Importing…" : "✓ Import changes"}
                </button>
                <button
                  className="btn btn-ghost"
                  onClick={() => setMercariPullSyncDiff(null)}
                  disabled={importingMercariChanges}
                  style={{ fontSize: 11 }}
                >
                  ✕ Dismiss
                </button>
              </div>
            </>
          )}
        </div>
      )}

      {ebaySyncMessage && (
        <div style={{ marginBottom: 12, fontSize: 12, color: "var(--info, #6366f1)", textAlign: "right" }}>
          {ebaySyncMessage}
        </div>
      )}

      {ebayPullSyncDiff && (
        <div id="ebay-diff-card" className="card" style={{ marginBottom: 12, padding: 14, border: "1px solid var(--accent, #6366f1)", borderRadius: 8, background: "var(--surface)" }}>
          <div style={{ fontWeight: 600, marginBottom: 8, display: "flex", alignItems: "center", gap: 6 }}>
            <span>📦 eBay Listing Changes Detected</span>
          </div>
          {ebayPullSyncDiff.diff.length === 0 ? (
            <div style={{ fontSize: 12, color: "var(--muted)" }}>No differences found. Live eBay listing matches Wonni.</div>
          ) : (
            <>
              <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 8 }}>
                The following fields differ between your Wonni data and the live eBay listing:
              </div>
              <div style={{ overflowX: "auto" }}>
                <table style={{ width: "100%", fontSize: 12, marginBottom: 10, borderCollapse: "collapse" }}>
                  <thead>
                    <tr style={{ textAlign: "left", color: "var(--muted)", borderBottom: "1px solid var(--border)" }}>
                      <th style={{ padding: "6px 8px" }}>Field</th>
                      <th style={{ padding: "6px 8px" }}>Current Wonni Value</th>
                      <th style={{ padding: "6px 8px" }}>Live eBay Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ebayPullSyncDiff.diff.map((d, i) => (
                      <tr key={i} style={{ borderBottom: "1px solid var(--surface-hover)" }}>
                        <td style={{ padding: "6px 8px", fontWeight: 600 }}>{d.field}</td>
                        <td style={{ padding: "6px 8px", color: "var(--danger, #ef4444)" }}>{String(d.wonni || "(empty)")}</td>
                        <td style={{ padding: "6px 8px", color: "var(--success, #22c55e)", fontWeight: 600 }}>{String(d.external || "(empty)")}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                <button
                  className="btn btn-primary"
                  onClick={importEbayPullSyncChanges}
                  disabled={importingEbayChanges}
                  style={{ fontSize: 11 }}
                >
                  {importingEbayChanges ? "⏳ Applying…" : "✓ Accept edits from eBay"}
                </button>
                <button
                  className="btn btn-ghost"
                  onClick={() => setEbayPullSyncDiff(null)}
                  disabled={importingEbayChanges}
                  style={{ fontSize: 11 }}
                >
                  ✕ Dismiss
                </button>
              </div>
            </>
          )}
        </div>
      )}

      {etsySyncMessage && (
        <div style={{ marginBottom: 12, fontSize: 12, color: "var(--info, #6366f1)", textAlign: "right" }}>
          {etsySyncMessage}
        </div>
      )}

      {etsyPullSyncDiff && (
        <div id="etsy-diff-card" className="card" style={{ marginBottom: 12, padding: 14, border: "1px solid #f97316", borderRadius: 8, background: "var(--surface)" }}>
          <div style={{ fontWeight: 600, marginBottom: 8, display: "flex", alignItems: "center", gap: 6 }}>
            <span>🎨 Etsy Listing Changes Detected</span>
          </div>
          {etsyPullSyncDiff.diff.length === 0 ? (
            <div style={{ fontSize: 12, color: "var(--muted)" }}>No differences found. Live Etsy listing matches Wonni.</div>
          ) : (
            <>
              <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 8 }}>
                The following fields differ between your Wonni data and the live Etsy listing:
              </div>
              <div style={{ overflowX: "auto" }}>
                <table style={{ width: "100%", fontSize: 12, marginBottom: 10, borderCollapse: "collapse" }}>
                  <thead>
                    <tr style={{ textAlign: "left", color: "var(--muted)", borderBottom: "1px solid var(--border)" }}>
                      <th style={{ padding: "6px 8px" }}>Field</th>
                      <th style={{ padding: "6px 8px" }}>Current Wonni Value</th>
                      <th style={{ padding: "6px 8px" }}>Live Etsy Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    {etsyPullSyncDiff.diff.map((d, i) => (
                      <tr key={i} style={{ borderBottom: "1px solid var(--surface-hover)" }}>
                        <td style={{ padding: "6px 8px", fontWeight: 600 }}>{d.field}</td>
                        <td style={{ padding: "6px 8px", color: "var(--danger, #ef4444)" }}>{String(d.wonni || "(empty)")}</td>
                        <td style={{ padding: "6px 8px", color: "var(--success, #22c55e)", fontWeight: 600 }}>{String(d.external || "(empty)")}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                <button
                  className="btn btn-primary"
                  onClick={importEtsyPullSyncChanges}
                  disabled={importingEtsyChanges}
                  style={{ fontSize: 11, background: "#f97316", borderColor: "#f97316" }}
                >
                  {importingEtsyChanges ? "⏳ Applying…" : "✓ Accept edits from Etsy"}
                </button>
                <button
                  className="btn btn-ghost"
                  onClick={() => setEtsyPullSyncDiff(null)}
                  disabled={importingEtsyChanges}
                  style={{ fontSize: 11 }}
                >
                  ✕ Dismiss
                </button>
              </div>
            </>
          )}
        </div>
      )}

      {error && <div className="card" style={{ marginBottom: 20, color: "var(--danger)" }}>{error}</div>}

      {loading ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>⏳</div>
          <p>Loading imported item details…</p>
        </div>
      ) : product ? (
        <div className="product-detail">
          {/* ── Photo Tile (Full Width) ── */}
          <div className="card" style={{ marginBottom: 20 }}>
            <div className="photo-tile-container">
              {/* Large Preview (Left 50%) */}
              <div className="photo-tile-preview">
                <div
                  style={{
                    position: "relative",
                    flex: 1,
                    width: "100%",
                    aspectRatio: "1 / 1",
                    background: "#000",
                    borderRadius: 8,
                    cursor: "pointer",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    overflow: "hidden",
                  }}
                  onClick={() => setShowFullscreenPhoto(true)}
                >
                  {previewImage ? (
                    <>
                      {/* Blurred glow layer behind */}
                      <img
                        src={previewImage}
                        alt=""
                        style={{
                          position: "absolute",
                          inset: 0,
                          width: "100%",
                          height: "100%",
                          objectFit: "cover",
                          filter: "blur(40px)",
                          opacity: 0.6,
                          zIndex: 0,
                        }}
                        aria-hidden="true"
                      />
                      {/* Sharp image on top */}
                      <img
                        src={previewImage}
                        alt={product.title}
                        style={{
                          maxWidth: "100%",
                          maxHeight: "100%",
                          objectFit: "contain",
                          position: "relative",
                          zIndex: 1,
                        }}
                      />
                    </>
                  ) : (
                    <div style={{ fontSize: 13, color: "var(--muted)", zIndex: 1 }}>No image</div>
                  )}
                  {/* Edit Button in Upper Right */}
                  <button
                    className="btn btn-primary photo-tile-edit-btn"
                    style={{
                      position: "absolute",
                      top: 12,
                      right: 12,
                      display: "flex",
                      alignItems: "center",
                      gap: 4,
                      zIndex: 10,
                    }}
                    onClick={(e) => {
                      e.stopPropagation();
                      setEditingImageId(images[safePreviewIndex]?.id ?? null);
                    }}
                  >
                    ✏ Edit
                  </button>
                  {/* Counter Badge */}
                  {images.length > 0 && (
                    <div style={{
                      position: "absolute",
                      bottom: 12,
                      left: 12,
                      background: "rgba(0,0,0,0.5)",
                      color: "white",
                      padding: "4px 8px",
                      borderRadius: 4,
                      fontSize: 11,
                    }}>
                      {safePreviewIndex + 1} / {images.length}
                    </div>
                  )}
                </div>
              </div>

              {/* Thumbnail Grid (Right 50%) */}
              {(() => {
                const maxVisiblePhotos = product.crossPostStatus?.tiktok === "active" ? 9 : 12;
                const hasMorePhotos = images.length > maxVisiblePhotos;
                const isPhotoGridMinimized = hasMorePhotos && !showAllPhotos;

                return (
                  <div className="photo-tile-grid">
                    <div
                      style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 8, flex: 1, width: "100%", overflowY: "auto", alignContent: "start" }}
                      onDragOver={(e) => {
                        e.preventDefault();
                        e.dataTransfer.dropEffect = "move";
                      }}
                      onDrop={(e) => {
                        e.preventDefault();
                        if (draggingPhotoId && dragStartImagesRef.current) {
                          dragHasCommittedRef.current = true;
                          const finalImages = imagesRef.current;
                          const changed = finalImages.some((img, i) => img.id !== dragStartImagesRef.current[i]?.id);
                          if (changed) {
                            stageMediaEdit(finalImages);
                          }
                          setDraggingPhotoId(null);
                          dragStartImagesRef.current = null;
                        }
                      }}
                    >
                      {(showAllPhotos ? images : images.slice(0, maxVisiblePhotos)).map((image, index) => {
                        const actualIndex = showAllPhotos ? images.indexOf(image) : index;
                        const isActive = actualIndex === safePreviewIndex;
                        const isDraggingThis = image.id === draggingPhotoId;
                        const tagLabels = (image.variantTags ?? []).map((t) => `${t.optionName}: ${t.value}`);
                        const overLimit = Object.entries(PLATFORM_IMAGE_LIMITS)
                          .filter(([, limit]) => actualIndex >= limit)
                          .map(([name]) => name);

                        return (
                          <div
                            key={image.id}
                            style={{
                              position: "relative",
                              aspectRatio: "1 / 1",
                              borderRadius: 8,
                              overflow: "hidden",
                              cursor: savingMedia ? "default" : isDraggingThis ? "grabbing" : "grab",
                              border: isDraggingThis
                                ? "2px dashed var(--primary)"
                                : isActive
                                  ? "3px solid var(--primary)"
                                  : "1px solid var(--border)",
                              opacity: isDraggingThis ? 0.35 : overLimit.length ? 0.6 : 1,
                              transform: isDraggingThis ? "scale(0.96)" : "scale(1)",
                              transition: "transform 0.15s ease, opacity 0.15s ease, border-color 0.15s ease",
                              backgroundColor: "var(--surface-hover)",
                            }}
                            onMouseEnter={() => {
                              if (!draggingPhotoId) setPreviewIndex(actualIndex);
                            }}
                            onDragStart={(e) => {
                              if (savingMedia) return;
                              setDraggingPhotoId(image.id);
                              dragStartImagesRef.current = imagesRef.current;
                              dragHasCommittedRef.current = false;
                              e.dataTransfer.effectAllowed = "move";
                              try {
                                e.dataTransfer.setData("text/plain", image.id);
                              } catch (_) {}
                            }}
                            onDragOver={(e) => {
                              e.preventDefault();
                              e.dataTransfer.dropEffect = "move";
                              if (draggingPhotoId && draggingPhotoId !== image.id) {
                                const cur = imagesRef.current;
                                const fromIdx = cur.findIndex((img) => img.id === draggingPhotoId);
                                const toIdx = cur.findIndex((img) => img.id === image.id);
                                if (fromIdx !== -1 && toIdx !== -1 && fromIdx !== toIdx) {
                                  const next = moveItem(cur, fromIdx, toIdx);
                                  imagesRef.current = next;
                                  setImages(next);
                                  setPreviewIndex(toIdx);
                                }
                              }
                            }}
                            onDrop={(e) => {
                              e.preventDefault();
                              dragHasCommittedRef.current = true;
                              if (dragStartImagesRef.current) {
                                const finalImages = imagesRef.current;
                                const changed = finalImages.some((img, i) => img.id !== dragStartImagesRef.current[i]?.id);
                                if (changed) {
                                  stageMediaEdit(finalImages);
                                }
                              }
                              setDraggingPhotoId(null);
                              dragStartImagesRef.current = null;
                            }}
                            onDragEnd={(e) => {
                              if (!dragHasCommittedRef.current && dragStartImagesRef.current) {
                                if (e.dataTransfer.dropEffect === "none") {
                                  setImages(dragStartImagesRef.current);
                                  imagesRef.current = dragStartImagesRef.current;
                                } else {
                                  const finalImages = imagesRef.current;
                                  const changed = finalImages.some((img, i) => img.id !== dragStartImagesRef.current[i]?.id);
                                  if (changed) {
                                    stageMediaEdit(finalImages);
                                  }
                                }
                              }
                              setDraggingPhotoId(null);
                              dragStartImagesRef.current = null;
                              dragHasCommittedRef.current = false;
                            }}
                            title={overLimit.length ? `Photo #${actualIndex + 1} won't be posted to ${overLimit.join(" or ")}.` : undefined}
                            draggable={!savingMedia}
                          >
                            <img
                              src={image.url}
                              alt={`Photo ${actualIndex + 1}`}
                              style={{
                                position: "absolute",
                                top: 0,
                                left: 0,
                                width: "100%",
                                height: "100%",
                                objectFit: "cover",
                                pointerEvents: "none",
                              }}
                            />
                            {/* Tags - bottom */}
                            {tagLabels.length > 0 && (
                              <div style={{
                                position: "absolute",
                                bottom: 0,
                                left: 0,
                                right: 0,
                                background: "rgba(0,0,0,0.7)",
                                color: "white",
                                fontSize: 9,
                                padding: "2px 4px",
                                whiteSpace: "nowrap",
                                overflow: "hidden",
                                textOverflow: "ellipsis",
                                zIndex: 2,
                                pointerEvents: "none",
                              }} title={tagLabels.join(", ")}>
                                {tagLabels[0]}
                              </div>
                            )}
                          </div>
                        );
                      })}

                      {/* Upload Button Tile (only when not minimized) */}
                      {!isPhotoGridMinimized && (
                        <label style={{
                          position: "relative",
                          aspectRatio: "1 / 1",
                          display: "flex",
                          flexDirection: "column",
                          alignItems: "center",
                          justifyContent: "center",
                          borderRadius: 8,
                          border: "2px dashed var(--border)",
                          background: "rgba(255, 255, 255, 0.03)",
                          cursor: savingMedia ? "not-allowed" : "pointer",
                          transition: "all 0.15s ease",
                        }} title="Add photos to listing">
                          <input
                            type="file"
                            accept="image/*"
                            multiple
                            disabled={savingMedia}
                            style={{ display: "none" }}
                            onChange={(e) => {
                              const files = Array.from(e.target.files ?? []);
                              if (files.length > 0) handleAddPhotos(files);
                              e.target.value = "";
                            }}
                          />
                          <div style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center" }}>
                            <span style={{ fontSize: 20, fontWeight: "bold", color: "var(--primary)", lineHeight: 1 }}>+</span>
                            <span style={{ fontSize: 9, color: "var(--muted)", marginTop: 2, fontWeight: 500, textAlign: "center" }}>Add</span>
                          </div>
                        </label>
                      )}
                    </div>

                    {/* Action Row below Grid (Toggle view and Trailing Add Photo button when minimized) */}
                    {hasMorePhotos && (
                      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 12, width: "100%" }}>
                        <button
                          type="button"
                          className="btn btn-ghost"
                          style={{ fontSize: 12 }}
                          onClick={() => setShowAllPhotos(!showAllPhotos)}
                        >
                          {showAllPhotos ? "↑ Show first " + maxVisiblePhotos : "↓ View all " + images.length + " photos"}
                        </button>
                        {isPhotoGridMinimized && (
                          <label
                            className="btn btn-ghost"
                            style={{
                              fontSize: 12,
                              display: "inline-flex",
                              alignItems: "center",
                              gap: 6,
                              cursor: savingMedia ? "not-allowed" : "pointer",
                              opacity: savingMedia ? 0.5 : 1,
                              margin: 0,
                            }}
                            title="Add photos to listing"
                          >
                            <input
                              type="file"
                              accept="image/*"
                              multiple
                              disabled={savingMedia}
                              style={{ display: "none" }}
                              onChange={(e) => {
                                const files = Array.from(e.target.files ?? []);
                                if (files.length > 0) handleAddPhotos(files);
                                e.target.value = "";
                              }}
                            />
                            <span>+ Add photo</span>
                          </label>
                        )}
                      </div>
                    )}

                    {/* Media Status Messages */}
                    {mediaError && <div style={{ color: "var(--danger)", fontSize: 12, marginTop: 12 }}>{mediaError}</div>}
                    {savingMedia && <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 12 }}>Saving…</div>}
                    {activeMediaJobs.length > 0 && (
                      <div style={{ fontSize: 12, color: "#ff6b35", marginTop: 12, display: "flex", alignItems: "center", gap: 6 }}>
                        <span style={{ display: "inline-block", animation: "spin 1s linear infinite" }}>⏳</span>
                        {activeMediaJobs.some((j) => j.status === "error")
                          ? "A change failed to save"
                          : activeMediaJobs.some((j) => j.type === "split")
                            ? "Splitting image…"
                            : "Uploading photo(s)…"}
                      </div>
                    )}
                  </div>
                );
              })()}
            </div>
          </div>

          {photoPickerValue !== null && (
            <SelectPhotoModal
              images={images}
              optionName={photoPickerValue.optionName}
              value={photoPickerValue.value}
              onClose={() => setPhotoPickerValue(null)}
              onSave={(ids) => {
                linkPhotosToValue(photoPickerValue.optionName, photoPickerValue.value, ids);
                setPhotoPickerValue(null);
              }}
            />
          )}

          {/* Fullscreen Photo Modal */}
          {showFullscreenPhoto && previewImage && (
            <div
              className="modal-overlay"
              style={{ background: "rgba(0,0,0,0.9)" }}
              onClick={() => setShowFullscreenPhoto(false)}
            >
              <div
                style={{
                  position: "relative",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  width: "100%",
                  height: "100%",
                }}
                onClick={(e) => e.stopPropagation()}
              >
                <img
                  src={previewImage}
                  alt={product.title}
                  style={{ maxWidth: "90%", maxHeight: "90%", objectFit: "contain" }}
                />
                <button
                  className="btn btn-ghost"
                  style={{
                    position: "absolute",
                    top: 20,
                    right: 20,
                    color: "white",
                    fontSize: 24,
                  }}
                  onClick={() => setShowFullscreenPhoto(false)}
                >
                  ✕
                </button>
              </div>
            </div>
          )}

          {/* Title, Description & Shipping (Full Width) */}
          <div className="product-detail-panel" style={{ display: "contents" }}>
              <div className="detail-section">
                <h2>Edit catalog text</h2>
                <div className="modal-field" style={{ marginBottom: 12 }}>
                  <label>Title</label>
                  {aiSuggestedTitle !== null && (
                    <div style={{ marginBottom: 8, background: "linear-gradient(135deg, rgba(99,102,241,0.08) 0%, rgba(168,85,247,0.08) 100%)", border: "1px solid rgba(99,102,241,0.3)", borderRadius: 8, padding: "10px 12px" }}>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                        <span style={{ fontSize: 11, fontWeight: 600, color: "var(--accent, #6366f1)", letterSpacing: "0.04em" }}>✨ AI SUGGESTED</span>
                        <div style={{ display: "flex", gap: 6 }}>
                          <button className="btn btn-primary" style={{ fontSize: 11, padding: "2px 10px" }} onClick={() => { handleTitleChange(aiSuggestedTitle); setAiSuggestedTitle(null); }}>Accept</button>
                          <button className="btn btn-ghost" style={{ fontSize: 11, padding: "2px 8px" }} onClick={() => { dismissedAiTitleRef.current = true; setAiSuggestedTitle(null); }}>Discard</button>
                        </div>
                      </div>
                      <p style={{ margin: 0, fontSize: 13, lineHeight: 1.55, color: "var(--text-secondary, var(--muted))" }}>{aiSuggestedTitle}</p>
                    </div>
                  )}
                  <input className="input" value={title} onChange={(e) => handleTitleChange(e.target.value)} />
                </div>
                <div className="modal-field" style={{ marginBottom: 12 }}>
                  <label>Brand (Optional)</label>
                  {aiSuggestedBrand !== null && (
                    <div style={{ marginBottom: 8, background: "linear-gradient(135deg, rgba(99,102,241,0.08) 0%, rgba(168,85,247,0.08) 100%)", border: "1px solid rgba(99,102,241,0.3)", borderRadius: 8, padding: "10px 12px" }}>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                        <span style={{ fontSize: 11, fontWeight: 600, color: "var(--accent, #6366f1)", letterSpacing: "0.04em" }}>✨ AI SUGGESTED BRAND</span>
                        <div style={{ display: "flex", gap: 6 }}>
                          <button className="btn btn-primary" style={{ fontSize: 11, padding: "2px 10px" }} onClick={() => { handleBrandChange(aiSuggestedBrand); setAiSuggestedBrand(null); }}>Accept</button>
                          <button className="btn btn-ghost" style={{ fontSize: 11, padding: "2px 8px" }} onClick={() => setAiSuggestedBrand(null)}>Discard</button>
                        </div>
                      </div>
                      <p style={{ margin: 0, fontSize: 13, lineHeight: 1.55, color: "var(--text-secondary, var(--muted))" }}>{aiSuggestedBrand}</p>
                    </div>
                  )}
                  <input
                    className="input"
                    placeholder="e.g. BTS, Nike, Sanrio, Unbranded"
                    value={brand}
                    onChange={(e) => handleBrandChange(e.target.value)}
                  />
                </div>
                <div className="modal-field">
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 4 }}>
                    <label style={{ margin: 0 }}>Description</label>
                    <button className="btn btn-ghost" style={{ fontSize: 11, padding: "2px 8px", display: "flex", alignItems: "center", gap: 4 }} onClick={generateAIDescription} disabled={aiDescLoading}>
                      {aiDescLoading ? <><span style={{ display: "inline-block", width: 10, height: 10, border: "2px solid currentColor", borderTopColor: "transparent", borderRadius: "50%", animation: "spin 0.7s linear infinite" }} />Generating…</> : <>✨ AI Suggest</>}
                    </button>
                  </div>
                  {aiDescSuggestion !== null && (
                    <div style={{ marginBottom: 10, background: "linear-gradient(135deg, rgba(99,102,241,0.08) 0%, rgba(168,85,247,0.08) 100%)", border: "1px solid rgba(99,102,241,0.3)", borderRadius: 8, padding: "10px 12px" }}>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 6 }}>
                        <span style={{ fontSize: 11, fontWeight: 600, color: "var(--accent, #6366f1)", letterSpacing: "0.04em" }}>✨ AI SUGGESTED</span>
                        <div style={{ display: "flex", gap: 6 }}>
                          <button className="btn btn-primary" style={{ fontSize: 11, padding: "2px 10px" }} onClick={() => { handleDescriptionChange(aiDescSuggestion); setAiDescSuggestion(null); }}>Accept</button>
                          <button className="btn btn-ghost" style={{ fontSize: 11, padding: "2px 8px" }} onClick={() => { dismissedAiDescriptionRef.current = true; setAiDescSuggestion(null); }}>Discard</button>
                        </div>
                      </div>
                      <p style={{ margin: 0, fontSize: 13, lineHeight: 1.55, color: "var(--text-secondary, var(--muted))" }}>{aiDescSuggestion}</p>
                    </div>
                  )}
                  {aiDescError && <div style={{ fontSize: 12, color: "#ef4444", marginBottom: 6 }}>{aiDescError}</div>}
                  <textarea className="input" rows={8} value={description} onChange={(e) => handleDescriptionChange(e.target.value)} />
                </div>

                {/* Tags section */}
                <div className="modal-field" style={{ marginTop: 12 }}>
                  <label>Tags</label>
                  {tags.length > 0 && (
                    <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 8 }}>
                      {tags.map((tag) => (
                        <span
                          key={tag}
                          style={{
                            display: "inline-flex",
                            alignItems: "center",
                            gap: 6,
                            padding: "3px 8px",
                            background: "var(--surface-high)",
                            border: "var(--border-thin) solid var(--border)",
                            borderRadius: "var(--radius)",
                            fontSize: 12,
                            fontFamily: "'Space Mono', monospace",
                            color: "var(--text)",
                          }}
                        >
                          <span>🏷️ {tag}</span>
                          <button
                            type="button"
                            onClick={() => handleRemoveTag(tag)}
                            style={{
                              background: "transparent",
                              border: "none",
                              color: "var(--muted)",
                              cursor: "pointer",
                              padding: "0 2px",
                              fontSize: 12,
                              lineHeight: 1,
                            }}
                            title={`Remove ${tag}`}
                          >
                            ✕
                          </button>
                        </span>
                      ))}
                    </div>
                  )}
                  <div style={{ position: "relative", display: "flex", gap: 8 }}>
                    <input
                      className="input"
                      placeholder="Add a tag (e.g. K-Pop, Photocard, Winter)..."
                      value={tagInput}
                      onChange={(e) => {
                        setTagInput(e.target.value);
                        setShowTagSuggestions(true);
                      }}
                      onFocus={() => setShowTagSuggestions(true)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") {
                          e.preventDefault();
                          handleAddTag(tagInput);
                        } else if (e.key === "Escape") {
                          setShowTagSuggestions(false);
                        }
                      }}
                      style={{ flex: 1 }}
                    />
                    <button
                      type="button"
                      className="btn btn-secondary"
                      style={{ fontSize: 12, padding: "6px 14px", whiteSpace: "nowrap" }}
                      onClick={() => handleAddTag(tagInput)}
                      disabled={!tagInput.trim()}
                    >
                      Add Tag
                    </button>

                    {showTagSuggestions && tagInput.trim() && (
                      (() => {
                        const matchingSuggestions = allUserTags.filter(
                          (t) =>
                            t.toLowerCase().includes(tagInput.trim().toLowerCase()) &&
                            !tags.includes(t)
                        );
                        if (matchingSuggestions.length === 0) return null;
                        return (
                          <div
                            style={{
                              position: "absolute",
                              top: "100%",
                              left: 0,
                              right: 90,
                              background: "var(--surface)",
                              border: "var(--border-thin) solid var(--border)",
                              borderRadius: "var(--radius)",
                              marginTop: 4,
                              maxHeight: 180,
                              overflowY: "auto",
                              zIndex: 30,
                              boxShadow: "0 4px 12px rgba(0, 0, 0, 0.4)",
                            }}
                          >
                            {matchingSuggestions.map((st) => (
                              <div
                                key={st}
                                style={{
                                  padding: "8px 12px",
                                  fontSize: 13,
                                  cursor: "pointer",
                                  display: "flex",
                                  alignItems: "center",
                                  gap: 8,
                                  borderBottom: "1px solid var(--surface-high)",
                                }}
                                onMouseDown={(e) => {
                                  e.preventDefault();
                                  handleAddTag(st);
                                }}
                              >
                                <span style={{ color: "var(--primary)" }}>🏷️</span> {st}
                              </div>
                            ))}
                          </div>
                        );
                      })()
                    )}
                  </div>
                </div>

                <div style={{ display: "flex", gap: 12, alignItems: "center", marginTop: 12 }}>
                  <span style={{ fontSize: 12, color: "var(--muted)" }}>Listings use these as the base catalog fields.</span>
                </div>
              </div>

              <div className="detail-badges">
                {product.crossPostStatus?.wonni === "active" && (
                  <span
                    className="chip chip-active"
                    style={{ cursor: "pointer" }}
                    onClick={() => {
                      const url = getPlatformListingUrl("wonni", product);
                      if (url) {
                        if (url.startsWith("http")) window.open(url, "_blank", "noopener,noreferrer");
                        else navigate(url);
                      }
                    }}
                    title="Click to view on Wonni"
                  >
                    Wonni: Active ↗
                  </span>
                )}
                {(product.crossPostStatus?.ebay === "active" || product.crossPostStatus?.ebay === "posted") && (
                  <div style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                    <span
                      className="chip chip-active"
                      style={{ cursor: "pointer" }}
                      onClick={() => {
                        const url = getPlatformListingUrl("ebay", product);
                        if (url) window.open(url, "_blank", "noopener,noreferrer");
                      }}
                      title="Click to open live eBay listing"
                    >
                      eBay: Live ↗
                    </span>
                    <button
                      className="btn btn-ghost"
                      style={{ fontSize: 11, padding: "2px 10px", borderRadius: 12, cursor: "pointer" }}
                      onClick={handleEbaySyncListing}
                      disabled={syncingEbay}
                      title="Sync between Wonni and eBay"
                    >
                      {syncingEbay ? "⏳ Syncing…" : "↻ Sync"}
                    </button>
                    {ebayPullSyncDiff?.hasDrift && (
                      <button
                        className="btn btn-warning"
                        style={{
                          fontSize: 11,
                          padding: "2px 10px",
                          borderRadius: 12,
                          background: "rgba(245, 158, 11, 0.15)",
                          color: "#f59e0b",
                          border: "1px solid #f59e0b",
                          fontWeight: 600,
                          cursor: "pointer"
                        }}
                        onClick={() => {
                          const diffEl = document.getElementById("ebay-diff-card");
                          if (diffEl) diffEl.scrollIntoView({ behavior: "smooth" });
                        }}
                        title="Click to view and accept edits from eBay"
                      >
                        ⚠️ Accept edits from eBay ({ebayPullSyncDiff.diff.length})
                      </button>
                    )}
                  </div>
                )}
                {(product.crossPostStatus?.etsy === "active" || product.crossPostStatus?.etsy === "posted") && (
                  <div style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                    <span
                      className="chip chip-active"
                      style={{ cursor: "pointer" }}
                      onClick={() => {
                        const url = getPlatformListingUrl("etsy", product);
                        if (url) window.open(url, "_blank", "noopener,noreferrer");
                      }}
                      title="Click to open live Etsy listing"
                    >
                      Etsy: Active ↗
                    </span>
                    {etsyPullSyncDiff?.hasDrift && (
                      <button
                        className="btn btn-warning"
                        style={{
                          fontSize: 11,
                          padding: "2px 10px",
                          borderRadius: 12,
                          background: "rgba(249, 115, 22, 0.15)",
                          color: "#f97316",
                          border: "1px solid #f97316",
                          fontWeight: 600,
                          cursor: "pointer"
                        }}
                        onClick={() => {
                          const diffEl = document.getElementById("etsy-diff-card");
                          if (diffEl) diffEl.scrollIntoView({ behavior: "smooth" });
                        }}
                        title="Click to view and accept edits from Etsy"
                      >
                        ⚠️ Accept edits from Etsy ({etsyPullSyncDiff.diff.length})
                      </button>
                    )}
                  </div>
                )}
                {product.crossPostStatus?.tiktok === "active" && (
                  <span
                    className="chip chip-active"
                    style={{ cursor: "pointer" }}
                    onClick={() => {
                      const url = getPlatformListingUrl("tiktok", product);
                      if (url) window.open(url, "_blank", "noopener,noreferrer");
                    }}
                    title="Click to open TikTok listing"
                  >
                    TikTok: Active ↗
                  </span>
                )}
                {product?.hasVariants ? (
                  mercariPostedVariants.length > 0 || variants.some((v) => v.mercariError) ? (
                    <button
                      className={`chip ${variants.some((v) => v.mercariError) ? "chip-pending" : "chip-active"}`}
                      style={{ border: "none", cursor: "pointer" }}
                      onClick={scrollToVariants}
                      title="Click to view variants"
                    >
                      {variants.some((v) => v.mercariError) ? "⚠️ Mercari" : `Mercari: ${mercariPostedVariants.length}/${mercariInStockVariants.length} Active`}
                    </button>
                  ) : null
                ) : (
                  mercariStatus === "active" || mercariStatus === "failed" || mercariError ? (
                    <span
                      className={`chip ${mercariStatus === "failed" || mercariError ? "chip-pending" : mercariStatus === "active" ? "chip-active" : (mercariStatus === "posting" || mercariStatus === "updating") ? "chip-pending" : "chip-draft"}`}
                      style={{ cursor: mercariStatus === "active" ? "pointer" : "default" }}
                      onClick={() => {
                        if (mercariStatus === "active") {
                          const url = getPlatformListingUrl("mercari", product);
                          if (url) window.open(url, "_blank", "noopener,noreferrer");
                        }
                      }}
                      title={mercariStatus === "active" ? "Click to open live Mercari listing" : undefined}
                    >
                      {mercariStatus === "failed" || mercariError ? "⚠️ Mercari" : `Mercari: ${mercariStatus} ↗`}
                    </span>
                  ) : null
                )}
              </div>

              {/* Mercari URL field for non-variant products */}
              {!product?.hasVariants && mercariStatus && (
                <div className="modal-field" style={{ marginTop: 12, marginBottom: 8, maxWidth: 300 }}>
                  <div style={{ fontSize: 12, display: "flex", alignItems: "center", gap: 4 }}>
                    <span>✏️ Mercari listing URL</span>
                  </div>
                  <input
                    className="input"
                    type="text"
                    placeholder="https://www.mercari.com/sell/item/m..."
                    value={mercariUrl || ""}
                    onChange={(e) => {
                      const url = e.target.value;
                      markFieldsDirty({ "listingUrl.mercari": url || null });
                    }}
                    onBlur={(e) => {
                      const url = e.target.value.trim();
                      if (url) {
                        const id = url.match(/item\/([a-z0-9]+)/i)?.[1];
                        if (id) {
                          markFieldsDirty({ "listingId.mercari": id });
                        }
                      } else {
                        markFieldsDirty({ "listingUrl.mercari": null, "listingId.mercari": null });
                      }
                    }}
                    style={{ fontSize: 12 }}
                  />
                  <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 4 }}>
                    Paste the Mercari listing URL. Leave empty to unlink. Mercari ID is auto-extracted.
                  </div>
                </div>
              )}

              <div className="modal-field" style={{ marginTop: 8, marginBottom: 8, maxWidth: 200 }}>
                <label>Listing price</label>
                {aiSuggestedPrice !== null && (
                  <div style={{
                    marginBottom: 6,
                    display: "flex",
                    alignItems: "center",
                    gap: 6,
                    fontSize: 11,
                    color: "var(--accent, #6366f1)",
                  }}>
                    <span>✨ AI suggests ${aiSuggestedPrice.toFixed(2)}</span>
                    <button
                      className="btn btn-ghost"
                      style={{ fontSize: 11, padding: "1px 6px" }}
                      onClick={() => {
                        handleListingPriceChange(String(aiSuggestedPrice));
                        setAiSuggestedPrice(null);
                      }}
                    >
                      Use
                    </button>
                    <button
                      className="btn btn-ghost"
                      style={{ fontSize: 11, padding: "1px 6px" }}
                      onClick={() => { dismissedAiPriceRef.current = true; setAiSuggestedPrice(null); }}
                    >
                      Dismiss
                    </button>
                  </div>
                )}
                <input
                  className="input"
                  type="number"
                  step="0.01"
                  min="0"
                  placeholder="(not set)"
                  value={listingPrice ?? ""}
                  onChange={(e) => handleListingPriceChange(e.target.value)}
                />
              </div>

              <div style={{ marginBottom: 8 }}>
                <label style={{ fontSize: 11, color: "var(--muted)" }}>Source price (cost) - optional</label>
                <DollarInput
                  style={{ maxWidth: 120, marginTop: 2 }}
                  value={sourcePriceInput}
                  onChangeText={setSourcePriceInput}
                  onCommit={(raw) => {
                    const trimmed = raw.trim();
                    const parsed = trimmed === "" ? null : Number(trimmed);
                    const normalized = parsed != null && Number.isNaN(parsed) ? null : parsed;
                    setSourcePriceInput(normalized != null ? String(normalized) : "");
                    handleSourcePriceChange(normalized === null ? "" : String(normalized));
                  }}
                />
              </div>

              {/* ── Draft Shipping Weight & Package Dimensions Section ── */}
              <div className="detail-section" style={{ background: "var(--surface-hover)", padding: 14, borderRadius: 8, gridColumn: "1 / -1", width: "100%" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                  <h2 style={{ margin: 0, fontSize: 14 }}>Shipping Weight & Package Dimensions</h2>
                  <button className="btn btn-ghost" style={{ fontSize: 11, padding: "2px 6px" }} onClick={applyAIShipping}>
                    ✨ Apply AI Suggested
                  </button>
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 10 }}>
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Weight (Pounds)</label>
                    <input className="input" type="number" min="0" value={weightLbs} onChange={(e) => handleWeightLbsChange(e.target.value)} />
                  </div>
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Weight (Ounces)</label>
                    <input className="input" type="number" min="0" max="15" value={weightOz} onChange={(e) => handleWeightOzChange(e.target.value)} />
                  </div>
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 8, marginBottom: 10 }}>
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Length (in)</label>
                    <input className="input" type="number" min="0" placeholder="10" value={lengthIn} onChange={(e) => handleLengthInChange(e.target.value)} />
                  </div>
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Width (in)</label>
                    <input className="input" type="number" min="0" placeholder="6" value={widthIn} onChange={(e) => handleWidthInChange(e.target.value)} />
                  </div>
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Height (in)</label>
                    <input className="input" type="number" min="0" placeholder="4" value={heightIn} onChange={(e) => handleHeightInChange(e.target.value)} />
                  </div>
                </div>
                <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 12 }}>
                  <span style={{ fontSize: 11, color: "var(--muted)" }}>
                    Used for Mercari prepaid labels & weight calculations.
                  </span>
                </div>

                {/* Shared with iOS's own shipping-config fields (buyerPaysShipping/
                    handlingFee/estimatedShippingDays/handlingTimeDays) — distinct from
                    the Mercari cross-post modal's own mercariBuyerPaysShipping, which
                    is a per-platform override of this general default. */}
                <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, marginBottom: 10 }}>
                  <input
                    type="checkbox"
                    checked={buyerPaysShipping}
                    onChange={(e) => handleBuyerPaysShippingChange(e.target.checked)}
                  />
                  Buyer pays shipping
                </label>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 8 }}>
                  {!buyerPaysShipping && (
                    <div className="modal-field">
                      <label style={{ fontSize: 11 }}>Handling fee ($)</label>
                      <input className="input" type="number" min="0" step="0.01" value={handlingFee} onChange={(e) => handleHandlingFeeChange(e.target.value)} />
                    </div>
                  )}
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Est. shipping days</label>
                    <input className="input" type="number" min="1" value={estimatedShippingDays} onChange={(e) => handleEstimatedShippingDaysChange(e.target.value)} />
                  </div>
                  <div className="modal-field">
                    <label style={{ fontSize: 11 }}>Handling time</label>
                    <select
                      className="input"
                      value={handlingTimeDays}
                      onChange={(e) => handleHandlingTimeDaysChange(e.target.value)}
                      style={{ width: "100%", background: "var(--surface)", color: "var(--text)" }}
                    >
                      <option value={0}>Same Business Day (0 days)</option>
                      <option value={1}>1 Business Day</option>
                      <option value={2}>2 Business Days</option>
                      <option value={3}>3 Business Days</option>
                      <option value={5}>5 Business Days (1 week)</option>
                      <option value={10}>10 Business Days (2 weeks)</option>
                      <option value={15}>15 Business Days (3 weeks)</option>
                      <option value={20}>20 Business Days (4 weeks)</option>
                      <option value={30}>30 Business Days (6 weeks — eBay max)</option>
                      <option value={40}>40 Business Days (8 weeks — Etsy pre-order)</option>
                      <option value={50}>50 Business Days (10 weeks — Etsy max)</option>
                    </select>
                  </div>
                </div>
              </div>

            </div>

          {legacyMigrationPending && (
            <div className="legacy-variant-banner">
              Legacy variant data detected — editing any field below migrates it to the new format
              automatically, or{" "}
              <button className="btn btn-ghost" style={{ padding: "2px 8px", fontSize: 12 }} onClick={commitVariantsNow}>
                migrate now
              </button>
              . Nothing is written until then.
            </div>
          )}

          <div ref={variantsSectionRef}>
            <VariantsEditor
              options={options}
              variants={variants}
              images={images}
              listingPrice={listingPrice}
              onOptionsChange={handleOptionsChange}
              onVariantFieldChange={updateVariantField}
              onBulkFieldChange={bulkSetFieldForPrimaryValue}
              onBulkSetActive={bulkSetActive}
              onMergeUnmatched={mergeUnmatchedInto}
              onDiscardUnmatched={discardUnmatched}
              onReactivateVariant={reactivateVariant}
              onDeleteVariantPermanently={deleteVariantPermanently}
              onOpenPhotoPicker={requestPhotoPicker}
              onCommit={commitVariantsNow}
              saving={savingVariants}
              error={variantsError}
            />
          </div>

          {/* Source Section */}
          <div className="card" style={{ marginBottom: 20 }}>
            <div style={{ padding: 20 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16, gap: 8, flexWrap: "wrap" }}>
                <h2 style={{ margin: 0 }}>Source</h2>
                <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
                  <span className="chip chip-draft">{badgeLabel(product.source)}</span>
                  {variants.some((v) => !v.active) && (
                    <span className="chip chip-pending" title={`${variants.filter((v) => !v.active).length} out of stock`}>
                      📦 {variants.filter((v) => !v.active).length}/{variants.length} OOS
                    </span>
                  )}
                </div>
              </div>

              {/* Source URL */}
              <div className="modal-field" style={{ marginBottom: 16 }}>
                <label>Source URL</label>
                {product.sourceUrl ? (
                  <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                    <a href={product.sourceUrl} target="_blank" rel="noreferrer" style={{ fontSize: 13, color: "var(--primary)", wordBreak: "break-all" }}>
                      {product.sourceUrl}
                    </a>
                  </div>
                ) : (
                  <input
                    className="input"
                    type="text"
                    placeholder="Add source URL"
                    value={product.sourceUrl || ""}
                    onChange={(e) => handleSourceUrlChange(e.target.value)}
                  />
                )}
              </div>

              {/* Expandable Images */}
              <div style={{ marginBottom: 16, borderTop: "1px solid var(--border)", paddingTop: 16 }}>
                <button
                  className="btn btn-ghost"
                  style={{ fontSize: 13, padding: "6px 0", cursor: "pointer", display: "flex", alignItems: "center", gap: 6 }}
                  onClick={() => refreshSourceData("images")}
                  disabled={!product.sourceUrl || sourceRefreshLoading}
                >
                  {expandedSourceSection === "images" ? "▼" : "▶"} Images ({images.length})
                </button>
                {expandedSourceSection === "images" && sourceRefreshLoading && (
                  <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 8 }}>Loading source images…</div>
                )}
                {expandedSourceSection === "images" && !sourceRefreshLoading && sourceImages.length > 0 && (
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 8, marginTop: 12 }}>
                    {sourceImages.map((img, idx) => (
                      <img
                        key={idx}
                        src={img.url}
                        alt={`Source image ${idx + 1}`}
                        style={{ width: "100%", aspectRatio: "1", objectFit: "cover", borderRadius: 8, cursor: "pointer" }}
                        title={`Click to add to listing`}
                      />
                    ))}
                  </div>
                )}
              </div>

              {/* Expandable Variants */}
              <div style={{ marginBottom: 16, borderTop: "1px solid var(--border)", paddingTop: 16 }}>
                <button
                  className="btn btn-ghost"
                  style={{ fontSize: 13, padding: "6px 0", cursor: "pointer", display: "flex", alignItems: "center", gap: 6 }}
                  onClick={() => refreshSourceData("variants")}
                  disabled={!product.sourceUrl || sourceRefreshLoading}
                >
                  {expandedSourceSection === "variants" ? "▼" : "▶"} Variants ({variants.filter((v) => v.active).length})
                </button>
                {expandedSourceSection === "variants" && sourceRefreshLoading && (
                  <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 8 }}>Loading source variants…</div>
                )}
                {expandedSourceSection === "variants" && !sourceRefreshLoading && sourceVariants.length > 0 && (
                  <div style={{ fontSize: 12, marginTop: 12, lineHeight: 1.6, fontFamily: "monospace", whiteSpace: "pre-wrap" }}>
                    {sourceVariants.map((v, idx) => (
                      <div key={idx}>{v}</div>
                    ))}
                  </div>
                )}
              </div>

              {/* Source Info Table */}
              {infoTable.length > 0 && (
                <div style={{ borderTop: "1px solid var(--border)", paddingTop: 16 }}>
                  <h3 style={{ margin: "0 0 12px 0", fontSize: 13 }}>Source Info</h3>
                  <div className="variant-list">
                    {infoTable.map((row, index) => (
                      <div key={`${row.label}-${index}`} className="variant-row" style={{ gap: 16 }}>
                        <div style={{ minWidth: 180 }}><strong style={{ fontSize: 12 }}>{row.label}</strong></div>
                        <div style={{ flex: 1 }}><span style={{ fontSize: 12, whiteSpace: "pre-wrap" }}>{row.value}</span></div>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
      ) : null}

      {/* Legacy Mercari Link Modal */}
      {showLegacyMercariLinkModal && (
        <div className="modal-overlay" onClick={() => setShowLegacyMercariLinkModal(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <h2>Link Mercari Listing</h2>
              <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={() => setShowLegacyMercariLinkModal(false)}>✕</button>
            </div>
            <div className="modal-body">
              <div className="modal-field">
                <label>Mercari URL or Item ID</label>
                <input
                  type="text"
                  className="input"
                  placeholder="Paste URL (e.g., mercari.com/us/item/m123...) or item ID (e.g., m123abc...)"
                  value={legacyMercariLinkInput}
                  onChange={(e) => {
                    setLegacyMercariLinkInput(e.target.value);
                    setLegacyMercariLinkError("");
                  }}
                />
                {legacyMercariLinkError && (
                  <div style={{ fontSize: 12, color: "var(--danger)", marginTop: 4 }}>{legacyMercariLinkError}</div>
                )}
              </div>
            </div>
            <div className="modal-footer">
              <button className="btn btn-ghost" onClick={() => setShowLegacyMercariLinkModal(false)}>Cancel</button>
              <button
                className="btn btn-primary"
                onClick={async () => {
                  setLegacyMercariLinkError("");
                  setLegacyMercariLinkLoading(true);
                  try {
                    await linkLegacyMercariListing(legacyMercariLinkInput);
                    setShowLegacyMercariLinkModal(false);
                    setLegacyMercariLinkInput("");
                  } catch (err) {
                    setLegacyMercariLinkError(err.message ?? "Failed to link listing.");
                  } finally {
                    setLegacyMercariLinkLoading(false);
                  }
                }}
                disabled={legacyMercariLinkLoading || !legacyMercariLinkInput.trim()}
              >
                {legacyMercariLinkLoading ? "Linking…" : "Link"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Mercari Cross-Post Modal */}
      {showMercariModal && product && (
        <MercariModal
          product={product}
          weightLbs={weightLbs}
          weightOz={weightOz}
          lengthIn={lengthIn}
          widthIn={widthIn}
          heightIn={heightIn}
          hasPendingMediaJobs={hasPendingMediaJobs}
          options={options}
          images={images}
          variants={variants}
          mercariTitleTokens={mercariTitleTokens}
          mercariTitleGaps={mercariTitleGaps}
          mercariPhotoTemplate={mercariPhotoTemplate}
          onTokensChange={persistMercariTitleTokens}
          onGapsChange={persistMercariTitleGaps}
          onPhotoTemplateChange={persistMercariPhotoTemplate}
          onSettingsChange={persistMercariModalSettings}
          onPostVariant={postVariantToMercari}
          onSyncVariant={syncVariantToMercari}
          onDeleteVariant={resetVariantMercariListing}
          onPostAllRemaining={postAllRemainingVariants}
          postingAllVariants={postingAllVariants}
          onRemoveVariantPhoto={removeVariantMercariPhoto}
          onClose={() => setShowMercariModal(false)}
          onLaunched={() => setShowMercariModal(false)}
        />
      )}

      {/* Post to Platforms Popover (Phase 4) */}
      {showPostModal && product && (
        <PostModal
          product={product}
          onClose={() => setShowPostModal(false)}
          mode="popover"
          buttonRef={postButtonRef}
        />
      )}

      {/* Image edit modal */}
      {editingIndex !== null && images[editingIndex] && (
        <ImageEditModal
          image={images[editingIndex]}
          index={editingIndex}
          total={images.length}
          productId={productId}
          onClose={() => setEditingImageId(null)}
          onDelete={() => handleDeleteImage(editingIndex)}
          onSetCover={() => handleSetCover(editingIndex)}
          onSaveCrop={handleSaveCrop}
          onSaveIdentify={handleSaveIdentify}
          onSaveSplit={handleSaveSplit}
          saving={savingMedia}
          splitInProgress={activeSplitUrls.has(images[editingIndex]?.url)}
        />
      )}

      {toast && <ActionToast message={toast.message} actions={toast.actions} onDismiss={() => setToast(null)} />}

      {/* Apply Mercari edits prompt */}
      <ApplyMercariEditsModal
        hasDrift={showApplyMercariEditsModal}
        onApplyEdits={handleApplyMercariEdits}
        onDontChange={handleDontChangeMercari}
        applying={applyingMercariEdits}
      />

      {showEbaySyncModal && (
        <ApplyEbayEditsModal
          product={product}
          listingDetails={ebayListingDetails}
          onApply={handleApplyEbaySync}
          onCancel={() => {
            setShowEbaySyncModal(false);
            setEbayListingDetails(null);
          }}
          isLoading={applyingEbaySync}
        />
      )}
    </Layout>
  );
}

class DetailErrorBoundary extends Component {
  state = { hasError: false, error: null };
  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }
  componentDidCatch(error, errorInfo) {
    console.error("ProductDetail ErrorBoundary caught an error:", error, errorInfo);
  }
  render() {
    if (this.state.hasError) {
      return (
        <Layout>
          <div className="card" style={{ margin: "40px auto", maxWidth: 600, padding: 24, textAlign: "center" }}>
            <h2>⚠️ Could not load product details</h2>
            <p style={{ color: "var(--danger)", margin: "12px 0" }}>
              {this.state.error?.message ?? "An unexpected error occurred."}
            </p>
            <button className="btn btn-primary" onClick={() => window.location.reload()}>
              Reload page
            </button>
          </div>
        </Layout>
      );
    }
    return this.props.children;
  }
}

export default function ProductDetailWithErrorBoundary() {
  return (
    <DetailErrorBoundary>
      <ProductDetail />
    </DetailErrorBoundary>
  );
}
