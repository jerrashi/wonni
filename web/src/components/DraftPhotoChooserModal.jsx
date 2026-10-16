import { useEffect, useState } from "react";
import { callFunction } from "../firebase";

// "Choose photos" for a proposal in the text-to-listings review (2026-10-15):
// the web twin of the iOS DraftPhotoChooserSheet, on the same backend search
// (draftPhotoCandidates → every eBay result with a photo, strong matches first;
// draftPhotoCandidateDetail → the ONE getItem per import). Cards: title + price,
// cover photo, chips (eBay → what the listing says is included → "different
// item" markers). Import hands the chosen listing's photos (and, with "Include
// listing details", its eBay category / condition / ePID / specifics) back to
// the caller, which puts them on the proposal; nothing is persisted here.

const INCLUDED_LABEL = {
  complete: "Complete in box",
  partial: "Missing parts",
  loose: "Loose",
  sealed: "Sealed",
  packaging: "Box or case only",
  unknown: null,
};

export default function DraftPhotoChooserModal({ proposal, onClose, onImport }) {
  const [query, setQuery] = useState(proposal.searchQuery || proposal.shortTitle || proposal.title);
  const [candidates, setCandidates] = useState(proposal.photoCandidates || []);
  const [selectedId, setSelectedId] = useState(null);
  const [includeDetails, setIncludeDetails] = useState(true);
  const [replacePhotos, setReplacePhotos] = useState(true);
  const [searching, setSearching] = useState(false);
  const [importing, setImporting] = useState(false);
  const [error, setError] = useState("");
  const ours = proposal.included && proposal.included !== "unknown" ? proposal.included : null;

  useEffect(() => {
    if (!candidates.length && query) search(query);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function search(q) {
    const trimmed = (q || "").trim();
    if (!trimmed) return;
    setSearching(true);
    setError("");
    try {
      const res = await callFunction("draftPhotoCandidates")({ query: trimmed, included: proposal.included || "unknown" });
      setCandidates(res.data?.candidates ?? []);
      setSelectedId(null);
    } catch (e) {
      setError(e.message ?? "Search failed");
    } finally {
      setSearching(false);
    }
  }

  async function handleImport() {
    const picked = candidates.find((c) => c.itemId === selectedId);
    if (!picked) return;
    setImporting(true);
    setError("");
    try {
      const res = await callFunction("draftPhotoCandidateDetail")({ itemId: picked.itemId, isBundle: Boolean(proposal.isBundle) });
      const detail = res.data ?? {};
      const photos = detail.imageUrls?.length ? detail.imageUrls : [picked.imageUrl];
      onImport({
        imageUrls: replacePhotos ? photos : [...(proposal.imageUrls || []), ...photos.filter((u) => !(proposal.imageUrls || []).includes(u))],
        imageSource: "ebay",
        photoMatch: "strong",
        searchQuery: query.trim(),
        photoCandidates: candidates,
        ...(includeDetails && {
          ...(detail.ebayCategoryId && { ebayCategoryId: detail.ebayCategoryId }),
          ...(detail.ebayConditionId && { ebayConditionId: detail.ebayConditionId }),
          ...(detail.epid && { epid: detail.epid }),
          ...(detail.itemSpecifics && { itemSpecifics: detail.itemSpecifics }),
          similarItemId: picked.itemId,
        }),
      });
    } catch (e) {
      setError(e.message ?? "Import failed");
    } finally {
      setImporting(false);
    }
  }

  const strong = candidates.filter((c) => c.strong);
  const others = candidates.filter((c) => !c.strong);

  function chips(c) {
    const out = [{ text: "eBay", tone: "src" }];
    const label = INCLUDED_LABEL[c.included];
    if (label) out.push({ text: label, tone: ours ? (ours === c.included ? "ok" : "warn") : c.included === "packaging" ? "warn" : "neutral" });
    for (const m of (c.markers || []).slice(0, 3)) out.push({ text: m, tone: "warn" });
    return out;
  }

  const toneStyle = {
    src: { background: "rgba(255,215,0,0.14)", color: "var(--primary)" },
    ok: { background: "rgba(74,222,128,0.15)", color: "var(--success)" },
    warn: { background: "rgba(245,158,11,0.18)", color: "var(--warning)" },
    neutral: { background: "var(--surface-high)", color: "var(--muted)" },
  };

  function card(c) {
    const picked = c.itemId === selectedId;
    return (
      <div
        key={c.itemId}
        onClick={() => setSelectedId(picked ? null : c.itemId)}
        style={{
          display: "flex", gap: 12, padding: 10, cursor: "pointer",
          border: `1px solid ${picked ? "var(--primary)" : "var(--border)"}`,
          background: picked ? "rgba(255,215,0,0.06)" : "var(--surface-low)",
        }}
      >
        <input type="radio" checked={picked} readOnly style={{ marginTop: 4 }} />
        <img src={c.imageUrl} alt="" style={{ width: 72, height: 72, objectFit: "cover", flex: "none", background: "var(--surface-high)" }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
            <div style={{ fontWeight: 700, fontSize: 13, lineHeight: 1.3 }}>{c.title}</div>
            {c.price != null && <div style={{ fontWeight: 700, fontSize: 13, whiteSpace: "nowrap" }}>${Number(c.price).toFixed(2)}</div>}
          </div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 6 }}>
            {chips(c).map((chip, i) => (
              <span key={i} style={{ ...toneStyle[chip.tone], fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 999 }}>{chip.text}</span>
            ))}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="modal-overlay" onClick={importing ? undefined : onClose}>
      <div className="modal" style={{ maxWidth: 640 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <div>
            <h2>Choose photos</h2>
            <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 4 }}>
              Photos for <b style={{ color: "var(--text)" }}>{proposal.shortTitle || proposal.title}</b>
              {ours && INCLUDED_LABEL[ours] ? ` · ${INCLUDED_LABEL[ours].toLowerCase()}` : ""}
            </div>
          </div>
          <button className="btn btn-ghost" style={{ padding: "4px 10px" }} onClick={onClose} disabled={importing}>×</button>
        </div>
        <div className="modal-body">
          <div className="input-group" style={{ gap: 8 }}>
            <input
              className="input"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && search(query)}
              placeholder="Search eBay"
            />
            <button className="btn btn-ghost" onClick={() => search(query)} disabled={searching || !query.trim()}>
              {searching ? "Searching…" : "Search"}
            </button>
          </div>
          {error && <div style={{ color: "var(--danger)", fontSize: 13 }}>{error}</div>}
          {!searching && !candidates.length && (
            <div style={{ color: "var(--muted)", fontSize: 13 }}>No listings with photos found. Try different words.</div>
          )}
          {strong.length > 0 && (
            <div>
              <div style={{ fontSize: 11, color: "var(--muted)", textTransform: "uppercase", letterSpacing: ".05em", marginBottom: 6 }}>
                {others.length ? "Best matches" : "eBay listings"}
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>{strong.map(card)}</div>
            </div>
          )}
          {others.length > 0 && (
            <div>
              <div style={{ fontSize: 11, color: "var(--muted)", textTransform: "uppercase", letterSpacing: ".05em", marginBottom: 6 }}>
                {strong.length ? "Other results" : "eBay listings"}
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>{others.map(card)}</div>
            </div>
          )}
        </div>
        <div className="modal-footer" style={{ justifyContent: "space-between", alignItems: "center", flexWrap: "wrap" }}>
          <div style={{ display: "flex", gap: 16, fontSize: 13 }}>
            <label style={{ display: "flex", gap: 6, alignItems: "center" }}>
              <input type="checkbox" checked={includeDetails} onChange={(e) => setIncludeDetails(e.target.checked)} /> Include listing details
            </label>
            <label style={{ display: "flex", gap: 6, alignItems: "center" }}>
              <input type="checkbox" checked={replacePhotos} onChange={(e) => setReplacePhotos(e.target.checked)} /> Replace current photos
            </label>
          </div>
          <button className="btn btn-primary" onClick={handleImport} disabled={!selectedId || importing}>
            {importing ? "Importing…" : "Import"}
          </button>
        </div>
      </div>
    </div>
  );
}
