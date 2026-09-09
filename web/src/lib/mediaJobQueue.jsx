import { createContext, useContext, useRef, useState } from "react";
import { doc, runTransaction, serverTimestamp } from "firebase/firestore";
import { auth, db, callFunction, uploadImageBlob } from "../firebase";
import { normalizeImageAssets, buildImagePayload } from "./media";

// App-wide queue for photo-split and photo-upload jobs. Lives above the
// router (see main.jsx) so a job started on one listing keeps running even
// after navigating to the dashboard or a different listing — unlike the
// component-local state it replaces, a job here can't be silently lost just
// because the ProductDetail page that started it is no longer mounted.
//
// Each write is merged into Firestore via a transaction that reads the
// product doc fresh at merge time (see mergeIntoProduct below), so results
// are never built from a stale in-memory snapshot.

const MAX_CONCURRENT = 2;

const MediaJobQueueContext = createContext(null);

async function processSplitJob(job) {
  const { productId, imageUrl, splitMethod, lines, boxes } = job;
  const uid = auth.currentUser?.uid;
  let results = [];
  let clientSucceeded = false;

  if (uid) {
    try {
      // Always load a fresh crossOrigin image for pixel access. Reusing an
      // <img> from the editor is unsafe: its canvas may have fallen back to
      // a non-CORS image (tainted), which makes canvas.toBlob() throw.
      const loadCorsImage = (src) =>
        new Promise((res, rej) => {
          const el = new Image();
          el.crossOrigin = "anonymous";
          el.onload = () => res(el);
          el.onerror = rej;
          el.src = src;
        });

      let img;
      try {
        img = await loadCorsImage(imageUrl);
      } catch {
        // Some hosts reject CORS preflight — bust the cache to get a fresh
        // response that may carry permissive headers.
        img = await loadCorsImage(
          imageUrl + (imageUrl.includes("?") ? "&" : "?") + "_cb=" + Date.now()
        );
      }

      const W = img.naturalWidth;
      const H = img.naturalHeight;

      if (splitMethod === "horizontal") {
        const boundaries = [0, ...(lines ?? []), 100].map((p) => Math.round((p / 100) * H));
        for (let i = 0; i < boundaries.length - 1; i++) {
          const y0 = boundaries[i];
          const y1 = boundaries[i + 1];
          const sliceH = y1 - y0;
          if (sliceH < 5) continue;

          const offscreen = document.createElement("canvas");
          offscreen.width = W;
          offscreen.height = sliceH;
          offscreen.getContext("2d").drawImage(img, 0, y0, W, sliceH, 0, 0, W, sliceH);

          const blob = await new Promise((res, rej) => {
            offscreen.toBlob((b) => (b ? res(b) : rej(new Error("Canvas blob error"))), "image/jpeg", 0.92);
          });
          const url = await uploadImageBlob(uid, productId, blob, `-split-${i}`);
          results.push({ url, width: W, height: sliceH, kind: "split" });
        }
      } else {
        // 2D bounding boxes (Custom, Grid, AI)
        const boxList = Array.isArray(boxes) ? boxes : [];
        for (let i = 0; i < boxList.length; i++) {
          const [ymin, xmin, ymax, xmax] = boxList[i].box;
          const cropX = Math.round((xmin / 1000) * W);
          const cropY = Math.round((ymin / 1000) * H);
          const cropW = Math.max(1, Math.round(((xmax - xmin) / 1000) * W));
          const cropH = Math.max(1, Math.round(((ymax - ymin) / 1000) * H));

          const offscreen = document.createElement("canvas");
          offscreen.width = cropW;
          offscreen.height = cropH;
          const ctx = offscreen.getContext("2d");
          ctx.drawImage(img, cropX, cropY, cropW, cropH, 0, 0, cropW, cropH);

          const blob = await new Promise((res, rej) => {
            offscreen.toBlob((b) => (b ? res(b) : rej(new Error("Canvas blob error"))), "image/jpeg", 0.92);
          });
          const url = await uploadImageBlob(uid, productId, blob, `-crop-${i}`);
          results.push({ url, width: cropW, height: cropH, kind: "split" });
        }
      }
      clientSucceeded = true;
    } catch (err) {
      console.warn("Client background split failed:", err);
    }
  }

  if (!clientSucceeded || !results.length) {
    const res = await callFunction("splitProductImage")({
      productId,
      imageUrl,
      slicePoints: lines ?? [50],
    });
    results = res?.data?.slices ?? [];
  }

  if (!results.length) {
    throw new Error("Could not split that image — please try again.");
  }

  return results.map((r, i) => ({
    id: `${r.url}-split-${i}`,
    url: r.url,
    sourceUrl: imageUrl,
    width: r.width ?? null,
    height: r.height ?? null,
    kind: "split",
  }));
}

