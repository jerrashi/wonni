import { useState, useEffect } from "react";
import { doc, onSnapshot } from "firebase/firestore";
import { linkWithPopup } from "firebase/auth";
import { db, auth, googleProvider, appleProvider, callFunction } from "../firebase";
import Layout from "../components/Layout";

const EXT_ID = import.meta.env.VITE_EXTENSION_ID;

function sendToExtension(msg) {
  if (!EXT_ID || typeof chrome === "undefined" || !chrome.runtime?.sendMessage) return;
  chrome.runtime.sendMessage(EXT_ID, msg).catch(() => {});
}

const ALIEXPRESS_APP_KEY = import.meta.env.VITE_ALIEXPRESS_APP_KEY ?? "REPLACE_ME";
const TIKTOK_APP_KEY = import.meta.env.VITE_TIKTOK_APP_KEY ?? "REPLACE_ME";
const EBAY_CLIENT_ID = import.meta.env.VITE_EBAY_CLIENT_ID ?? "REPLACE_ME";
const EBAY_RU_NAME = import.meta.env.VITE_EBAY_RU_NAME ?? "REPLACE_ME";
const EBAY_AUTH_HOST = import.meta.env.VITE_EBAY_ENV === "production"
  ? "auth.ebay.com"
  : "auth.sandbox.ebay.com";
const EBAY_SCOPES = [
  "https://api.ebay.com/oauth/api_scope/sell.inventory",
  "https://api.ebay.com/oauth/api_scope/sell.account",
].join(" ");
const ETSY_CLIENT_ID = import.meta.env.VITE_ETSY_CLIENT_ID ?? "REPLACE_ME";

// PKCE helpers for Etsy OAuth
async function generateCodeChallenge(verifier) {
  const encoder = new TextEncoder();
  const data = encoder.encode(verifier);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return btoa(String.fromCharCode(...new Uint8Array(hash)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}

function generateCodeVerifier() {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
  let verifier = "";
  for (let i = 0; i < 128; i++) {
    verifier += chars[Math.floor(Math.random() * chars.length)];
  }
  return verifier;
}

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

const SIGN_IN_METHODS = [
  { id: "google.com", label: "Google", provider: googleProvider },
  { id: "apple.com", label: "Apple", provider: appleProvider },
];

export default function Settings() {
  const [integrations, setIntegrations] = useState({});
  const [feeRate, setFeeRate] = useState("7.5");
  const [linkedProviderIds, setLinkedProviderIds] = useState(
    () => auth.currentUser?.providerData.map((p) => p.providerId) ?? []
  );
  const [linkError, setLinkError] = useState("");

  async function linkProvider(provider) {
    setLinkError("");
    try {
      await linkWithPopup(auth.currentUser, provider);
      setLinkedProviderIds(auth.currentUser.providerData.map((p) => p.providerId));
    } catch (e) {
      setLinkError(e.message ?? "Could not link account.");
    }
  }

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
    const platforms = ["aliexpress", "tiktok", "ebay", "etsy"];
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

    const urls = {
      // redirect_uri must exactly match what's registered in each platform's
      // own developer console (AliExpress Open Platform / TikTok Shop
      // Partner Center) — updating this string alone does nothing until
      // that registration is also updated to the new /web/oauth/* path.
      aliexpress: "https://oauth.aliexpress.com/authorize?" + new URLSearchParams({
        response_type: "code",
        client_id: ALIEXPRESS_APP_KEY,
        redirect_uri: "https://wonni-app.web.app/web/oauth/aliexpress",
        state,
      }),
      tiktok: "https://auth.tiktok-shops.com/oauth/authorize?" + new URLSearchParams({
        app_key: TIKTOK_APP_KEY,
        redirect_uri: "https://wonni-app.web.app/web/oauth/tiktok",
        state,
      }),
      // eBay's redirect_uri is the RuName; the RuName config points at /oauth/ebay
      ebay: `https://${EBAY_AUTH_HOST}/oauth2/authorize?` + new URLSearchParams({
        client_id: EBAY_CLIENT_ID,
        redirect_uri: EBAY_RU_NAME,
        response_type: "code",
        scope: EBAY_SCOPES,
        state,
      }),
    };

    // Handle Etsy separately due to PKCE requirement
    if (platform === "etsy") {
      const codeVerifier = generateCodeVerifier();
      const codeChallenge = await generateCodeChallenge(codeVerifier);
      sessionStorage.setItem(`etsy_verifier_${state}`, codeVerifier);

      const etsyUrl = "https://www.etsy.com/oauth/connect?" + new URLSearchParams({
        response_type: "code",
        client_id: ETSY_CLIENT_ID,
        redirect_uri: "https://wonni-app.web.app/web/oauth/etsy",
        scope: "listings_w listings_r shops_r",
        state,
        code_challenge: codeChallenge,
        code_challenge_method: "S256",
      });

      window.open(etsyUrl, "_blank", "width=600,height=700");
      return;
    }

    const url = urls[platform];
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
        <h2>Linked Sign-in Methods</h2>
        {linkError && <div style={{ fontSize: 12, color: "var(--danger)", marginBottom: 8 }}>{linkError}</div>}
        <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
          {SIGN_IN_METHODS.map(({ id, label, provider }) => {
            const linked = linkedProviderIds.includes(id);
            const email = auth.currentUser?.providerData.find((p) => p.providerId === id)?.email;
            return (
              <div className="connect-row" key={id}>
                <div className="connect-info">
                  <span>{label}</span>
                  <span>{linked ? `Linked${email ? ` as ${email}` : ""}` : `Not linked — sign in with ${label} on this account`}</span>
                </div>
                {!linked && (
                  <button className="btn btn-primary" onClick={() => linkProvider(provider)}>Link</button>
                )}
              </div>
            );
          })}
        </div>
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
          <ConnectRow
            label="eBay"
            description="Connect to list products with one click"
            connected={integrations.ebay?.isConnected}
            username={integrations.ebay?.connectedUsername}
            onConnect={() => openOAuth("ebay")}
            onDisconnect={() => disconnect("ebay")}
          />
          <ConnectRow
            label="Etsy"
            description="Connect to cross-post to your Etsy shop"
            connected={integrations.etsy?.isConnected}
            username={integrations.etsy?.connectedUsername}
            onConnect={() => openOAuth("etsy")}
            onDisconnect={() => disconnect("etsy")}
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
