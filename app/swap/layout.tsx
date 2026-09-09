import type { Metadata } from "next";
import type { ReactNode } from "react";
import Shell from "../launchpad/shell";
import "../launchpad/launchpad.css";

export const metadata: Metadata = {
  title: "DyorHQ Swap — best price across Monad",
  description: "Swap spot assets on Monad at the best quote from Kuru Flow, Uniswap and Monday Trade.",
};

export default function SwapLayout({ children }: { children: ReactNode }) {
  return <Shell>{children}</Shell>;
}
