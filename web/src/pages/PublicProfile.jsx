import React, { useState, useEffect } from "react";
import { useParams, Link, useNavigate } from "react-router-dom";
import { doc, getDoc, collection, query, where, getDocs } from "firebase/firestore";
import { ref, getDownloadURL } from "firebase/storage";
import { db, storage } from "../firebase";
import { useAuthState } from "../hooks/useAuthState";

const CONDITION_MAP = {
  new: "New",
  newWithoutTags: "New without tags",
  likeNew: "Like New",
  good: "Good",
  fair: "Fair",
  poor: "Poor",
  forParts: "For Parts",
};

export default function PublicProfile() {
  const { userId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuthState();

  const [profile, setProfile] = useState(null);
  const [listings, setListings] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    let isMounted = true;

    async function fetchProfileAndListings() {
      if (!userId) return;
      setLoading(true);
      setError(null);

      try {
        // Fetch user profile
        const userRef = doc(db, "users", userId);
        const userSnap = await getDoc(userRef);
        if (userSnap.exists() && isMounted) {
          setProfile(userSnap.data());
        }

        // Fetch active listings
        let items = [];
        try {
          const listingsQuery = query(
            collection(db, "listings"),
            where("userId", "==", userId),
            where("status", "==", "active")
          );
          const snap = await getDocs(listingsQuery);
          items = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
        } catch (e) {
          console.warn("Could not query listings:", e);
        }

        // If no listings found, fallback to query products collection
        if (items.length === 0) {
          try {
            const productsQuery = query(
              collection(db, "products"),
              where("userId", "==", userId)
            );
            const pSnap = await getDocs(productsQuery);
            items = pSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
          } catch (e) {
            console.warn("Could not query products:", e);
          }
        }

        // Resolve cover photos for each item
        const resolvedListings = await Promise.all(
          items.map(async (item) => {
            const rawCover = item.coverPhotoPath || (item.photoPaths && item.photoPaths[0]) || (item.images && item.images[0]) || (item.imageAssets && item.imageAssets[0]?.url) || "";
            let coverUrl = "";
            if (rawCover) {
              const coverStr = typeof rawCover === "string" ? rawCover : rawCover.url || "";
              if (coverStr.startsWith("http://") || coverStr.startsWith("https://") || coverStr.startsWith("data:")) {
                coverUrl = coverStr;
              } else {
                try {
                  coverUrl = await getDownloadURL(ref(storage, coverStr));
                } catch {
                  coverUrl = "";
                }
              }
            }
            return {
              ...item,
              resolvedCoverUrl: coverUrl,
            };
          })
        );

        if (isMounted) {
          setListings(resolvedListings);
        }
      } catch (err) {
        console.error("Error fetching profile:", err);
        if (isMounted) setError("Failed to load seller profile.");
      } finally {
        if (isMounted) setLoading(false);
      }
    }

    fetchProfileAndListings();
    return () => { isMounted = false; };
  }, [userId]);

  const isSelf = Boolean(user && user.uid === userId);
  const displayName = profile?.displayName || profile?.username || (userId ? `User (${userId.slice(0, 6)})` : "Wonni Seller");
  const initial = (displayName || "W")[0].toUpperCase();

  return (
    <div className="public-page-container">
      <header className="public-top-header">
        <div className="public-header-inner">
          <Link to="/" className="public-logo">Wonni</Link>
          <div className="public-header-nav">
            <Link to="/sell" className="btn btn-ghost btn-sm">Sell</Link>
            {user ? (
              <Link to="/sell" className="btn btn-primary btn-sm">Dashboard</Link>
            ) : (
              <Link to="/login" className="btn btn-primary btn-sm">Sign In</Link>
            )}
          </div>
        </div>
      </header>

      {isSelf && (
        <div className="owner-status-banner">
          <div className="owner-banner-content">
            <span className="owner-badge">👑 Your Public Profile</span>
            <span>This is how buyers see your storefront.</span>
          </div>
          <button className="btn btn-primary btn-sm" onClick={() => navigate("/sell")}>
            Manage Store / Dashboard
          </button>
        </div>
      )}

      <main className="public-profile-main">
        {/* Profile Card */}
        <div className="profile-header-card">
          <div className="profile-avatar-large">
            {profile?.photoURL ? (
              <img src={profile.photoURL} alt={displayName} />
            ) : (
              <span>{initial}</span>
            )}
          </div>
          <div className="profile-details">
            <h1 className="profile-name">{displayName}</h1>
            {profile?.username && <span className="profile-username">@{profile.username}</span>}
            {profile?.bio && <p className="profile-bio">{profile.bio}</p>}
            <div className="profile-stats">
              <span><strong>{listings.length}</strong> active listing{listings.length === 1 ? "" : "s"}</span>
            </div>
          </div>
        </div>

        {/* Listings Grid */}
        <section className="profile-listings-section">
          <h2>Items for Sale ({listings.length})</h2>

          {loading ? (
            <div className="loading" style={{ height: "30vh" }}>Loading items...</div>
          ) : listings.length === 0 ? (
            <div className="profile-empty-listings">
              <p>No active listings found for this seller.</p>
              {isSelf && (
                <Link to="/sell" className="btn btn-primary" style={{ marginTop: 12 }}>
                  Create Your First Listing
                </Link>
              )}
            </div>
          ) : (
            <div className="public-listings-grid">
              {listings.map((item) => {
                const title = item.customTitle || item.title || "Untitled Item";
                const price = item.price != null ? item.price : (item.listingPrice != null ? item.listingPrice : item.sourceCost);
                const condition = CONDITION_MAP[item.condition] || item.condition || "Pre-owned";

                return (
                  <Link key={item.id} to={`/listing/${item.id}`} className="public-listing-card">
                    <div className="listing-card-image-wrap">
                      {item.resolvedCoverUrl ? (
                        <img src={item.resolvedCoverUrl} alt={title} />
                      ) : (
                        <div className="listing-card-no-photo">No Photo</div>
                      )}
                      <span className="listing-card-condition-badge">{condition}</span>
                    </div>
                    <div className="listing-card-body">
                      <h4 className="listing-card-title">{title}</h4>
                      <div className="listing-card-price">
                        {price != null && !isNaN(price) ? `$${Number(price).toFixed(2)}` : "Price on request"}
                      </div>
                    </div>
                  </Link>
                );
              })}
            </div>
          )}
        </section>
      </main>
    </div>
  );
}
