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
                    case .email: EmailPasswordView(path: $path)
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
                MethodButton(title: "Continue with Email", symbol: "envelope", busy: false) { path.append(.email) }
            } footer: {
                Text("Sign up or log in with an email and password. Your wallet is created on this device from them — no code is sent.")
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

/// Email + password onboarding. Sign up sets a strong password (enforced) that deterministically becomes the wallet;
/// log in re-derives the same wallet from the same email + password. No code is sent. See `PasswordWallet`.
struct EmailPasswordView: View {
    @Environment(Session.self) private var session
    @Binding var path: [OnboardingStep]

    enum Mode: String, CaseIterable, Identifiable { case signUp = "Sign Up", logIn = "Log In"; var id: String { rawValue } }
    @State private var mode: Mode = .signUp
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password, confirm }

    private var emailValid: Bool { email.contains("@") && email.contains(".") && !email.hasSuffix(".") }
    /// Sign-up strength gate (not applied when logging in with an existing password).
    private var rejection: String? { PasswordStrength.rejection(password, email: email) }
    private var canSubmit: Bool {
        guard emailValid, !busy else { return false }
        switch mode {
        case .signUp: return rejection == nil && !confirm.isEmpty && password == confirm && acknowledged
        case .logIn: return !password.isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
            }
            .listRowBackground(Color.clear)

            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                PasswordField(title: "Password", text: $password)
                    .focused($focus, equals: .password)
                if mode == .signUp {
                    PasswordField(title: "Confirm password", text: $confirm)
                        .focused($focus, equals: .confirm)
                }
            } footer: {
                if mode == .logIn {
                    Text("Logging in recreates your wallet from your email and password. A different password makes a different wallet — there is no reset.")
                } else if !password.isEmpty, !confirm.isEmpty, password != confirm {
                    Text("Passwords don’t match.").foregroundStyle(Color.negative)
                }
            }

            if mode == .signUp {
                Section {
                    StrengthMeter(score: PasswordStrength.score(password))
                    if !password.isEmpty, let rejection {
                        Label(rejection, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.attention)
                    }
                } header: {
                    Text("Password strength")
                }

                Section {
                    Label {
                        Text("This password **is** your wallet. We can’t reset it or send a recovery email. If you lose it, you lose access to your funds — write it down or save it in your password manager.")
                    } icon: {
                        Image(systemName: "key.horizontal.fill").foregroundStyle(Color.attention)
                    }
                    .font(.footnote)
                    Toggle("I understand my password is the only way back to my wallet", isOn: $acknowledged)
                        .font(.footnote)
                }
            }

            if let error {
                Section { InlineError(message: error) }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Email & Password")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() }
                else { Button(mode == .signUp ? "Create" : "Log In") { submit() }.disabled(!canSubmit) }
            }
        }
        .onAppear { focus = .email }
    }

    private func submit() {
        focus = nil
        busy = true
        error = nil
        Task {
            do { try await session.signInWithPassword(email: email, password: password) }
            catch { self.error = describe(error) }
            busy = false
        }
    }
}

/// A password field with a reveal toggle — reveal matters here because a mistyped password derives a different
/// wallet, and iOS's password content type lets the user save/autofill it (so they don't forget it).
private struct PasswordField: View {
    let title: String
    @Binding var text: String
    @State private var reveal = false

    var body: some View {
        HStack {
            Group {
                if reveal { TextField(title, text: $text) } else { SecureField(title, text: $text) }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide password" : "Show password")
        }
    }
}

/// Four-segment strength bar for the sign-up password.
private struct StrengthMeter: View {
    let score: Int // 0…4

    private var tint: Color {
        switch score { case 0, 1: return .negative; case 2: return .attention; default: return .positive }
    }
    private var label: String {
        switch score { case 0: return " "; case 1: return "Weak"; case 2: return "Fair"; case 3: return "Good"; default: return "Strong" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < score ? tint : Color(.tertiarySystemFill))
                        .frame(height: 5)
                }
            }
            Text(label).font(.caption2).foregroundStyle(tint)
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
