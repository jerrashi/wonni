import { useState, useEffect, useRef } from "react";
import { doc, getDoc, updateDoc, serverTimestamp } from "firebase/firestore";
import { db, auth, callFunction } from "../firebase";
import { EbayEditingNoticeModal } from "./EbayEditingNoticeModal";

const PLATFORMS = [
  { id: "wonni", name: "Wonni", requiresConnected: false, locked: true },
  { id: "ebay", name: "eBay", requiresConnected: true },
  { id: "etsy", name: "Etsy", requiresConnected: true },
  { id: "mercari", name: "Mercari", requiresConnected: false },
  { id: "tiktok", name: "TikTok Shop", requiresConnected: true },
];

export function isPlatformAlreadyPosted(platformId, product) {
  if (!product) return false;
  switch (platformId) {
    case "ebay":
      return product.ebayStatus === "active"
        || product.crossPostStatus?.ebay === "active"
        || product.crossPostStatus?.ebay === "posted"
        || !!product.ebayListingId
        || !!product.crossPostListingIds?.ebay;
    case "etsy":
      return product.etsyStatus === "active"
        || product.crossPostStatus?.etsy === "active"
        || product.crossPostStatus?.etsy === "posted"
        || !!product.etsyListingId
        || !!product.crossPostListingIds?.etsy;
    case "tiktok":
      return product.tiktokStatus === "active"
        || product.crossPostStatus?.tiktok === "active"
        || product.crossPostStatus?.tiktok === "posted";
    case "mercari":
      return product.listingStatus?.mercari === "active"
        || product.crossPostStatus?.mercari === "posted"
        || !!product.listingId?.mercari;
    case "wonni":
      return false;
    default:
      return false;
  }
}

