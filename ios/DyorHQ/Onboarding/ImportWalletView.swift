import DyorKit
import SwiftUI

/// Imports an existing wallet by its recovery phrase or private key. Everything happens on-device: the address is
/// derived locally and previewed before anything is saved, and on import the key is written only to this iPhone's
/// Keychain. Nothing is transmitted. This is how someone who already has a MetaMask / Rabby / OKX wallet uses it in
/// DyorHQ without creating a new one.
struct ImportWalletView: View {
    @Environment(Session.self) private var session
    @State private var kind: Kind = .phrase
    @State private var phrase = ""
    @State private var privateKey = ""
    @State private var derived: Secp256k1Account?
    @State private var importing = false
    @State private var error: String?

    enum Kind: String, CaseIterable, Identifiable { case phrase = "Recovery Phrase", key = "Private Key"; var id: String { rawValue } }

    private var currentInput: String { kind == .phrase ? phrase : privateKey }

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch kind {
            case .phrase: phraseSection
            case .key: keySection
            }

            if let derived {
                Section {
                    HStack(spacing: 12) {
                        Avatar(url: nil, initials: "", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wallet found").font(.subheadline.weight(.semibold))
                            Text(derived.address.short).font(.footnote.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.positive)
                    }
                } footer: {
                    Text("Check this is the address you expect before importing.")
                }
            } else if !currentInput.isEmpty {
                Section {
                    Label(kind == .phrase ? "Not a valid 12–24 word recovery phrase yet." : "Not a valid private key.", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Section {
                Label("Your key is stored only on this iPhone, in the Keychain, and is never sent anywhere. DyorHQ cannot recover it — keep your original backup safe.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Import Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let error { InlineError(message: error).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                PrimaryButton(title: "Import Wallet", isBusy: importing, isDisabled: derived == nil) { runImport() }
                    .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .background(.bar)
        }
        .keyboardDoneButton()
        .task(id: currentInput + kind.rawValue) {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            derived = await deriveAccount()
        }
    }

    private var phraseSection: some View {
        Section {
            TextField("Enter your 12 or 24 word phrase", text: $phrase, axis: .vertical)
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
            Button("Paste", systemImage: "doc.on.clipboard") {
                if let pasted = UIPasteboard.general.string { phrase = pasted.trimmingCharacters(in: .whitespacesAndNewlines); Haptics.selection() }
            }
            .font(.subheadline)
        } header: {
            Text("Recovery Phrase")
        } footer: {
            let count = WalletImport.wordCount(phrase)
            if count > 0 { Text("\(count) word\(count == 1 ? "" : "s"). Words are separated by spaces.") }
            else { Text("The 12 or 24 words from your existing wallet, in order.") }
        }
    }

    private var keySection: some View {
        Section {
            TextField("0x…", text: $privateKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            Button("Paste", systemImage: "doc.on.clipboard") {
                if let pasted = UIPasteboard.general.string { privateKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines); Haptics.selection() }
            }
            .font(.subheadline)
        } header: {
            Text("Private Key")
        } footer: {
            Text("A 64-character hex private key, with or without a 0x prefix.")
        }
    }

    /// Derives the account off the main actor — PBKDF2 over a 24-word phrase is cheap but not free, and this runs
    /// on every edit. `Secp256k1Account` is Sendable, so it crosses back safely.
    private func deriveAccount() async -> Secp256k1Account? {
        let kind = kind, phrase = phrase, privateKey = privateKey
        return await Task.detached(priority: .userInitiated) {
            switch kind {
            case .phrase: return WalletImport.isValidMnemonic(phrase) ? WalletImport.account(fromMnemonic: phrase) : nil
            case .key: return WalletImport.account(fromPrivateKey: privateKey)
            }
        }.value
    }

    private func runImport() {
        guard let derived else { return }
        importing = true
        error = nil
        Task {
            await session.importWallet(derived)
            Haptics.success()
            importing = false
            // The session flips to signed-in and the root view swaps to the app; nothing else to dismiss.
        }
    }
}
