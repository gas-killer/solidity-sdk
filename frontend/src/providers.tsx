import { ReactNode } from "react";
import { WagmiProvider, createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BreadUIKitProvider } from "@breadcoop/ui";
import { getChain, usdcAddr, CONFIG } from "./chain";
import { erc20Abi } from "./abi/erc20";

// A wagmi config is required by @breadcoop/ui's context/components. Chain interaction in this app
// is done directly via viem (see chain.ts) — the frontend is the operator — but the kit's providers
// still need a wagmi context to mount without throwing.
const chain = getChain();
const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [injected()],
  transports: { [chain.id]: http(CONFIG.rpcUrl) },
});

const queryClient = new QueryClient();

export function Providers({ children }: { children: ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BreadUIKitProvider
          app="fund"
          chainId={chain.id}
          authProvider="general"
          tokenConfig={{ BREAD: { address: usdcAddr(), abi: erc20Abi as never } }}
        >
          {children}
        </BreadUIKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
