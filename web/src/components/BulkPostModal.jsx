import { useState, useEffect } from "react";
import { doc, getDoc, updateDoc, serverTimestamp } from "firebase/firestore";
import { db, auth, callFunction } from "../firebase";
import { EbayEditingNoticeModal } from "./EbayEditingNoticeModal";

const PLATFORMS = [
  { id: "wonni", name: "Wonni", locked: true },
  { id: "ebay", name: "eBay", requiresConnected: true },
  { id: "etsy", name: "Etsy", requiresConnected: true },
  { id: "mercari", name: "Mercari", requiresConnected: false },
  { id: "tiktok", name: "TikTok Shop", requiresConnected: true },
];

export default function BulkPostModal({ products, onClose }) {
  const [integrations, setIntegrations] = useState({});
  const [selected, setSelected] = useState(new Set(["wonni"])); // Wonni always selected
  const [showEbayNotice, setShowEbayNotice] = useState(false);
  const [posting, setPosting] = useState(false);
  const [error, setError] = useState("");
  const [results, setResults] = useState({});

  const uid = auth.currentUser?.uid;

  useEffect(() => {
    if (!uid) return;
    const loadIntegrations = async () => {
      const intData = {};
      for (const p of PLATFORMS) {
        try {
          const snap = await getDoc(doc(db, "users", uid, "integrations", p.id));
          intData[p.id] = snap.data() || {};
        } catch {
          intData[p.id] = {};
        }
      }
      setIntegrations(intData);
    };
    loadIntegrations();
  }, [uid]);

  const togglePlatform = (platformId) => {
    if (platformId === "wonni") return; // Can't deselect Wonni
    const newSelected = new Set(selected);
    if (newSelected.has(platformId)) {
      newSelected.delete(platformId);
    } else {
      newSelected.add(platformId);
    }
    setSelected(newSelected);
  };

  const handleSubmit = async () => {
    setPosting(true);
    setError("");
    setResults({});

    const allResults = {};

    try {
      for (const product of products) {
        allResults[product.id] = {};

        // Always ensure product exists on Wonni first
        try {
          await callFunction("postToWonni")({
            productId: product.id,
          });
          allResults[product.id].wonni = { status: "success" };
        } catch (wErr) {
          allResults[product.id].wonni = { status: "error", message: wErr.message };
        }

        for (const platformId of Array.from(selected)) {
          if (platformId === "wonni") continue; // Already posted above

          try {
            if (platformId === "ebay") {
              const ebayRes = await callFunction("ebayCreateListing")({
                listingId: product.id,
                productId: product.id,
                credentialSet: "web",
              });
              const ebayListingId = ebayRes.data?.listingId;
              if (!localStorage.getItem("hasSeenEbayEditingNotice")) {
                setShowEbayNotice(true);
              }
              try {
                await updateDoc(doc(db, "products", product.id), {
                  ebayStatus: "active",
                  "crossPostStatus.ebay": "active",
                  "crossPostListingIds.ebay": ebayListingId || null,
                  ebayListingId: ebayListingId || null,
                  updatedAt: serverTimestamp(),
                });
              } catch (syncErr) {
                console.warn("Could not update product doc with ebay status:", syncErr);
              }
            } else if (platformId === "etsy") {
              const etsyRes = await callFunction("etsyCreateListing")({
                listingId: product.id,
                credentialSet: "web",
              });
              const etsyListingId = etsyRes.data?.listingId;
              try {
                await updateDoc(doc(db, "products", product.id), {
                  etsyStatus: "active",
                  "crossPostStatus.etsy": "active",
                  "crossPostListingIds.etsy": etsyListingId || null,
                  etsyListingId: etsyListingId || null,
                  updatedAt: serverTimestamp(),
                });
              } catch (syncErr) {
                console.warn("Could not update product doc with etsy status:", syncErr);
              }
            } else if (platformId === "tiktok") {
              await callFunction("tiktokCreateListing")({
                productId: product.id,
                title: product.title.slice(0, 255),
                sellPrice: parseFloat(product.listingPrice || product.aliexpressPrice * 2.5 || 0),
                categoryId: null,
              });
            } else if (platformId === "mercari") {
              const variants = Array.isArray(product.variants) ? product.variants : [];
              const inStockVariants = product.hasVariants
                ? variants.filter((v) => v.active && (v.quantity ?? 0) > 0)
                : [];

              if (product.hasVariants && inStockVariants.length > 0) {
                // Post each in-stock variant separately
                for (const variant of inStockVariants) {
                  const payload = {
                    productId: product.id,
                    variantId: variant.id,
                    title: product.title,
                    description: product.description,
                    price: parseFloat(product.listingPrice || variant.price || product.aliexpressPrice * 2.2 || 15),
                    condition: product.condition || "good",
                    brand: product.brand || "",
                    suggestedCategory: product.category || "",
                    images: product.images || [],
                    weightLbs: product.weightLbs,
                    lengthIn: product.lengthIn,
                    widthIn: product.widthIn,
                    heightIn: product.heightIn,
                  };

                  if (window.chrome?.runtime?.sendMessage) {
                    await new Promise((resolve, reject) => {
                      chrome.runtime.sendMessage(
                        import.meta.env.VITE_EXTENSION_ID,
                        { type: "START_MERCARI_CROSS_POST", payload },
                        (response) => {
                          if (chrome.runtime.lastError) {
                            reject(new Error(chrome.runtime.lastError.message));
                          } else {
                            resolve(response);
                          }
                        }
                      );
                    });
                  } else {
                    localStorage.setItem("pendingMercariPayload", JSON.stringify(payload));
                    window.open("https://www.mercari.com/sell/", "_blank");
                  }
                }
              } else {
                // Legacy single-product posting
                const payload = {
                  productId: product.id,
                  title: product.title,
                  description: product.description,
                  price: parseFloat(product.listingPrice || product.aliexpressPrice * 2.2 || 15),
                  condition: product.condition || "good",
                  brand: product.brand || "",
                  suggestedCategory: product.category || "",
                  images: product.images || [],
                  weightLbs: product.weightLbs,
                  lengthIn: product.lengthIn,
                  widthIn: product.widthIn,
                  heightIn: product.heightIn,
                };

                if (window.chrome?.runtime?.sendMessage) {
                  await new Promise((resolve, reject) => {
                    chrome.runtime.sendMessage(
                      import.meta.env.VITE_EXTENSION_ID,
                      { type: "START_MERCARI_CROSS_POST", payload },
                      (response) => {
                        if (chrome.runtime.lastError) {
                          reject(new Error(chrome.runtime.lastError.message));
                        } else {
                          resolve(response);
                        }
                      }
                    );
                  });
                } else {
                  localStorage.setItem("pendingMercariPayload", JSON.stringify(payload));
                  window.open("https://www.mercari.com/sell/", "_blank");
                }
              }
            }

            allResults[product.id][platformId] = { status: "success" };
          } catch (err) {
            allResults[product.id][platformId] = { status: "error", message: err.message };
          }
        }
      }
    } catch (err) {
      setError(err.message || "Posting failed.");
    } finally {
      setPosting(false);
      setResults(allResults);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>Post {products.length} Products</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>
            ✕
          </button>
        </div>

        <div className="modal-body" style={{ maxHeight: "60vh", overflowY: "auto" }}>
          {error && (
            <div style={{ fontSize: 13, color: "var(--danger)", marginBottom: 12 }}>
              {error}
            </div>
          )}

          <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 16 }}>
            Select platforms to post these {products.length} product{products.length !== 1 ? "s" : ""} to.
            Wonni is always included.
          </div>

          {/* Product list */}
          <div style={{ marginBottom: 16, paddingBottom: 16, borderBottom: "1px solid var(--border)" }}>
            <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8 }}>Products:</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              {products.slice(0, 5).map((p) => (
                <div key={p.id} style={{ fontSize: 12, color: "var(--muted)" }}>
                  • {p.title.slice(0, 60)}{p.title.length > 60 ? "…" : ""}
                </div>
              ))}
              {products.length > 5 && (
                <div style={{ fontSize: 12, color: "var(--muted)" }}>
                  + {products.length - 5} more
                </div>
              )}
            </div>
          </div>

          {/* Platform checkboxes */}
          {PLATFORMS.map((p) => {
            const isConnected = integrations[p.id]?.isConnected;
            const isSelected = selected.has(p.id);
            const isDisabled = (p.requiresConnected && !isConnected) || p.locked;

            return (
              <div key={p.id} style={{ marginBottom: 12, paddingBottom: 12, borderBottom: "1px solid var(--border)" }}>
                <label style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  cursor: isDisabled ? "not-allowed" : "pointer",
                  opacity: isDisabled ? 0.6 : 1
                }}>
                  <input
                    type="checkbox"
                    checked={isSelected}
                    onChange={() => !isDisabled && togglePlatform(p.id)}
                    disabled={isDisabled}
                  />
                  <span style={{ fontWeight: p.locked ? 600 : 500 }}>
                    {p.name}
                    {p.locked && " (always included)"}
                  </span>
                  {isConnected && !p.locked && <span style={{ fontSize: 11, color: "var(--success)" }}>✓ Connected</span>}
                  {!isConnected && p.requiresConnected && (
                    <span style={{ fontSize: 11, color: "var(--muted)" }}>Not connected</span>
                  )}
                </label>
              </div>
            );
          })}
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn-primary"
            onClick={handleSubmit}
            disabled={posting}
          >
            {posting ? "Posting…" : "Post"}
          </button>
        </div>
      </div>

      <EbayEditingNoticeModal
        isOpen={showEbayNotice}
        onClose={() => {
          setShowEbayNotice(false);
          onClose();
        }}
      />
    </div>
  );
}
