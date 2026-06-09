import { useState, useEffect } from "react";
import { doc, onSnapshot } from "firebase/firestore";
import { db, auth, callFunction } from "../firebase";
import Layout from "../components/Layout";

const EXT_ID = import.meta.env.VITE_EXTENSION_ID;

function sendToExtension(msg) {
  if (!EXT_ID || typeof chrome === "undefined" || !chrome.runtime?.sendMessage) return;
  chrome.runtime.sendMessage(EXT_ID, msg).catch(() => {});
}

const ALIEXPRESS_APP_KEY = import.meta.env.VITE_ALIEXPRESS_APP_KEY ?? "REPLACE_ME";
const TIKTOK_APP_KEY = import.meta.env.VITE_TIKTOK_APP_KEY ?? "REPLACE_ME";

function ConnectRow({ label, description, connected, username, onConnect, onDisconnect }) {
  return (
    <div className="connect-row">
      <div className="connect-info">
        <span>{label}</span>
        <span>{connected ? `Connected as ${username ?? "unknown"}` : description}</span>
      </div>
      {connected ? (
        <button className="btn btn-ghost" onClick={onDisconnect}>Disconnect</button>
      ) : (
        <button className="btn btn-primary" onClick={onConnect}>Connect</button>
      )}
    </div>
  );
}

export default function Settings() {
  const [integrations, setIntegrations] = useState({});
  const [feeRate, setFeeRate] = useState("7.5");

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) return;
    const ref = doc(db, "users", uid);
    return onSnapshot(ref, (snap) => {
      const data = snap.data() ?? {};
      setFeeRate(String((data.tiktokFeeRate ?? 0.075) * 100));
    });
  }, []);

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) return;
    const platforms = ["aliexpress", "tiktok"];
    const unsubs = platforms.map((p) =>
      onSnapshot(doc(db, "users", uid, "integrations", p), (snap) => {
        setIntegrations((prev) => ({ ...prev, [p]: snap.data() }));
      })
    );
    return () => unsubs.forEach((u) => u());
  }, []);

  async function openOAuth(platform) {
    const { data } = await callFunction("generateOAuthState")({ platform });
    const state = data.state;

    const url = platform === "aliexpress"
      ? "https://oauth.aliexpress.com/authorize?" + new URLSearchParams({
          response_type: "code",
          client_id: ALIEXPRESS_APP_KEY,
          redirect_uri: "https://wonni-dropship.web.app/oauth/aliexpress",
          state,
        })
      : "https://auth.tiktok-shops.com/oauth/authorize?" + new URLSearchParams({
          app_key: TIKTOK_APP_KEY,
          redirect_uri: "https://wonni-dropship.web.app/oauth/tiktok",
          state,
        });

    window.open(url, "_blank", "width=600,height=700");
  }

  async function disconnect(platform) {
    await callFunction("disconnectPlatform")({ platform });
  }

  return (
    <Layout>
      <div className="page-header">
        <h1>Settings</h1>
      </div>

      <div className="settings-section">
        <h2>Platform Connections</h2>
        <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
          <ConnectRow
            label="AliExpress"
            description="Connect to import products and place orders"
            connected={integrations.aliexpress?.isConnected}
            username={integrations.aliexpress?.connectedUsername}
            onConnect={() => openOAuth("aliexpress")}
            onDisconnect={() => disconnect("aliexpress")}
          />
          <ConnectRow
            label="TikTok Shop"
            description="Connect to list products and receive orders"
            connected={integrations.tiktok?.isConnected}
            username={integrations.tiktok?.connectedUsername}
            onConnect={() => openOAuth("tiktok")}
            onDisconnect={() => disconnect("tiktok")}
          />
        </div>
      </div>

      <div className="settings-section">
        <h2>Margin Calculator</h2>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <label style={{ fontSize: 14 }}>TikTok Shop fee rate (%)</label>
          <input
            className="input"
            style={{ width: 100 }}
            type="number"
            step="0.1"
            value={feeRate}
            onChange={(e) => setFeeRate(e.target.value)}
          />
          <button
            className="btn btn-primary"
            onClick={async () => {
              const rate = parseFloat(feeRate) / 100;
              await callFunction("updateSettings")({ tiktokFeeRate: rate });
              sendToExtension({ type: "SET_FEE_RATE", feeRate: rate });
            }}
          >
            Save
          </button>
        </div>
        <div style={{ marginTop: 8, fontSize: 12, color: "var(--muted)" }}>
          Default 7.5% = 5% referral + 2.5% transaction. Used by the Chrome extension margin calculator.
        </div>
      </div>
    </Layout>
  );
}
