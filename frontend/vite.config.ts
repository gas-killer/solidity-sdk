import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Base path for project-subpath hosting (GitHub Pages at /<repo>/). Empty for a root domain / local
// dev. The Pages deploy workflow sets VITE_BASE_PATH.
const base = process.env.VITE_BASE_PATH || "/";

export default defineConfig({
  base,
  plugins: [react(), tailwindcss()],
  server: { port: 5173, host: true },
});
