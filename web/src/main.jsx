import React from "react";
import ReactDOM from "react-dom/client";
import { createBrowserRouter, RouterProvider, Outlet, Navigate } from "react-router-dom";
import { useAuthState } from "./hooks/useAuthState";
import Login from "./pages/Login";
import Dashboard from "./pages/Dashboard";
import ProductDetail from "./pages/ProductDetail";
import Orders from "./pages/Orders";
import Sales from "./pages/Sales";
import Settings from "./pages/Settings";
import { MediaJobQueueProvider } from "./lib/mediaJobQueue";
import BackgroundTasksTray from "./components/BackgroundTasksTray";
import "./index.css";

import PublicListingDetail from "./pages/PublicListingDetail";
import PublicProfile from "./pages/PublicProfile";

function ProtectedRoute({ children }) {
  const { user, loading } = useAuthState();
  if (loading) return <div className="loading">Loading...</div>;
  return user ? children : <Navigate to="/login" replace />;
}

function RootRedirect() {
  const { user, loading } = useAuthState();
  if (loading) return <div className="loading">Loading...</div>;
  return user ? <Navigate to="/sell" replace /> : <Navigate to="/login" replace />;
}

function RootLayout() {
  return (
    <MediaJobQueueProvider>
      <Outlet />
      <BackgroundTasksTray />
    </MediaJobQueueProvider>
  );
}

const router = createBrowserRouter([
  {
    element: <RootLayout />,
    children: [
      { path: "/", element: <RootRedirect /> },
      { path: "/login", element: <Login /> },
      
      // Public Views
      { path: "/listing/:listingId", element: <PublicListingDetail /> },
      { path: "/profile/:userId", element: <PublicProfile /> },

      // Seller Portal (/sell/...)
      { path: "/sell", element: <ProtectedRoute><Dashboard /></ProtectedRoute> },
      { path: "/sell/products/:productId", element: <ProtectedRoute><ProductDetail /></ProtectedRoute> },
      { path: "/sell/sales", element: <ProtectedRoute><Sales /></ProtectedRoute> },
      { path: "/sell/orders", element: <ProtectedRoute><Orders /></ProtectedRoute> },
      { path: "/sell/settings", element: <ProtectedRoute><Settings /></ProtectedRoute> },

      // Backward-compatibility redirects for existing paths
      { path: "/products/:productId", element: <Navigate to="/sell/products/:productId" replace /> },
      { path: "/sales", element: <Navigate to="/sell/sales" replace /> },
      { path: "/orders", element: <Navigate to="/sell/orders" replace /> },
      { path: "/settings", element: <Navigate to="/sell/settings" replace /> },
      { path: "/web", element: <Navigate to="/sell" replace /> },
      { path: "/web/*", element: <Navigate to="/sell" replace /> },
    ],
  },
]);

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <RouterProvider router={router} />
  </React.StrictMode>
);
