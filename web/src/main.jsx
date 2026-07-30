import React from "react";
import ReactDOM from "react-dom/client";
import { createBrowserRouter, RouterProvider, Navigate } from "react-router-dom";
import { useAuthState } from "./hooks/useAuthState";
import Login from "./pages/Login";
import Dashboard from "./pages/Dashboard";
import ProductDetail from "./pages/ProductDetail";
import Orders from "./pages/Orders";
import Settings from "./pages/Settings";
import "./index.css";

function ProtectedRoute({ children }) {
  const { user, loading } = useAuthState();
  if (loading) return <div className="loading">Loading...</div>;
  return user ? children : <Navigate to="/login" replace />;
}

const router = createBrowserRouter([
  { path: "/login", element: <Login /> },
  { path: "/", element: <ProtectedRoute><Dashboard /></ProtectedRoute> },
  { path: "/products/:productId", element: <ProtectedRoute><ProductDetail /></ProtectedRoute> },
  { path: "/orders", element: <ProtectedRoute><Orders /></ProtectedRoute> },
  { path: "/settings", element: <ProtectedRoute><Settings /></ProtectedRoute> },
]);

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <RouterProvider router={router} />
  </React.StrictMode>
);
