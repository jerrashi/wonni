import { useState, useEffect } from "react";
import { doc, getDoc } from "firebase/firestore";
import { db, auth, callFunction } from "../firebase";

const PLATFORMS = [
  { id: "wonni", name: "Wonni", requiresConnected: false, locked: true },
  { id: "ebay", name: "eBay", requiresConnected: true },
  { id: "etsy", name: "Etsy", requiresConnected: true },
  { id: "mercari", name: "Mercari", requiresConnected: false },
  { id: "tiktok", name: "TikTok Shop", requiresConnected: true },
];

export default function PostModal({ product, onClose }) {
  const [integrations, setIntegrations] = useState({});
  const [selected, setSelected] = useState(new Set(["wonni"])); // Wonni always selected
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

  const uid = auth.currentUser?.uid;

  // Load integrations
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
            await callFunction("ebayCreateListing")({
              productId: product.id,
              credentialSet: "web",
            });
          } else if (platformId === "etsy") {
            await callFunction("etsyCreateListing")({
              listingId,
              credentialSet: "web",
              taxonomyId: etsyCategory.id,
              shippingProfileId: etsyShippingId,
              returnPolicyId: etsyReturnId,
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
            const isSelected = selected.has(p.id);
            const isDisabled = (p.requiresConnected && !isConnected) || p.locked;

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
                  {isConnected && !p.locked && <span style={{ fontSize: 11, color: "var(--success)" }}>✓ Connected</span>}
                  {!isConnected && p.requiresConnected && (
                    <span style={{ fontSize: 11, color: "var(--muted)" }}>Not connected</span>
                  )}
                </label>

                {/* Etsy-specific options */}
                {isSelected && p.id === "etsy" && (
                  <div style={{ marginTop: 12, paddingLeft: 24 }}>
                    {etsyError && (
                      <div style={{ fontSize: 12, color: "var(--danger)", marginBottom: 8 }}>
                        {etsyError}
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
    </div>
  );
}
