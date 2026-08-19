export default function ApplyMercariEditsModal({
  hasDrift,
  onApplyEdits,
  onDontChange,
  applying,
}) {
  if (!hasDrift) return null;

  return (
    <div className="modal-overlay" onClick={onDontChange}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>Unapplied Mercari Changes</h2>
        </div>

        <div className="modal-body">
          <p style={{ fontSize: 13, marginBottom: 12 }}>
            You have made changes to this product's title, description, price, or photos that haven't been synced to Mercari yet.
          </p>
          <p style={{ fontSize: 13, color: "var(--muted)" }}>
            Would you like to apply these changes to your live Mercari listing before leaving?
          </p>
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onDontChange} disabled={applying}>
            Don't Change
          </button>
          <button
            className="btn btn-primary"
            onClick={onApplyEdits}
            disabled={applying}
          >
            {applying ? "Applying…" : "Apply Edits"}
          </button>
        </div>
      </div>
    </div>
  );
}
