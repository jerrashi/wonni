import { useEffect, useRef, useState } from "react";
import { callFunction } from "../firebase";
import DraftPhotoChooserModal from "./DraftPhotoChooserModal";

// Text and product links → draft products (2026-10-15; mock approved the same
// day). The web twin of the iOS "Drafts from a List" flow, on the same
// `textToListings` function: the text (with any Amazon / eBay / AliExpress /
// Weverse / other links) is parsed once; listings are priced and photographed
// 40 per round trip (`remaining` → `pendingItems`); an entry that names several
// things ("issues 211-215") comes back in `needsDecision` and is asked about
// ONCE per run while the other entries keep going. Unlike iOS, the web has no
// drafts screen to fix things in afterwards, so there is a review table (ask,
// paid, source, Choose photos) before `commitListingProposals` writes the
// product docs and re-hosts the photos.

const BATCH = 40;

const STORE_NAME = { amazon: "Amazon", ebay: "eBay", aliexpress: "AliExpress", weverse: "Weverse", web: "Web" };

function shortHost(url) {
  try {
    const u = new URL(url);
    const path = u.pathname.length > 24 ? u.pathname.slice(0, 24) + "…" : u.pathname;
    return u.host.replace(/^www\./, "") + (path === "/" ? "" : path);
  } catch {
    return url;
  }
}

