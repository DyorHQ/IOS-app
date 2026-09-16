import DyorKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The self-custody escape hatch: export the private key of the wallet you're signed in with.
///
/// - **Imported wallets** — the raw secp256k1 key already lives in this device's Keychain (`ImportedWalletStore`),
///   so it is revealed natively behind a biometric prompt. Nothing leaves the device.
/// - **Privy embedded wallets** (email / Apple / Google / passkey) — Privy's iOS SDK has **no** native key export;
///   export is only offered through Privy's React SDK. Per Privy's mobile key-export recipe we load a Privy-hosted
///   export page in a **non-persistent** `WKWebView`; the key is reconstructed off-device and shown inside Privy's
///   own secure UI, and is never held by DyorHQ. Requires `WalletExportURL` to be configured and its origin added
///   to the Privy dashboard's allowed origins.
/// - **Watch-only** — there is no key to export.
struct WalletExportView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    @State private var revealedKey: String?
    @State private var working = false
    @State private var error: String?
    @State private var copied = false
    @State private var showPrivyExport = false

    private var method: Session.Method? { session.account?.method }

    var body: some View {
        List {
            if method == .imported {
                importedSections
            } else if method == nil || method == .watchOnly {
                watchOnlySection
            } else {
                privySections
            }
        }
        .navigationTitle("Export Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPrivyExport) {
            if let url = env.config.walletExportURL { PrivyExportSheet(url: url) }
        }
        // Never leave the key on screen once the app leaves the foreground (app-switcher snapshot, screen recording).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealedKey = nil; copied = false }
        }
    }

    // MARK: Imported — native reveal

    @ViewBuilder private var importedSections: some View {
        Section {
            if let key = revealedKey {
                Text(key)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .privacySensitive()
                    .padding(.vertical, 4)
                Button(copied ? "Copied" : "Copy Private Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyKey(key)
                }
                Button("Hide", systemImage: "eye.slash") { revealedKey = nil; copied = false }
            } else {
                Button {
                    reveal()
                } label: {
                    HStack {
                        Label("Reveal Private Key", systemImage: "key.horizontal")
                        Spacer()
                        if working { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(working)
            }
        } header: {
            Text("Private Key")
        } footer: {
            if let error { InlineError(message: error) }
            else if copied { Text("Copied to the clipboard — it clears automatically in 90 seconds.") }
            else if revealedKey == nil { Text("Shown once behind \(BiometricGate.typeName). Reveal it only somewhere private.") }
        }

        warningSection
    }

    // MARK: Privy embedded — secure WebView export

    @ViewBuilder private var privySections: some View {
        Section {
            Button {
                showPrivyExport = true
            } label: {
                HStack {
                    Label("Export in Secure View", systemImage: "lock.rectangle.on.rectangle")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .disabled(env.config.walletExportURL == nil || !session.canSign)
        } header: {
            Text("Private Key")
        } footer: {
            if env.config.walletExportURL == nil {
                Text("Key export for this wallet type isn't set up in this build yet.")
            } else {
                Text("Your \(method?.title ?? "") wallet's key is held by Privy, not DyorHQ. Export opens Privy's own secure page — you re-confirm your Privy sign-in there, and the key is shown inside that page only. DyorHQ never sees or stores it.")
            }
        }

        warningSection
    }

    // MARK: Watch-only

    private var watchOnlySection: some View {
        Section {
            Label("You're watching this address — there's no key to export.", systemImage: "eye")
                .font(.subheadline).foregroundStyle(.secondary)
        } footer: {
            Text("Import a wallet with its private key or recovery phrase to sign, trade, and export it later.")
        }
    }

    // MARK: Shared

    private var warningSection: some View {
        Section {
            Label("Anyone with this key has full control of your funds. Never share it — DyorHQ support will never ask for it.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Color.attention)
            Label("Only enter it into a wallet you trust (MetaMask, Rabby, OKX…). A hardware wallet is safest.", systemImage: "hand.raised.fill")
                .font(.footnote).foregroundStyle(.secondary)
        } footer: {
            Text("This is the key for \(session.address?.short ?? "your wallet"). Treat it like the keys to a safe.")
        }
    }

    private func reveal() {
        working = true
        error = nil
        Task {
            let ok = await BiometricGate.authenticate(reason: "Reveal your wallet's private key")
            guard ok else {
                error = "\(BiometricGate.typeName) is required to reveal your key."
                working = false
                return
            }
            guard let account = ImportedWalletStore.loadAccount() else {
                error = "Couldn't read the key from this device's Keychain."
                working = false
                return
            }
            revealedKey = account.privateKey.hexString // already 0x-prefixed
            working = false
            Haptics.warning()
        }
    }

    private func copyKey(_ key: String) {
        // Auto-expiring clipboard so a copied key doesn't linger for other apps to read.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: key]],
            options: [.expirationDate: Date().addingTimeInterval(90)]
        )
        copied = true
        Haptics.selection()
    }
}

// MARK: - Privy secure-export WebView (Privy mobile key-export recipe)

/// Presents Privy's hosted export page in a non-persistent WebView. The page runs Privy's React SDK; on completion
/// it posts a JSON message (`{status: "success" | "error"}`) to the `exportResult` script-message handler.
private struct PrivyExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?

    var body: some View {
        NavigationStack {
            PrivyExportWebView(url: url) { result in
                if result == "success" { dismiss() }
                else { status = "Export was cancelled or didn't finish." }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Export Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if let status {
                    Text(status).font(.footnote).foregroundStyle(Color.attention)
                        .frame(maxWidth: .infinity).padding().background(.bar)
                }
            }
        }
    }
}

private struct PrivyExportWebView: UIViewRepresentable {
    let url: URL
    let onResult: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // don't cache Privy login / export material on device
        config.userContentController.add(context.coordinator, name: "exportResult")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "exportResult")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onResult: (String) -> Void
        init(onResult: @escaping (String) -> Void) { self.onResult = onResult }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "exportResult" else { return }
            var status = "error"
            if let body = message.body as? String, let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["status"] as? String {
                status = value
            } else if let dict = message.body as? [String: Any], let value = dict["status"] as? String {
                status = value
            }
            onResult(status)
        }
    }
}
