import { useState } from "react";

export default function ApplyEbayEditsModal({ product, listingDetails, onApply, onCancel, isLoading }) {
  const [choosing, setChoosing] = useState(null); // null | "wonni" | "ebay"

  if (!listingDetails || !product) return null;

  const { wonni, ebay } = listingDetails;
  const hasDifferences = {
    title: wonni.title !== ebay.title,
    description: wonni.description !== ebay.description,
    price: Math.abs((wonni.price ?? 0) - (ebay.price ?? 0)) > 0.01,
    quantity: wonni.quantity !== ebay.quantity,
    photos: wonni.photoCount != null && ebay.photoCount != null && wonni.photoCount !== ebay.photoCount,
    handlingTime: wonni.handlingTimeDays != null && ebay.handlingTimeDays != null && wonni.handlingTimeDays !== ebay.handlingTimeDays,
  };

  const anyDifference = Object.values(hasDifferences).some(v => v);

  if (!anyDifference) {
    return (
      <div style={{
        position: "fixed", top: 0, left: 0, right: 0, bottom: 0,
        background: "rgba(0, 0, 0, 0.5)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000
      }}>
        <div style={{
          background: "var(--bg)", border: "1px solid var(--border)", borderRadius: 12, padding: 24, maxWidth: 400, boxShadow: "0 10px 40px rgba(0, 0, 0, 0.2)"
        }}>
          <h3>eBay & Wonni are in sync</h3>
          <p style={{ color: "var(--muted)", marginTop: 8, marginBottom: 16 }}>Title, description, price, quantity, and photos all match. No changes needed.</p>
          <button className="btn btn-primary" onClick={onCancel} style={{ width: "100%" }}>
            Close
          </button>
        </div>
      </div>
    );
  }

  return (
    <div style={{
      position: "fixed", top: 0, left: 0, right: 0, bottom: 0,
      background: "rgba(0, 0, 0, 0.5)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000, overflow: "auto", padding: 16
    }}>
      <div style={{
        background: "var(--bg)", border: "1px solid var(--border)", borderRadius: 12, padding: 24, maxWidth: 600, boxShadow: "0 10px 40px rgba(0, 0, 0, 0.2)"
      }}>
        <h3>eBay & Wonni listings are out of sync</h3>
        <p style={{ color: "var(--muted)", marginTop: 8, marginBottom: 20, fontSize: 14 }}>Choose which version to keep. The other will be updated to match.</p>

        {/* Differences table */}
        <div style={{ marginBottom: 20, border: "1px solid var(--border)", borderRadius: 8, overflow: "hidden" }}>
          <table style={{ width: "100%", fontSize: 13, borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ background: "var(--bg-secondary)", borderBottom: "1px solid var(--border)" }}>
                <th style={{ padding: 12, textAlign: "left", fontWeight: 600 }}>Field</th>
                <th style={{ padding: 12, textAlign: "left", fontWeight: 600 }}>Wonni</th>
                <th style={{ padding: 12, textAlign: "left", fontWeight: 600 }}>eBay</th>
              </tr>
            </thead>
            <tbody>
              {hasDifferences.title && (
                <tr style={{ borderBottom: "1px solid var(--border)", background: "rgba(249, 115, 22, 0.05)" }}>
                  <td style={{ padding: 12, fontWeight: 600 }}>Title</td>
                  <td style={{ padding: 12, maxWidth: 150, overflow: "hidden", textOverflow: "ellipsis" }}>{wonni.title}</td>
                  <td style={{ padding: 12, maxWidth: 150, overflow: "hidden", textOverflow: "ellipsis" }}>{ebay.title}</td>
                </tr>
              )}
              {hasDifferences.description && (
                <tr style={{ borderBottom: "1px solid var(--border)", background: "rgba(249, 115, 22, 0.05)" }}>
                  <td style={{ padding: 12, fontWeight: 600 }}>Description</td>
                  <td style={{ padding: 12, maxWidth: 150, overflow: "hidden", textOverflow: "ellipsis", fontSize: 12 }}>
                    {wonni.description.slice(0, 50)}…
                  </td>
                  <td style={{ padding: 12, maxWidth: 150, overflow: "hidden", textOverflow: "ellipsis", fontSize: 12 }}>
                    {ebay.description.slice(0, 50)}…
                  </td>
                </tr>
              )}
              {hasDifferences.price && (
                <tr style={{ borderBottom: "1px solid var(--border)", background: "rgba(249, 115, 22, 0.05)" }}>
                  <td style={{ padding: 12, fontWeight: 600 }}>Price</td>
                  <td style={{ padding: 12 }}>${wonni.price?.toFixed(2)}</td>
                  <td style={{ padding: 12 }}>${ebay.price?.toFixed(2)}</td>
                </tr>
              )}
              {hasDifferences.quantity && (
                <tr style={{ borderBottom: (hasDifferences.photos || hasDifferences.handlingTime) ? "1px solid var(--border)" : "none", background: "rgba(249, 115, 22, 0.05)" }}>
                  <td style={{ padding: 12, fontWeight: 600 }}>Quantity</td>
                  <td style={{ padding: 12 }}>{wonni.quantity}</td>
                  <td style={{ padding: 12 }}>{ebay.quantity}</td>
                </tr>
              )}
              {hasDifferences.photos && (
                <tr style={{ borderBottom: hasDifferences.handlingTime ? "1px solid var(--border)" : "none", background: "rgba(249, 115, 22, 0.05)" }}>
                  <td style={{ padding: 12, fontWeight: 600 }}>Photos</td>
                  <td style={{ padding: 12 }}>{wonni.photoCount} photos</td>
                  <td style={{ padding: 12 }}>{ebay.photoCount} photos</td>
                </tr>
              )}
              {hasDifferences.handlingTime && (
                <tr style={{ background: "rgba(249, 115, 22, 0.05)" }}>
                  <td style={{ padding: 12, fontWeight: 600 }}>Handling Time</td>
                  <td style={{ padding: 12 }}>{wonni.handlingTimeDays} day{wonni.handlingTimeDays === 1 ? "" : "s"}</td>
                  <td style={{ padding: 12 }}>{ebay.handlingTimeDays} day{ebay.handlingTimeDays === 1 ? "" : "s"}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        {/* Choice buttons */}
        <div style={{ display: "flex", gap: 12 }}>
          <button
            className={`btn ${choosing === "wonni" ? "btn-primary" : "btn-ghost"}`}
            onClick={() => setChoosing("wonni")}
            disabled={isLoading}
            style={{ flex: 1 }}
          >
            ✓ Keep Wonni version
            <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 4 }}>Update eBay to match</div>
          </button>
          <button
            className={`btn ${choosing === "ebay" ? "btn-primary" : "btn-ghost"}`}
            onClick={() => setChoosing("ebay")}
            disabled={isLoading}
            style={{ flex: 1 }}
          >
            ✓ Keep eBay version
            <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 4 }}>Update Wonni to match</div>
          </button>
        </div>

        {/* Action buttons */}
        <div style={{ display: "flex", gap: 12, marginTop: 16 }}>
          <button className="btn btn-ghost" onClick={onCancel} disabled={isLoading} style={{ flex: 1 }}>
            Cancel
          </button>
          <button
            className="btn btn-primary"
            onClick={() => onApply(choosing)}
            disabled={!choosing || isLoading}
            style={{ flex: 1 }}
          >
            {isLoading ? "⏳ Applying…" : "Apply"}
          </button>
        </div>
      </div>
    </div>
  );
}
