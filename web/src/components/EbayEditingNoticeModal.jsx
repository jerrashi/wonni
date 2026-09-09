import React from "react";

export function EbayEditingNoticeModal({ isOpen, onClose }) {
  if (!isOpen) return null;

  const handleDismiss = () => {
    localStorage.setItem("hasSeenEbayEditingNotice", "true");
    onClose();
  };

  return (
    <div className="modal-overlay" style={{ zIndex: 10000, background: "rgba(0,0,0,0.6)", backdropFilter: "blur(2px)" }}>
      <div className="modal-content" style={{ maxWidth: 480, padding: 24, borderRadius: 12, border: "1px solid var(--border)", background: "var(--surface)" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 14 }}>
          <span style={{ fontSize: 24 }}>ℹ️</span>
          <h3 style={{ margin: 0, fontSize: 18, fontWeight: 600 }}>Managing Your eBay Listing</h3>
        </div>

        <p style={{ fontSize: 13, lineHeight: 1.6, color: "var(--text-secondary, var(--muted))", marginBottom: 14 }}>
          Your item was successfully posted to eBay via API! Here is how editing works for API-connected listings:
        </p>

        <div style={{ background: "var(--surface-hover)", padding: 14, borderRadius: 8, marginBottom: 16, fontSize: 13, display: "flex", flexDirection: "column", gap: 10 }}>
          <div>
            <strong style={{ color: "var(--accent, #6366f1)" }}>1. Edit in Wonni (Recommended):</strong>
            <div style={{ color: "var(--text-secondary, var(--muted))", marginTop: 2 }}>
              Update title, price, description, or stock right here in Wonni. Edits push to eBay automatically.
            </div>
          </div>

          <div>
            <strong>2. Editing on eBay:</strong>
            <div style={{ color: "var(--text-secondary, var(--muted))", marginTop: 2 }}>
              eBay locks the standard consumer edit page (<em>"Created by external tool"</em>). To edit on eBay, use <a href="https://www.ebay.com/sh/lst/active" target="_blank" rel="noreferrer" style={{ color: "var(--accent, #6366f1)", textDecoration: "underline" }}>eBay Seller Hub</a>.
            </div>
          </div>

          <div>
            <strong>3. Syncing Changes:</strong>
            <div style={{ color: "var(--text-secondary, var(--muted))", marginTop: 2 }}>
              If you change prices or stock in Seller Hub, click <strong>"🔄 Sync from eBay"</strong> on the Product Detail page to pull the edits into Wonni.
            </div>
          </div>
        </div>

        <div style={{ display: "flex", justifyContent: "flex-end" }}>
          <button className="btn btn-primary" onClick={handleDismiss} style={{ padding: "8px 20px" }}>
            Got It
          </button>
        </div>
      </div>
    </div>
  );
}
