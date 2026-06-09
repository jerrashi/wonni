import { NavLink, useNavigate } from "react-router-dom";
import { signOut } from "firebase/auth";
import { auth } from "../firebase";

export default function Layout({ children }) {
  const navigate = useNavigate();

  async function handleSignOut() {
    await signOut(auth);
    navigate("/login");
  }

  return (
    <div className="app-layout">
      <aside className="sidebar">
        <div className="sidebar-logo">Wonni Drop</div>
        <NavLink to="/" end>Dashboard</NavLink>
        <NavLink to="/orders">Orders</NavLink>
        <NavLink to="/settings">Settings</NavLink>
        <div style={{ marginTop: "auto", padding: "0 8px" }}>
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
