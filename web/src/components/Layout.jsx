import { useState } from "react";
import { NavLink, useNavigate } from "react-router-dom";
import { signOut } from "firebase/auth";
import { auth } from "../firebase";

// Stroke icons in the SF Symbols spirit (square.grid.2x2, chart.bar, gearshape,
// sidebar.left). Inline so the sidebar has no icon dependency.
const Icon = {
  grid: (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" />
      <rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" />
    </svg>
  ),
  chart: (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <path d="M4 20V10M10 20V4M16 20v-7M22 20H2" />
    </svg>
  ),
  gear: (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" />
    </svg>
  ),
  sidebar: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
      <rect x="3" y="4" width="18" height="16" rx="3" /><path d="M9 4v16" />
    </svg>
  ),
};

export default function Layout({ children }) {
  const navigate = useNavigate();
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem("sidebarCollapsed") === "1"; } catch { return false; }
  });

  async function handleSignOut() {
    await signOut(auth);
    navigate("/login");
  }

  function toggleCollapsed() {
    const next = !collapsed;
    setCollapsed(next);
    try { localStorage.setItem("sidebarCollapsed", next ? "1" : "0"); } catch { /* private mode */ }
  }

  return (
    <div className={`app-layout ${collapsed ? "sidebar-collapsed" : ""}`}>
      <nav className="sidebar" aria-label="Main">
        <div className="sidebar-top">
          <span className="sidebar-logo">Wonni</span>
          <button
            className="sidebar-collapse"
            onClick={toggleCollapsed}
            aria-label={collapsed ? "Show sidebar" : "Hide sidebar"}
            title={collapsed ? "Show sidebar" : "Hide sidebar"}
          >
            {Icon.sidebar}
          </button>
        </div>
        <NavLink to="/sell" end title="Products">{Icon.grid}<span className="sidebar-label">Products</span></NavLink>
        <NavLink to="/sell/sales" title="Sales">{Icon.chart}<span className="sidebar-label">Sales</span></NavLink>
        <NavLink to="/sell/settings" title="Settings">{Icon.gear}<span className="sidebar-label">Settings</span></NavLink>
        {auth.currentUser && (
          <NavLink
            to={`/profile/${auth.currentUser.uid}`}
            target="_blank"
            rel="noopener noreferrer"
            className="sidebar-public-link"
          >
            View public store ↗
          </NavLink>
        )}
        <button className="sidebar-signout" onClick={handleSignOut}>
          Sign out
        </button>
      </nav>
      <main className="main-content">{children}</main>
    </div>
  );
}
