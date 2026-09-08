import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export async function generateMetadata(): Promise<Metadata> {
  const origin = "https://mainstreet-ui.bushy-petal-0744.chatgpt.site";
  const description = "The RWA HQ for social trading. A self-custodial mobile app on Monad for stock-backed memecoins, copying on-chain traders, perps and swaps.";
  return {
    title: "DyorHQ — The RWA HQ for social trading",
    description,
    icons: { icon: "/brand/dyorhq-mark.png", shortcut: "/brand/dyorhq-mark.png" },
    metadataBase: new URL(origin),
    openGraph: { title: "DyorHQ", description },
    twitter: { card: "summary", title: "DyorHQ", description },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