export default function TextToListingsModal({ text, onClose, onCreated }) {
  // phase: "working" | "review" | "creating" | "done"
  const [phase, setPhase] = useState("working");
  const [status, setStatus] = useState("Reading your text…");
  const [drafts, setDrafts] = useState([]);
  const [links, setLinks] = useState([]);
  const [decisions, setDecisions] = useState([]);        // waiting for the user
  const [decisionChoices, setDecisionChoices] = useState({}); // index → "individual" | "bundle"
  const [showDecisions, setShowDecisions] = useState(false);
  const [checked, setChecked] = useState(new Set());
  const [chooserFor, setChooserFor] = useState(null);     // draft index
  const [error, setError] = useState("");
  const [result, setResult] = useState(null);
  const cancelled = useRef(false);
  const decisionResolver = useRef(null);

  useEffect(() => {
    run();
    return () => { cancelled.current = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const draftCount = useRef(0);
  /** Every new row starts checked; the user unticks what they don't want. */
  function addDrafts(list) {
    const start = draftCount.current;
    draftCount.current += list.length;
    setDrafts((prev) => [...prev, ...list]);
    setChecked((c) => {
      const next = new Set(c);
      list.forEach((_, i) => next.add(start + i));
      return next;
    });
  }

  async function run() {
    const propose = callFunction("textToListings", { timeout: 540000 });
    let queue = [];
    let context = "";
    let unparsed = text.trim();
    let pendingDecision = null; // Promise<[pendingItems]>
    try {
      while (!cancelled.current) {
        let response;
        if (queue.length) {
          const batch = queue.slice(0, BATCH);
          setStatus(`Pricing and finding photos… ${queue.length} to go`);
          response = (await propose({ pendingItems: batch, context: context || undefined, maxItems: BATCH })).data;
          queue = queue.slice(batch.length);
        } else if (unparsed) {
          response = (await propose({ text: unparsed, context: context || undefined, maxItems: BATCH })).data;
          queue = response.remaining || [];
          if (response.context) context = response.context;
          if (response.links?.length) setLinks((l) => [...l, ...response.links]);
          if (response.needsDecision?.length) {
            pendingDecision = askDecisions(response.needsDecision);
          }
          const tail = (response.unparsedText || "").trim();
          if (!tail) unparsed = "";
          else if (!response.drafts?.length && !response.remaining?.length) { unparsed = ""; setError("Part of the text couldn't be read."); }
          else unparsed = tail;
        } else if (pendingDecision) {
          setStatus("Waiting for your answer…");
          queue = await pendingDecision;
          pendingDecision = null;
          continue;
        } else {
          break;
        }
        if (response.drafts?.length) addDrafts(response.drafts);
      }
    } catch (e) {
      setError(e.message ?? "Something went wrong");
    }
    if (!cancelled.current) setPhase("review");
  }

  /** One question per run (the mock's "Several items in one entry"). */
  function askDecisions(asked) {
    return new Promise((resolve) => {
      setDecisions((prev) => [...prev, ...asked]);
      setShowDecisions(true);
      decisionResolver.current = resolve;
    });
  }

  function answerDecisions() {
    const items = decisions.flatMap((d, i) => (decisionChoices[i] === "bundle" ? [d.asBundle] : d.asIndividual));
    setShowDecisions(false);
    setDecisions([]);
    setDecisionChoices({});
    decisionResolver.current?.(items);
    decisionResolver.current = null;
  }

  function toggle(i) {
    setChecked((c) => { const n = new Set(c); n.has(i) ? n.delete(i) : n.add(i); return n; });
  }

  function patchDraft(i, patch) {
    setDrafts((prev) => prev.map((d, j) => (j === i ? { ...d, ...patch } : d)));
  }

  async function create() {
    const chosen = drafts.filter((_, i) => checked.has(i));
    if (!chosen.length) return;
    setPhase("creating");
    setError("");
    try {
      const res = await callFunction("commitListingProposals", { timeout: 300000 })({ proposals: chosen });
      setResult(res.data);
      setPhase("done");
      onCreated?.(res.data?.productIds ?? []);
    } catch (e) {
      setError(e.message ?? "Couldn't create the drafts");
      setPhase("review");
    }
  }

  const sourceChip = (d) => {
    if (d.source) return { text: STORE_NAME[d.source] || d.source, tone: "src" };
    return { text: "Text", tone: "neutral" };
  };
  const toneStyle = {
    src: { background: "rgba(255,215,0,0.14)", color: "var(--primary)" },
    neutral: { background: "var(--surface-high)", color: "var(--muted)" },
    bad: { background: "rgba(239,68,68,0.14)", color: "var(--danger)" },
  };
  const photoLabel = (d) => {
    const n = d.imageUrls?.length || 0;
    if (d.imageSource === "source") return `${n} photo${n === 1 ? "" : "s"} from the link`;
    if (d.imageSource === "ebay") return n > 1 ? `${n} eBay seller photos` : "eBay seller photo";
    if (d.imageSource === "google") return n > 1 ? `${n} web photos` : "Web photo";
    return "No photo";
  };
  const conditionLabel = { new: "New", likenew: "Like new", good: "Good", fair: "Fair", poor: "Poor" };
  const failedLinks = links.filter((l) => l.status !== "ok");
  const readLinks = links.filter((l) => l.status === "ok");

  // ── decision modal (over the progress view) ─────────────────────────────
  if (showDecisions) {
    return (
      <div className="modal-overlay">
        <div className="modal" style={{ maxWidth: 520 }} onClick={(e) => e.stopPropagation()}>
          <div className="modal-header"><h2>Several items in one entry</h2></div>
          <div className="modal-body">
            <div style={{ fontSize: 13, color: "var(--muted)" }}>
              These entries name more than one thing. List each one on its own, or sell them together as one lot?
            </div>
            {decisions.map((d, i) => (
              <div key={i} style={{ border: "1px solid var(--border)", padding: 12, display: "flex", flexDirection: "column", gap: 8 }}>
                <div style={{ fontWeight: 700, fontSize: 14 }}>{d.title}</div>
                <div style={{ fontSize: 12, color: "var(--muted)" }}>
                  {d.memberTitles.length} items · {d.memberTitles.slice(0, 6).join(", ")}{d.memberTitles.length > 6 ? ", …" : ""}
                  {d.sourceText && d.sourceText.toLowerCase() !== d.title.toLowerCase() ? ` · “${d.sourceText.slice(0, 60)}${d.sourceText.length > 60 ? "…" : ""}”` : ""}
                </div>
                <div style={{ display: "flex", gap: 0, border: "1px solid var(--border)" }}>
                  {[["individual", `${d.memberTitles.length} separate listings`], ["bundle", "One bundle"]].map(([value, label]) => {
                    const on = (decisionChoices[i] || "individual") === value;
                    return (
                      <button
                        key={value}
                        className="btn"
                        style={{ flex: 1, padding: "8px 10px", fontSize: 12, background: on ? "var(--primary)" : "transparent", color: on ? "var(--on-primary)" : "var(--text)" }}
                        onClick={() => setDecisionChoices((c) => ({ ...c, [i]: value }))}
                      >
                        {label}
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
          <div className="modal-footer" style={{ justifyContent: "space-between", alignItems: "center" }}>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>Other entries are being priced meanwhile.</span>
            <button className="btn btn-primary" onClick={answerDecisions}>Continue</button>
          </div>
        </div>
      </div>
    );
  }

  // ── progress ─────────────────────────────────────────────────────────────
  if (phase === "working") {
    return (
      <div className="modal-overlay">
        <div className="modal" style={{ maxWidth: 480 }} onClick={(e) => e.stopPropagation()}>
          <div className="modal-header"><h2>Creating drafts</h2></div>
          <div className="modal-body">
            <div style={{ fontSize: 14 }}>{drafts.length ? `${drafts.length} listing${drafts.length === 1 ? "" : "s"} ready` : "Working…"}</div>
            <div style={{ fontSize: 13, color: "var(--muted)" }}>{status}</div>
            {links.length > 0 && (
              <div style={{ fontSize: 12, color: "var(--muted)" }}>
                {readLinks.length} of {links.length} link{links.length === 1 ? "" : "s"} read
              </div>
            )}
            {error && <div style={{ color: "var(--danger)", fontSize: 13 }}>{error}</div>}
          </div>
          <div className="modal-footer">
            <button className="btn btn-ghost" onClick={() => { cancelled.current = true; setPhase("review"); }}>Stop and review</button>
          </div>
        </div>
      </div>
    );
  }

  // ── done ─────────────────────────────────────────────────────────────────
  if (phase === "done") {
    const made = result?.productIds?.length ?? 0;
    return (
      <div className="modal-overlay" onClick={onClose}>
        <div className="modal" style={{ maxWidth: 480 }} onClick={(e) => e.stopPropagation()}>
          <div className="modal-header"><h2>{made === 1 ? "1 draft created" : `${made} drafts created`}</h2></div>
          <div className="modal-body">
            {result?.errors?.length > 0 && (
              <div style={{ color: "var(--danger)", fontSize: 13 }}>
                {result.errors.length} could not be created: {result.errors.map((e) => `${e.title} (${e.error})`).join("; ")}
              </div>
            )}
            <div style={{ fontSize: 13, color: "var(--muted)" }}>They are in your drafts. Photos from the links were copied to your storage.</div>
          </div>
          <div className="modal-footer"><button className="btn btn-primary" onClick={onClose}>Done</button></div>
        </div>
      </div>
    );
  }

  // ── review ───────────────────────────────────────────────────────────────
  return (
    <>
      <div className="modal-overlay" onClick={phase === "creating" ? undefined : onClose}>
        <div className="modal" style={{ maxWidth: 900 }} onClick={(e) => e.stopPropagation()}>
          <div className="modal-header">
            <h2>Review {drafts.length} draft{drafts.length === 1 ? "" : "s"}</h2>
            <button className="btn btn-ghost" style={{ padding: "4px 10px" }} onClick={onClose} disabled={phase === "creating"}>×</button>
          </div>
          <div className="modal-body">
            {error && <div style={{ color: "var(--danger)", fontSize: 13 }}>{error}</div>}
            {failedLinks.length > 0 && (
              <div style={{ fontSize: 12, color: "var(--warning)" }}>
                {failedLinks.map((l, i) => (
                  <div key={i}>{shortHost(l.url)} could not be {l.status === "partial" ? "fully " : ""}read{l.error ? `: ${l.error.replace(/\.$/, "")}` : ""}. Its draft was built from the link's own words.</div>
                ))}
              </div>
            )}
            {!drafts.length && <div style={{ color: "var(--muted)", fontSize: 13 }}>No listings were found in that text.</div>}
            {drafts.length > 0 && (
              <div style={{ overflowX: "auto" }}>
                <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
                  <thead>
                    <tr style={{ fontSize: 11, color: "var(--muted)", textTransform: "uppercase", letterSpacing: ".05em", textAlign: "left" }}>
                      <th style={{ padding: 6 }}><input type="checkbox" checked={checked.size === drafts.length} onChange={(e) => setChecked(e.target.checked ? new Set(drafts.map((_, i) => i)) : new Set())} /></th>
                      <th style={{ padding: 6 }}>Photo</th>
                      <th style={{ padding: 6 }}>Listing</th>
                      <th style={{ padding: 6, textAlign: "right" }}>Ask</th>
                      <th style={{ padding: 6, textAlign: "right" }}>Paid</th>
                      <th style={{ padding: 6 }}>Source</th>
                    </tr>
                  </thead>
                  <tbody>
                    {drafts.map((d, i) => {
                      const weak = d.photoMatch !== "strong";
                      const chip = sourceChip(d);
                      return (
                        <tr key={i} style={{ borderTop: "1px solid var(--border)", opacity: checked.has(i) ? 1 : 0.55 }}>
                          <td style={{ padding: 8, verticalAlign: "top" }}><input type="checkbox" checked={checked.has(i)} onChange={() => toggle(i)} /></td>
                          <td style={{ padding: 8, verticalAlign: "top" }}>
                            {d.imageUrls?.[0]
                              ? <img src={d.imageUrls[0]} alt="" style={{ width: 48, height: 48, objectFit: "cover", background: "var(--surface-high)" }} />
                              : <div style={{ width: 48, height: 48, border: "1px dashed var(--border)", display: "grid", placeItems: "center", color: "var(--muted)", fontSize: 10 }}>none</div>}
                          </td>
                          <td style={{ padding: 8, verticalAlign: "top", minWidth: 240 }}>
                            <input
                              className="input"
                              value={d.shortTitle || d.title}
                              onChange={(e) => patchDraft(i, { shortTitle: e.target.value.slice(0, 80), title: d.title })}
                              style={{ fontWeight: 700, padding: "4px 6px", fontSize: 13, width: "100%" }}
                            />
                            <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 4, display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
                              <span>{conditionLabel[d.condition] || d.condition}{d.quantity > 1 ? ` · Qty ${d.quantity}` : ""} · {photoLabel(d)}</span>
                              {weak && (
                                <button className="btn btn-ghost" style={{ padding: "2px 8px", fontSize: 11, color: "var(--warning)", borderColor: "var(--warning)" }} onClick={() => setChooserFor(i)}>
                                  ⚠ {d.imageUrls?.length ? "Photo may not match" : "No photo found"} · Choose photos ›
                                </button>
                              )}
                              {!weak && <button className="btn btn-ghost" style={{ padding: "2px 8px", fontSize: 11 }} onClick={() => setChooserFor(i)}>Choose photos</button>}
                            </div>
                          </td>
                          <td style={{ padding: 8, verticalAlign: "top", textAlign: "right", whiteSpace: "nowrap" }}>
                            <input
                              className="input"
                              value={d.suggestedPrice ?? ""}
                              onChange={(e) => {
                                const v = parseFloat(e.target.value);
                                patchDraft(i, { suggestedPrice: Number.isFinite(v) && v > 0 ? v : undefined, priceSource: Number.isFinite(v) && v > 0 ? "user" : "none" });
                              }}
                              placeholder="—"
                              style={{ width: 84, textAlign: "right", padding: "4px 6px", fontSize: 13 }}
                            />
                            {d.priceSource === "comps" && <div style={{ fontSize: 10, color: "var(--muted)" }}>eBay comps</div>}
                            {d.priceSource === "ai" && <div style={{ fontSize: 10, color: "var(--muted)" }}>AI estimate</div>}
                          </td>
                          <td style={{ padding: 8, verticalAlign: "top", textAlign: "right", whiteSpace: "nowrap", fontVariantNumeric: "tabular-nums" }}>
                            {d.sourcePrice != null ? `$${Number(d.sourcePrice).toFixed(2)}` : "—"}
                          </td>
                          <td style={{ padding: 8, verticalAlign: "top" }}>
                            <span style={{ ...toneStyle[chip.tone], fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 999, whiteSpace: "nowrap" }}>{chip.text}</span>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
          <div className="modal-footer" style={{ justifyContent: "space-between", alignItems: "center", flexWrap: "wrap" }}>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>Unchecked rows are not created. Photos from eBay, Amazon and other links are copied to your storage.</span>
            <button className="btn btn-primary" onClick={create} disabled={phase === "creating" || !checked.size}>
              {phase === "creating" ? "Creating…" : `Create ${checked.size} draft${checked.size === 1 ? "" : "s"}`}
            </button>
          </div>
        </div>
      </div>
      {chooserFor != null && (
        <DraftPhotoChooserModal
          proposal={drafts[chooserFor]}
          onClose={() => setChooserFor(null)}
          onImport={(patch) => { patchDraft(chooserFor, patch); setChooserFor(null); }}
        />
      )}
    </>
  );
}
