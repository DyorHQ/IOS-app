import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

// The current deployment, used only when there is no request to read the host from (prerendering).
const FALLBACK_ORIGIN = "https://mainstreet-ui.bushy-petal-0744.chatgpt.site";
const DESCRIPTION = "DyorHQ on Monad: launch memecoins, turn photos and videos into NFT Moments, trade perps on Perpl and swap tokens, all from your own wallet.";
const SHARE_IMAGE = { url: "/brand/dyorhq-monogram.png", width: 1254, height: 1254, alt: "DyorHQ" };

/** The origin that served this request, so share links and the share image point at the deployment people opened
    rather than one written into the code. The Worker sets x-forwarded-host/-proto from the request URL itself
    (worker/index.ts), replacing any the client sent; only a plain host[:port] is accepted. */
async function siteOrigin(): Promise<URL> {
  try {
    const h = await headers();
    const host = h.get("x-forwarded-host") ?? h.get("host");
    const scheme = h.get("x-forwarded-proto") === "http" ? "http" : "https";
    if (host && /^[a-z0-9.-]+(:\d{1,5})?$/i.test(host)) return new URL(`${scheme}://${host}`);
  } catch {
    /* no request */
  }
  return new URL(FALLBACK_ORIGIN);
}

export async function generateMetadata(): Promise<Metadata> {
  return {
    title: "DyorHQ | The RWA HQ for social trading",
    description: DESCRIPTION,
    icons: { icon: "/brand/dyorhq-monogram.png", shortcut: "/brand/dyorhq-monogram.png" },
    metadataBase: await siteOrigin(),
    openGraph: { title: "DyorHQ", description: DESCRIPTION, siteName: "DyorHQ", type: "website", url: "/", images: [SHARE_IMAGE] },
    twitter: { card: "summary", title: "DyorHQ", description: DESCRIPTION, images: [SHARE_IMAGE.url] },
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
