import type { Metadata } from "next";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const origin = "https://mainstreet-ui.bushy-petal-0744.chatgpt.site";
  const description = "DyorHQ is a self-custodial mobile app on Monad for launching stock-backed memecoins, copying on-chain traders, and trading perps and swaps.";
  return {
    title: "DyorHQ | The RWA HQ for social trading",
    description,
    icons: { icon: "/brand/dyorhq-mark.png", shortcut: "/brand/dyorhq-mark.png" },
    metadataBase: new URL(origin),
    openGraph: { title: "DyorHQ", description },
    twitter: { card: "summary", title: "DyorHQ", description },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <head><link rel="preload" href="/fonts/manrope.ttf" as="font" type="font/ttf" crossOrigin="anonymous" /></head>
      <body className="antialiased">{children}</body>
    </html>
  );
}
