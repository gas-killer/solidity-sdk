import React from "react";
import ReactDOM from "react-dom/client";
import "./globals.css";
import { hydrateRemoteAddresses } from "./lib/addresses";

// Resolve the latest contract addresses from the published manifest BEFORE any module that captures
// them at import time (providers.tsx builds the wagmi config; chain.ts memoizes its viem clients).
// Dynamic imports below run only after CONFIG is hydrated. Fail-soft to the baked-in fallback.
async function boot() {
  await hydrateRemoteAddresses();
  const [{ Providers }, { App }] = await Promise.all([import("./providers"), import("./App")]);
  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <Providers>
        <App />
      </Providers>
    </React.StrictMode>,
  );
}

void boot();
