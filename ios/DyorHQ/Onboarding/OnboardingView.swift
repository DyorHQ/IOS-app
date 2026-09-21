import AuthenticationServices
import Combine
import DyorKit
import SwiftUI

/// Welcome → Get Started. A brand hero (serif wordmark over a soft purple glow) and an auto-advancing tour of what
/// DyorHQ does, then a focused hub that LEADS with the working path — Email & Password — and keeps Import / Watch as
/// quiet alternatives. Apple / Google appear only when the build actually enables them, so no one taps a dead method.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Hero: the wordmark on a soft brand-purple glow.
            ZStack {
                BrandGlow().offset(y: -8)
                VStack(spacing: 10) {
                    Image(.wordmark)
                        .renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(maxWidth: 250)
                        .accessibilityLabel("\(SupportLinks.name). \(SupportLinks.tagline).")
                    Text(SupportLinks.tagline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }
            .padding(.top, 44)

            // An auto-advancing tour of what you can do.
            FeatureTour()
                .frame(maxHeight: .infinity)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 14) {
                PrimaryButton(title: "Get Started", action: onContinue)
                Label("DyorHQ never holds your keys or your funds.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { appeared = true }
        }
    }
}

/// A soft radial halo in the Monad accent — the one splash of color on the monochrome canvas.
private struct BrandGlow: View {
    var body: some View {
        RadialGradient(colors: [Color.brand.opacity(0.30), Color.brand.opacity(0)],
                       center: .center, startRadius: 4, endRadius: 210)
            .frame(height: 240)
            .blur(radius: 18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct Feature {
    let symbol: String
    let title: String
    let detail: String
    init(_ symbol: String, _ title: String, _ detail: String) { self.symbol = symbol; self.title = title; self.detail = detail }
}

/// A gentle, swipeable carousel of the four things DyorHQ does. Auto-advances unless the user prefers reduced motion.
private struct FeatureTour: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    private let features = [
        Feature("camera.aperture", "Make Moments last forever", "Mint a photo or video as an NFT on Monad. Share it, and earn when it’s collected."),
        Feature("flame", "Launch a coin", "Fair-launch a memecoin paired with a tokenized stock."),
        Feature("arrow.left.arrow.right", "Swap at the best price", "Kuru, Uniswap and Monday Trade — compared on every swap."),
        Feature("chart.line.uptrend.xyaxis", "Trade perpetuals", "Perpl’s on-chain order book, signed by your own wallet."),
    ]
    private let advance = Timer.publish(every: 3.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            TabView(selection: $index) {
                ForEach(features.indices, id: \.self) { i in
                    FeatureCard(feature: features[i]).tag(i).padding(.horizontal, 28)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.5), value: index)

            HStack(spacing: 7) {
                ForEach(features.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.brand : Color.secondary.opacity(0.28))
                        .frame(width: i == index ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
            .accessibilityHidden(true)
        }
        .onReceive(advance) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % features.count }
        }
    }
}

private struct FeatureCard: View {
    let feature: Feature

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.12)).frame(width: 100, height: 100)
                Image(systemName: feature.symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.brand)
            }
            VStack(spacing: 8) {
                Text(feature.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var path: [OnboardingStep]
    @State private var busy: String?
    @State private var error: String?
    @State private var appeared = false

    /// Any social/passkey method the build actually offers. When none do, the whole block (and its divider) is hidden
    /// so the user only ever sees paths that work.
    private var hasAlternates: Bool { session.hasSocialLogins || session.hasMera || session.hasPasskeys }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get started").font(.largeTitle.weight(.bold))
                    Text("Your wallet is created and kept on this device — you hold the keys.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                // The primary, recommended path.
                HeroAuthCard(title: "Email & Password",
                             subtitle: "Sign up or log in. New accounts verify with a one-time code.",
                             symbol: "envelope.fill") { Haptics.tap(); path.append(.email) }

                if hasAlternates {
                    LabeledDivider("or continue with")
                    VStack(spacing: 10) { alternates }
                }

                if let error { InlineError(message: error) }

                LabeledDivider("more ways in")
                VStack(spacing: 10) {
                    SecondaryAuthRow(title: "Import a wallet",
                                     subtitle: "Use your recovery phrase or private key.",
                                     symbol: "square.and.arrow.down") { Haptics.tap(); path.append(.importWallet) }
                    SecondaryAuthRow(title: "Watch an address",
                                     subtitle: "Follow any Monad wallet. Trading needs an account.",
                                     symbol: "eye") { Haptics.tap(); path.append(.watch) }
                }

                Label("DyorHQ never holds your keys or your funds.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
        }
        .background(Color(.systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy != nil)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { appeared = true } }
    }

    @ViewBuilder private var alternates: some View {
        if session.hasSocialLogins {
            SignInWithAppleButton(.continue) { _ in } onCompletion: { _ in }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    // Privy drives the native Apple flow itself; the button is the affordance Apple requires.
                    Color.clear.contentShape(Rectangle()).onTapGesture { Haptics.tap(); run("apple") { try await session.signInWithApple() } }
                }
            SocialButton(title: "Continue with Google", symbol: "g.circle.fill", busy: busy == "google") { run("google") { try await session.signInWithGoogle() } }
        }
        if session.hasMera {
            SocialButton(title: "Continue with a Passkey", symbol: "faceid", busy: busy == "mera") { run("mera") { try await session.signInWithMera(create: true) } }
            SocialButton(title: "I already have a Passkey", symbol: "person.badge.key", busy: busy == "mera-signin") { run("mera-signin") { try await session.signInWithMera(create: false) } }
        } else if session.hasPasskeys {
            SocialButton(title: "Sign in with a Passkey", symbol: "person.badge.key", busy: busy == "passkey") { run("passkey") { try await session.signInWithPasskey() } }
            SocialButton(title: "Create a Passkey", symbol: "faceid", busy: busy == "create") { run("create") { try await session.createPasskey(displayName: "DyorHQ") } }
        }
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

/// The primary sign-in affordance: a filled brand-purple card that draws the eye first.
private struct HeroAuthCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: symbol).font(.title3).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// A quiet, neutral alternative sign-in row.
private struct SecondaryAuthRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(.tertiarySystemFill)).frame(width: 42, height: 42)
                    Image(systemName: symbol).font(.body).foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
        }
        .buttonStyle(PressableStyle())
    }
}

