import { useState, useEffect } from "react";
import { doc, onSnapshot, setDoc } from "firebase/firestore";
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
  // Use Web Crypto CSPRNG for cryptographically secure randomness (RFC 7636 S4.1)
  const bytes = new Uint8Array(96);
  crypto.getRandomValues(bytes);
  // Base64url-encode without padding
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
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

  // Seller address & shipping settings (for eBay & shipping policies)
  const [addressLine1, setAddressLine1] = useState("");
  const [city, setCity] = useState("");
  const [stateOrProvince, setStateOrProvince] = useState("");
  const [postalCode, setPostalCode] = useState("");
  const [country, setCountry] = useState("US");
  const [shippingType, setShippingType] = useState("calculated");
  const [buyerPaysShipping, setBuyerPaysShipping] = useState(true);
  const [handlingTimeDays, setHandlingTimeDays] = useState(1);
  const [returnsAccepted, setReturnsAccepted] = useState(false);
  const [returnWindowDays, setReturnWindowDays] = useState(30);
  const [savingSettings, setSavingSettings] = useState(false);
  const [settingsSavedMessage, setSettingsSavedMessage] = useState("");

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
    const ref = doc(db, "users", uid, "sellingSettings", "default");
    return onSnapshot(ref, (snap) => {
      if (snap.exists()) {
        const data = snap.data();
        if (data.defaultLocation) {
          setAddressLine1(data.defaultLocation.addressLine1 || "");
          setCity(data.defaultLocation.city || "");
          setStateOrProvince(data.defaultLocation.stateOrProvince || "");
          setPostalCode(data.defaultLocation.postalCode || "");
          setCountry(data.defaultLocation.country || "US");
        }
        if (data.shippingType) setShippingType(data.shippingType);
        if (typeof data.buyerPaysShipping === "boolean") setBuyerPaysShipping(data.buyerPaysShipping);
        if (data.handlingTimeDays) setHandlingTimeDays(data.handlingTimeDays);
        if (typeof data.returnsAccepted === "boolean") setReturnsAccepted(data.returnsAccepted);
        if (data.returnWindowDays) setReturnWindowDays(data.returnWindowDays);
      }
    });
  }, []);

  async function handleSaveSellingSettings(e) {
    e.preventDefault();
    const uid = auth.currentUser?.uid;
    if (!uid) return;
    setSavingSettings(true);
    setSettingsSavedMessage("");
    try {
      await setDoc(
        doc(db, "users", uid, "sellingSettings", "default"),
        {
          defaultLocation: {
            addressLine1,
            city,
            stateOrProvince,
            postalCode,
            country: country || "US",
          },
          shippingType,
          buyerPaysShipping,
          handlingTimeDays: parseInt(handlingTimeDays, 10) || 1,
          returnsAccepted,
          returnWindowDays: parseInt(returnWindowDays, 10) || 30,
        },
        { merge: true }
      );
      setSettingsSavedMessage("Settings saved successfully.");
      setTimeout(() => setSettingsSavedMessage(""), 3000);
    } catch (err) {
      alert("Failed to save seller settings: " + err.message);
    } finally {
      setSavingSettings(false);
    }
  }

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
      localStorage.setItem(`etsy_verifier_${state}`, codeVerifier);
      sessionStorage.setItem(`etsy_verifier_${state}`, codeVerifier);
      localStorage.setItem("latest_etsy_verifier", codeVerifier);

      const handleEtsyMessage = async (event) => {
        // Validate origin to prevent postMessage spoofing
        if (event.origin !== window.location.origin || event.source !== popup) return;

        if (event.data?.type === "ETSY_AUTH_CALLBACK") {
          const { code, state: returnedState, error } = event.data;

          if (error) {
            window.removeEventListener("message", handleEtsyMessage);
            if (event.source) {
              try {
                event.source.postMessage({ type: "ETSY_AUTH_ERROR", error }, window.location.origin);
              } catch (_) {}
            }
            alert(`Etsy authorization failed: ${error}`);
            return;
          }

          if (code) {
            window.removeEventListener("message", handleEtsyMessage);
            const verifier =
              (returnedState && (localStorage.getItem(`etsy_verifier_${returnedState}`) || sessionStorage.getItem(`etsy_verifier_${returnedState}`))) ||
              localStorage.getItem(`etsy_verifier_${state}`) ||
              sessionStorage.getItem(`etsy_verifier_${state}`) ||
              localStorage.getItem("latest_etsy_verifier") ||
              codeVerifier;

            try {
              const res = await callFunction("etsyExchangeToken")({
                code,
                codeVerifier: verifier,
                redirectUri: "https://wonni-app.web.app/web/oauth/etsy",
              });

              if (event.source) {
                try {
                  event.source.postMessage(
                    {
                      type: "ETSY_AUTH_SUCCESS",
                      shopName: res.data?.shopName,
                    },
                    window.location.origin
                  );
                } catch (_) {}
              }

              if (returnedState) {
                localStorage.removeItem(`etsy_verifier_${returnedState}`);
                sessionStorage.removeItem(`etsy_verifier_${returnedState}`);
              }
              localStorage.removeItem(`etsy_verifier_${state}`);
              sessionStorage.removeItem(`etsy_verifier_${state}`);
              localStorage.removeItem("latest_etsy_verifier");
            } catch (err) {
              console.error("Failed to exchange Etsy token:", err);
              if (event.source) {
                try {
                  event.source.postMessage(
                    {
                      type: "ETSY_AUTH_ERROR",
                      error: err.message || "Failed to exchange token",
                    },
                    window.location.origin
                  );
                } catch (_) {}
              }
              alert(`Failed to connect Etsy: ${err.message || "Unknown error"}`);
            }
          }
        }
      };

      window.addEventListener("message", handleEtsyMessage);

      const etsyUrl = "https://www.etsy.com/oauth/connect?" + new URLSearchParams({
        response_type: "code",
        client_id: ETSY_CLIENT_ID,
        redirect_uri: "https://wonni-app.web.app/web/oauth/etsy",
        scope: "listings_w listings_r shops_r",
        state,
        code_challenge: codeChallenge,
        code_challenge_method: "S256",
      });

      const popup = window.open(etsyUrl, "etsyOAuth", "width=600,height=700");

      const timer = setInterval(() => {
        if (popup && popup.closed) {
          clearInterval(timer);
          window.removeEventListener("message", handleEtsyMessage);
        }
      }, 1000);

      return;
    }

    // Handle eBay OAuth with postMessage (similar to Etsy)
    if (platform === "ebay") {
      const popup = window.open(urls[platform], "ebayOAuth", "width=600,height=700");

      const handleEbayMessage = (event) => {
        // Validate origin to prevent postMessage spoofing
        if (event.origin !== window.location.origin || event.source !== popup) return;

        if (event.data?.type === "EBAY_AUTH_SUCCESS") {
          window.removeEventListener("message", handleEbayMessage);
          // Refresh integrations to show eBay as connected
          loadIntegrations();
        } else if (event.data?.type === "EBAY_AUTH_ERROR") {
          window.removeEventListener("message", handleEbayMessage);
          alert(`eBay authorization failed: ${event.data.error}`);
        }
      };

      window.addEventListener("message", handleEbayMessage);

      const timer = setInterval(() => {
        if (popup && popup.closed) {
          clearInterval(timer);
          window.removeEventListener("message", handleEbayMessage);
        }
      }, 1000);

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
        <h2>Seller & Shipping Settings (eBay)</h2>
        <p style={{ fontSize: 13, color: "var(--muted)", marginBottom: 16 }}>
          eBay requires a ship-from address and business policy settings to publish listings.
        </p>
        <form onSubmit={handleSaveSellingSettings}>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 12 }}>
            <div style={{ gridColumn: "1 / -1" }}>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                Street Address
              </label>
              <input
                className="input"
                style={{ width: "100%" }}
                value={addressLine1}
                onChange={(e) => setAddressLine1(e.target.value)}
                placeholder="123 Main St"
                required
              />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                City
              </label>
              <input
                className="input"
                style={{ width: "100%" }}
                value={city}
                onChange={(e) => setCity(e.target.value)}
                placeholder="New York"
                required
              />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                State / Province
              </label>
              <input
                className="input"
                style={{ width: "100%" }}
                value={stateOrProvince}
                onChange={(e) => setStateOrProvince(e.target.value)}
                placeholder="NY"
                required
              />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                Postal Code
              </label>
              <input
                className="input"
                style={{ width: "100%" }}
                value={postalCode}
                onChange={(e) => setPostalCode(e.target.value)}
                placeholder="10001"
                required
              />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                Country
              </label>
              <input
                className="input"
                style={{ width: "100%" }}
                value={country}
                onChange={(e) => setCountry(e.target.value)}
                placeholder="US"
                required
              />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                Default Shipping Type
              </label>
              <select
                className="input"
                style={{ width: "100%" }}
                value={shippingType}
                onChange={(e) => setShippingType(e.target.value)}
              >
                <option value="calculated">USPS Ground Advantage (Calculated)</option>
                <option value="mediaMailUSPS">USPS Media Mail</option>
                <option value="firstClassEnvelope">USPS First Class Envelope</option>
              </select>
            </div>
            <div>
              <label style={{ display: "block", fontSize: 12, fontWeight: 500, marginBottom: 4 }}>
                Handling Time (Days)
              </label>
              <input
                className="input"
                type="number"
                min="1"
                max="30"
                style={{ width: "100%" }}
                value={handlingTimeDays}
                onChange={(e) => setHandlingTimeDays(e.target.value)}
              />
            </div>
            <div style={{ gridColumn: "1 / -1", display: "flex", gap: 24, alignItems: "center", marginTop: 4 }}>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={buyerPaysShipping}
                  onChange={(e) => setBuyerPaysShipping(e.target.checked)}
                />
                Buyer pays shipping (Calculated)
              </label>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={returnsAccepted}
                  onChange={(e) => setReturnsAccepted(e.target.checked)}
                />
                Accept returns
              </label>
              {returnsAccepted && (
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <label style={{ fontSize: 12 }}>Window:</label>
                  <select
                    className="input"
                    style={{ padding: "4px 8px", fontSize: 12 }}
                    value={returnWindowDays}
                    onChange={(e) => setReturnWindowDays(e.target.value)}
                  >
                    <option value="14">14 days</option>
                    <option value="30">30 days</option>
                    <option value="60">60 days</option>
                  </select>
                </div>
              )}
            </div>
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <button className="btn btn-primary" type="submit" disabled={savingSettings}>
              {savingSettings ? "Saving…" : "Save Seller Settings"}
            </button>
            {settingsSavedMessage && (
              <span style={{ fontSize: 13, color: "var(--success)" }}>{settingsSavedMessage}</span>
            )}
          </div>
        </form>
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
