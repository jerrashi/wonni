import { useState } from "react";
import { NavLink, useNavigate } from "react-router-dom";
import { signOut } from "firebase/auth";
import { auth } from "../firebase";

export default function Layout({ children }) {
  const navigate = useNavigate();
  const [collapsed, setCollapsed] = useState(() => localStorage.getItem("sidebarCollapsed") === "1");

  async function handleSignOut() {
    await signOut(auth);
    navigate("/login");
  }

  function toggleCollapsed() {
    const next = !collapsed;
    setCollapsed(next);
    localStorage.setItem("sidebarCollapsed", next ? "1" : "0");
  }

  return (
    <div className={`app-layout ${collapsed ? "sidebar-collapsed" : ""}`}>
      <aside className="sidebar">
        <button
          className="btn btn-ghost"
          style={{ padding: "8px", width: "100%", justifyContent: "center", marginBottom: 8, fontSize: 12 }}
          onClick={toggleCollapsed}
          title={collapsed ? "Expand sidebar" : "Collapse sidebar"}
        >
          {collapsed ? "▸" : "▾"}
        </button>
        <NavLink to="/sell" end>Dashboard</NavLink>
        <NavLink to="/sell/sales">Sales</NavLink>
        <NavLink to="/sell/settings">Settings</NavLink>
        {auth.currentUser && (
          <NavLink to={`/profile/${auth.currentUser.uid}`} target="_blank" rel="noopener noreferrer" style={{ fontSize: 13, marginTop: 12, opacity: 0.85 }}>
            ↗ View Public Store
          </NavLink>
        )}
        <div className="sidebar-signout" style={{ marginTop: "auto", padding: "0 8px" }}>
          <button
            className="btn btn-ghost"
            style={{ width: "100%", justifyContent: "center" }}
            onClick={handleSignOut}
          >
            Sign out
          </button>
        </div>
      </aside>
      <main className="main-content">{children}</main>
    </div>
  );
}
