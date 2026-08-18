import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // Served at wonni-app.web.app/web post-merge (see main.jsx's matching
  // BrowserRouter basename) — asset URLs must resolve under that subpath,
  // not the site root.
  base: "/web/",
  build: { outDir: "../public" },
});
