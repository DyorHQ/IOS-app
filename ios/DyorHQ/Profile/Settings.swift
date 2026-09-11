import DyorKit
import SwiftUI

// The settings screens reached from Profile: wallets, security (passkeys + app lock), notifications, trading
// defaults, language, and the appearance sheet. Plain grouped lists in DyorHQ's system, each doing one real thing.

/// Perpl web links. New users open a Perpl account on the web app first (the on-chain Exchange needs an account
/// before it will report positions or accept the authenticated trading enrollment); this carries the DyorHQ referral.
enum PerplLinks {
    static let signup = URL(string: "https://app.perpl.xyz/trade?ref=H3ehW3FCqoj")!
}

/// Manage the signed-in wallet: its address, how it is secured, and the network it is on.
struct ManageWalletsView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            if let account = session.account {
                Section {
                    AddressRow(title: "Address", address: account.address)
                    LabeledContent("Sign-in", value: account.method.title)
                    if let label = account.label { LabeledContent("Account", value: label) }
                } header: {
                    Text("This Wallet")
                } footer: {
                    Text(account.method == .watchOnly
                         ? "You are watching this address. Sign in to create a wallet you can sign with."
                         : "This wallet was created on this device and is secured by your \(account.method.title) account. DyorHQ never holds your keys.")
                }