export default function PostModal({ product, onClose, mode = "modal", buttonRef }) {
  const [integrations, setIntegrations] = useState({});
  const [hasSellingSettings, setHasSellingSettings] = useState(true);
  const [selected, setSelected] = useState(new Set(["wonni"])); // Wonni always selected
  const [showEbayNotice, setShowEbayNotice] = useState(false);
  const [etsyCategory, setEtsyCategory] = useState(null);
  const [etsyCategories, setEtsyCategories] = useState([]);
  const [etsyCategorySearch, setEtsyCategorySearch] = useState("");
  const [etsyShippingProfiles, setEtsyShippingProfiles] = useState([]);
  const [etsyShippingId, setEtsyShippingId] = useState(null);
  const [etsyReturnPolicies, setEtsyReturnPolicies] = useState([]);
  const [etsyReturnId, setEtsyReturnId] = useState(null);
  const [loadingEtsyData, setLoadingEtsyData] = useState(false);
  const [etsyError, setEtsyError] = useState("");
  const [posting, setPosting] = useState(false);
  const [error, setError] = useState("");
  const [results, setResults] = useState({});
  const [buttonRect, setButtonRect] = useState(null);
  const popoverRef = useRef(null);

  const uid = auth.currentUser?.uid;

  // Track button position for popover mode
  useEffect(() => {
    if (mode !== "popover" || !buttonRef?.current) return;

    const updatePosition = () => {
      const rect = buttonRef.current.getBoundingClientRect();
      setButtonRect(rect);
    };

    updatePosition();
    window.addEventListener("scroll", updatePosition);
    window.addEventListener("resize", updatePosition);
    return () => {
      window.removeEventListener("scroll", updatePosition);
      window.removeEventListener("resize", updatePosition);
    };
  }, [mode, buttonRef]);

  // Close popover on outside click
  useEffect(() => {
    if (mode !== "popover") return;

    const handleClickOutside = (e) => {
      if (popoverRef.current && !popoverRef.current.contains(e.target) && !buttonRef?.current?.contains(e.target)) {
        onClose();
      }
    };

    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [mode, onClose, buttonRef]);

  // Load integrations and seller settings
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

      try {
        const settingsSnap = await getDoc(doc(db, "users", uid, "sellingSettings", "default"));
        const data = settingsSnap.data() || {};
        setHasSellingSettings(!!data.defaultLocation?.postalCode);
      } catch {
        setHasSellingSettings(false);
      }
    };
    loadIntegrations();
  }, [uid]);

  // Load Etsy-specific data when Etsy is selected
  useEffect(() => {
    if (!selected.has("etsy") || loadingEtsyData) return;

    const loadEtsyData = async () => {
      setLoadingEtsyData(true);
      setEtsyError("");
      try {
        const [categoriesRes, shippingRes, returnRes] = await Promise.all([
          callFunction("getEtsyCategories")({ credentialSet: "web" }),
          callFunction("getEtsyShippingProfiles")({ credentialSet: "web" }),
          callFunction("getEtsyReturnPolicies")({ credentialSet: "web" }),
        ]);

        setEtsyCategories(categoriesRes.data.categories || []);
        setEtsyShippingProfiles(shippingRes.data.profiles || []);
        setEtsyReturnPolicies(returnRes.data.policies || []);

        if (shippingRes.data.profiles?.length > 0) {
          setEtsyShippingId(shippingRes.data.profiles[0].id);
        }
        if (returnRes.data.policies?.length > 0) {
          setEtsyReturnId(returnRes.data.policies[0].id);
        }
      } catch (err) {
        setEtsyError(`Failed to load Etsy data: ${err.message}`);
      } finally {
        setLoadingEtsyData(false);
      }
    };

    loadEtsyData();
  }, [selected.has("etsy")]);

  // Suggest category when Etsy is selected and category not yet set
  useEffect(() => {
    if (!selected.has("etsy") || etsyCategory) return;

    const suggestCategory = async () => {
      try {
        const res = await callFunction("suggestEtsyCategory")({
          title: product?.title,
          category: product?.category,
          credentialSet: "web",
        });
        setEtsyCategory({
          id: res.data.taxonomyId,
          name: res.data.taxonomyName,
        });
      } catch {
        // Fail silently; user can pick manually
      }
    };

    suggestCategory();
  }, [selected.has("etsy"), etsyCategory, product?.title, product?.category]);

  const togglePlatform = (platformId) => {
    if (platformId === "wonni") return; // Can't deselect Wonni
    if (isPlatformAlreadyPosted(platformId, product)) return; // Can't select already posted platforms
    const newSelected = new Set(selected);
    if (newSelected.has(platformId)) {
      newSelected.delete(platformId);
    } else {
      newSelected.add(platformId);
    }
    setSelected(newSelected);
  };

  const etsyFilteredCategories = etsyCategorySearch
    ? etsyCategories.filter((c) =>
        c.name.toLowerCase().includes(etsyCategorySearch.toLowerCase())
      )
    : [];

  const handleSubmit = async () => {
    if (selected.size === 0 || (selected.size === 1 && selected.has("wonni"))) {
      setError("Select at least one platform besides Wonni.");
      return;
    }

    // Validate eBay requirements
    if (selected.has("ebay")) {
      if (!integrations.ebay?.isConnected) {
        setError("eBay not connected. Please connect in Settings first.");
        return;
      }
      if (!hasSellingSettings) {
        setError("eBay requires a seller address. Please save your address in Settings first.");
        return;
      }
    }

    // Validate Etsy requirements
    if (selected.has("etsy")) {
      if (!integrations.etsy?.isConnected) {
        setError("Etsy not connected. Please connect in Settings first.");
        return;
      }
      if (!etsyCategory) {
        setError("Please select an Etsy category.");
        return;
      }
      if (!etsyShippingId) {
        setError("Please select an Etsy shipping profile.");
        return;
      }
      if (!etsyReturnId) {
        setError("Please select an Etsy return policy.");
        return;
      }
    }

    setPosting(true);
    setError("");
    setResults({});

    try {
      // Step 1: Ensure listing exists on Wonni
      const wonniRes = await callFunction("postToWonni")({
        productId: product.id,
      });
      const listingId = wonniRes.data.listingId;

      setResults((prev) => ({
        ...prev,
        wonni: { status: "success" },
      }));

      // Step 2: Post to each selected platform
      for (const platformId of Array.from(selected)) {
        if (platformId === "wonni") continue; // Already done

        try {
          if (platformId === "tiktok") {
            await callFunction("tiktokCreateListing")({
              productId: product.id,
              title: product.title.slice(0, 255),
              sellPrice: parseFloat(product.listingPrice || product.aliexpressPrice * 2.5 || 0),
              categoryId: null,
            });
          } else if (platformId === "ebay") {
            const ebayRes = await callFunction("ebayCreateListing")({
              listingId: listingId || product.id,
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
              listingId: listingId || product.id,
              credentialSet: "web",
              taxonomyId: etsyCategory.id,
              shippingProfileId: etsyShippingId,
              returnPolicyId: etsyReturnId,
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

          setResults((prev) => ({
            ...prev,
            [platformId]: { status: "success" },
          }));
        } catch (err) {
          setResults((prev) => ({
            ...prev,
            [platformId]: { status: "error", message: err.message },
          }));
        }
      }
    } catch (err) {
      setError(err.message || "Posting failed.");
    } finally {
      setPosting(false);
    }
  };

  if (mode === "popover") {
    if (!buttonRect) return null;

    const popoverTop = buttonRect.bottom + 8;
    const popoverLeft = buttonRect.right - 380; // Approximate modal width, align right
    const popoverMaxHeight = window.innerHeight - popoverTop - 20;

    return (
      <>
        <div
          style={{
            position: "fixed",
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            zIndex: 99,
          }}
          onClick={onClose}
        />
        <div
          ref={popoverRef}
          style={{
            position: "fixed",
            top: popoverTop,
            left: popoverLeft,
            width: 380,
            maxHeight: popoverMaxHeight,
            background: "var(--surface)",
            border: "1px solid var(--border)",
            borderRadius: 8,
            boxShadow: "0 8px 24px rgba(0,0,0,0.15)",
            zIndex: 100,
            display: "flex",
            flexDirection: "column",
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--border)", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <h3 style={{ fontSize: 14, fontWeight: 600, margin: 0 }}>Post to Platforms</h3>
            <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>
              ✕
            </button>
          </div>

          <div style={{ flex: 1, overflowY: "auto", padding: "12px 16px" }}>
            <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 16 }}>
              Select platforms to post this item to. Wonni is always included.
            </div>

            {error && (
              <div style={{ fontSize: 13, color: "var(--danger)", marginBottom: 12 }}>
                {error}
              </div>
            )}

            {/* Platform checkboxes */}
            {PLATFORMS.map((p) => {
              const isConnected = integrations[p.id]?.isConnected;
              const isAlreadyPosted = isPlatformAlreadyPosted(p.id, product);
              const isSelected = selected.has(p.id) && !isAlreadyPosted;
              const isDisabled = (p.requiresConnected && !isConnected) || p.locked || isAlreadyPosted;

              return (
                <div key={p.id} style={{ marginBottom: 12, paddingBottom: 12, borderBottom: "1px solid var(--border)" }}>
                  <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: isDisabled ? "not-allowed" : "pointer", opacity: isDisabled ? 0.6 : 1 }}>
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
                    {isAlreadyPosted && (
                      <span style={{ fontSize: 11, color: "var(--accent, #6366f1)", fontWeight: 600, marginLeft: "auto" }}>
                        ✓ Already Posted
                      </span>
                    )}
                    {!isAlreadyPosted && isConnected && !p.locked && <span style={{ fontSize: 11, color: "var(--success)" }}>✓ Connected</span>}
                    {!isAlreadyPosted && !isConnected && p.requiresConnected && (
                      <span style={{ fontSize: 11, color: "var(--muted)" }}>Not connected</span>
                    )}
                  </label>

                  {/* eBay-specific options: sync/delete if already posted */}
                  {p.id === "ebay" && isPlatformAlreadyPosted("ebay", product) && (
                    <div style={{ marginTop: 12, paddingLeft: 24, display: "flex", gap: 8 }}>
                      <button
                        className="btn btn-ghost"
                        style={{ fontSize: 12, padding: "4px 12px" }}
                        onClick={() => {
                          if (window.confirm("Push changes to eBay? Title, description, and price will be updated.")) {
                            callFunction("ebayUpdateListing")({ productId: product.id })
                              .then(() => alert("eBay listing updated"))
                              .catch((e) => alert(`Error: ${e.message}`));
                          }
                        }}
                      >
                        ↻ Sync to eBay
                      </button>
                      <button
                        className="btn btn-danger"
                        style={{ fontSize: 12, padding: "4px 12px" }}
                        onClick={() => {
                          if (window.confirm("Delete eBay listing? It will be removed from eBay.")) {
                            callFunction("ebayDeleteListing")({ productId: product.id })
                              .then(() => alert("eBay listing deleted"))
                              .catch((e) => alert(`Error: ${e.message}`));
                          }
                        }}
                      >
                        🗑️ Delete from eBay
                      </button>
                    </div>
                  )}

                  {/* Etsy-specific options */}
                  {isSelected && p.id === "etsy" && (
                    <div style={{ marginTop: 12, paddingLeft: 24 }}>
                      {etsyError && (
                        <div style={{ fontSize: 12, color: "var(--danger)", marginBottom: 8, padding: 8, background: "rgba(239, 68, 68, 0.08)", borderRadius: 6, border: "1px solid rgba(239, 68, 68, 0.2)" }}>
                          <div style={{ marginBottom: 6 }}>{etsyError}</div>
                          <div style={{ display: "flex", gap: 12 }}>
                            <a
                              href="https://www.etsy.com/sell"
                              target="_blank"
                              rel="noopener noreferrer"
                              style={{ fontSize: 11, color: "var(--accent, #6366f1)", textDecoration: "underline", fontWeight: 600 }}
                            >
                              Open Etsy Shop Setup ↗
                            </a>
                            <a
                              href="/web/settings"
                              target="_blank"
                              rel="noopener noreferrer"
                              style={{ fontSize: 11, color: "var(--accent, #6366f1)", textDecoration: "underline", fontWeight: 600 }}
                            >
                              Settings ↗
                            </a>
                          </div>
                        </div>
                      )}

                      {loadingEtsyData && <div style={{ fontSize: 12, color: "var(--muted)" }}>Loading Etsy data…</div>}

                      {!loadingEtsyData && (
                        <>
                          {/* Category selector */}
                          <div style={{ marginBottom: 12 }}>
                            <label style={{ fontSize: 12, fontWeight: 500, display: "block", marginBottom: 4 }}>
                              Category
                            </label>
                            <input
                              className="input"
                              style={{ fontSize: 12, marginBottom: 4 }}
                              placeholder="Search categories…"
                              value={etsyCategorySearch}
                              onChange={(e) => setEtsyCategorySearch(e.target.value)}
                            />
                            {etsyCategorySearch && etsyFilteredCategories.length > 0 && (
                              <div style={{ border: "1px solid var(--border)", borderRadius: 4, maxHeight: 150, overflowY: "auto" }}>
                                {etsyFilteredCategories.slice(0, 20).map((c) => (
                                  <div
                                    key={c.id}
                                    style={{
                                      padding: 8,
                                      cursor: "pointer",
                                      backgroundColor: etsyCategory?.id === c.id ? "var(--primary)" : "transparent",
                                      color: etsyCategory?.id === c.id ? "white" : "inherit",
                                    }}
                                    onClick={() => {
                                      setEtsyCategory(c);
                                      setEtsyCategorySearch("");
                                    }}
                                  >
                                    {c.name}
                                  </div>
                                ))}
                              </div>
                            )}
                            {etsyCategory && (
                              <div style={{ fontSize: 11, color: "var(--success)", marginTop: 4 }}>
                                ✓ {etsyCategory.name}
                              </div>
                            )}
                          </div>

                          {/* Shipping profile selector */}
                          {etsyShippingProfiles.length > 0 ? (
                            <div style={{ marginBottom: 12 }}>
                              <label style={{ fontSize: 12, fontWeight: 500, display: "block", marginBottom: 4 }}>
                                Shipping Profile
                              </label>
                              <select
                                className="input"
                                style={{ fontSize: 12 }}
                                value={etsyShippingId || ""}
                                onChange={(e) => setEtsyShippingId(e.target.value)}
                              >
                                <option value="">Select a profile…</option>
                                {etsyShippingProfiles.map((p) => (
                                  <option key={p.id} value={p.id}>
                                    {p.title}
                                  </option>
                                ))}
                              </select>
                            </div>
                          ) : (
                            <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 12 }}>
                              No shipping profiles found. Please create one in your Etsy shop settings.
                            </div>
                          )}

                          {/* Return policy selector */}
                          {etsyReturnPolicies.length > 0 ? (
                            <div style={{ marginBottom: 12 }}>
                              <label style={{ fontSize: 12, fontWeight: 500, display: "block", marginBottom: 4 }}>
                                Return Policy
                              </label>
                              <select
                                className="input"
                                style={{ fontSize: 12 }}
                                value={etsyReturnId || ""}
                                onChange={(e) => setEtsyReturnId(e.target.value)}
                              >
                                <option value="">Select a policy…</option>
                                {etsyReturnPolicies.map((p) => (
                                  <option key={p.id} value={p.id}>
                                    {p.name}
                                  </option>
                                ))}
                              </select>
                            </div>
                          ) : (
                            <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 12 }}>
                              No return policies found. Please create one in your Etsy shop settings.
                            </div>
                          )}
                        </>
                      )}
                    </div>
                  )}

                  {/* Post result for this platform */}
                  {results[p.id] && (
                    <div style={{ marginTop: 8, paddingLeft: 24 }}>
                      {results[p.id].status === "success" && (
                        <div style={{ fontSize: 11, color: "var(--success)" }}>
                          ✓ Posted to {p.name}
                        </div>
                      )}
                      {results[p.id].status === "error" && (
                        <div style={{ fontSize: 11, color: "var(--danger)" }}>
                          ✕ {results[p.id].message}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>

          <div style={{ padding: "12px 16px", borderTop: "1px solid var(--border)", display: "flex", gap: 8, justifyContent: "flex-end" }}>
            <button className="btn btn-ghost" onClick={onClose}>
              Cancel
            </button>
            <button
              className="btn btn-primary"
              onClick={handleSubmit}
              disabled={posting || selected.size <= 1}
            >
              {posting ? "Posting…" : "Post"}
            </button>
          </div>
        </div>
      </>
    );
  }

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>Post to Platforms</h2>
          <button className="btn btn-ghost" style={{ padding: "4px 8px" }} onClick={onClose}>
            ✕
          </button>
        </div>

        <div className="modal-body" style={{ maxHeight: "60vh", overflowY: "auto" }}>
          <div style={{ fontSize: 12, color: "var(--muted)", marginBottom: 16 }}>
            Select platforms to post this item to. Wonni is always included.
          </div>

          {error && (
            <div style={{ fontSize: 13, color: "var(--danger)", marginBottom: 12 }}>
              {error}
            </div>
          )}

          {/* Platform checkboxes */}
          {PLATFORMS.map((p) => {
            const isConnected = integrations[p.id]?.isConnected;
            const isAlreadyPosted = isPlatformAlreadyPosted(p.id, product);
            const isSelected = selected.has(p.id) && !isAlreadyPosted;
            const isDisabled = (p.requiresConnected && !isConnected) || p.locked || isAlreadyPosted;

            return (
              <div key={p.id} style={{ marginBottom: 12, paddingBottom: 12, borderBottom: "1px solid var(--border)" }}>
                <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: isDisabled ? "not-allowed" : "pointer", opacity: isDisabled ? 0.6 : 1 }}>
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
                  {isAlreadyPosted && (
                    <span style={{ fontSize: 11, color: "var(--accent, #6366f1)", fontWeight: 600, marginLeft: "auto" }}>
                      ✓ Already Posted
                    </span>
                  )}
                  {!isAlreadyPosted && isConnected && !p.locked && <span style={{ fontSize: 11, color: "var(--success)" }}>✓ Connected</span>}
                  {!isAlreadyPosted && !isConnected && p.requiresConnected && (
                    <span style={{ fontSize: 11, color: "var(--muted)" }}>Not connected</span>
                  )}
                </label>

                {/* Etsy-specific options */}
                {isSelected && p.id === "etsy" && (
                  <div style={{ marginTop: 12, paddingLeft: 24 }}>
                    {etsyError && (
                      <div style={{ fontSize: 12, color: "var(--danger)", marginBottom: 8, padding: 8, background: "rgba(239, 68, 68, 0.08)", borderRadius: 6, border: "1px solid rgba(239, 68, 68, 0.2)" }}>
                        <div style={{ marginBottom: 6 }}>{etsyError}</div>
                        <div style={{ display: "flex", gap: 12 }}>
                          <a
                            href="https://www.etsy.com/sell"
                            target="_blank"
                            rel="noopener noreferrer"
                            style={{ fontSize: 11, color: "var(--accent, #6366f1)", textDecoration: "underline", fontWeight: 600 }}
                          >
                            Open Etsy Shop Setup ↗
                          </a>
                          <a
                            href="/web/settings"
                            target="_blank"
                            rel="noopener noreferrer"
                            style={{ fontSize: 11, color: "var(--accent, #6366f1)", textDecoration: "underline", fontWeight: 600 }}
                          >
                            Settings ↗
                          </a>
                        </div>
                      </div>
                    )}

                    {loadingEtsyData && <div style={{ fontSize: 12, color: "var(--muted)" }}>Loading Etsy data…</div>}

                    {!loadingEtsyData && (
                      <>
                        {/* Category selector */}
                        <div style={{ marginBottom: 12 }}>
                          <label style={{ fontSize: 12, fontWeight: 500, display: "block", marginBottom: 4 }}>
                            Category
                          </label>
                          <input
                            className="input"
                            style={{ fontSize: 12, marginBottom: 4 }}
                            placeholder="Search categories…"
                            value={etsyCategorySearch}
                            onChange={(e) => setEtsyCategorySearch(e.target.value)}
                          />
                          {etsyCategorySearch && etsyFilteredCategories.length > 0 && (
                            <div style={{ border: "1px solid var(--border)", borderRadius: 4, maxHeight: 150, overflowY: "auto" }}>
                              {etsyFilteredCategories.slice(0, 20).map((c) => (
                                <div
                                  key={c.id}
                                  style={{
                                    padding: 8,
                                    cursor: "pointer",
                                    backgroundColor: etsyCategory?.id === c.id ? "var(--primary)" : "transparent",
                                    color: etsyCategory?.id === c.id ? "white" : "inherit",
                                  }}
                                  onClick={() => {
                                    setEtsyCategory(c);
                                    setEtsyCategorySearch("");
                                  }}
                                >
                                  {c.name}
                                </div>
                              ))}
                            </div>
                          )}
                          {etsyCategory && (
                            <div style={{ fontSize: 11, color: "var(--success)", marginTop: 4 }}>
                              ✓ {etsyCategory.name}
                            </div>
                          )}
                        </div>

                        {/* Shipping profile selector */}
                        {etsyShippingProfiles.length > 0 ? (
                          <div style={{ marginBottom: 12 }}>
                            <label style={{ fontSize: 12, fontWeight: 500, display: "block", marginBottom: 4 }}>
                              Shipping Profile
                            </label>
                            <select
                              className="input"
                              style={{ fontSize: 12 }}
                              value={etsyShippingId || ""}
                              onChange={(e) => setEtsyShippingId(e.target.value)}
                            >
                              <option value="">Select a profile…</option>
                              {etsyShippingProfiles.map((p) => (
                                <option key={p.id} value={p.id}>
                                  {p.title}
                                </option>
                              ))}
                            </select>
                          </div>
                        ) : (
                          <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 12 }}>
                            No shipping profiles found. Please create one in your Etsy shop settings.
                          </div>
                        )}

                        {/* Return policy selector */}
                        {etsyReturnPolicies.length > 0 ? (
                          <div style={{ marginBottom: 12 }}>
                            <label style={{ fontSize: 12, fontWeight: 500, display: "block", marginBottom: 4 }}>
                              Return Policy
                            </label>
                            <select
                              className="input"
                              style={{ fontSize: 12 }}
                              value={etsyReturnId || ""}
                              onChange={(e) => setEtsyReturnId(e.target.value)}
                            >
                              <option value="">Select a policy…</option>
                              {etsyReturnPolicies.map((p) => (
                                <option key={p.id} value={p.id}>
                                  {p.name}
                                </option>
                              ))}
                            </select>
                          </div>
                        ) : (
                          <div style={{ fontSize: 11, color: "var(--danger)", marginBottom: 12 }}>
                            No return policies found. Please create one in your Etsy shop settings.
                          </div>
                        )}
                      </>
                    )}
                  </div>
                )}

                {/* Post result for this platform */}
                {results[p.id] && (
                  <div style={{ marginTop: 8, paddingLeft: 24 }}>
                    {results[p.id].status === "success" && (
                      <div style={{ fontSize: 11, color: "var(--success)" }}>
                        ✓ Posted to {p.name}
                      </div>
                    )}
                    {results[p.id].status === "error" && (
                      <div style={{ fontSize: 11, color: "var(--danger)" }}>
                        ✕ {results[p.id].message}
                      </div>
                    )}
                  </div>
                )}
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
            disabled={posting || selected.size <= 1}
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
