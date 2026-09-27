import DyorKit
import SwiftUI

/// Account deletion, as App Store guideline 5.1.1(v) requires of an app that creates accounts. Everything DyorHQ
/// keeps for the account goes: the profile and every server row keyed to the wallet (posts, comments, follows,
/// alerts, watchlists, referral codes, device tokens — they cascade from the profile row), the
/// profile picture, the Privy sign-in account when there is one, a passkey account's passkey (reported to the passkey
/// provider, MERA-PLAN §8), and every key, token, cache and setting on this device. Funds and on-chain history stay on
/// the blockchain, reachable only through the user's own backup.
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
    /// A passkey account goes through `deletePasskeyAccount`, which also removes the passkey.
    @MainActor
    static func run(session: Session, social: SocialSession, env: AppEnvironment) async throws {
        guard let account = session.account else { return }
        if account.method == .meraPasskey {
            try await deletePasskeyAccount(shown: account.address, session: session, social: social, env: env)
            return
        }
        let wallet = account.address.checksummed.lowercased()

        if account.canSign {
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { throw Failure.backendSignInNeeded(social.error ?? "the signature was cancelled") }
            try await deleteServerRows(wallet: wallet, social: social)
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

    /// A passkey (Mera) account's deletion, which removes the passkey too (MERA-PLAN §8), in the order
    /// `Mera.AccountDeletion.run` fixes:
    ///
    /// 1. A forced pinned ceremony, even while a session is live (`MeraSession.stepUp`), that must derive `address` —
    ///    the one on screen. Its credential ID is kept in memory: the erase below clears `MeraCredentialStore`. The
    ///    session it opens signs the backend sign-in.
    /// 2. The server rows. A failure stops here with "Nothing on this phone was changed": no signal, no erase.
    /// 3. The signal to the passkey provider, for `Mera.relyingParty` and that credential ID.
    /// 4. This device, erased.
    ///
    /// Then the "Account deleted." screen, which RootView shows once the account is signed out (`Session.passkeyDeletion`).
    @MainActor
    static func deletePasskeyAccount(shown address: Address, session: Session, social: SocialSession, env: AppEnvironment) async throws {
        let outcome = try await Mera.AccountDeletion.run(
            account: address,
            confirm: {
                let approval = try await session.mera.stepUp(expecting: address)
                return Mera.AccountDeletion.Confirmation(credentialID: approval.credentialID, address: approval.address)
            },
            deleteServerData: {
                try await deletePasskeyServerRows(address: address, session: session, social: social)
            },
            signal: session.mera.signal,
            eraseLocalData: { await eraseThisDevice(address: address, session: session, social: social, env: env) })
        session.passkeyDeletion = Mera.AccountDeletion.Done(outcome: outcome)
    }

    /// This device's copy of an account, gone: the backend session closed, Perpl's token and socket dropped, the
    /// notification center cleared, then `Session.eraseLocalData`. Nothing on the server is deleted and nothing is
    /// reported to the passkey provider. A passkey account's deletion does both first; "Forget This Device"
    /// (`ProfileView`) is only this, so the passkey keeps the account and "I already have a passkey" brings it back.
    @MainActor
    static func eraseThisDevice(address: Address, session: Session, social: SocialSession, env: AppEnvironment) async {
        social.signOut()
        env.perplTrading.forget(address: address)
        NotificationHub.shared.clear()
        await session.eraseLocalData()
    }

    /// The server half for a passkey account. The backend sign-in, when one is needed, is signed prompt-free by the
    /// session the deletion's ceremony just opened (`Session.backgroundWallet`): never a second prompt. Profile work
    /// still running (a new account's background follow-up, a restore) is waited out first, so it can't recreate the
    /// profile row after it is deleted.
    @MainActor
    private static func deletePasskeyServerRows(address: Address, session: Session, social: SocialSession) async throws {
        let wallet = address.checksummed.lowercased()
        await social.settle()
        #if DEBUG && targetEnvironment(simulator)
        // Simulator test mode: a stub account never signs in to the backend (`SocialSession.startSignIn`), so it has no
        // rows there to delete. Skipped quietly, and the deletion goes on to the signal and the erase.
        if session.mera.isStub, !social.isSignedIn { return }
        #endif
        if !social.isSignedIn, let signer = session.backgroundWallet {
            await social.signIn(address: address, wallet: signer)
        }
        guard social.isSignedIn, await social.client.signedInWallet?.lowercased() == wallet else {
            throw Failure.backendSignInNeeded(social.error ?? "the passkey session ended before it could sign")
        }
        await social.settle()
        try await deleteServerRows(wallet: wallet, social: social)
    }

    /// The wallet's server data, in this order, for every account type.
    @MainActor
    private static func deleteServerRows(wallet: String, social: SocialSession) async throws {
        try await social.client.deleteObjects(bucket: "avatars", prefix: wallet)
        // The profile row is the root: every other table references it with ON DELETE CASCADE.
        try await social.client.delete("profiles", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
        // The email → wallet binding has NO FK to profiles, so it doesn't cascade. Delete it explicitly: an
        // email+password wallet is deterministic, so leaving the binding would let the same credentials log back
        // in through the gate (email_account_matches) after "deletion". Owner-scoped DELETE (migration 17) only
        // touches this wallet's own row; other account types simply have no row here.
        try await social.client.delete("email_accounts", query: [URLQueryItem(name: "wallet", value: "eq.\(wallet)")])
    }
}

/// The confirmation sheet: what goes, what stays, the wallet-specific warning, and two deliberate steps
/// (an acknowledgement and typing DELETE) before the destructive button.
///
/// A passkey (Mera) account's version (MERA-PLAN §8) leads with its address and what could be lost, because deleting
/// removes the passkey — the wallet's only key. Its first actions are Export Recovery Phrase and Move Funds Out.
/// Deleting without having exported the phrase here always needs "I understand I may permanently lose these funds"
/// ticked, whatever the balances read. The button is "Delete with Face ID": a forced passkey prompt.
struct DeleteAccountView: View {
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var confirmation = ""
    @State private var deleting = false
    @State private var error: String?
    /// A passkey account's recovery phrase was shown and confirmed from this screen (`RecoveryPhraseView`).
    @State private var exported = false
    @State private var showSend = false

    private var method: Session.Method { session.account?.method ?? .watchOnly }
    private var isPrivy: Bool { [.apple, .google, .email, .passkey].contains(method) }
    private var isPasskey: Bool { method == .meraPasskey }
    private var typedDelete: Bool { confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" }
    private var ready: Bool {
        guard typedDelete, !deleting else { return false }
        if isPasskey { return exported || acknowledged }
        return acknowledged || !session.canSign
    }

    var body: some View {
        NavigationStack {
            List {
                if isPasskey, let address = session.address { passkeySections(address) }

                Section {
                    Label("Your DyorHQ profile, posts, comments, follows and reactions", systemImage: "person.2")
                    Label("Alerts, watchlists and referral codes", systemImage: "bell.badge")
                    Label("Notification history and this device's push registration", systemImage: "iphone")
                    if isPrivy { Label("Your \(method.title) sign-in account at Privy, including its embedded wallet", systemImage: "key") }
                    if isPasskey { Label("Your passkey: DyorHQ asks your passkey app to remove it", systemImage: "person.badge.key") }
                    Label("Every key, session and cache stored on this device", systemImage: "trash")
                } header: {
                    Text("What is deleted")
                } footer: {
                    Text("Transactions, tokens and Moments you created stay on the Monad blockchain — nothing can remove them — and images you published for coins or Moments stay online because those tokens point to them.")
                }

                if method == .apple {
                    Section {
                        // Apple's fallback when the app can't revoke the Sign in with Apple token itself (TN3194); the
                        // steps are Apple's own (support.apple.com/102571).
                        Text("Also stop using Sign in with Apple for DyorHQ: open Settings, tap your name, tap Sign in with Apple, select DyorHQ, then tap Delete.")
                    } header: {
                        Text("Sign in with Apple")
                    }
                }

                if session.canSign, !isPasskey {
                    Section {
                        switch method {
                        case .apple, .google, .email, .passkey:
                            Text("Your embedded wallet is deleted together with the Privy account. Send your funds elsewhere or export the wallet's key first; afterwards nobody can recover it.")
                            NavigationLink { WalletExportView() } label: { Label("Export Wallet First", systemImage: "key.horizontal") }
                        case .imported:
                            Text("This wallet's private key is removed from this device. Keep its recovery phrase or key somewhere safe; it is the only way back to the funds.")
                        case .emailPassword:
                            Text("This wallet is recreated from your email and password. Removing it deletes the device copy; keep your email and password, the only way back to the funds. A password reset can't bring them back: it creates a new, empty wallet.")
                        case .meraPasskey, .watchOnly:
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
                            Label(isPasskey ? "Delete with \(BiometricGate.promptName)" : "Delete Account", systemImage: isPasskey ? BiometricGate.promptSymbol : "person.crop.circle.badge.xmark")
                            Spacer()
                            if deleting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!ready)
                } footer: {
                    if let error { Text(error).foregroundStyle(Color.attention) }
                    else if isPasskey { Text("\(BiometricGate.promptName) confirms it's your passkey, even if your session is open. Your data on the server is deleted first; only then is the passkey removed and this phone cleared. This cannot be undone.") }
                    else { Text(session.canSign ? "The server asks your wallet for one signature to prove it is you, then deletes everything. This cannot be undone." : "Removes everything about this watched address from this device.") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(deleting) } }
            .interactiveDismissDisabled(deleting)
            .sheet(isPresented: $showSend) { SendSheet() }
        }
    }

    /// A passkey account: the address, the warning, the two ways to keep the funds, and what could be lost.
    @ViewBuilder private func passkeySections(_ address: Address) -> some View {
        Section {
            Text(address.checksummed)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding(.vertical, 2)
            Text("Deleting removes your passkey, which is this wallet's only key. Assume this is permanent unless you export the recovery phrase first.")
                .font(.subheadline)
        } header: {
            Text("Your wallet")
        }

        Section {
            NavigationLink {
                RecoveryPhraseView(onConfirmed: { exported = true })
            } label: {
                Label(exported ? "Recovery Phrase Exported" : "Export Recovery Phrase", systemImage: exported ? "checkmark.seal.fill" : "key.horizontal")
                    .fontWeight(.semibold)
                    .foregroundStyle(exported ? Color.positive : Color.brand)
            }
            Button { showSend = true } label: {
                Label("Move Funds Out", systemImage: "arrow.up.right")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.brand)
            }
        } footer: {
            Text("The recovery phrase restores this wallet in any other wallet app. Or send what it holds to a wallet you keep.")
        }
        .disabled(deleting)

        Section {
            Label("MON and tokens in this wallet", systemImage: "dollarsign.circle")
            Label("Perpl collateral and open positions", systemImage: "chart.line.uptrend.xyaxis")
            Label("NFTs and Moments", systemImage: "photo.on.rectangle")
            Label("Launchpad creator fees and holder rewards", systemImage: "flame")
            Label("Moments vesting and creator proceeds", systemImage: "hourglass")
            Label("Funds at this same address on other EVM chains (Bridge)", systemImage: "point.3.connected.trianglepath.dotted")
            if exported {
                Label("You exported and confirmed the recovery phrase.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.positive)
            } else {
                Toggle("I understand I may permanently lose these funds", isOn: $acknowledged)
            }
        } header: {
            Text("What could be lost")
        } footer: {
            Text("All of it stays at \(address.short) on the blockchain, but without the passkey or the recovery phrase nothing can move it.")
        }
    }

    private func deleteAccount() async {
        deleting = true
        error = nil
        do {
            if isPasskey, let address = session.address {
                try await AccountDeletion.deletePasskeyAccount(shown: address, session: session, social: social, env: env)
            } else {
                try await AccountDeletion.run(session: session, social: social, env: env)
            }
            dismiss()
        } catch where isUserCancellation(error) {
            // The passkey prompt was closed: nothing was deleted, and the form stays as it was.
        } catch {
            self.error = describe(error)
        }
        deleting = false
    }
}

/// The screen a passkey account's deletion ends on (MERA-PLAN §8), in place of onboarding (RootView) until closed:
/// the account is gone, and what may be left of the passkey. Apple doesn't confirm what the provider did with the
/// signal, so the manual steps are always there; on iOS 18, which has no signal, they are the one step left.
struct AccountDeletedView: View {
    let done: Mera.AccountDeletion.Done
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Color.positive)
                        Text(done.title)
                            .font(.title2.weight(.bold))
                        if let note = done.recentlyDeleted {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Section {
                    if done.passkeyRemains {
                        Label(done.stepsHeading, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.attention)
                    }
                    ForEach(Array(done.steps.enumerated()), id: \.offset) { index, step in
                        Label { Text(step) } icon: { Image(systemName: "\(index + 1).circle") }
                    }
                } header: {
                    if !done.passkeyRemains { Text(done.stepsHeading) }
                }

                Section {
                    PrimaryButton(title: "Done", systemImage: "checkmark") { onClose() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