                Section {
                    Link(destination: Monad.explorerAddress(account.address)) { Label("View on Monadscan", systemImage: "safari") }
                    Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = account.address.checksummed }
                }

                if account.method == .watchOnly {
                    Section {
                        NavigationLink { ImportWalletView() } label: { Label("Import an Existing Wallet", systemImage: "square.and.arrow.down") }
                    } footer: {
                        Text("Bring in your own wallet (MetaMask, Rabby, OKX…) with its recovery phrase or private key to trade. The key is stored only on this device.")
                    }
                }
            }
            Section("Network") {
                LabeledContent("Chain", value: "Monad mainnet")
                LabeledContent("Chain ID", value: "143")
                LabeledContent("RPC", value: env.config.rpcURL.host() ?? "—")
            }
        }
        .navigationTitle("Manage Wallets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Passkeys and the biometric app lock — the second factors a self-custodial wallet can offer.
struct SecurityView: View {
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                if session.hasPasskeys {
                    Button {
                        busy = true; message = nil
                        Task {
                            do { try await session.createPasskey(displayName: "DyorHQ"); message = "Passkey added."; isError = false }
                            catch { message = describe(error); isError = true }
                            busy = false
                        }
                    } label: {
                        HStack {
                            Label("Add a Passkey", systemImage: "person.badge.key")
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(busy || !session.canSign)
                } else {
                    Label("Passkeys are not enabled in this build.", systemImage: "key.slash").foregroundStyle(.secondary).font(.subheadline)
                }
            } header: {
                Text("Passkeys")
            } footer: {
                if let message { Text(message).foregroundStyle(isError ? Color.attention : Color.positive) }
                else { Text("A passkey signs you in with Face ID or Touch ID and is phishing-resistant — a strong second factor. Add one per device.") }
            }

            Section {
                if BiometricGate.isAvailable {
                    Toggle("Require \(BiometricGate.typeName)", isOn: $settings.requireBiometrics)
                } else {
                    Label("No biometrics enrolled on this device.", systemImage: "faceid").foregroundStyle(.secondary).font(.subheadline)
                }
            } header: {
                Text("App Lock")
            } footer: {
                Text("When on, \(BiometricGate.typeName) is required before every transaction is signed — a second factor that stays on your device.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Notification preferences. Turning them on requests the system permission; local notifications then fire on swap
/// and perp-order completion and when a price alert triggers.
struct NotificationsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var denied = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle("Enable Notifications", isOn: $settings.notificationsEnabled)
            } footer: {
                if denied { Text("Notifications are turned off for DyorHQ in iOS Settings. Enable them there to receive alerts.").foregroundStyle(Color.attention) }
                else { Text("Get notified when a swap or perp order completes, or when a price alert triggers.") }
            }
            Section {
                Toggle("Swaps & Fills", isOn: $settings.notifyFills)
                Toggle("Price Alerts", isOn: $settings.notifyPriceAlerts)
                Toggle("Copy Trade Signals", isOn: $settings.notifyCopyTrades)
                NavigationLink { PriceAlertsView() } label: {
                    HStack {
                        Label("Manage Price Alerts", systemImage: "bell.badge")
                        Spacer()
                        Text("\(PriceAlertStore.all().count)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("“Swaps & Fills” notifies you when a spot swap or a perps order completes. Price alerts notify you when a token crosses a price you set. Copy trade signals alert you when a trader you copy makes a move.")
            }
            .disabled(!settings.notificationsEnabled)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { denied = await Notifications.authorizationStatus() == .denied }
        .onChange(of: settings.notificationsEnabled) { _, on in
            guard on else { return }
            Task {
                let granted = await Notifications.requestAuthorization()
                denied = !granted
                if !granted { settings.notificationsEnabled = false }
            }
        }
    }
}

/// Defaults the trade tickets open with.
struct TradingPreferencesView: View {
    @Environment(AppSettings.self) private var settings

    private let slippageChoices: [(Int, String)] = [(10, "0.1%"), (50, "0.5%"), (100, "1%"), (200, "2%")]

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Stepper(value: $settings.defaultLeverage, in: 1...50, step: 1) {
                    LabeledContent("Default Leverage", value: "\(Int(settings.defaultLeverage))×")
                }
            } footer: {
                Text("The leverage a new perps order opens on. Each market still caps it to its own maximum.")
            }
            Section {
                Picker("Max Slippage", selection: $settings.slippageBps) {
                    ForEach(slippageChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
            } footer: {
                Text("The furthest a market order or swap may move from its quote before it is cancelled.")
            }
        }
        .navigationTitle("Trading Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Connect to Perpl's authenticated trading API (the route to real TP/SL). One-time enrollment signs a payload
/// with the wallet; the Ed25519 key lives in the Keychain.
struct PerplTradingView: View {
    @Environment(PerplTrading.self) private var trading
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Status") { statusLabel }
                if trading.key != nil {
                    LabeledContent("Signed in") { checkmark(trading.isSignedIn) }
                    LabeledContent("One-click trading") { checkmark(trading.isForwarding) }
                }
            } footer: {
                Text("Perpl's trading connection lets you place market, limit, and take-profit / stop-loss orders. Your Ed25519 key is generated on this device and authorized once by your wallet — it never leaves the device.")
            }

            Section {
                Link(destination: PerplLinks.signup) {
                    HStack {
                        Label("Create a Perpl Account", systemImage: "arrow.up.forward.square")
                        Spacer()
                        Image(systemName: "safari").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("New to Perpl?")
            } footer: {
                Text("Open a Perpl account on the web first — your wallet needs one before it can enroll trading or hold a position. Opens app.perpl.xyz; come back and connect here afterwards.")
            }

            Section {
                switch trading.status {
                case .notEnrolled:
                    Button("Connect Perpl Trading") { run { try await enroll() } }
                        .disabled(busy || !session.canSign)
                case .enrolled:
                    Button("Reconnect") { run { try await trading.connect() } }.disabled(busy)
                case .connecting:
                    HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                case .needsForwarding:
                    Button("Enable One-Click Trading") { run { try await enableForwarding() } }.disabled(busy)
                case .connected:
                    Label("Ready to trade", systemImage: "checkmark.seal.fill").foregroundStyle(Color.positive)
                    Button("Disconnect") { trading.disconnect() }.disabled(busy)
                case .failed:
                    Button("Try Again") { run { try await trading.connect() } }.disabled(busy)
                }
            } header: {
                Text("Connection")
            } footer: {
                if let error { InlineError(message: error) }
                // A drop that happened outside a tap (idle timeout, rejected key, connection cap) is only on `status`.
                else if case .failed(let why) = trading.status { InlineError(message: why) }
                else if trading.status == .needsForwarding { Text("One-click trading lets Perpl's keeper forward your signed orders and fire triggers. It is a single on-chain transaction from your wallet.") }
            }

            if trading.key != nil {
                Section {
                    Button("Remove API Key", role: .destructive) { if let address = session.address { trading.forget(address: address) } }.disabled(busy)
                } footer: {
                    Text("Deletes the key from this device. You can reconnect any time; revoke it fully in Perpl's web app.")
                }
            }
        }
        .navigationTitle("Perpl Trading")
        .navigationBarTitleDisplayMode(.inline)
        .task { trading.refresh(address: session.address) }
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(on ? Color.positive : Color.secondary)
    }

    @ViewBuilder private var statusLabel: some View {
        switch trading.status {
        case .notEnrolled: Text("Not connected").foregroundStyle(.secondary)
        case .enrolled: Text("Enrolled").foregroundStyle(.secondary)
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .needsForwarding: Text("Enable one-click").foregroundStyle(Color.attention)
        case .connected: Text("Ready").foregroundStyle(Color.positive)
        case .failed: Text("Error").foregroundStyle(Color.attention)
        }
    }

    private func enroll() async throws {
        guard let wallet = session.wallet as? DigestSigner, let address = session.address else { throw SessionError.readOnly }
        try await trading.enroll(wallet: wallet, address: address)
    }

    private func enableForwarding() async throws {
        guard let wallet = session.wallet else { throw SessionError.readOnly }
        try await trading.enableForwarding(env: env, wallet: wallet)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { do { try await work() } catch { self.error = describe(error) }; busy = false }
    }
}

struct LanguageView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Language", value: "English")
            } footer: {
                Text("DyorHQ follows your device language. More languages are coming.")
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The appearance sheet: System / Light / Dark, applied live, plus what the trading colors mean.
struct AppearanceSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button { settings.appearance = mode } label: {
                            VStack(spacing: 10) {
                                Image(systemName: mode.symbol).font(.title2)
                                Text(mode.label).font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(settings.appearance == mode ? Color.accentColor : Color.clear, lineWidth: 2)
                            }
                        }
                        .foregroundStyle(settings.appearance == mode ? Color.primary : Color.secondary)
                    }
                }

                HStack(spacing: 12) {
                    swatch(.positive, "Long / Up")
                    swatch(.negative, "Short / Down")
                }
                .padding(.top, 4)

                Spacer()
            }
            .padding(20)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.height(300)])
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label).font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
