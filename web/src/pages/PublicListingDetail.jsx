import React, { useState, useEffect } from "react";
import { useParams, Link, useNavigate } from "react-router-dom";
import { doc, getDoc } from "firebase/firestore";
import { ref, getDownloadURL } from "firebase/storage";
import { db, storage } from "../firebase";
import { useAuthState } from "../hooks/useAuthState";

const CONDITION_MAP = {
  new: "New",
  newWithoutTags: "New without tags",
  likeNew: "Used - Like New",
  good: "Used - Good",
  fair: "Used - Fair",
  poor: "Used - Poor",
  forParts: "For Parts",
};

export default function PublicListingDetail() {
  const { listingId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuthState();

  const [listing, setListing] = useState(null);
  const [seller, setSeller] = useState(null);
  const [photoUrls, setPhotoUrls] = useState([]);
  const [selectedPhotoIndex, setSelectedPhotoIndex] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [copiedToast, setCopiedToast] = useState(false);
  const [offerModalOpen, setOfferModalOpen] = useState(false);
  const [offerAmount, setOfferAmount] = useState("");
  const [offerSent, setOfferSent] = useState(false);

  useEffect(() => {
    let isMounted = true;

    async function fetchListingData() {
      if (!listingId) return;
      setLoading(true);
      setError(null);

      try {
        // Try fetching from 'listings' collection first
        let docRef = doc(db, "listings", listingId);
        let docSnap = await getDoc(docRef);

        // Fallback to 'products' collection if not in 'listings'
        if (!docSnap.exists()) {
          docRef = doc(db, "products", listingId);
          docSnap = await getDoc(docRef);
        }

        if (!docSnap.exists()) {
          if (isMounted) {
            setError("Listing not found.");
            setLoading(false);
          }
          return;
        }

        const data = { id: docSnap.id, ...docSnap.data() };
        if (isMounted) setListing(data);

        // Fetch seller profile if userId is available
        if (data.userId) {
          try {
            const userRef = doc(db, "users", data.userId);
            const userSnap = await getDoc(userRef);
            if (userSnap.exists() && isMounted) {
              setSeller(userSnap.data());
            }
          } catch (err) {
            console.warn("Could not load seller profile:", err);
          }
        }

        // Resolve photo paths
        const rawPhotos = data.photoPaths || data.images || (data.imageAssets ? data.imageAssets.map((a) => (typeof a === "string" ? a : a.url)) : []) || [];
        const resolvedUrls = await Promise.all(
          rawPhotos.map(async (photo) => {
            if (!photo) return "";
            const photoStr = typeof photo === "string" ? photo : photo.url || "";
            if (!photoStr) return "";
            if (photoStr.startsWith("http://") || photoStr.startsWith("https://") || photoStr.startsWith("data:")) {
              return photoStr;
            }
            // Resolve from Firebase Storage
            try {
              return await getDownloadURL(ref(storage, photoStr));
            } catch (storageErr) {
              console.warn("Error getting download URL for", photoStr, storageErr);
              return "";
            }
          })
        );

        if (isMounted) {
          setPhotoUrls(resolvedUrls.filter(Boolean));
        }
      } catch (err) {
        console.error("Error fetching listing:", err);
        if (isMounted) setError("Failed to load listing.");
      } finally {
        if (isMounted) setLoading(false);
      }
    }

    fetchListingData();
    return () => { isMounted = false; };
  }, [listingId]);

  function handleShare() {
    navigator.clipboard?.writeText(window.location.href);
    setCopiedToast(true);
    setTimeout(() => setCopiedToast(false), 2500);
  }

  function handleSendOffer(e) {
    e.preventDefault();
    if (!offerAmount || isNaN(offerAmount)) return;
    setOfferSent(true);
    setTimeout(() => {
      setOfferSent(false);
      setOfferModalOpen(false);
      setOfferAmount("");
    }, 2000);
  }

  if (loading) {
    return (
      <div className="public-page-container">
        <PublicHeader user={user} />
        <div className="loading" style={{ height: "60vh" }}>Loading listing...</div>
      </div>
    );
  }

  if (error || !listing) {
    return (
      <div className="public-page-container">
        <PublicHeader user={user} />
        <div className="public-error-state">
          <h2>Listing Not Found</h2>
          <p>{error || "This item may have been sold or removed by the seller."}</p>
          <Link to="/" className="btn btn-primary" style={{ marginTop: 16 }}>
            Browse Wonni
          </Link>
        </div>
      </div>
    );
  }

  const isOwner = Boolean(user && listing.userId && user.uid === listing.userId);
  const title = listing.customTitle || listing.title || "Untitled Item";
  const description = listing.customDescription || listing.description || "";
  const price = listing.price != null ? listing.price : listing.listingPrice;
  const conditionDisplay = CONDITION_MAP[listing.condition] || listing.condition || "Pre-owned";
  const sellerName = seller?.displayName || seller?.username || (listing.userId ? `Seller (${listing.userId.slice(0, 6)})` : "Verified Seller");
  const sellerInitial = (sellerName || "W")[0].toUpperCase();

  return (
    <div className="public-page-container">
      <PublicHeader user={user} />

      {/* Owner Banner */}
      {isOwner && (
        <div className="owner-status-banner">
          <div className="owner-banner-content">
            <span className="owner-badge">👑 Your Listing</span>
            <span>You are viewing this item as the poster.</span>
          </div>
          <div style={{ display: "flex", gap: 10 }}>
            <button
              className="btn btn-primary btn-sm"
              onClick={() => navigate(`/sell/products/${listing.id}`)}
            >
              ✏️ Edit Listing
            </button>
            <button
              className="btn btn-ghost btn-sm"
              onClick={() => navigate("/sell")}
            >
              Seller Dashboard
            </button>
          </div>
        </div>
      )}

      <main className="public-listing-main">
        {/* Left Column: Media Gallery */}
        <div className="listing-gallery-section">
          <div className="listing-main-photo-container">
            {photoUrls.length > 0 ? (
              <img
                src={photoUrls[selectedPhotoIndex] || photoUrls[0]}
                alt={title}
                className="listing-main-photo"
              />
            ) : (
              <div className="listing-photo-placeholder">No Photo Available</div>
            )}
            {listing.status && listing.status !== "active" && (
              <div className="listing-status-overlay-tag">{listing.status.toUpperCase()}</div>
            )}
          </div>

          {photoUrls.length > 1 && (
            <div className="listing-thumbnails-row">
              {photoUrls.map((url, idx) => (
                <button
                  key={idx}
                  className={`listing-thumb-btn ${idx === selectedPhotoIndex ? "active" : ""}`}
                  onClick={() => setSelectedPhotoIndex(idx)}
                >
                  <img src={url} alt={`${title} ${idx + 1}`} />
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Right Column: Listing Details & Actions */}
        <div className="listing-info-section">
          <div className="listing-meta-top">
            <span className="listing-condition-badge">{conditionDisplay}</span>
            {listing.brand && <span className="listing-brand-tag">{listing.brand}</span>}
            {listing.category && <span className="listing-category-tag">{listing.category}</span>}
          </div>

          <h1 className="listing-title">{title}</h1>

          <div className="listing-price-row">
            <span className="listing-price">
              {price != null && !isNaN(price) ? `$${Number(price).toFixed(2)}` : "Price on request"}
            </span>
            {listing.currency && listing.currency !== "USD" && (
              <span className="listing-currency">{listing.currency}</span>
            )}
          </div>

          {/* Seller Card */}
          <Link to={`/profile/${listing.userId}`} className="listing-seller-card">
            <div className="seller-avatar-circle">
              {seller?.photoURL ? (
                <img src={seller.photoURL} alt={sellerName} />
              ) : (
                <span>{sellerInitial}</span>
              )}
            </div>
            <div className="seller-card-info">
              <span className="seller-card-label">Listed by</span>
              <span className="seller-card-name">{sellerName}</span>
            </div>
            <span className="seller-card-arrow">→</span>
          </Link>

          {/* Actions */}
          <div className="listing-actions-container">
            {isOwner ? (
              <button
                className="btn btn-primary btn-lg"
                style={{ width: "100%" }}
                onClick={() => navigate(`/sell/products/${listing.id}`)}
              >
                ✏️ Edit Listing
              </button>
            ) : (
              <div className="visitor-action-stack">
                <button
                  className="btn btn-primary btn-lg"
                  style={{ width: "100%" }}
                  onClick={() => setOfferModalOpen(true)}
                >
                  Make an Offer
                </button>
                <div style={{ display: "flex", gap: 10 }}>
                  <button
                    className="btn btn-ghost"
                    style={{ flex: 1 }}
                    onClick={handleShare}
                  >
                    {copiedToast ? "✓ Link Copied!" : "🔗 Share"}
                  </button>
                  <a
                    href={`wonni://listing/${listing.id}`}
                    className="btn btn-ghost"
                    style={{ flex: 1, textAlign: "center" }}
                  >
                    📱 Open in App
                  </a>
                </div>
              </div>
            )}
          </div>

          {/* Description */}
          <div className="listing-description-container">
            <h3>Description</h3>
            {description ? (
              <div className="listing-description-text">{description}</div>
            ) : (
              <p style={{ color: "var(--muted)", fontStyle: "italic" }}>No description provided.</p>
            )}
          </div>

          {/* Variations (if any) */}
          {listing.variations && listing.variations.length > 0 && (
            <div className="listing-variations-container">
              <h3>Available Options</h3>
              <div className="listing-variations-grid">
                {listing.variations.map((v, i) => (
                  <div key={v.id || i} className="listing-variation-chip">
                    <span className="var-attributes">
                      {(v.attributes || []).map((a) => `${a.name}: ${a.value}`).join(", ") || `Option ${i + 1}`}
                    </span>
                    {v.price != null && (
                      <span className="var-price">${Number(v.price).toFixed(2)}</span>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </main>

      {/* Offer Modal */}
      {offerModalOpen && (
        <div className="modal-backdrop" onClick={() => setOfferModalOpen(false)}>
          <div className="modal-box" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 400 }}>
            <h3>Make an Offer</h3>
            <p style={{ color: "var(--text-secondary)", marginBottom: 16, fontSize: 14 }}>
              Current listing price: <strong>${price != null ? Number(price).toFixed(2) : "--"}</strong>
            </p>
            {offerSent ? (
              <div className="offer-success-message">
                ✓ Offer submitted to seller!
              </div>
            ) : (
              <form onSubmit={handleSendOffer}>
                <div className="form-group" style={{ marginBottom: 16 }}>
                  <label className="form-label">Your Offer Amount ($ USD)</label>
                  <input
                    type="number"
                    step="0.01"
                    min="1"
                    className="form-input"
                    placeholder="e.g. 25.00"
                    value={offerAmount}
                    onChange={(e) => setOfferAmount(e.target.value)}
                    required
                    autoFocus
                  />
                </div>
                <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
                  <button
                    type="button"
                    className="btn btn-ghost"
                    onClick={() => setOfferModalOpen(false)}
                  >
                    Cancel
                  </button>
                  <button type="submit" className="btn btn-primary">
                    Send Offer
                  </button>
                </div>
              </form>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function PublicHeader({ user }) {
  return (
    <header className="public-top-header">
      <div className="public-header-inner">
        <Link to="/" className="public-logo">
          Wonni
        </Link>
        <div className="public-header-nav">
          <Link to="/sell" className="btn btn-ghost btn-sm">
            Sell
          </Link>
          {user ? (
            <Link to="/sell" className="btn btn-primary btn-sm">
              Dashboard
            </Link>
          ) : (
            <Link to="/login" className="btn btn-primary btn-sm">
              Sign In
            </Link>
          )}
        </div>
      </div>
    </header>
  );
}
