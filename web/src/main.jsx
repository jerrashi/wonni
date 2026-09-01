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

function ProtectedRoute({ children }) {
  const { user, loading } = useAuthState();
  if (loading) return <div className="loading">Loading...</div>;
  return user ? children : <Navigate to="/login" replace />;
}

function RootLayout() {
  return (
    <MediaJobQueueProvider>
      <Outlet />
      <BackgroundTasksTray />
    </MediaJobQueueProvider>
  );
}

const router = createBrowserRouter(
  [
    {
      element: <RootLayout />,
      children: [
        { path: "/login", element: <Login /> },
        { path: "/", element: <ProtectedRoute><Dashboard /></ProtectedRoute> },
        { path: "/products/:productId", element: <ProtectedRoute><ProductDetail /></ProtectedRoute> },
        { path: "/sales", element: <ProtectedRoute><Sales /></ProtectedRoute> },
        { path: "/orders", element: <ProtectedRoute><Orders /></ProtectedRoute> },
        { path: "/settings", element: <ProtectedRoute><Settings /></ProtectedRoute> },
      ],
    },
  ],
  {
    // This app is served at wonni-app.web.app/web (Phase B merge, sharing
    // wonni-app's Hosting site with the iOS app's own oauth/privacy pages)
    // rather than its own site root. A data router (not plain BrowserRouter)
    // is required here so ProductDetail's useBlocker navigation guard works.
    basename: "/web",
  }
);

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <RouterProvider router={router} />
  </React.StrictMode>
);
