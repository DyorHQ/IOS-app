import type { Metadata } from "next";
import type { ReactNode } from "react";
import Shell from "./shell";
import "./launchpad.css";

export const metadata: Metadata = {
  title: "DyorHQ Launchpad — fair launches on Monad",
  description: "Launch a memecoin on a fair bonding curve. When it graduates, liquidity moves to Uniswap v4 on Monad and locks forever.",
};

export default function LaunchpadLayout({ children }: { children: ReactNode }) {
  return <Shell>{children}</Shell>;
}
