import { useState, useEffect } from "react";
import { collection, query, where, orderBy, onSnapshot } from "firebase/firestore";
import { db, callFunction, auth } from "../firebase";
import Layout from "../components/Layout";

const STATUS_TABS = ["pending", "fulfilling", "shipped", "all"];

function OrderRow({ order, onFulfill }) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleFulfill() {
    setLoading(true);
    setError("");
    try {
      await callFunction("placeAliexpressOrder")({ orderId: order.id });
      onFulfill?.();
    } catch (e) {
      setError(e.message ?? "Failed to fulfill");
    } finally {
      setLoading(false);
    }
  }

  const statusChip = {
    pending: "chip-pending",
    fulfilling: "chip-fulfilling",
    shipped: "chip-shipped",
    cancelled: "chip-draft",
  };

  const margin = order.salePrice && order.aliexpressPrice
    ? ((order.salePrice * 0.925 - order.aliexpressPrice)).toFixed(2)
    : null;

  return (
    <tr>
      <td>
        <div style={{ fontWeight: 500, fontSize: 13 }}>{order.productTitle ?? "—"}</div>
        <div style={{ fontSize: 12, color: "var(--muted)", marginTop: 2 }}>
          {new Date(order.createdAt?.toDate?.() ?? order.createdAt).toLocaleDateString()}
        </div>
      </td>
      <td style={{ fontSize: 13 }}>
        {order.buyerName ?? "—"}
        {order.buyerAddress?.city && (
          <div style={{ fontSize: 12, color: "var(--muted)" }}>
            {order.buyerAddress.city}, {order.buyerAddress.state}
          </div>
        )}
      </td>
      <td style={{ fontSize: 13 }}>${order.salePrice?.toFixed(2) ?? "—"}</td>
      <td style={{ fontSize: 13 }}>
        {margin !== null ? (
          <span style={{ color: parseFloat(margin) > 0 ? "var(--success)" : "var(--danger)" }}>
            ${margin}
          </span>
        ) : "—"}
      </td>
      <td>
        <span className={`chip ${statusChip[order.status] ?? "chip-draft"}`}>{order.status}</span>
      </td>
      <td>
        {order.trackingNumber && (
          <div style={{ fontSize: 12, color: "var(--muted)" }}>{order.trackingNumber}</div>
        )}
        {order.status === "pending" && (
          <button className="btn btn-primary" onClick={handleFulfill} disabled={loading}>
            {loading ? "Placing…" : "Fulfill"}
          </button>
        )}
        {error && <div style={{ fontSize: 12, color: "var(--danger)", marginTop: 4 }}>{error}</div>}
      </td>
    </tr>
  );
}

export default function Orders() {
  const [orders, setOrders] = useState([]);
  const [tab, setTab] = useState("pending");
  const [syncing, setSyncing] = useState(false);

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) return;
    const constraints = [where("userId", "==", uid), orderBy("createdAt", "desc")];
    if (tab !== "all") constraints.splice(1, 0, where("status", "==", tab));
    const q = query(collection(db, "orders"), ...constraints);
    return onSnapshot(q, (snap) => setOrders(snap.docs.map((d) => ({ id: d.id, ...d.data() }))));
  }, [tab]);

  async function handleSync() {
    setSyncing(true);
    try {
      await callFunction("syncTiktokOrders")({});
    } finally {
      setSyncing(false);
    }
  }

  return (
    <Layout>
      <div className="page-header">
        <h1>Orders</h1>
        <button className="btn btn-ghost" onClick={handleSync} disabled={syncing}>
          {syncing ? "Syncing…" : "Sync Orders"}
        </button>
      </div>

      <div className="tab-bar">
        {STATUS_TABS.map((t) => (
          <button key={t} className={`tab ${tab === t ? "active" : ""}`} onClick={() => setTab(t)}>
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>

      {orders.length === 0 ? (
        <div className="empty-state">
          <div style={{ fontSize: 32 }}>🛍️</div>
          <p>No {tab === "all" ? "" : tab} orders yet.</p>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflow: "hidden" }}>
          <table className="orders-table">
            <thead>
              <tr>
                <th>Product</th>
                <th>Buyer</th>
                <th>Sale Price</th>
                <th>Est. Margin</th>
                <th>Status</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {orders.map((o) => <OrderRow key={o.id} order={o} />)}
            </tbody>
          </table>
        </div>
      )}
    </Layout>
  );
}
