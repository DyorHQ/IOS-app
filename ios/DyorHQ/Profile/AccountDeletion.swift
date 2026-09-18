import DyorKit
import SwiftUI

/// Account deletion, as App Store guideline 5.1.1(v) requires of an app that creates accounts. Everything DyorHQ
/// keeps for the account goes: the profile and every server row keyed to the wallet (posts, comments, follows,
/// alerts, watchlists, referral codes, device tokens — they cascade from the profile row), the
/// profile picture, the Privy sign-in account when there is one, and every key, token, cache and setting on this
/// device. Funds and on-chain history stay on the blockchain, reachable only through the user's own backup.
enum AccountDeletion {
    enum Failure: LocalizedError {
        case backendSignInNeeded(String)
        case privyNotConfigured

        var errorDescription: String? {
            switch self {
            case .backendSignInNeeded(let why):
                return "The server verifies it is your wallet before deleting anything, and that sign-in didn't complete: \(why)"
            case .privyNotConfigured:
                return "Your DyorHQ data was deleted, but the sign-in account (Privy) could not be: deletion isn't enabled on the server yet. Contact support to finish, or try again later."
            }
        }
    }

    /// Runs the whole deletion. Server data first (authorized by the wallet's own signature), then the Privy
    /// account, then this device. Throws before touching the device when a server step fails, so a retry is safe.
    @MainActor
    static func run(session: Session, social: SocialSession, env: AppEnvironment) async throws {
        guard let account = session.account else { return }
        let wallet = account.address.checksummed.lowercased()

        if account.canSign {
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { throw Failure.backendSignInNeeded(social.error ?? "the signature was cancelled") }
            try await social.client.deleteObjects(bucket: "avatars", prefix: wallet)
            // The profile row is the root: every other table references it with ON DELETE CASCADE.
            try await social.client.delete("profiles", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
            if let token = try await session.privyAccessToken() {
                do {
                    _ = try await social.client.invoke(function: "delete-account", bearer: token)
                } catch SupabaseError.http(let code, let body) where code == 500 && body.contains("PRIVY_APP_SECRET") {
                    throw Failure.privyNotConfigured
                }
            }
            social.signOut()
        }

        env.perplTrading.forget(address: account.address)
        NotificationHub.shared.clear()
        await session.eraseLocalData()
    }
}

/// The confirmation sheet: what goes, what stays, the wallet-specific warning, and two deliberate steps
/// (an acknowledgement and typing DELETE) before the destructive button.
struct DeleteAccountView: View {
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var confirmation = ""
    @State private var deleting = false
    @State private var error: String?

    private var method: Session.Method { session.account?.method ?? .watchOnly }
    private var isPrivy: Bool { [.apple, .google, .email, .passkey].contains(method) }
    private var ready: Bool { (acknowledged || !session.canSign) && confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" && !deleting }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Your DyorHQ profile, posts, comments, follows and reactions", systemImage: "person.2")
                    Label("Alerts, watchlists and referral codes", systemImage: "bell.badge")
                    Label("Notification history and this device's push registration", systemImage: "iphone")
                    if isPrivy { Label("Your \(method.title) sign-in account at Privy, including its embedded wallet", systemImage: "key") }
                    Label("Every key, session and cache stored on this device", systemImage: "trash")
                } header: {
                    Text("What is deleted")
                } footer: {
                    Text("Transactions, tokens and Moments you created stay on the Monad blockchain — nothing can remove them — and images you published for coins or Moments stay online because those tokens point to them.")
                }

                if session.canSign {
                    Section {
                        switch method {
                        case .apple, .google, .email, .passkey:
                            Text("Your embedded wallet is deleted together with the Privy account. Send your funds elsewhere or export the wallet's key first; afterwards nobody can recover it.")
                            NavigationLink { WalletExportView() } label: { Label("Export Wallet First", systemImage: "key.horizontal") }
                        case .imported:
                            Text("This wallet's private key is removed from this device. Keep its recovery phrase or key somewhere safe; it is the only way back to the funds.")
                        case .meraPasskey:
                            Text("Nothing about a passkey wallet is stored, so the same passkey recreates it later. To remove the passkey itself, delete it in Settings › Passwords.")
                        case .watchOnly:
                            EmptyView()
                        }
                        Toggle("I understand only my own backup can recover my funds", isOn: $acknowledged)
                    } header: {
                        Text("Your wallet")
                    }
                }

                Section {
                    TextField("Type DELETE to confirm", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button(role: .destructive) { Task { await deleteAccount() } } label: {
                        HStack {
                            Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                            Spacer()
                            if deleting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!ready)
                } footer: {
                    if let error { Text(error).foregroundStyle(Color.attention) }
                    else { Text(session.canSign ? "The server asks your wallet for one signature to prove it is you, then deletes everything. This cannot be undone." : "Removes everything about this watched address from this device.") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(deleting) } }
            .interactiveDismissDisabled(deleting)
        }
    }

    private func deleteAccount() async {
        deleting = true
        error = nil
        do {
            try await AccountDeletion.run(session: session, social: social, env: env)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        deleting = false
    }
}
