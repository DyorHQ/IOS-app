"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { Icon, Sprite } from "../ui/icons";
import { setPrefs, useApplyPrefs, type Theme } from "../preview-controls";
import { NetworkPill, WalletButton } from "./ui";

const NEXT_THEME: Record<Theme, Theme> = { system: "light", light: "dark", dark: "system" };
const THEME_ICON = { system: "settings", light: "sun", dark: "moon" } as const;

export default function Shell({ children }: { children: ReactNode }) {
  const { prefs } = useApplyPrefs();
  const pathname = usePathname();
  const current = (href: string, exact = false) => ((exact ? pathname === href : pathname.startsWith(href)) ? "page" : undefined);
  return (
    <div className="site">
      <Sprite />
      <header className="site-head">
        <div className="bar glass">
          <Link href="/launchpad" className="brand"><img src="/brand/dyorhq-mark-small.png" alt="" /><span>Dyor<b>HQ</b></span></Link>
          <nav className="site-nav" aria-label="Launchpad">
            <Link href="/launchpad" aria-current={current("/launchpad", true)}>Explore</Link>
            <Link href="/launchpad/create" aria-current={current("/launchpad/create")}>Create</Link>
            <Link href="/">App preview</Link>
          </nav>
          <span className="spacer" />
          <NetworkPill />
          <button type="button" className="iconbtn" aria-label={`Theme: ${prefs.theme}. Switch theme`} title={`Theme: ${prefs.theme}`} onClick={() => setPrefs({ ...prefs, theme: NEXT_THEME[prefs.theme] })}>
            <Icon name={THEME_ICON[prefs.theme]} />
          </button>
          <WalletButton />
        </div>
      </header>
      <main className="wrap">{children}</main>
      <footer className="site-foot">DyorHQ Launchpad on Monad · bonding curves that graduate into Uniswap v4 pools with permanently locked liquidity · <a href="https://monadscan.com" target="_blank" rel="noreferrer">Monadscan</a></footer>
    </div>
  );
}