/// A bordered full-width social/passkey button, matched to the hub's card language.
private struct SocialButton: View {
    let title: String
    let symbol: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol) }
                Text(title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(.primary)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
        }
        // Plain style so the label stays neutral Ink (not the brand tint) — the purple hero stays the only focal point.
        .buttonStyle(.plain)
    }
}

/// A hairline rule with a small centered caption ("or continue with").
private struct LabeledDivider: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5)
            Text(text).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.tertiary).fixedSize()
            Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// Subtle press feedback for the card-style buttons.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Email + password onboarding. Sign up **verifies the email with a one-time code** (Privy), then sets a strong
/// password that deterministically becomes the wallet; log in re-derives the same wallet — no code — but only when the
/// email is a verified account matching the derived address. See `PasswordWallet` and `Session`.
struct EmailPasswordView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Binding var path: [OnboardingStep]

    enum Mode: String, CaseIterable, Identifiable { case signUp = "Sign Up", logIn = "Log In"; var id: String { rawValue } }
    enum Stage { case form, otp }
    @State private var mode: Mode = .signUp
    @State private var stage: Stage = .form
    /// Forgot-password: re-verify the email by OTP, then bind it to a NEW password/wallet. Reuses the sign-up form and
    /// verify UI (it collects a new password the same way), but finishes through the `email-rebind` function.
    @State private var reset = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var code = ""
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password, confirm, code }

    /// Sign-up and reset share the same "set a password" form and OTP verification; only login is different.
    private var setsPassword: Bool { mode == .signUp || reset }
    private var emailValid: Bool { email.contains("@") && email.contains(".") && !email.hasSuffix(".") }
    private var rejection: String? { PasswordStrength.rejection(password, email: email) }
    private var otpStage: Bool { setsPassword && stage == .otp }
    private var formValid: Bool {
        guard emailValid else { return false }
        if setsPassword { return rejection == nil && !confirm.isEmpty && password == confirm && acknowledged }
        return !password.isEmpty
    }

    var body: some View {
        Form {
            if !otpStage {
                if reset {
                    Section {
                        Text("Enter your email and a new password. We’ll email a code to confirm it’s you, then this new password becomes your wallet.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Reset password") }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .email)
                    PasswordField(title: reset ? "New password" : "Password", text: $password).focused($focus, equals: .password)
                    if setsPassword {
                        PasswordField(title: "Confirm password", text: $confirm).focused($focus, equals: .confirm)
                    }
                } footer: {
                    if reset {
                        if !password.isEmpty, !confirm.isEmpty, password != confirm {
                            Text("Passwords don’t match.").foregroundStyle(Color.negative)
                        }
                    } else if mode == .logIn {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Log in with the email and password you signed up with. Your wallet is recreated on this device — no code needed.")
                            Button("Forgot password?") { beginReset() }.font(.footnote)
                        }
                    } else if !password.isEmpty, !confirm.isEmpty, password != confirm {
                        Text("Passwords don’t match.").foregroundStyle(Color.negative)
                    }
                }

                if setsPassword {
                    Section {
                        StrengthMeter(score: PasswordStrength.score(password))
                        if !password.isEmpty, let rejection {
                            Label(rejection, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.attention)
                        }
                    } header: { Text("Password strength") }

                    Section {
                        Label {
                            Text("This password **is** your wallet. We can’t reset it or send a recovery email. If you lose it, you lose access to your funds — write it down or save it in your password manager.")
                        } icon: {
                            Image(systemName: "key.horizontal.fill").foregroundStyle(Color.attention)
                        }
                        .font(.footnote)
                        Toggle("I understand my password is the only way back to my wallet", isOn: $acknowledged).font(.footnote)
                    }
                }
            } else {
                Section {
                    TextField("6-digit code", text: $code)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .font(.title2.monospacedDigit()).focused($focus, equals: .code)
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(6))
                            if code.count == 6 { completeVerification() }
                        }
                } header: {
                    Text("Verify your email")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if reset {
                            Text("Enter the code we emailed to \(email). This confirms it’s you before your new password takes over your wallet.")
                        } else {
                            Text("Enter the code we emailed to \(email). This proves the email is yours — your wallet is created after you verify, so no fake or unowned emails can register.")
                        }
                        HStack(spacing: 16) {
                            Button("Send a new code") { startSignUp() }.disabled(busy)
                            Button("Change details") { stage = .form; code = "" }.disabled(busy)
                        }
                        .font(.footnote)
                    }
                }
            }

            if let error {
                Section { InlineError(message: error) }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(otpStage ? "Verify Email" : (reset ? "Reset Password" : "Email & Password"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if reset, !busy { Button("Cancel") { cancelReset() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() }
                else if mode == .logIn, !reset { Button("Log In") { logIn() }.disabled(!formValid) }
                else if stage == .form { Button("Continue") { startSignUp() }.disabled(!formValid) }
                else { Button("Verify") { completeVerification() }.disabled(code.count != 6) }
            }
        }
        .onAppear { focus = .email }
        .onChange(of: mode) { _, _ in stage = .form; code = ""; error = nil }
    }

    // MARK: Actions

    /// Send the sign-up OTP, then move to the verify step.
    private func startSignUp() {
        focus = nil; busy = true; error = nil
        Task {
            do { try await session.sendSignUpCode(to: email); stage = .otp; code = ""; focus = .code }
            catch { self.error = describe(error) }
            busy = false
        }
    }

    /// Verify the OTP, then create the wallet and register the verified email → address binding.
    private func completeSignUp() {
        guard code.count == 6, !busy else { return }
        focus = nil; busy = true; error = nil
        Task {
            do {
                try await session.verifyEmailForSignUp(email: email, code: code)
                try await session.signUpWithPassword(email: email, password: password, register: registerBinding)
            } catch {
                self.error = describe(error)
                code = ""
            }
            busy = false
        }
    }

    private func logIn() {
        focus = nil; busy = true; error = nil
        Task {
            do { try await session.logInWithPassword(email: email, password: password, verify: verifyBinding) }
            catch { self.error = describe(error) }
            busy = false
        }
    }

    // MARK: Forgot password (re-verify the email, then re-bind it to the new password's wallet)

    /// Switch the Log In form into the reset flow: same fields, but a fresh new password and a required email re-verify.
    private func beginReset() {
        reset = true; stage = .form; password = ""; confirm = ""; code = ""; acknowledged = false; error = nil; focus = .email
    }

    private func cancelReset() {
        reset = false; stage = .form; code = ""; error = nil
    }

    /// The OTP step finishes either a sign-up or a password reset.
    private func completeVerification() { reset ? completeReset() : completeSignUp() }

    /// Verify the OTP, then move the email to the new password's wallet through the `email-rebind` function. Nothing is
    /// committed until the server accepts both proofs, so a failed reset leaves the current session untouched.
    private func completeReset() {
        guard code.count == 6, !busy else { return }
        focus = nil; busy = true; error = nil
        Task {
            do {
                let token = try await session.verifyEmailCapturingToken(email: email, code: code)
                try await session.rebindEmailPassword(email: email, password: password, token: token, rebind: rebindBinding)
            } catch {
                self.error = describe(error)
                code = ""
            }
            busy = false
        }
    }

    /// Push the OTP proof (Privy token) and the new wallet's signature to the server, which rewrites the binding.
    private func rebindBinding(_ token: String, _ message: String, _ signature: String) async throws {
        struct Body: Encodable { let message: String; let signature: String }
        let body = try JSONEncoder().encode(Body(message: message, signature: signature))
        do { _ = try await env.social.client.invoke(function: "email-rebind", bearer: token, body: body) }
        catch SupabaseError.http(_, let text) { throw EmailAuthError.rebind(Self.serverMessage(text)) }
    }

    /// Surfaces the `{ "error": … }` reason the edge function returns (e.g. wrong code, expired) as a clean sentence.
    private static func serverMessage(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (obj["error"] as? String), !msg.isEmpty else {
            return "We couldn’t confirm that reset. Please try again."
        }
        let capped = msg.prefix(1).uppercased() + String(msg.dropFirst())
        return capped.hasSuffix(".") ? capped : capped + "."
    }

    // MARK: Backend binding (email_accounts)

    /// Bind the verified email to the derived address. Fails if the email is already registered to a different wallet.
    private func registerBinding(_ email: String, _ address: Address) async throws {
        if !env.social.isSignedIn { await env.social.signIn(session: session) }
        let wallet = address.checksummed.lowercased()
        struct Row: Encodable { let email: String; let wallet: String }
        _ = try? await env.social.client.upsertRows("email_accounts", [Row(email: email, wallet: wallet)], onConflict: "email")
        // Authoritative check: the binding must now resolve to THIS wallet (RLS blocks stealing a taken email).
        let bound: Bool = try await env.social.client.rpc("email_account_matches", ["p_email": email, "p_wallet": wallet], authed: false)
        if !bound { throw EmailAuthError.emailTaken }
    }

    /// Login gate: does this email map to exactly the derived address?
    private func verifyBinding(_ email: String, _ address: Address) async throws -> Bool {
        try await env.social.client.rpc("email_account_matches",
                                        ["p_email": email, "p_wallet": address.checksummed.lowercased()], authed: false)
    }
}

enum EmailAuthError: LocalizedError {
    case emailTaken
    case rebind(String)
    var errorDescription: String? {
        switch self {
        case .emailTaken:
            return "That email is already registered to a different wallet. Log in with the password you used before, or use a different email."
        case .rebind(let message):
            return message
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
