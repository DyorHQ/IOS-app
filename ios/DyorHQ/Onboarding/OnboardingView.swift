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
                .padding(.bottom, 32) // keep the page dots clear of the Get Started button
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

/// A gentle, swipeable carousel of the four things DyorHQ does. Auto-advances (unless the user prefers reduced motion)
/// and loops forward seamlessly — it never visibly rewinds to the first card.
private struct FeatureTour: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    private let features = [
        Feature("camera.aperture", "Make Moments last forever", "Mint a photo or video as an NFT on Monad. Share it, and earn when it’s collected."),
        Feature("flame", "Launch a coin", "Fair-launch a memecoin paired with a tokenized stock."),
        Feature("arrow.left.arrow.right", "Swap at the best price", "Kuru, Uniswap and Monday Trade — compared on every swap."),
        Feature("chart.line.uptrend.xyaxis", "Trade perpetuals", "Perpl’s on-chain order book, signed by your own wallet."),
    ]
    // A copy of the first card is appended so the tour can slide FORWARD off the last card into it, then snap back to
    // the real first with no animation — an invisible seam, so the loop never rewinds backwards to the start.
    private var loop: [Feature] { features + [features[0]] }
    private var activeDot: Int { index % features.count }
    private let advance = Timer.publish(every: 3.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            TabView(selection: $index) {
                ForEach(loop.indices, id: \.self) { i in
                    FeatureCard(feature: loop[i]).tag(i).padding(.horizontal, 28)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(features.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == activeDot ? Color.brand : Color.secondary.opacity(0.28))
                        .frame(width: i == activeDot ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeDot)
            .accessibilityHidden(true)
        }
        .onReceive(advance) { _ in
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index += 1 }
        }
        .onChange(of: index) { _, new in
            // Once we slide onto the duplicated first card, jump back to the real first with animations off. Both show
            // the same content, so the reset is invisible and the tour keeps moving forward forever.
            guard new == loop.count - 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard index == loop.count - 1 else { return } // the user didn't swipe elsewhere in the meantime
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { index = 0 }
            }
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
                    Text("Your wallet is yours — you hold the keys.")
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

                // Also the reason a restored Privy session was ended (its wallet couldn't be set up).
                if let message = error ?? session.lastError { InlineError(message: message) }

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
            // Apple and Google always appear together (App Review 4.8), at the same size (Google's branding guidelines).
            AppleSignInButton(busy: busy == "apple") { Haptics.tap(); run("apple") { try await session.signInWithApple() } }
            GoogleSignInButton(busy: busy == "google") { run("google") { try await session.signInWithGoogle() } }
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
        session.lastError = nil // a new attempt replaces any earlier sign-in problem
        Task {
            do {
                try await work()
            } catch where isUserCancellation(error) {
                // Closing Apple's or Google's sheet is a choice, not a failure — nothing to show.
            } catch {
                self.error = describe(error)
            }
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

/// Apple's own "Continue with Apple" button (ASAuthorizationAppleIDButton), as Privy recommends for its Swift SDK: a tap
/// hands the whole Sign in with Apple ceremony to PrivySDK, which presents Apple's native sheet. Apple draws the label,
/// artwork and accessibility; the style follows the appearance (black in light mode, white in dark).
private struct AppleSignInButton: View {
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        AppleIDButton(style: dark ? .white : .black, action: action)
            .id(dark) // the style is fixed when the button is created — rebuild it when the appearance changes
            .frame(height: 50)
            .overlay {
                if busy {
                    RoundedRectangle(cornerRadius: 14, style: .circular)
                        .fill(dark ? Color.white : Color.black)
                        .overlay(ProgressView().tint(dark ? .black : .white))
                        .accessibilityLabel("Signing in with Apple")
                }
            }
    }
}

private struct AppleIDButton: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: style)
        button.cornerRadius = 14
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

