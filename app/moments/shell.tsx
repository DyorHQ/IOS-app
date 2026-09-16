"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { Icon, Sprite } from "../ui/icons";
import { setPrefs, useApplyPrefs, type Theme } from "../preview-controls";
import { NetworkPill, WalletButton } from "../launchpad/ui";
import { Wordmark } from "../ui/wordmark";
import "../lib/dev-wallet";

const NEXT_THEME: Record<Theme, Theme> = { system: "light", light: "dark", dark: "system" };
const THEME_ICON = { system: "settings", light: "sun", dark: "moon" } as const;

export default function MomentsShell({ children }: { children: ReactNode }) {
  const { prefs } = useApplyPrefs();
  const pathname = usePathname();
  const current = (href: string, exact = false) => ((exact ? pathname === href : pathname.startsWith(href)) ? "page" : undefined);
  return (
    <div className="site">
      <Sprite />
      <header className="site-head">
        <div className="bar glass">
          <Link href="/moments" className="brand" aria-label="DyorHQ Moments"><Wordmark /></Link>
          <nav className="site-nav" aria-label="Moments">
            <Link href="/moments" aria-current={current("/moments", true)}>Moments</Link>
            <Link href="/moments/create" aria-current={current("/moments/create")}>Publish</Link>
            <Link href="/moments/portfolio" aria-current={current("/moments/portfolio")}>Portfolio</Link>
            <Link href="/swap" aria-current={current("/swap")}>Swap</Link>
            <Link href="/launchpad">Launchpad</Link>
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
      <footer className="site-foot">DyorHQ Moments on Monad · collect a moment, own its edition, share its coin · early, low-cap, validation-stage assets · <a href="https://monadscan.com" target="_blank" rel="noreferrer">Monadscan</a></footer>
    </div>
  );
}
