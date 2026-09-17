import AuthenticationServices
import DyorKit
import SwiftUI

/// Welcome → Sign In. Modeled on Apple's own feature-list welcome screens: a wordmark, three benefits with
/// symbols, one button. Sign-in offers Apple, Google, email and passkeys through Privy, or a watch-only address.
struct OnboardingView: View {
    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView { path.append(.signIn) }
                .navigationDestination(for: OnboardingStep.self) { step in
                    switch step {
                    case .signIn: SignInView(path: $path)
                    case .email: EmailSignInView(path: $path)
                    case .watch: WatchAddressView(path: $path)
                    case .importWallet: ImportWalletView()
                    }
                }
        }
    }
}

enum OnboardingStep: Hashable {
    case signIn, email, watch, importWallet
}

struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(.wordmark)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(maxWidth: 300)
                .accessibilityLabel("\(SupportLinks.name). \(SupportLinks.tagline).")
            Text(SupportLinks.tagline)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 24) {
                FeatureRow(symbol: "camera.aperture", title: "Make Moments Last Forever", detail: "Publish a photo or video as an NFT on Monad. Share it with everyone and earn when it's collected.")
                FeatureRow(symbol: "flame", title: "Launch a Coin", detail: "Fair-launch a memecoin paired with a tokenized stock.")
                FeatureRow(symbol: "arrow.left.arrow.right", title: "Swap at the Best Price", detail: "Kuru, Uniswap and Monday Trade, compared on every swap.")
                FeatureRow(symbol: "chart.line.uptrend.xyaxis", title: "Trade Perpetuals", detail: "Perpl's on-chain order book, signed by your own wallet.")
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                PrimaryButton(title: "Continue", action: onContinue)
                Text("DyorHQ never holds your keys or your funds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title)
                .frame(width: 40)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Binding var path: [OnboardingStep]
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign In")
                        .font(.largeTitle.weight(.bold))
                    Text("Your wallet lives on this device. Add more sign-in methods later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
            }

            Section {
                if session.hasPrivy {
                    SignInWithAppleButton(.continue) { _ in } onCompletion: { _ in }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .overlay {
                            // Privy drives the native Apple flow itself; the button is the affordance Apple requires.
                            Color.clear.contentShape(Rectangle()).onTapGesture { Haptics.tap(); run("apple") { try await session.signInWithApple() } }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowBackground(Color.clear)
                    MethodButton(title: "Continue with Google", symbol: "g.circle", busy: busy == "google") { run("google") { try await session.signInWithGoogle() } }
                    MethodButton(title: "Continue with Email", symbol: "envelope", busy: false) { path.append(.email) }
                    if session.hasMera {
                        MethodButton(title: "Continue with a Passkey", symbol: "faceid", busy: busy == "mera") { run("mera") { try await session.signInWithMera(create: true) } }
                        MethodButton(title: "I already have a Passkey", symbol: "person.badge.key", busy: busy == "mera-signin") { run("mera-signin") { try await session.signInWithMera(create: false) } }
                    } else if session.hasPasskeys {
                        MethodButton(title: "Sign In with a Passkey", symbol: "person.badge.key", busy: busy == "passkey") { run("passkey") { try await session.signInWithPasskey() } }
                        MethodButton(title: "Create a Passkey", symbol: "faceid", busy: busy == "create") { run("create") { try await session.createPasskey(displayName: "DyorHQ") } }
                    }
                } else if session.hasMera {
                    MethodButton(title: "Continue with a Passkey", symbol: "faceid", busy: busy == "mera") { run("mera") { try await session.signInWithMera(create: true) } }
                    MethodButton(title: "I already have a Passkey", symbol: "person.badge.key", busy: busy == "mera-signin") { run("mera-signin") { try await session.signInWithMera(create: false) } }
                } else {
                    Label("Sign-in is not set up in this build. Add the Privy keys to Secrets.xcconfig to enable Apple, Google, email and passkeys.", systemImage: "key.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let error { InlineError(message: error) }
            }

            Section {
                MethodButton(title: "Import an Existing Wallet", symbol: "square.and.arrow.down", busy: false) { path.append(.importWallet) }
            } footer: {
                Text("Bring your own wallet with its recovery phrase or private key. It stays on this device.")
            }

            Section {
                MethodButton(title: "Watch an Address", symbol: "eye", busy: false) { path.append(.watch) }
            } footer: {
                Text("Follow any Monad wallet. Trading needs an account.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy != nil)
    }

    private func run(_ key: String, _ work: @escaping () async throws -> Void) {
        busy = key
        error = nil
        Task {
            do { try await work() } catch { self.error = describe(error) }
            busy = nil
        }
    }
}

private struct MethodButton: View {
    let title: String
    let symbol: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .foregroundStyle(.primary)
    }
}

struct EmailSignInView: View {
    @Environment(Session.self) private var session
    @Binding var path: [OnboardingStep]
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    private var emailValid: Bool { email.contains("@") && email.contains(".") && !email.hasSuffix(".") }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .disabled(sent)
                    .submitLabel(.send)
                    .onSubmit { if emailValid { send() } }
            } header: {
                Text(sent ? "Signed in with" : "Email")
            } footer: {
                if !sent { Text("We will send a six-digit code to this address.") }
            }

            if sent {
                Section {
                    TextField("Six-digit code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(6))
                            if code.count == 6 { verify() }
                        }
                } header: {
                    Text("Code")
                } footer: {
                    Button("Send a New Code") { send() }.font(.footnote).disabled(busy)
                }
            }

            if let error {
                Section { InlineError(message: error) }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Continue with Email")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else if sent {
                    Button("Verify") { verify() }.disabled(code.count != 6)
                } else {
                    Button("Send Code") { send() }.disabled(!emailValid)
                }
            }
        }
        .onAppear { focus = .email }
    }

    private func send() {
        busy = true
        error = nil
        Task {
            do {
                try await session.sendEmailCode(to: email.trimmingCharacters(in: .whitespaces))
                sent = true
                code = ""
                focus = .code
            } catch { self.error = describe(error) }
            busy = false
        }
    }

    private func verify() {
        guard code.count == 6, !busy else { return }
        busy = true
        error = nil
        Task {
            do { try await session.signIn(email: email.trimmingCharacters(in: .whitespaces), code: code) } catch { self.error = describe(error) }
            busy = false
        }
    }
}

struct WatchAddressView: View {
    @Environment(Session.self) private var session
    @Binding var path: [OnboardingStep]
    @State private var text = ""
    @FocusState private var focused: Bool

    private var address: Address? { Address(text) }

    var body: some View {
        Form {
            Section {
                TextField("0x…", text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { watch() }
            } header: {
                Text("Monad address")
            } footer: {
                if !text.isEmpty, address == nil {
                    Text("Enter a 42-character address starting with 0x.")
                } else {
                    Text("Balances, positions and launches for this address will be shown. Nothing can be signed.")
                }
            }
            Section {
                Button("Paste from Clipboard", systemImage: "doc.on.clipboard") {
                    if let pasted = UIPasteboard.general.string { text = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }
        .navigationTitle("Watch an Address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Watch") { watch() }.disabled(address == nil)
            }
        }
        .onAppear { focused = true }
    }

    private func watch() {
        guard let address else { return }
        session.watch(address)
    }
}
