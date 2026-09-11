import { useState } from "react";
import { doc, updateDoc, serverTimestamp, Timestamp } from "firebase/firestore";
import { db } from "../firebase";

const STATUSES = [
  { id: "pending", label: "Pending" },
  { id: "shipped", label: "Shipped" },
  { id: "delivered", label: "Delivered" },
  { id: "complete", label: "Complete" },
  { id: "cancelled", label: "Cancelled" },
  { id: "returned", label: "Returned" },
];

const CARRIERS = ["USPS", "UPS", "FedEx", "Other"];

function toDateInput(ts) {
  const d = ts?.toDate?.();
  return d ? d.toISOString().slice(0, 10) : "";
}

// Direct-write edit surface for a recorded sale — matches the field set on
// the iOS SaleDetailSheet. Rules already allow the owner to update sales/{id}
// (functions/contracts/sales.js decision 2026-09-11: no updateSale callable).
export default function EditSaleModal({ sale, onClose, onSaved }) {
  const [soldDate, setSoldDate] = useState(() => toDateInput(sale.soldAt) || new Date().toISOString().slice(0, 10));
  const [takeHome, setTakeHome] = useState(sale.takeHome != null ? String(sale.takeHome) : "");
  const [trackingNumber, setTrackingNumber] = useState(sale.trackingNumber || "");
  const [carrier, setCarrier] = useState(sale.carrier || "");
  const [status, setStatus] = useState(sale.status || "pending");
  const [address, setAddress] = useState({
    name: sale.buyerAddress?.name || "",
    line1: sale.buyerAddress?.line1 || "",
    line2: sale.buyerAddress?.line2 || "",
    city: sale.buyerAddress?.city || "",
    state: sale.buyerAddress?.state || "",
    zip: sale.buyerAddress?.zip || "",
    country: sale.buyerAddress?.country || "",
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  function setAddr(field, value) {
    setAddress((a) => ({ ...a, [field]: value }));
  }

  async function handleSave(e) {
    e.preventDefault();
    setSaving(true);
    setError("");
    try {
      const hasAddress = Object.values(address).some((v) => v.trim());
      await updateDoc(doc(db, "sales", sale.id), {
        soldAt: Timestamp.fromDate(new Date(soldDate + "T12:00:00")),
        takeHome: takeHome.trim() ? parseFloat(takeHome) : null,
        trackingNumber: trackingNumber.trim() || null,
        carrier: carrier || null,
        status,
        buyerAddress: hasAddress ? address : null,
        updatedAt: serverTimestamp(),
      });
      onSaved?.();
      onClose();
    } catch (err) {
      setError(err?.message ?? "Failed to save changes.");
      setSaving(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-content" style={{ maxWidth: 540 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <h2 style={{ margin: 0, fontSize: 18 }}>✏️ Edit Sale</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>✕</button>
        </div>

        <form onSubmit={handleSave}>
          <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: "16px 0" }}>
            <div style={{ fontSize: 13, fontWeight: 600 }}>
              {sale.listingTitle || sale.productTitle || "Manual sale"}
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                  Sale Date
                </label>
                <input className="input" type="date" value={soldDate} onChange={(e) => setSoldDate(e.target.value)} />
              </div>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                  Net Payout ($)
                </label>
                <input
                  className="input"
                  type="number"
                  step="0.01"
                  placeholder="after fees"
                  value={takeHome}
                  onChange={(e) => setTakeHome(e.target.value)}
                />
              </div>
            </div>

            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>Status</label>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                {STATUSES.map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    className={`btn ${status === s.id ? "btn-primary" : "btn-ghost"}`}
                    style={{ fontSize: 12, padding: "6px 12px" }}
                    onClick={() => setStatus(s.id)}
                  >
                    {s.label}
                  </button>
                ))}
              </div>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                  Tracking Number
                </label>
                <input
                  className="input"
                  type="text"
                  value={trackingNumber}
                  onChange={(e) => setTrackingNumber(e.target.value)}
                />
              </div>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>Carrier</label>
                <select className="input" value={carrier} onChange={(e) => setCarrier(e.target.value)}>
                  <option value="">—</option>
                  {CARRIERS.map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                </select>
              </div>
            </div>

            <div>
              <label style={{ fontSize: 12, fontWeight: 600, display: "block", marginBottom: 4 }}>
                Buyer Address (Optional)
              </label>
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                <input className="input" type="text" placeholder="Name" value={address.name} onChange={(e) => setAddr("name", e.target.value)} />
                <input className="input" type="text" placeholder="Address line 1" value={address.line1} onChange={(e) => setAddr("line1", e.target.value)} />
                <input className="input" type="text" placeholder="Address line 2" value={address.line2} onChange={(e) => setAddr("line2", e.target.value)} />
                <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr 1fr", gap: 6 }}>
                  <input className="input" type="text" placeholder="City" value={address.city} onChange={(e) => setAddr("city", e.target.value)} />
                  <input className="input" type="text" placeholder="State" value={address.state} onChange={(e) => setAddr("state", e.target.value)} />
                  <input className="input" type="text" placeholder="ZIP" value={address.zip} onChange={(e) => setAddr("zip", e.target.value)} />
                </div>
                <input className="input" type="text" placeholder="Country" value={address.country} onChange={(e) => setAddr("country", e.target.value)} />
              </div>
            </div>

            {error && <div style={{ fontSize: 12, color: "var(--danger)" }}>{error}</div>}
          </div>

          <div className="modal-footer" style={{ display: "flex", justifyContent: "flex-end", gap: 8, borderTop: "var(--border-thin) solid var(--border)", paddingTop: 12 }}>
            <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
            <button type="submit" className="btn btn-primary" disabled={saving}>
              {saving ? "Saving…" : "Save Changes"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
