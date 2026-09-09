import { useState } from "react";
import { Link } from "react-router-dom";
import { useMediaJobQueue } from "../lib/mediaJobQueue";

const LABELS = {
  split: (job) => `Splitting a photo — ${job.title || "listing"}`,
  upload: (job) => `Uploading ${job.files?.length ?? ""} photo(s) — ${job.title || "listing"}`,
};

// Rendered once at the app root (see main.jsx) so it stays visible across
// navigation — this is the durable, cross-page failure signal for
// split/upload jobs, replacing the old page-scoped `mediaError` text that
// vanished the moment you left the listing that started the job.
export default function BackgroundTasksTray() {
  const { jobs, retry, dismiss } = useMediaJobQueue();
  const [collapsed, setCollapsed] = useState(false);

  const visible = jobs.filter((j) => j.status !== "done");
  if (!visible.length) return null;

  const activeCount = visible.filter((j) => j.status !== "error").length;
  const errorCount = visible.filter((j) => j.status === "error").length;

  return (
    <div style={{ position: "fixed", bottom: 16, right: 16, zIndex: 1000, width: 320, fontSize: 13 }}>
      <div
        onClick={() => setCollapsed((c) => !c)}
        style={{
          background: "var(--card, #1a1a1a)",
          border: "1px solid var(--border)",
          borderRadius: 8,
          padding: "8px 12px",
          cursor: "pointer",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          boxShadow: "0 4px 16px rgba(0,0,0,0.3)",
        }}
      >
        <span>
          {activeCount > 0 && <span style={{ color: "var(--accent)" }}>{activeCount} processing</span>}
          {activeCount > 0 && errorCount > 0 && " · "}
          {errorCount > 0 && <span style={{ color: "var(--danger)" }}>{errorCount} failed</span>}
        </span>
        <span style={{ color: "var(--muted)" }}>{collapsed ? "▲" : "▼"}</span>
      </div>

      {!collapsed && (
        <div
          style={{
            marginTop: 6,
            background: "var(--card, #1a1a1a)",
            border: "1px solid var(--border)",
            borderRadius: 8,
            maxHeight: 280,
            overflowY: "auto",
          }}
        >
          {visible.map((job) => (
            <div
              key={job.id}
              style={{ padding: "8px 12px", borderTop: "1px solid var(--border)", display: "flex", flexDirection: "column", gap: 4 }}
            >
              <Link to={`/products/${job.productId}`} style={{ color: "var(--text)" }}>
                {LABELS[job.type]?.(job) ?? job.type}
              </Link>
              {job.status === "processing" && <span style={{ color: "var(--muted)" }}>⏳ Working…</span>}
              {job.status === "queued" && <span style={{ color: "var(--muted)" }}>Queued…</span>}
              {job.status === "error" && (
                <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 6 }}>
                  <span style={{ color: "var(--danger)" }}>{job.error}</span>
                  <div style={{ display: "flex", gap: 4, flexShrink: 0 }}>
                    <button className="btn btn-ghost" style={{ padding: "2px 8px", fontSize: 12 }} onClick={() => retry(job.id)}>
                      Retry
                    </button>
                    <button className="btn btn-ghost" style={{ padding: "2px 8px", fontSize: 12 }} onClick={() => dismiss(job.id)}>
                      ✕
                    </button>
                  </div>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
