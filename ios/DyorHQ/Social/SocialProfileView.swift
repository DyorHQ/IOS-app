import DyorKit
import SwiftUI

/// Connect to DyorHQ social (sign a nonce with the wallet) and edit the public profile — the first end-to-end
/// use of the Supabase backend: wallet sign-in → session → an RLS-protected write.
struct SocialProfileView: View {
    @Environment(SocialSession.self) private var social
    @Environment(Session.self) private var session
    @State private var handle = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var busy = false
    @State private var error: String?
    @State private var savedNote: String?

    var body: some View {
        List {
            if !session.canSign {
                Section {
                    Label("Sign in with a wallet to join DyorHQ social.", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.secondary).font(.subheadline)
                }
            } else if !social.isSignedIn {
                Section {
                    Button {
                        Task { busy = true; await social.signIn(session: session); busy = false; sync() }
                    } label: {
                        HStack {
                            Label("Connect to DyorHQ Social", systemImage: "person.2")
                            Spacer()
                            if social.state == .signingIn { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(busy || social.state == .signingIn)
                } footer: {
                    if let error = social.error { InlineError(message: error) }
                    else { Text("You'll sign a short message with your wallet to prove it's you — no transaction, no fees.") }
                }
            } else {
                Section("Your Profile") {
                    LabeledContent("Wallet") {
                        Text(shortWallet(social.profile?.wallet ?? "")).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("handle", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField("Display name", text: $displayName)
                    TextField("Bio", text: $bio, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { Text("Save Profile"); Spacer(); if busy { ProgressView().controlSize(.small) } }
                    }
                    .disabled(busy)
                    Button("Sign Out of Social", role: .destructive) { social.signOut() }.disabled(busy)
                } footer: {
                    if let error { InlineError(message: error) }
                    else if let savedNote { Label(savedNote, systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive) }
                    else { Text("Handle is lowercase letters, numbers and underscores, 3–20 characters.") }
                }
            }
        }
        .navigationTitle("DyorHQ Social")
        .navigationBarTitleDisplayMode(.inline)
        .task { social.restore(address: session.address); sync() }
        .onChange(of: social.isSignedIn) { _, _ in sync() }
        .onChange(of: social.profile) { _, _ in sync() }
    }

    private func sync() {
        guard let profile = social.profile else { return }
        if handle.isEmpty { handle = profile.handle ?? "" }
        if displayName.isEmpty { displayName = profile.display_name ?? "" }
        if bio.isEmpty { bio = profile.bio ?? "" }
    }

    private func save() async {
        busy = true; error = nil; savedNote = nil
        do { try await social.save(handle: handle, displayName: displayName, bio: bio); savedNote = "Saved to DyorHQ." }
        catch { self.error = describe(error) }
        busy = false
    }

    private func shortWallet(_ wallet: String) -> String {
        wallet.count > 12 ? "\(wallet.prefix(6))…\(wallet.suffix(4))" : wallet
    }
}
