# Wallet Export

Lets a signed-in user export their wallet's private key **without leaving the app**.

There are two wallet types in DyorHQ, and export works differently for each:

| Wallet type (`Session.Method`) | Export path | Status |
|---|---|---|
| **Imported** (`.imported`) | Native reveal from the device Keychain, behind a biometric prompt | ✅ Works now, fully on-device |
| **Privy embedded** (`.apple/.google/.email/.passkey`) | Privy's **mobile key-export recipe**: a Privy-React page loaded in a `WKWebView` | ⚙️ iOS side done — needs the web page deployed + `WalletExportURL` set + a Privy allowed origin |
| **Watch-only** (`.watchOnly`) | N/A (no key) | — |

## Why Privy embedded needs a web page

Privy's **iOS SDK has no native key-export API**. Per Privy's docs, client-side wallets "can only be exported via
the `exportWallet` method in the **React** SDK … only available in web environments." Privy's official workaround is
the [mobile key-export recipe](https://docs.privy.io/recipes/mobile-key-export): host a tiny Privy-React page and load
it in a `WKWebView`. The key is reconstructed off-device inside Privy's own iframe and shown there — DyorHQ never sees
it.

The iOS side is implemented in [`DyorHQ/Wallet/WalletExportView.swift`](../../DyorHQ/Wallet/WalletExportView.swift):
`PrivyExportWebView` loads `AppConfig.walletExportURL` in a **non-persistent** `WKWebView` with an `exportResult`
script-message handler. Entry point: **Profile → Manage Wallets → Export Wallet**.

## To finish the Privy-embedded path (owner action)

1. **Deploy the export page** below to an HTTPS origin you control — recommended `https://dyorhq.fun/export`
   (a route in the existing Next.js app, or any static React host).
2. **Privy dashboard →** add that origin to **Allowed origins** for the **same** Privy app the iOS app uses
   (`PrivyAppID`). Login + export only work from an allowed origin.
3. **Set `WalletExportURL`** in `Secrets.xcconfig` (and declare it in `project.yml` `info.properties` as
   `WalletExportURL: "$(WALLET_EXPORT_URL)"`, then `xcodegen generate`) to that URL. Until it's set, the app shows
   "Key export for this wallet type isn't set up in this build yet" and the imported path still works.

## The export page (`app/export/page.tsx` — Next.js App Router, client component)

Requires `@privy-io/react-auth` in the web app. The page posts its result to the native `exportResult` handler.

```tsx
"use client";
import { PrivyProvider, usePrivy } from "@privy-io/react-auth";
import { useCallback } from "react";

const APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID!; // same app id as the iOS app

function postToNative(message: object) {
  const json = JSON.stringify(message);
  // iOS WKWebView bridge
  (window as any).webkit?.messageHandlers?.exportResult?.postMessage(json);
}

function ExportInner() {
  const { ready, authenticated, user, login, exportWallet } = usePrivy();

  const handleExport = useCallback(async () => {
    try {
      // Export the embedded wallet. exportWallet() opens Privy's secure key-reveal UI.
      const address = user?.wallet?.address;
      await exportWallet(address ? { address } : undefined);
      postToNative({ status: "success" });
    } catch (e) {
      postToNative({ status: "error", error: String(e) });
    }
  }, [exportWallet, user]);

  if (!ready) return <p style={{ padding: 24 }}>Loading…</p>;

  if (!authenticated) {
    return (
      <div style={{ padding: 24 }}>
        <p>Confirm your DyorHQ sign-in to export your wallet key.</p>
        <button onClick={() => login()}>Continue</button>
      </div>
    );
  }

  return (
    <div style={{ padding: 24 }}>
      <p>Reveal your wallet's private key to back it up or move it to another wallet.</p>
      <button onClick={handleExport}>Export private key</button>
      <p style={{ color: "#b45309", marginTop: 16, fontSize: 13 }}>
        Anyone with this key controls your funds. Never share it.
      </p>
    </div>
  );
}

export default function ExportPage() {
  return (
    <PrivyProvider appId={APP_ID} config={{ embeddedWallets: { createOnLogin: "off" } }}>
      <ExportInner />
    </PrivyProvider>
  );
}
```

Notes:
- Use the **same `PrivyAppID`** as the iOS app so the user's existing embedded wallet is the one exported. The user
  re-authenticates in the WebView (Privy sessions don't cross the native↔web boundary).
- `createOnLogin: "off"` — never create a new wallet from the export page.
- Confirm the exact `exportWallet` signature against your installed `@privy-io/react-auth` version (older versions
  take no argument and export the user's embedded wallet; newer ones accept `{address}`). The native side only cares
  about the `{status}` message.
- The native handler name **must** be `exportResult` (matches `WalletExportView.swift`).
