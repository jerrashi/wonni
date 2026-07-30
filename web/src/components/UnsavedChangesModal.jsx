// Shown when the user tries to navigate away from a draft with unsaved
// edits still staged in pendingEdits. Mirrors the modal-overlay/modal
// styling convention used inline throughout ProductDetail.jsx (e.g.
// MercariModal) — there's no shared <Modal> primitive in this codebase yet.
export default function UnsavedChangesModal({ saving, error, onSave, onDiscard, onCancel }) {
  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 420 }}>
        <div className="modal-header">
          <h2>Save changes?</h2>
        </div>
        <div className="modal-body">
          <p>You have unsaved changes to this draft. Save them before leaving?</p>
          {error && <div style={{ fontSize: 13, color: "var(--danger)", marginTop: 8 }}>{error}</div>}
        </div>
        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onCancel} disabled={saving}>Cancel</button>
          <button className="btn btn-danger" onClick={onDiscard} disabled={saving}>Discard</button>
          <button className="btn btn-primary" onClick={onSave} disabled={saving}>
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