async function processUploadJob(job) {
  const { productId, files } = job;
  const uid = auth.currentUser?.uid;
  if (!uid) throw new Error("You're signed out — please sign back in and try again.");

  const uploaded = [];
  for (let i = 0; i < files.length; i++) {
    const url = await uploadImageBlob(uid, productId, files[i], `-added-${Date.now()}-${i}`);
    uploaded.push({ id: `${url}-added-${i}`, url, sourceUrl: url, kind: "added" });
  }
  return uploaded;
}

// Reads the product doc fresh inside a transaction and splices/appends the
// job's results into it — this is what makes the merge correct regardless of
// which (if any) ProductDetail instance is mounted, and safe under
// concurrent jobs for the same product (Firestore retries on contention).
async function mergeIntoProduct(job, newImages) {
  const ref = doc(db, "products", job.productId);
  await runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists()) throw new Error("This listing no longer exists.");
    const current = normalizeImageAssets({ id: snap.id, ...snap.data() });

    let next;
    if (job.type === "split") {
      const idx = current.findIndex((img) => img.url === job.imageUrl || img.id === job.targetImageId);
      const at = idx !== -1 ? idx : current.length;
      next = [...current.slice(0, at), ...newImages, ...current.slice(at + 1)];
    } else {
      next = [...current, ...newImages];
    }

    const payload = buildImagePayload(next);
    tx.update(ref, {
      images: payload.map((image) => image.url),
      imageAssets: payload,
      listingImages: payload.map((image) => image.url),
      updatedAt: serverTimestamp(),
    });
  });
}

export function MediaJobQueueProvider({ children }) {
  const queueRef = useRef([]);
  const activeCountRef = useRef(0);
  const [jobs, setJobs] = useState([]);

  function sync() {
    setJobs([...queueRef.current]);
  }

  function patchJob(id, patch) {
    queueRef.current = queueRef.current.map((j) => (j.id === id ? { ...j, ...patch } : j));
    sync();
  }

  function scheduleAutoDismiss(id) {
    setTimeout(() => {
      queueRef.current = queueRef.current.filter((j) => j.id !== id);
      sync();
    }, 4000);
  }

  async function runNext() {
    if (activeCountRef.current >= MAX_CONCURRENT) return;
    const next = queueRef.current.find((j) => j.status === "queued");
    if (!next) return;

    activeCountRef.current += 1;
    patchJob(next.id, { status: "processing" });
    try {
      const newImages = next.type === "split" ? await processSplitJob(next) : await processUploadJob(next);
      await mergeIntoProduct(next, newImages);
      patchJob(next.id, { status: "done" });
      scheduleAutoDismiss(next.id);
    } catch (err) {
      patchJob(next.id, { status: "error", error: err?.message ?? "Something went wrong." });
    } finally {
      activeCountRef.current -= 1;
      runNext();
    }
  }

  function enqueue(job) {
    if (job.type === "split") {
      const alreadyActive = queueRef.current.some(
        (j) => j.type === "split" && j.productId === job.productId && j.imageUrl === job.imageUrl
          && (j.status === "queued" || j.status === "processing")
      );
      if (alreadyActive) return null;
    }
    const id = `${job.type}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    queueRef.current = [...queueRef.current, { ...job, id, status: "queued", error: null, createdAt: Date.now() }];
    sync();
    runNext();
    return id;
  }

  function retry(id) {
    queueRef.current = queueRef.current.map((j) => (j.id === id ? { ...j, status: "queued", error: null } : j));
    sync();
    runNext();
  }

  function dismiss(id) {
    queueRef.current = queueRef.current.filter((j) => j.id !== id);
    sync();
  }

  return (
    <MediaJobQueueContext.Provider value={{ jobs, enqueue, retry, dismiss }}>
      {children}
    </MediaJobQueueContext.Provider>
  );
}

export function useMediaJobQueue() {
  const ctx = useContext(MediaJobQueueContext);
  if (!ctx) throw new Error("useMediaJobQueue must be used within a MediaJobQueueProvider");
  return ctx;
}