/// "Continue with Google" to Google's sign-in branding guidelines: the official "G" (cropped from Google's pre-approved
/// iOS assets, one per theme), Google Sans Medium, and the Light / Dark theme fill, 1pt inside stroke and text colors.
/// Same size as the Apple button, so neither provider is more prominent.
private struct GoogleSignInButton: View {
    var busy = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 14, style: .circular)
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 12) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 20, height: 20)
                } else {
                    Image("GoogleG").resizable().frame(width: 20, height: 20)
                }
                Text("Continue with Google")
                    .font(.custom("GoogleSans-Medium", size: 17, relativeTo: .body))
                    // Scales with Dynamic Type up to the largest size that still fits the 50pt button in one line;
                    // beyond it the label would truncate (and "…" isn't in the subset font).
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(dark ? Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255)
                                  : Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255))
            .background(dark ? Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x14 / 255) : .white, in: shape)
            .overlay(shape.strokeBorder(dark ? Color(red: 0x8E / 255, green: 0x91 / 255, blue: 0x8F / 255)
                                             : Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(busy ? "Signing in with Google" : "Continue with Google")
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
/// email is a verified account matching the derived address. An account created before v2 upgrades once at log-in:
/// a new password and an email re-verify move it to a v2 wallet. If log-in finds the email's anonymous `email-pepper`
/// budget spent (anyone who knows the address can spend it), it offers the one-time code instead: its Privy token
/// opens the email's separate verified budget and log-in runs again. See `EmailWallet` (DyorKit), PasswordWallet.swift
/// and `Session`.
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
    /// Log-in found an account created before v2, bound to an empty legacy wallet. It upgrades through the reset flow
    /// (`reset` is on): a NEW password — the old one's S stays guessable offline against the public legacy address —
    /// then the OTP, then that password's v2 wallet takes over the binding.
    @State private var upgrade: Upgrade?
    /// The user confirmed a used legacy wallet (`Upgrade.used`) holds nothing they want to keep.
    @State private var movedOut = false
    /// Log-in stopped on an `EmailPepperError` (the email's anonymous budget is spent, or a proof went stale): offer
    /// the email one-time code, whose token pays from the email's verified budget.
    @State private var offerVerification = false
    /// The code step is proving the email for log-in (not for sign-up or a reset); log-in runs again once it is done.
    @State private var verifyingLogIn = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var code = ""
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password, confirm, code }

    private struct Upgrade {
        /// The legacy wallet the email is bound to (already public in `profiles`).
        let legacy: Address
        /// It has sent transactions, so it may hold what the balance check can't see (Perpl collateral, launchpad or
        /// Moment holdings): the user confirms they've moved everything out (`movedOut`).
        let used: Bool
        /// The password log-in used, refused as the new one.
        let oldPassword: String
    }

    /// Sign-up and reset share the same "set a password" form and OTP verification; only login is different.
    private var setsPassword: Bool { mode == .signUp || reset }
    private var emailValid: Bool { email.contains("@") && email.contains(".") && !email.hasSuffix(".") }
    private var rejection: String? {
        if let upgrade, password == upgrade.oldPassword { return "Choose a new password — your current one can’t be reused." }
        return PasswordStrength.rejection(password, email: email)
    }
    private var otpStage: Bool { (setsPassword || verifyingLogIn) && stage == .otp }
    private var formValid: Bool {
        guard emailValid else { return false }
        if setsPassword {
            return rejection == nil && !confirm.isEmpty && password == confirm && acknowledged && (upgrade?.used != true || movedOut)
        }
        return !password.isEmpty
    }

    var body: some View {
        Form {
            if !otpStage {
                if let upgrade {
                    Section {
                        Text("Your account was created before our email-wallet security upgrade. Choose a new password: it becomes a new wallet that can’t be guessed offline, and we’ll email a code to confirm it’s you. Your previous wallet (\(upgrade.legacy.short)) has no MON or token balance left.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Security upgrade") }
                    .listRowBackground(Color.clear)
                } else if reset {
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
                        .disabled(upgrade != nil) // the upgrade moves this email's account, found at log-in
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
                        if let upgrade, upgrade.used {
                            Toggle("I’ve moved everything I want to keep out of my previous wallet (\(upgrade.legacy.short)). Anything left there won’t be reachable in DyorHQ after the upgrade.", isOn: $movedOut)
                                .font(.footnote)
                        }
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
                        if let upgrade {
                            Text("One-time security upgrade: enter the code we emailed to \(email). Your account then moves to the new wallet your new password creates. Your previous wallet (\(upgrade.legacy.short)) stays behind, and so does its public profile.")
                        } else if verifyingLogIn {
                            Text("Enter the code we emailed to \(email). It proves the email is yours, so you can log in even while others are making attempts on it. We’ll log you in right after.")
                        } else if reset {
                            Text("Enter the code we emailed to \(email). This confirms it’s you before your new password takes over your wallet.")
                        } else {
                            Text("Enter the code we emailed to \(email). This proves the email is yours — your wallet is created after you verify, so no fake or unowned emails can register.")
                        }
                        HStack(spacing: 16) {
                            Button("Send a new code") { startSignUp() }.disabled(busy)
                            Button("Change details") { stage = .form; code = ""; verifyingLogIn = false }.disabled(busy)
                        }
                        .font(.footnote)
                    }
                }
            }

            if let error {
                Section { InlineError(message: error) }.listRowBackground(Color.clear)
            }

            if offerVerification, !otpStage {
                Section {
                    Button("Verify Email", systemImage: "envelope.badge") { startLogInVerification() }
                } footer: {
                    Text("We’ll email a one-time code to \(email). Entering it proves the email is yours, then we log you in.")
                }
            }
        }
        .navigationTitle(otpStage ? "Verify Email" : (upgrade != nil ? "Security Upgrade" : reset ? "Reset Password" : "Email & Password"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if reset, !busy { Button("Cancel") { cancelReset() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() }
                else if otpStage { Button("Verify") { completeVerification() }.disabled(code.count != 6) }
                else if mode == .logIn, !reset { Button("Log In") { logIn() }.disabled(!formValid) }
                else { Button("Continue") { startSignUp() }.disabled(!formValid) }
            }
        }
        .onAppear { focus = .email }
        // Email proofs only live for this screen's flow; they never outlast it.
        .onDisappear { let backend = env.social.client; Task { await backend.forgetEmailProofs() } }
        .onChange(of: mode) { _, _ in stage = .form; code = ""; error = nil; offerVerification = false; verifyingLogIn = false }
        .onChange(of: email) { _, _ in offerVerification = false }
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

    private func logIn() {
        focus = nil; busy = true; error = nil; offerVerification = false
        Task {
            do {
                let outcome = try await session.logInWithPassword(email: email, password: password, pepper: fetchPepper,
                                                                  verify: verifyBinding, holdsFunds: legacyHoldsFunds)
                if outcome == .signedIn { await env.social.client.forgetEmailProofs() }
                if case .needsUpgrade(let legacy) = outcome {
                    await env.social.client.signOut() // the legacy wallet's check-in session is not the user's session
                    let used: Bool
                    do { used = try await env.rpc.transactionCount(of: legacy) > 0 }
                    catch { throw SessionError.legacyBalanceUnavailable }
                    beginUpgrade(Upgrade(legacy: legacy, used: used, oldPassword: password))
                }
            } catch {
                await env.social.client.signOut() // never leave a check-in session behind a failed log-in
                // The email's anonymous budget is spent (or a proof went stale): offer the one-time code, not a wait.
                offerVerification = error is EmailPepperError
                self.error = describe(error)
            }
            busy = false
        }
    }

    /// Log-in hit `EmailPepperError`: email the one-time code (the same Privy OTP as sign-up), then the code step's
    /// token opens the email's verified budget and log-in runs again (`completeVerification`).
    private func startLogInVerification() {
        focus = nil; busy = true; error = nil
        Task {
            do {
                try await session.sendSignUpCode(to: email)
                verifyingLogIn = true; offerVerification = false; stage = .otp; code = ""; focus = .code
            } catch { self.error = describe(error) }
            busy = false
        }
    }

    // MARK: Forgot password (re-verify the email, then re-bind it to the new password's wallet)

    /// Switch the Log In form into the reset flow: same fields, but a fresh new password and a required email re-verify.
    private func beginReset() {
        reset = true; stage = .form; password = ""; confirm = ""; code = ""; acknowledged = false; error = nil; focus = .email
        offerVerification = false; verifyingLogIn = false
    }

    private func cancelReset() {
        reset = false; stage = .form; code = ""; error = nil; upgrade = nil; movedOut = false
    }

    /// The pre-v2 upgrade is a reset of this email's account onto a new password (see `upgrade`).
    private func beginUpgrade(_ found: Upgrade) {
        beginReset(); upgrade = found; movedOut = false; focus = .password
    }

    /// Verify the email OTP, then bind it to the wallet the password derives — server-side, through the `email-rebind`
    /// function. Sign-up, forgot-password and the pre-v2 upgrade all land here; only the upgrade names a legacy wallet
    /// to check first. Nothing is committed until the server re-verifies both proofs, so a failed attempt leaves any
    /// current session untouched. The OTP's Privy token also pays for this email's pepper from its verified budget,
    /// so these flows never meet the anonymous limit; a log-in that did (`verifyingLogIn`) just runs again with it.
    private func completeVerification() {
        guard code.count == 6, !busy else { return }
        focus = nil; busy = true; error = nil
        Task {
            do {
                let token = try await session.verifyEmailCapturingToken(email: email, code: code)
                // Sent only to `email-pepper` (for this email's e) and `email-rebind` — nowhere else.
                await env.social.client.rememberEmailProof(token, forEmail: email)
                if verifyingLogIn {
                    verifyingLogIn = false; stage = .form; code = ""; busy = false
                    logIn()
                    return
                }
                try await session.bindEmailPassword(email: email, password: password, token: token,
                                                    upgradingFrom: upgrade?.legacy, pepper: fetchPepper,
                                                    holdsFunds: legacyHoldsFunds, bind: bindViaServer)
                await env.social.client.forgetEmailProofs()
            } catch {
                self.error = describe(error)
                code = ""
            }
            busy = false
        }
    }

    /// Push the OTP proof (Privy token) and the wallet's signature to the `email-rebind` function, which verifies both
    /// and writes the binding with the service role. This is the ONLY path that writes the email → wallet row — direct
    /// PostgREST writes are revoked (migration 16) — so an email that wasn't OTP-verified can never be bound.
    private func bindViaServer(_ token: String, _ message: String, _ signature: String) async throws {
        struct Body: Encodable { let message: String; let signature: String }
        let body = try JSONEncoder().encode(Body(message: message, signature: signature))
        do { _ = try await env.social.client.invoke(function: "email-rebind", bearer: token, body: body) }
        catch SupabaseError.http(_, let text) { throw EmailAuthError.bindFailed(Self.serverMessage(text)) }
    }

    /// Surfaces the `{ "error": … }` reason the edge function returns (e.g. wrong code, expired) as a clean sentence.
    private static func serverMessage(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (obj["error"] as? String), !msg.isEmpty else {
            return "We couldn’t confirm that. Please try again."
        }
        let capped = msg.prefix(1).uppercased() + String(msg.dropFirst())
        return capped.hasSuffix(".") ? capped : capped + "."
    }

    // MARK: v2 derivation inputs

    /// The server pepper for (e, t) — the `email-pepper` function, called before sign-in: from the email's verified
    /// budget when this screen holds its one-time-code token (`rememberEmailProof`), else the anonymous one.
    private func fetchPepper(_ e: Data, _ t: Data) async throws -> Data {
        try await env.social.client.emailPepper(e: e, t: t)
    }

    /// Does a legacy (pre-v2) wallet hold anything? Native MON or any curated token (`Token.core`: USDC, AUSD, USDT0,
    /// WMON, …) — any non-zero balance keeps the email on it. Only ever asked about the bound legacy wallet log-in
    /// found, whose address is already public. What balances can't show (Perpl collateral, launchpad or Moment
    /// holdings) takes transactions from the wallet, which log-in turns into an explicit confirmation (`Upgrade.used`).
    private func legacyHoldsFunds(_ legacy: Address) async throws -> Bool {
        let rpc = env.rpc, multicall = env.multicall
        let calls = try Token.core.filter { !$0.isNative }.map { try ERC20.balanceOf($0.address, legacy) }
        async let native = rpc.balance(of: legacy)
        async let tokens = multicall.readAll(calls)
        let (mon, results) = try await (native, tokens)
        let balances = results.compactMap { $0.first?.uintOrNil }
        guard balances.count == calls.count else { throw SessionError.legacyBalanceUnavailable }
        return mon > 0 || balances.contains { $0 > 0 }
    }

    // MARK: Backend gate (email_accounts)

    /// Login gate: is this email bound to exactly the derived wallet? The derived wallet proves itself by signing in to
    /// the backend (wallet-auth), then reads ITS OWN binding under row-level security. There is deliberately no
    /// anonymous "does this email match this wallet" lookup — that would let anyone confirm a guessed password online.
    /// A wrong password derives a wallet with no binding: it reads nothing, the temporary session is dropped, and no
    /// profile row is created for it.
    private func verifyBinding(_ email: String, _ account: Secp256k1Account) async throws -> Bool {
        let signer = LocalWallet(account: account)
        let backend = env.social.client
        _ = try await backend.signIn(address: account.address.checksummed) { message in try await signer.signMessage(message) }
        struct Binding: Decodable { let email: String }
        let wallet = account.address.checksummed.lowercased()
        let rows: [Binding]
        do {
            rows = try await backend.read("email_accounts", query: [URLQueryItem(name: "select", value: "email"),
                                                                    URLQueryItem(name: "wallet", value: "eq.\(wallet)")], authed: true)
        } catch {
            await backend.signOut()
            throw error
        }
        let matches = rows.contains { $0.email == email }
        if !matches { await backend.signOut() } // never leave a session for a wallet that isn't the user's
        return matches
    }
}

enum EmailAuthError: LocalizedError {
    case bindFailed(String)
    var errorDescription: String? {
        switch self {
        case .bindFailed(let message): return message
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
