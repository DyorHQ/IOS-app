import DyorKit
import SwiftUI

// The settings screens reached from Profile: wallets, security (passkeys + app lock), notifications, trading
// defaults, language, and the appearance sheet. Plain grouped lists in DyorHQ's system, each doing one real thing.

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

/// Notification preferences. Delivery still needs the system permission; these choose what DyorHQ would send.
struct NotificationsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle("Enable Notifications", isOn: $settings.notificationsEnabled)
            } footer: {
                Text("Turn on to receive alerts. You can also allow or mute DyorHQ in the iOS Settings app.")
            }
            Section("Alerts") {
                Toggle("Fills & Liquidations", isOn: $settings.notifyFills)
                Toggle("Price Alerts", isOn: $settings.notifyPriceAlerts)
            }
            .disabled(!settings.notificationsEnabled)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
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
