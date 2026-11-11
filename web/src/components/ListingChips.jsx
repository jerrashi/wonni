import { useEffect, useRef, useState } from "react";
import { startPostJob, visibleJob } from "../lib/postJobs";

/** "eBay: Live · 3 listings ▾" with a menu of one link per listing. Used only
 *  when a product was split across several platform listings. */
export function SplitListingChip({ platformName, word, urls }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const onDown = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const onKey = (e) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); document.removeEventListener("keydown", onKey); };
  }, [open]);
  return (
    <span ref={ref} style={{ position: "relative", display: "inline-block" }}>
      <button
        type="button"
        className="chip chip-active"
        style={{ cursor: "pointer", border: "none" }}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        title={`This product is split across ${urls.length} ${platformName} listings`}
      >
        {platformName}: {word} · {urls.length} listings ▾
      </button>
      {open && (
        <div
          role="menu"
          style={{
            position: "absolute", top: "calc(100% + 6px)", left: 0, zIndex: 20, minWidth: 220,
            background: "var(--surface-high, #fff)", border: "1px solid var(--border, #ddd)", borderRadius: 10,
            padding: 6, boxShadow: "0 8px 24px rgba(0,0,0,.2)",
          }}
        >
          {urls.map((u) => (
            <a
              key={u.url}
              role="menuitem"
              href={u.url}
              target="_blank"
              rel="noopener noreferrer"
              onClick={() => setOpen(false)}
              style={{ display: "block", padding: "8px 10px", borderRadius: 6, fontSize: 13, color: "inherit", textDecoration: "none" }}
            >
              {u.label} ↗
            </a>
          ))}
        </div>
      )}
    </span>
  );
}

const NAMES = { ebay: "eBay", etsy: "Etsy" };

/** Progress / failure chip for a background post job. Renders nothing when
 *  there is no job to show. `onRetry` defaults to starting a new job. */
export function PostJobChip({ job, productId }) {
  const [busy, setBusy] = useState(false);
  const shown = visibleJob(job);
  if (!shown) return null;
  const name = NAMES[shown.platform] || shown.platform;
  const total = shown.groupsTotal;
  const done = shown.groupsDone ?? 0;

  if (shown.status === "failed") {
    return (
      <span style={{ display: "inline-flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <span className="chip" style={{ background: "var(--bad-bg, #fbe3e1)", color: "var(--bad, #b3261e)" }}>
          Posting to {name} stopped{total ? ` · ${done} of ${total} live` : ""}
        </span>
        <button
          type="button"
          className="btn btn-ghost"
          style={{ fontSize: 11, padding: "2px 10px", borderRadius: 12 }}
          disabled={busy}
          onClick={async () => { setBusy(true); try { await startPostJob(productId, shown.platform); } finally { setBusy(false); } }}
        >
          {busy ? "Starting…" : "Resume"}
        </button>
        {shown.error && <span style={{ fontSize: 12, opacity: 0.8 }}>{shown.error}</span>}
      </span>
    );
  }

  const pct = total ? Math.round((done / total) * 100) : 0;
  return (
    <span className="chip" style={{ display: "inline-flex", gap: 8, alignItems: "center", background: "var(--warn-bg, #fdf0d9)", color: "var(--warn, #b26a00)" }}>
      Posting to {name}{total ? ` · ${done} of ${total} listings` : "…"}
      <span aria-hidden style={{ width: 70, height: 6, borderRadius: 3, background: "rgba(0,0,0,.12)", overflow: "hidden", display: "inline-block" }}>
        <i style={{ display: "block", height: "100%", width: `${pct}%`, background: "currentColor" }} />
      </span>
    </span>
  );
}
