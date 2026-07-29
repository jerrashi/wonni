import { useState, useRef, useEffect } from "react";
import { collection, addDoc, serverTimestamp } from "firebase/firestore";
import { useNavigate } from "react-router-dom";
import { db, auth, callFunction, uploadFileToStorage } from "../firebase";

// Helper to convert a File object to Data URL
function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

// Helper to load HTMLImageElement from src
function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = src;
  });
}

export default function CreateDraftModal({ onClose, onCreated }) {
  const navigate = useNavigate();
  const uid = auth.currentUser?.uid;

  // ── Mode & File State ───────────────────────────────────────────────────────
  const [mode, setMode] = useState("single"); // "single" | "split"
  const [files, setFiles] = useState([]); // Array of File objects
  const [filePreviews, setFilePreviews] = useState([]); // Array of { id, file, url, dataUrl }
  const [targetPhotoIndex, setTargetPhotoIndex] = useState(0); // Selected file index for split mode
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  // ── Single Draft Form State ──────────────────────────────────────────────────
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [costPrice, setCostPrice] = useState("");
  const [sellPrice, setSellPrice] = useState("");
  const [variants, setVariants] = useState([]); // [{ name: "Red", price: 19.99, imageId: "" }]

  // ── Photo Split State ───────────────────────────────────────────────────────
  const [splitMethod, setSplitMethod] = useState("grid"); // "grid" | "horizontal" | "ai"
  const [gridRows, setGridRows] = useState(3);
  const [gridCols, setGridCols] = useState(3);
  const [horizontalCutPcts, setHorizontalCutPcts] = useState([33, 66]); // Percentages 0..100
  const [boxes, setBoxes] = useState([]); // [{ id, label, price, box: [ymin, xmin, ymax, xmax] }] (0..1000 scale)
  const [selectedBoxId, setSelectedBoxId] = useState(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [batchBaseCost, setBatchBaseCost] = useState("");
  const [batchBaseSell, setBatchBaseSell] = useState("");
  const [splitItemDetails, setSplitItemDetails] = useState({}); // boxId -> { title, costPrice, sellPrice }

  // Canvas ref for split editor
  const canvasRef = useRef(null);
  const imageObjRef = useRef(null);
  const [dragState, setDragState] = useState(null); // { boxId, handle: 'move'|'tl'|'tr'|'bl'|'br', startPos, startBox }

  // ── Handle File Selection ────────────────────────────────────────────────────
  async function handleFileSelect(e) {
    const selectedFiles = Array.from(e.target.files || []);
    if (!selectedFiles.length) return;

    const newPreviews = await Promise.all(
      selectedFiles.map(async (file, idx) => {
        const dataUrl = await fileToDataUrl(file);
        return {
          id: `file-${Date.now()}-${idx}-${Math.random().toString(36).substr(2, 5)}`,
          file,
          dataUrl,
        };
      })
    );

    setFilePreviews((prev) => [...prev, ...newPreviews]);
    setFiles((prev) => [...prev, ...selectedFiles]);
    if (!title && selectedFiles[0]) {
      // Auto-name title from file name without extension
      const name = selectedFiles[0].name.replace(/\.[^/.]+$/, "").replace(/[-_]/g, " ");
      setTitle(name.charAt(0).toUpperCase() + name.slice(1));
    }
  }

  function removeFile(index) {
    setFilePreviews((prev) => prev.filter((_, i) => i !== index));
    setFiles((prev) => prev.filter((_, i) => i !== index));
    if (targetPhotoIndex >= filePreviews.length - 1) {
      setTargetPhotoIndex(Math.max(0, filePreviews.length - 2));
    }
  }

  function moveFile(from, to) {
    if (to < 0 || to >= filePreviews.length) return;
    const updated = [...filePreviews];
    const [item] = updated.splice(from, 1);
    updated.splice(to, 0, item);
    setFilePreviews(updated);
  }

  // ── Variation Helpers ────────────────────────────────────────────────────────
  function addVariant() {
    setVariants((prev) => [
      ...prev,
      {
        id: `var-${Date.now()}-${prev.length}`,
        name: `Option ${prev.length + 1}`,
        price: parseFloat(sellPrice) || 0,
        costPrice: parseFloat(costPrice) || 0,
        imageId: filePreviews[0]?.id ?? "",
      },
    ]);
  }

  function updateVariant(index, field, value) {
    setVariants((prev) => {
      const copy = [...prev];
      copy[index] = { ...copy[index], [field]: value };
      return copy;
    });
  }

  function removeVariant(index) {
    setVariants((prev) => prev.filter((_, i) => i !== index));
  }

  // ── Split Grid Generator ─────────────────────────────────────────────────────
  function generateGridBoxes(rows = gridRows, cols = gridCols) {
    const r = Math.max(1, Math.min(10, parseInt(rows) || 1));
    const c = Math.max(1, Math.min(10, parseInt(cols) || 1));
    const rowH = 1000 / r;
    const colW = 1000 / c;
    const newBoxes = [];
    let count = 1;

    for (let i = 0; i < r; i++) {
      for (let j = 0; j < c; j++) {
        const ymin = Math.round(i * rowH);
        const ymax = Math.round((i + 1) * rowH);
        const xmin = Math.round(j * colW);
        const xmax = Math.round((j + 1) * colW);
        const id = `box-${count}`;
        newBoxes.push({
          id,
          label: `Item #${count}`,
          box: [ymin, xmin, ymax, xmax],
        });
        count++;
      }
    }
    setBoxes(newBoxes);
  }

  // Generate boxes on mode switch or initial grid load
  useEffect(() => {
    if (mode === "split" && boxes.length === 0 && filePreviews.length > 0) {
      generateGridBoxes(gridRows, gridCols);
    }
  }, [mode, filePreviews]);

  // ── AI Auto-Detection (Gemini Vision) ────────────────────────────────────────
  async function runAiDetection() {
    const activePhoto = filePreviews[targetPhotoIndex];
    if (!activePhoto) {
      setError("Please upload a photo first.");
      return;
    }
    setAiLoading(true);
    setError("");
    try {
      const res = await callFunction("identifyProductsInImage")({
        imageBase64: activePhoto.dataUrl,
      });
      const detected = res.data?.objects ?? [];
      if (!detected.length) {
        setError("AI could not identify specific items in this image. Try grid split instead.");
      } else {
        setBoxes(
          detected.map((obj, idx) => ({
            id: obj.id ?? `ai-box-${idx + 1}`,
            label: obj.label || `Detected Item #${idx + 1}`,
            price: obj.price ?? null,
            box: obj.box,
          }))
        );
        // Pre-fill item details if price or label extracted
        const newDetails = {};
        detected.forEach((obj, idx) => {
          const key = obj.id ?? `ai-box-${idx + 1}`;
          newDetails[key] = {
            title: obj.label || `Item #${idx + 1}`,
            sellPrice: obj.price ? String(obj.price) : "",
          };
        });
        setSplitItemDetails((prev) => ({ ...prev, ...newDetails }));
      }
    } catch (e) {
      setError(e.message ?? "AI item detection failed.");
    } finally {
      setAiLoading(false);
    }
  }

  // ── Canvas Rendering for Split Mode Editor ──────────────────────────────────
  const activePhotoUrl = filePreviews[targetPhotoIndex]?.dataUrl;

  useEffect(() => {
    if (mode !== "split" || !activePhotoUrl || !canvasRef.current) return;
    let isCancelled = false;

    loadImage(activePhotoUrl).then((img) => {
      if (isCancelled) return;
      imageObjRef.current = img;
      const canvas = canvasRef.current;
      const ctx = canvas.getContext("2d");

      // Set canvas dimension based on image aspect ratio
      const maxW = 680;
      const scale = Math.min(1, maxW / img.width);
      canvas.width = img.width * scale;
      canvas.height = img.height * scale;

      drawCanvasContent(ctx, canvas, img, boxes, horizontalCutPcts, splitMethod, selectedBoxId);
    });

    return () => {
      isCancelled = true;
    };
  }, [mode, activePhotoUrl, boxes, horizontalCutPcts, splitMethod, selectedBoxId]);

  function drawCanvasContent(ctx, canvas, img, boxList, cutPcts, currentMethod, activeBoxId) {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

    const w = canvas.width;
    const h = canvas.height;

    if (currentMethod === "horizontal") {
      // Draw horizontal cut lines
      const sortedPcts = [0, ...cutPcts.slice().sort((a, b) => a - b), 100];
      for (let i = 0; i < sortedPcts.length - 1; i++) {
        const topY = (sortedPcts[i] / 100) * h;
        const botY = (sortedPcts[i + 1] / 100) * h;
        ctx.fillStyle = i % 2 === 0 ? "rgba(99, 102, 241, 0.08)" : "rgba(16, 185, 129, 0.08)";
        ctx.fillRect(0, topY, w, botY - topY);

        ctx.fillStyle = "#ffffff";
        ctx.font = "bold 12px sans-serif";
        ctx.fillText(`Slice #${i + 1}`, 12, topY + (botY - topY) / 2 + 4);
      }

      cutPcts.forEach((pct, idx) => {
        const y = (pct / 100) * h;
        ctx.strokeStyle = "#ef4444";
        ctx.lineWidth = 2;
        ctx.setLineDash([6, 4]);
        ctx.beginPath();
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
        ctx.stroke();
        ctx.setLineDash([]);

        ctx.fillStyle = "#ef4444";
        ctx.fillRect(w / 2 - 24, y - 10, 48, 20);
        ctx.fillStyle = "#ffffff";
        ctx.font = "bold 11px sans-serif";
        ctx.textAlign = "center";
        ctx.fillText(`✂ ${idx + 1}`, w / 2, y + 4);
        ctx.textAlign = "left";
      });
    } else {
      // Grid or AI Bounding Boxes
      boxList.forEach((item) => {
        const [ymin, xmin, ymax, xmax] = item.box;
        const boxX = (xmin / 1000) * w;
        const boxY = (ymin / 1000) * h;
        const boxW = ((xmax - xmin) / 1000) * w;
        const boxH = ((ymax - ymin) / 1000) * h;

        const isSelected = item.id === activeBoxId;

        // Box fill overlay
        ctx.fillStyle = isSelected ? "rgba(99, 102, 241, 0.25)" : "rgba(59, 130, 246, 0.12)";
        ctx.fillRect(boxX, boxY, boxW, boxH);

        // Box border
        ctx.strokeStyle = isSelected ? "#4f46e5" : "#3b82f6";
        ctx.lineWidth = isSelected ? 3 : 2;
        ctx.setLineDash(isSelected ? [] : [4, 4]);
        ctx.strokeRect(boxX, boxY, boxW, boxH);
        ctx.setLineDash([]);

        // Label badge
        ctx.fillStyle = isSelected ? "#4f46e5" : "#3b82f6";
        ctx.fillRect(boxX, boxY, Math.min(100, boxW), 20);
        ctx.fillStyle = "#ffffff";
        ctx.font = "bold 11px sans-serif";
        ctx.fillText(item.label.slice(0, 14), boxX + 6, boxY + 14);

        // Corner handles for active box
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
        }
      });
    }
  }

  // ── Interactive Dragging on Canvas ──────────────────────────────────────────
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

  function handleCanvasMouseDown(e) {
    if (splitMethod === "horizontal") return;
    const { x, y } = getCanvasCoords(e);
    const canvas = canvasRef.current;
    if (!canvas) return;
    const w = canvas.width;
    const h = canvas.height;

    // Check hit test starting from top box
    for (let i = boxes.length - 1; i >= 0; i--) {
      const b = boxes[i];
      const [ymin, xmin, ymax, xmax] = b.box;
      const boxX = (xmin / 1000) * w;
      const boxY = (ymin / 1000) * h;
      const boxW = ((xmax - xmin) / 1000) * w;
      const boxH = ((ymax - ymin) / 1000) * h;

      // Check handles
      const hs = 12;
      const corners = {
        tl: [boxX, boxY],
        tr: [boxX + boxW, boxY],
        bl: [boxX, boxY + boxH],
        br: [boxX + boxW, boxY + boxH],
      };

      for (const [name, [cx, cy]] of Object.entries(corners)) {
        if (Math.abs(x - cx) <= hs && Math.abs(y - cy) <= hs) {
          setSelectedBoxId(b.id);
          setDragState({
            boxId: b.id,
            handle: name,
            startX: x,
            startY: y,
            startBox: [...b.box],
          });
          return;
        }
      }

      // Check body
      if (x >= boxX && x <= boxX + boxW && y >= boxY && y <= boxY + boxH) {
        setSelectedBoxId(b.id);
        setDragState({
          boxId: b.id,
          handle: "move",
          startX: x,
          startY: y,
          startBox: [...b.box],
        });
        return;
      }
    }

    setSelectedBoxId(null);
  }

  function handleCanvasMouseMove(e) {
    if (!dragState || !canvasRef.current) return;
    const { x, y } = getCanvasCoords(e);
    const canvas = canvasRef.current;
    const w = canvas.width;
    const h = canvas.height;

    const dxNorm = ((x - dragState.startX) / w) * 1000;
    const dyNorm = ((y - dragState.startY) / h) * 1000;

    const [ymin, xmin, ymax, xmax] = dragState.startBox;
    let nyMin = ymin,
      nxMin = xmin,
      nyMax = ymax,
      nxMax = xmax;

    if (dragState.handle === "move") {
      const bw = xmax - xmin;
      const bh = ymax - ymin;
      nxMin = Math.max(0, Math.min(1000 - bw, xmin + dxNorm));
      nyMin = Math.max(0, Math.min(1000 - bh, ymin + dyNorm));
      nxMax = nxMin + bw;
      nyMax = nyMin + bh;
    } else {
      if (dragState.handle.includes("l")) nxMin = Math.max(0, Math.min(xmax - 20, xmin + dxNorm));
      if (dragState.handle.includes("r")) nxMax = Math.max(xmin + 20, Math.min(1000, xmax + dxNorm));
      if (dragState.handle.includes("t")) nyMin = Math.max(0, Math.min(ymax - 20, ymin + dyNorm));
      if (dragState.handle.includes("b")) nyMax = Math.max(ymin + 20, Math.min(1000, ymax + dyNorm));
    }

    setBoxes((prev) =>
      prev.map((b) =>
        b.id === dragState.boxId
          ? { ...b, box: [Math.round(nyMin), Math.round(nxMin), Math.round(nyMax), Math.round(nxMax)] }
          : b
      )
    );
  }

  function handleCanvasMouseUp() {
    setDragState(null);
  }

  function addCutLine() {
    setHorizontalCutPcts((prev) => {
      const next = [...prev, 50].sort((a, b) => a - b);
      return next;
    });
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

  function removeBox(id) {
    setBoxes((prev) => prev.filter((b) => b.id !== id));
    if (selectedBoxId === id) setSelectedBoxId(null);
  }

  // ── Crop a Bounding Box into a Canvas Blob ──────────────────────────────────
  async function cropBoxToBlob(img, [ymin, xmin, ymax, xmax]) {
    const cropX = Math.round((xmin / 1000) * img.width);
    const cropY = Math.round((ymin / 1000) * img.height);
    const cropW = Math.max(1, Math.round(((xmax - xmin) / 1000) * img.width));
    const cropH = Math.max(1, Math.round(((ymax - ymin) / 1000) * img.height));

    const tempCanvas = document.createElement("canvas");
    tempCanvas.width = cropW;
    tempCanvas.height = cropH;
    const ctx = tempCanvas.getContext("2d");
    ctx.drawImage(img, cropX, cropY, cropW, cropH, 0, 0, cropW, cropH);

    return new Promise((resolve) => tempCanvas.toBlob(resolve, "image/jpeg", 0.92));
  }

  // ── Submit Single Product Draft ─────────────────────────────────────────────
  async function handleSingleDraftSubmit() {
    if (!title.trim()) {
      setError("Please enter a title for the product draft.");
      return;
    }
    if (!filePreviews.length) {
      setError("Please upload at least one photo.");
      return;
    }
    if (!uid) {
      setError("You must be logged in to create a draft.");
      return;
    }

    setLoading(true);
    setError("");

    try {
      // 1. Upload all selected photos to Firebase Storage
      const draftTempId = `draft-${Date.now()}`;
      const storedImages = [];
      const storedImageAssets = [];

      for (let i = 0; i < filePreviews.length; i++) {
        const item = filePreviews[i];
        const storedUrl = await uploadFileToStorage(uid, draftTempId, item.file, `img-${i + 1}`);
        storedImages.push(storedUrl);
        storedImageAssets.push({
          id: `${storedUrl}-${i}`,
          url: storedUrl,
          sourceUrl: storedUrl,
          width: null,
          height: null,
          kind: i === 0 ? "cover" : "gallery",
        });
      }

      // Map variation images if assigned
      const mappedVariants = variants.map((v) => {
        const assignedPreview = filePreviews.find((p) => p.id === v.imageId);
        const assignedIdx = assignedPreview ? filePreviews.indexOf(assignedPreview) : 0;
        const imageUrl = storedImages[assignedIdx] ?? storedImages[0];
        return {
          name: v.name,
          price: parseFloat(v.price) || parseFloat(sellPrice) || 0,
          costPrice: parseFloat(v.costPrice) || parseFloat(costPrice) || 0,
          stockId: `SKU-${Date.now()}-${Math.floor(Math.random() * 1000)}`,
          imageUrl,
          soldOut: false,
        };
      });

      const parsedCost = parseFloat(costPrice) || 0;
      const parsedSell = parseFloat(sellPrice) || (parsedCost ? parsedCost * 2 : 0);

      // 2. Save document in Firestore `products` collection matching standard schema
      const docRef = await addDoc(collection(db, "products"), {
        userId: uid,
        source: "photo_upload",
        title: title.trim(),
        description: description.trim(),
        images: storedImages,
        imageAssets: storedImageAssets,
        aliexpressPrice: parsedCost, // Cost price
        suggestedSellPrice: parsedSell,
        variants: mappedVariants,
        tiktokStatus: "draft",
        ebayStatus: "draft",
        importedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      });

      onCreated?.(docRef.id);
      onClose();
      navigate(`/products/${docRef.id}`);
    } catch (e) {
      setError(e.message ?? "Could not save product draft.");
    } finally {
      setLoading(false);
    }
  }

  // ── Submit Multi-Item Photo Split Drafts ────────────────────────────────────
  async function handleSplitDraftSubmit() {
    if (!filePreviews.length) {
      setError("Please upload a photo to split.");
      return;
    }
    if (!uid) {
      setError("You must be logged in to create drafts.");
      return;
    }

    const activePhoto = filePreviews[targetPhotoIndex];
    if (!activePhoto) return;

    setLoading(true);
    setError("");

    try {
      const img = await loadImage(activePhoto.dataUrl);
      const createdDraftIds = [];

      let itemsToCrop = [];
      if (splitMethod === "horizontal") {
        const sortedPcts = [0, ...horizontalCutPcts.slice().sort((a, b) => a - b), 100];
        for (let i = 0; i < sortedPcts.length - 1; i++) {
          const ymin = Math.round(sortedPcts[i] * 10);
          const ymax = Math.round(sortedPcts[i + 1] * 10);
          itemsToCrop.push({
            id: `slice-${i + 1}`,
            label: `${title || "Product"} - Slice #${i + 1}`,
            box: [ymin, 0, ymax, 1000],
          });
        }
      } else {
        if (!boxes.length) {
          setError("No item boxes found to split.");
          setLoading(false);
          return;
        }
        itemsToCrop = boxes;
      }

      // Process each box/slice
      for (let i = 0; i < itemsToCrop.length; i++) {
        const item = itemsToCrop[i];
        const blob = await cropBoxToBlob(img, item.box);

        const draftTempId = `split-draft-${Date.now()}-${i}`;
        const storedUrl = await uploadFileToStorage(uid, draftTempId, blob, `crop-${i + 1}`);

        const itemDetails = splitItemDetails[item.id] || {};
        const itemTitle = itemDetails.title || item.label || `Split Item #${i + 1}`;
        const itemCost = parseFloat(itemDetails.costPrice || batchBaseCost) || 0;
        const itemSell = parseFloat(itemDetails.sellPrice || batchBaseSell) || (itemCost ? itemCost * 2 : 0);

        const docRef = await addDoc(collection(db, "products"), {
          userId: uid,
          source: "photo_upload_split",
          title: itemTitle.trim(),
          description: `Created from photo split (${activePhoto.file?.name ?? "Photo"}).`,
          images: [storedUrl],
          imageAssets: [{ id: `${storedUrl}-0`, url: storedUrl, sourceUrl: storedUrl, kind: "cover" }],
          aliexpressPrice: itemCost,
          suggestedSellPrice: itemSell,
          variants: [],
          tiktokStatus: "draft",
          ebayStatus: "draft",
          importedAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
        });

        createdDraftIds.push(docRef.id);
      }

      onCreated?.(createdDraftIds[0]);
      onClose();
    } catch (e) {
      setError(e.message ?? "Failed to create split drafts.");
    } finally {
      setLoading(false);
    }
  }

  // ── Render ──────────────────────────────────────────────────────────────────
  return (
    <div className="modal-overlay" onClick={onClose}>
      <div
        className="modal modal-lg"
        onClick={(e) => e.stopPropagation()}
        style={{ maxWidth: mode === "split" ? 940 : 680, width: "95vw", maxHeight: "90vh" }}
      >
        <div className="modal-header">
          <div>
            <h2>Create Draft from Photo</h2>
            <div style={{ fontSize: 12, color: "var(--muted)" }}>
              Upload photos to create a single product or split 1 photo into multiple listing drafts.
            </div>
          </div>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>
            ✕
          </button>
        </div>

        <div className="modal-body" style={{ overflowY: "auto", maxHeight: "calc(90vh - 130px)" }}>
          {/* Mode Switcher Tabs */}
          <div style={{ display: "flex", gap: 12, marginBottom: 16 }}>
            <button
              className={`btn ${mode === "single" ? "btn-primary" : "btn-ghost"}`}
              style={{ flex: 1 }}
              onClick={() => setMode("single")}
            >
              📷 Single Product Draft
            </button>
            <button
              className={`btn ${mode === "split" ? "btn-primary" : "btn-ghost"}`}
              style={{ flex: 1 }}
              onClick={() => setMode("split")}
            >
              ✂ Split Photo into Multiple Listings
            </button>
          </div>

          {/* Photo Dropzone / Upload Box */}
          <div className="dropzone" style={{ marginBottom: 16 }}>
            <input
              type="file"
              accept="image/*"
              multiple={mode === "single"}
              onChange={handleFileSelect}
              style={{ display: "none" }}
              id="photo-upload-input"
            />
            <label
              htmlFor="photo-upload-input"
              style={{
                display: "block",
                padding: "24px 16px",
                border: "2px dashed var(--border)",
                borderRadius: 8,
                textAlign: "center",
                cursor: "pointer",
                background: "var(--bg-subtle, rgba(255,255,255,0.02))",
              }}
            >
              <div style={{ fontSize: 28, marginBottom: 4 }}>🖼️</div>
              <div style={{ fontWeight: 600 }}>Click or Drag & Drop Photos Here</div>
              <div style={{ fontSize: 12, color: "var(--muted)" }}>Supports PNG, JPG, WEBP</div>
            </label>
          </div>

          {/* Uploaded File Previews */}
          {filePreviews.length > 0 && (
            <div style={{ marginBottom: 16 }}>
              <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8 }}>
                Uploaded Images ({filePreviews.length}) — Drag / click arrows to reorder cover photo:
              </div>
              <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
                {filePreviews.map((p, idx) => (
                  <div
                    key={p.id}
                    style={{
                      position: "relative",
                      width: 80,
                      height: 80,
                      borderRadius: 6,
                      overflow: "hidden",
                      border:
                        mode === "split" && targetPhotoIndex === idx
                          ? "2px solid var(--primary)"
                          : "1px solid var(--border)",
                      cursor: mode === "split" ? "pointer" : "default",
                    }}
                    onClick={() => mode === "split" && setTargetPhotoIndex(idx)}
                  >
                    <img src={p.dataUrl} alt={`Upload ${idx}`} style={{ width: "100%", height: "100%", objectFit: "cover" }} />
                    {idx === 0 && (
                      <span
                        style={{
                          position: "absolute",
                          bottom: 0,
                          left: 0,
                          right: 0,
                          background: "rgba(0,0,0,0.75)",
                          color: "#fff",
                          fontSize: 9,
                          textAlign: "center",
                          padding: "2px 0",
                        }}
                      >
                        COVER
                      </span>
                    )}
                    <div style={{ position: "absolute", top: 2, right: 2, display: "flex", gap: 2 }}>
                      <button
                        style={{ background: "rgba(0,0,0,0.6)", color: "#fff", border: "none", borderRadius: 3, padding: "1px 4px", fontSize: 10 }}
                        onClick={(e) => { e.stopPropagation(); removeFile(idx); }}
                      >
                        ✕
                      </button>
                    </div>
                    {mode === "single" && filePreviews.length > 1 && (
                      <div style={{ position: "absolute", bottom: 2, right: 2, display: "flex", gap: 2 }}>
                        {idx > 0 && (
                          <button
                            style={{ background: "rgba(0,0,0,0.6)", color: "#fff", border: "none", borderRadius: 3, padding: "1px 3px", fontSize: 10 }}
                            onClick={(e) => { e.stopPropagation(); moveFile(idx, idx - 1); }}
                          >
                            ◀
                          </button>
                        )}
                        {idx < filePreviews.length - 1 && (
                          <button
                            style={{ background: "rgba(0,0,0,0.6)", color: "#fff", border: "none", borderRadius: 3, padding: "1px 3px", fontSize: 10 }}
                            onClick={(e) => { e.stopPropagation(); moveFile(idx, idx + 1); }}
                          >
                            ▶
                          </button>
                        )}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* ────────────────── SINGLE DRAFT FORM ────────────────── */}
          {mode === "single" && (
            <div>
              <div className="modal-field">
                <label>Product Title *</label>
                <input
                  className="input"
                  placeholder="e.g. Vintage Printed Graphic T-Shirt"
                  value={title}
                  onChange={(e) => setTitle(e.target.value)}
                />
              </div>

              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
                <div className="modal-field">
                  <label>Cost / Acquisition Price ($)</label>
                  <input
                    className="input"
                    type="number"
                    step="0.01"
                    placeholder="0.00 (optional)"
                    value={costPrice}
                    onChange={(e) => setCostPrice(e.target.value)}
                  />
                </div>
                <div className="modal-field">
                  <label>Listing Sell Price ($)</label>
                  <input
                    className="input"
                    type="number"
                    step="0.01"
                    placeholder="0.00"
                    value={sellPrice}
                    onChange={(e) => setSellPrice(e.target.value)}
                  />
                </div>
              </div>

              <div className="modal-field">
                <label>Description</label>
                <textarea
                  className="input"
                  rows={3}
                  placeholder="Product description and details…"
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                />
              </div>

              {/* Product Variations section (matching scraped listing experience) */}
              <div style={{ marginTop: 20, paddingTop: 16, borderTop: "1px solid var(--border)" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                  <label style={{ fontWeight: 600, fontSize: 13 }}>Product Variations</label>
                  <button className="btn btn-ghost" style={{ fontSize: 12, padding: "4px 8px" }} onClick={addVariant}>
                    + Add Variation
                  </button>
                </div>

                {variants.length === 0 ? (
                  <div style={{ fontSize: 12, color: "var(--muted)", fontStyle: "italic", marginBottom: 12 }}>
                    No variations added. Add options (e.g. Size, Color) and assign photos to them if applicable.
                  </div>
                ) : (
                  <div style={{ display: "flex", flexDirection: "column", gap: 8, marginBottom: 12 }}>
                    {variants.map((v, idx) => (
                      <div
                        key={v.id}
                        style={{
                          display: "grid",
                          gridTemplateColumns: "1.5fr 1fr 1.5fr auto",
                          gap: 8,
                          alignItems: "center",
                          background: "var(--bg-subtle, rgba(255,255,255,0.02))",
                          padding: 8,
                          borderRadius: 6,
                          border: "1px solid var(--border)",
                        }}
                      >
                        <input
                          className="input"
                          placeholder="Variant Name (e.g. Red / Size M)"
                          value={v.name}
                          onChange={(e) => updateVariant(idx, "name", e.target.value)}
                        />
                        <input
                          className="input"
                          type="number"
                          step="0.01"
                          placeholder="Price ($)"
                          value={v.price}
                          onChange={(e) => updateVariant(idx, "price", e.target.value)}
                        />
                        <select
                          className="input"
                          value={v.imageId}
                          onChange={(e) => updateVariant(idx, "imageId", e.target.value)}
                        >
                          <option value="">(Default Cover Photo)</option>
                          {filePreviews.map((p, pIdx) => (
                            <option key={p.id} value={p.id}>
                              Photo #{pIdx + 1}
                            </option>
                          ))}
                        </select>
                        <button
                          className="btn btn-ghost"
                          style={{ padding: "4px 8px", color: "var(--danger)" }}
                          onClick={() => removeVariant(idx)}
                        >
                          ✕
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          )}

          {/* ────────────────── PHOTO SPLIT FLOW ────────────────── */}
          {mode === "split" && (
            <div>
              {/* Split Tools Bar */}
              <div
                style={{
                  display: "flex",
                  gap: 12,
                  alignItems: "center",
                  flexWrap: "wrap",
                  padding: 12,
                  background: "var(--bg-subtle, rgba(255,255,255,0.02))",
                  borderRadius: 8,
                  marginBottom: 16,
                  border: "1px solid var(--border)",
                }}
              >
                <div style={{ display: "flex", gap: 6 }}>
                  <button
                    className={`btn ${splitMethod === "grid" ? "btn-primary" : "btn-ghost"}`}
                    style={{ fontSize: 12, padding: "4px 10px" }}
                    onClick={() => {
                      setSplitMethod("grid");
                      generateGridBoxes(gridRows, gridCols);
                    }}
                  >
                    田 Grid Split
                  </button>
                  <button
                    className={`btn ${splitMethod === "horizontal" ? "btn-primary" : "btn-ghost"}`}
                    style={{ fontSize: 12, padding: "4px 10px" }}
                    onClick={() => setSplitMethod("horizontal")}
                  >
                    ✂ Horizontal Slice
                  </button>
                </div>

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
                    <button
                      className="btn btn-ghost"
                      style={{ fontSize: 11, padding: "2px 6px" }}
                      onClick={addBox}
                    >
                      + Add Box
                    </button>
                  </div>
                )}

                {splitMethod === "horizontal" && (
                  <button
                    className="btn btn-ghost"
                    style={{ fontSize: 12, padding: "4px 8px" }}
                    onClick={addCutLine}
                  >
                    + Add Cut Line
                  </button>
                )}

                {/* AI Toggle / Button */}
                <div style={{ marginLeft: "auto" }}>
                  <button
                    className="btn btn-ghost"
                    style={{
                      fontSize: 12,
                      padding: "4px 10px",
                      borderColor: "var(--primary)",
                      color: "var(--primary)",
                    }}
                    onClick={runAiDetection}
                    disabled={aiLoading || !filePreviews.length}
                  >
                    {aiLoading ? "⚡ AI Detecting…" : "⚡ AI Auto-Detect Items"}
                  </button>
                </div>
              </div>

              {/* Canvas Editor and Preview Cards Layout */}
              <div style={{ display: "grid", gridTemplateColumns: "1fr 280px", gap: 16, alignItems: "start" }}>
                {/* Canvas Container */}
                <div style={{ textAlign: "center", position: "relative" }}>
                  {activePhotoUrl ? (
                    <div style={{ display: "inline-block", position: "relative", border: "1px solid var(--border)" }}>
                      <canvas
                        ref={canvasRef}
                        onMouseDown={handleCanvasMouseDown}
                        onMouseMove={handleCanvasMouseMove}
                        onMouseUp={handleCanvasMouseUp}
                        style={{ cursor: dragState ? "grabbing" : "crosshair", display: "block" }}
                      />
                    </div>
                  ) : (
                    <div style={{ padding: 40, color: "var(--muted)" }}>Upload a photo above to display split canvas.</div>
                  )}
                  <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 6 }}>
                    {splitMethod === "grid"
                      ? "Boxes start aligned in a grid but can be independently dragged, resized, or removed."
                      : splitMethod === "horizontal"
                      ? "Horizontal cut lines slice long images vertically into separate items."
                      : "Items detected by AI. Click any box to adjust crop edges."}
                  </div>
                </div>

                {/* Right Side: Split Items List & Price Defaults */}
                <div>
                  <div style={{ marginBottom: 12 }}>
                    <label style={{ fontSize: 12, fontWeight: 600 }}>Apply Bulk Prices</label>
                    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 6, marginTop: 4 }}>
                      <input
                        className="input"
                        style={{ fontSize: 11, padding: 4 }}
                        placeholder="Base Cost ($)"
                        value={batchBaseCost}
                        onChange={(e) => setBatchBaseCost(e.target.value)}
                      />
                      <input
                        className="input"
                        style={{ fontSize: 11, padding: 4 }}
                        placeholder="Base Sell ($)"
                        value={batchBaseSell}
                        onChange={(e) => setBatchBaseSell(e.target.value)}
                      />
                    </div>
                  </div>

                  <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8 }}>
                    Items to Create ({splitMethod === "horizontal" ? horizontalCutPcts.length + 1 : boxes.length}):
                  </div>

                  <div style={{ display: "flex", flexDirection: "column", gap: 8, maxHeight: 360, overflowY: "auto" }}>
                    {boxes.map((b, idx) => {
                      const details = splitItemDetails[b.id] || {};
                      const isSelected = b.id === selectedBoxId;
                      return (
                        <div
                          key={b.id}
                          style={{
                            padding: 8,
                            borderRadius: 6,
                            border: isSelected ? "2px solid var(--primary)" : "1px solid var(--border)",
                            background: "var(--bg-subtle, rgba(255,255,255,0.02))",
                          }}
                          onClick={() => setSelectedBoxId(b.id)}
                        >
                          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 4 }}>
                            <span style={{ fontSize: 11, fontWeight: 600 }}>#{idx + 1} {b.label}</span>
                            <button
                              style={{ border: "none", background: "none", color: "var(--danger)", cursor: "pointer", fontSize: 11 }}
                              onClick={(e) => {
                                e.stopPropagation();
                                removeBox(b.id);
                              }}
                            >
                              ✕
                            </button>
                          </div>
                          <input
                            className="input"
                            style={{ fontSize: 11, padding: "2px 6px", marginBottom: 4 }}
                            placeholder="Item Title"
                            value={details.title ?? b.label}
                            onChange={(e) =>
                              setSplitItemDetails((prev) => ({
                                ...prev,
                                [b.id]: { ...prev[b.id], title: e.target.value },
                              }))
                            }
                          />
                          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 4 }}>
                            <input
                              className="input"
                              style={{ fontSize: 11, padding: "2px 6px" }}
                              placeholder={`Cost: $${batchBaseCost || "0"}`}
                              value={details.costPrice ?? ""}
                              onChange={(e) =>
                                setSplitItemDetails((prev) => ({
                                  ...prev,
                                  [b.id]: { ...prev[b.id], costPrice: e.target.value },
                                }))
                              }
                            />
                            <input
                              className="input"
                              style={{ fontSize: 11, padding: "2px 6px" }}
                              placeholder={`Sell: $${batchBaseSell || "0"}`}
                              value={details.sellPrice ?? (b.price ? String(b.price) : "")}
                              onChange={(e) =>
                                setSplitItemDetails((prev) => ({
                                  ...prev,
                                  [b.id]: { ...prev[b.id], sellPrice: e.target.value },
                                }))
                              }
                            />
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              </div>
            </div>
          )}

          {error && <div style={{ color: "var(--danger)", fontSize: 13, marginTop: 12 }}>{error}</div>}
        </div>

        <div className="modal-footer" style={{ borderTop: "1px solid var(--border)", paddingTop: 12 }}>
          <button className="btn btn-ghost" onClick={onClose} disabled={loading}>
            Cancel
          </button>
          {mode === "single" ? (
            <button
              className="btn btn-primary"
              onClick={handleSingleDraftSubmit}
              disabled={loading || !filePreviews.length}
            >
              {loading ? "Creating Draft…" : "Create Product Draft"}
            </button>
          ) : (
            <button
              className="btn btn-primary"
              onClick={handleSplitDraftSubmit}
              disabled={loading || !filePreviews.length || (!boxes.length && splitMethod !== "horizontal")}
            >
              {loading
                ? "Creating Drafts…"
                : `Create ${splitMethod === "horizontal" ? horizontalCutPcts.length + 1 : boxes.length} Split Drafts`}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
