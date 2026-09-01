import { useState } from "react";
import { doc, updateDoc, arrayUnion, arrayRemove, serverTimestamp } from "firebase/firestore";
import { db } from "../firebase";

export default function BulkTagModal({ products, allUserTags = [], onClose, onUpdated }) {
  const [tagInput, setTagInput] = useState("");
  const [tagsToAdd, setTagsToAdd] = useState([]);
  const [tagsToRemove, setTagsToRemove] = useState([]);
  const [showSuggestions, setShowSuggestions] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [error, setError] = useState("");
  const [statusMessage, setStatusMessage] = useState("");

  // Collect all tags that currently exist on any of the selected products
  const selectedProductsExistingTags = Array.from(
    new Set(
      products.flatMap((p) => (Array.isArray(p.tags) ? p.tags : []))
    )
  ).sort((a, b) => a.localeCompare(b));

  const matchingSuggestions = allUserTags.filter(
    (t) =>
      t.toLowerCase().includes(tagInput.trim().toLowerCase()) &&
      !tagsToAdd.includes(t)
  );

  function handleAddTagToList(tag) {
    const clean = (typeof tag === "string" ? tag : tagInput).trim();
    if (!clean) return;
    if (!tagsToAdd.includes(clean)) {
      setTagsToAdd([...tagsToAdd, clean]);
    }
    setTagInput("");
    setShowSuggestions(false);
  }

  function handleRemoveTagFromAddList(tag) {
    setTagsToAdd(tagsToAdd.filter((t) => t !== tag));
  }

  function toggleTagToRemove(tag) {
    if (tagsToRemove.includes(tag)) {
      setTagsToRemove(tagsToRemove.filter((t) => t !== tag));
    } else {
      setTagsToRemove([...tagsToRemove, tag]);
    }
  }

  async function handleApplyTags() {
    if (tagsToAdd.length === 0 && tagsToRemove.length === 0) {
      setError("Please select at least one tag to add or remove.");
      return;
    }

    setUpdating(true);
    setError("");
    setStatusMessage("Applying tag changes…");

    try {
      for (const product of products) {
        const docRef = doc(db, "products", product.id);
        const updates = {
          updatedAt: serverTimestamp(),
        };

        if (tagsToAdd.length > 0) {
          updates.tags = arrayUnion(...tagsToAdd);
        }

        await updateDoc(docRef, updates);

        if (tagsToRemove.length > 0) {
          await updateDoc(docRef, {
            tags: arrayRemove(...tagsToRemove),
            updatedAt: serverTimestamp(),
          });
        }
      }

      setStatusMessage("Tags updated successfully!");
      setTimeout(() => {
        onUpdated?.();
        onClose();
      }, 600);
    } catch (err) {
      console.error("Error updating tags:", err);
      setError(err?.message || "Failed to update tags.");
      setUpdating(false);
    }
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" style={{ maxWidth: 520 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <div>
            <h2 style={{ margin: 0, fontSize: 18 }}>🏷️ Bulk Tag Products</h2>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>
              Applying to {products.length} selected product{products.length === 1 ? "" : "s"}
            </span>
          </div>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
        </div>

        <div className="modal-body">
          {/* Add Tags Section */}
          <div className="modal-field" style={{ marginBottom: 16 }}>
            <label style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.05em" }}>
              Add Tags to Selected
            </label>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: tagsToAdd.length ? 8 : 0 }}>
              {tagsToAdd.map((tag) => (
                <span
                  key={tag}
                  style={{
                    display: "inline-flex",
                    alignItems: "center",
                    gap: 6,
                    padding: "3px 8px",
                    background: "rgba(255, 215, 0, 0.15)",
                    border: "var(--border-thin) solid var(--primary)",
                    borderRadius: "var(--radius)",
                    fontSize: 12,
                    fontFamily: "'Space Mono', monospace",
                    color: "var(--primary)",
                  }}
                >
                  <span>+ {tag}</span>
                  <button
                    type="button"
                    onClick={() => handleRemoveTagFromAddList(tag)}
                    style={{
                      background: "transparent",
                      border: "none",
                      color: "var(--primary)",
                      cursor: "pointer",
                      padding: "0 2px",
                      fontSize: 12,
                      lineHeight: 1,
                    }}
                  >
                    ✕
                  </button>
                </span>
              ))}
            </div>

            <div style={{ position: "relative", display: "flex", gap: 8, marginTop: 6 }}>
              <input
                className="input"
                placeholder="Type tag to add..."
                value={tagInput}
                onChange={(e) => {
                  setTagInput(e.target.value);
                  setShowSuggestions(true);
                }}
                onFocus={() => setShowSuggestions(true)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    handleAddTagToList(tagInput);
                  } else if (e.key === "Escape") {
                    setShowSuggestions(false);
                  }
                }}
                style={{ flex: 1 }}
              />
              <button
                type="button"
                className="btn btn-secondary"
                style={{ fontSize: 12, padding: "6px 14px" }}
                onClick={() => handleAddTagToList(tagInput)}
                disabled={!tagInput.trim()}
              >
                Add
              </button>

              {showSuggestions && tagInput.trim() && matchingSuggestions.length > 0 && (
                <div
                  style={{
                    position: "absolute",
                    top: "100%",
                    left: 0,
                    right: 70,
                    background: "var(--surface)",
                    border: "var(--border-thin) solid var(--border)",
                    borderRadius: "var(--radius)",
                    marginTop: 4,
                    maxHeight: 150,
                    overflowY: "auto",
                    zIndex: 40,
                    boxShadow: "0 4px 12px rgba(0, 0, 0, 0.5)",
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
                        handleAddTagToList(st);
                      }}
                    >
                      <span style={{ color: "var(--primary)" }}>🏷️</span> {st}
                    </div>
                  ))}
                </div>
              )}
            </div>

            {allUserTags.length > 0 && (
              <div style={{ marginTop: 8 }}>
                <span style={{ fontSize: 11, color: "var(--muted)", marginRight: 6 }}>Suggested from catalog:</span>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 4, marginTop: 4 }}>
                  {allUserTags.slice(0, 10).map((t) => (
                    <button
                      key={t}
                      type="button"
                      className="btn btn-ghost"
                      style={{
                        fontSize: 11,
                        padding: "2px 8px",
                        borderRadius: "var(--radius)",
                        border: tagsToAdd.includes(t) ? "1px solid var(--primary)" : "1px solid var(--border)",
                        color: tagsToAdd.includes(t) ? "var(--primary)" : "var(--muted)",
                      }}
                      onClick={() => handleAddTagToList(t)}
                    >
                      +{t}
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>

          {/* Remove Tags Section */}
          {selectedProductsExistingTags.length > 0 && (
            <div className="modal-field" style={{ marginTop: 16, paddingTop: 16, borderTop: "1px solid var(--border)" }}>
              <label style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.05em", color: "var(--danger)" }}>
                Remove Existing Tags
              </label>
              <span style={{ fontSize: 11, color: "var(--muted)", display: "block", marginBottom: 8 }}>
                Click a tag to mark it for removal from all selected products:
              </span>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
                {selectedProductsExistingTags.map((tag) => {
                  const isMarked = tagsToRemove.includes(tag);
                  return (
                    <button
                      key={tag}
                      type="button"
                      onClick={() => toggleTagToRemove(tag)}
                      style={{
                        display: "inline-flex",
                        alignItems: "center",
                        gap: 6,
                        padding: "4px 10px",
                        background: isMarked ? "rgba(239, 68, 68, 0.2)" : "var(--surface-high)",
                        border: isMarked ? "1px solid var(--danger)" : "var(--border-thin) solid var(--border)",
                        borderRadius: "var(--radius)",
                        fontSize: 12,
                        fontFamily: "'Space Mono', monospace",
                        color: isMarked ? "var(--danger)" : "var(--text)",
                        cursor: "pointer",
                        textDecoration: isMarked ? "line-through" : "none",
                      }}
                    >
                      <span>{isMarked ? "✕" : "🏷️"} {tag}</span>
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {error && <div style={{ marginTop: 12, fontSize: 13, color: "var(--danger)" }}>{error}</div>}
          {statusMessage && <div style={{ marginTop: 12, fontSize: 13, color: "var(--success)" }}>{statusMessage}</div>}
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose} disabled={updating}>
            Cancel
          </button>
          <button
            className="btn btn-primary"
            onClick={handleApplyTags}
            disabled={updating || (tagsToAdd.length === 0 && tagsToRemove.length === 0)}
          >
            {updating ? "Updating Tags…" : "Apply Tag Changes"}
          </button>
        </div>
      </div>
    </div>
  );
}
