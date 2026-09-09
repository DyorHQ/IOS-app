import BigInt
import CoreImage.CIFilterBuiltins
import DyorKit
import SwiftUI

/// The account hub: who is signed in, the wallet actions, and every setting — wallets, security (passkeys and
/// two-factor), notifications, appearance, language, support — then sign out. Modeled on a settings screen: a
/// grouped list with a symbol per row, in DyorHQ's system.
struct ProfileView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(SocialSession.self) private var social
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showAppearance = false
    @State private var confirmSignOut = false
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            List {
                if let account = session.account { header(account) }

                Section {
                    Button { showReceive = true } label: { SettingsRow("Receive", symbol: "qrcode", tint: .accent) }
                    Button { showSend = true } label: { SettingsRow("Send", symbol: "paperplane", tint: .accent) }
                        .disabled(!session.canSign)
                    if let address = session.address {
                        Link(destination: Monad.explorerAddress(address)) { SettingsRow("Activity on Monadscan", symbol: "clock.arrow.circlepath", tint: .accent) }
                    }
                } header: {
                    Text("Wallet")
                } footer: {
                    if !session.canSign { Text("Sign in to send from this address.") }
                }

                Section("Settings") {
                    NavigationLink { SocialProfileView() } label: {
                        HStack {
                            SettingsRow("DyorHQ Social", symbol: "person.2.circle", tint: .accent)
                            Spacer()
                            if social.isSignedIn { Text(social.profile?.handle.map { "@\($0)" } ?? "Connected").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink { ManageWalletsView() } label: { SettingsRow("Manage Wallets", symbol: "wallet.bifold", tint: .accent) }
                    NavigationLink { SecurityView() } label: { SettingsRow("Security", symbol: "lock.shield", tint: .accent) }
                    NavigationLink { NotificationsView() } label: { SettingsRow("Notifications", symbol: "bell.badge", tint: .accent) }
                    Button { showAppearance = true } label: {
                        HStack {
                            SettingsRow("Appearance", symbol: "paintbrush", tint: .accent)
                            Spacer()
                            Text(settings.appearance.label).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { TradingPreferencesView() } label: { SettingsRow("Trading Preferences", symbol: "slider.horizontal.3", tint: .accent) }
                    NavigationLink { PerplTradingView() } label: {
                        HStack {
                            SettingsRow("Perpl Trading", symbol: "bolt.horizontal", tint: .accent)
                            Spacer()
                            if perplTrading.isReady { Text("Connected").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink { LanguageView() } label: {
                        HStack { SettingsRow("Language", symbol: "globe", tint: .accent); Spacer(); Text("English").foregroundStyle(.secondary) }
                    }
                    Link(destination: URL(string: "https://dyorhq.xyz/support")!) { SettingsRow("Support", symbol: "questionmark.circle", tint: .accent) }
                    Link(destination: URL(string: "https://dyorhq.xyz/terms")!) { SettingsRow("Terms of Use", symbol: "doc.text", tint: .accent) }
                }

                Section("Network") {
                    LabeledContent("Chain", value: "Monad mainnet")
                    LabeledContent("RPC", value: env.config.rpcURL.host() ?? env.config.rpcURL.absoluteString)
                }

                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label(session.canSign ? "Sign Out" : "Stop Watching", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(signingOut)
                } footer: {
                    Text("DyorHQ \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · Self-custodial. Keys never leave your device.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .foregroundStyle(.primary)
            .sheet(isPresented: $showReceive) { if let address = session.address { ReceiveSheet(address: address) } }
            .sheet(isPresented: $showSend) { SendSheet() }
            .sheet(isPresented: $showAppearance) { AppearanceSheet() }
            .confirmationDialog(session.canSign ? "Sign out of DyorHQ?" : "Stop watching this address?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(session.canSign ? "Sign Out" : "Stop Watching", role: .destructive) {
                    signingOut = true
                    Task { await session.signOut(); signingOut = false }
                }
            } message: {
                Text(session.canSign ? "Your wallet stays with your account. Sign in again to use it." : "Balances and positions for this address will no longer be shown.")
            }
        }
    }

    private func header(_ account: Session.Account) -> some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color(.tertiarySystemFill)).frame(width: 56, height: 56)
                    Image(systemName: account.method == .watchOnly ? "eye" : "person.fill").font(.title2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label ?? account.address.short).font(.title3.weight(.semibold))
                    Text(account.method == .watchOnly ? "Watching this address" : "Signed in with \(account.method.title)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            AddressRow(title: "Address", address: account.address)
        }
    }
}

/// A settings row: a symbol in the accent tint, then the title. Matches Apple's own settings rows.
struct SettingsRow: View {
    let title: String
    let symbol: String
    var tint: Color = .accent

    init(_ title: String, symbol: String, tint: Color = .accent) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

struct ReceiveSheet: View {
    let address: Address
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = QRCode.image(for: address.checksummed) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("QR code of your address")
                }
                VStack(spacing: 8) {
                    Text(address.checksummed)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text("Send MON or any Monad token to this address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                HStack(spacing: 12) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = address.checksummed
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: address.checksummed) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sensoryFeedback(.success, trigger: copied)
        }
        .presentationDetents([.large])
    }
}

/// Send MON or an ERC-20 to another address.
struct SendSheet: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var token: Token = .mon
    @State private var recipient = ""
    @State private var amount = ""
    @State private var balance: BigUInt?
    @State private var showConfirm = false

    private var recipientAddress: Address? { Address(recipient) }
    private var rawAmount: BigUInt? { Amount.parse(amount, decimals: token.decimals) }
    private var valid: Bool {
        guard let recipientAddress, !recipientAddress.isZero, let rawAmount, rawAmount > 0 else { return false }
        if let balance { return rawAmount <= balance }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    TextField("Address", text: $recipient)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste", systemImage: "doc.on.clipboard") { recipient = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? recipient }
                }
                Section {
                    Picker("Token", selection: $token) {
                        ForEach(Token.core.filter { !$0.symbol.hasPrefix("W") || $0.symbol == "WETH" }) { Text($0.symbol).tag($0) }
                    }
                    AmountField(title: "Amount", text: $amount, token: token) {
                        if let balance { amount = Amount.exact(balance, decimals: token.decimals) }
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    if let balance { Text("Available: \(NumberStyle.units(balance, decimals: token.decimals)) \(token.symbol)") }
                    if !recipient.isEmpty, recipientAddress == nil { Text("Enter a 42-character address starting with 0x.") }
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(!valid) }
            }
            .task(id: token) {
                guard let address = session.address else { return }
                balance = try? await ERC20.balances(of: [token], owner: address, rpc: env.rpc, multicall: env.multicall)[token.address]
            }
            .sheet(isPresented: $showConfirm) {
                if let to = recipientAddress, let raw = rawAmount {
                    ConfirmationSheet(title: "Send \(token.symbol)", confirmTitle: "Send", build: { [.call(transfer(to: to, amount: raw), label: "Send \(token.symbol)")] }, onDone: { dismiss() }) {
                        DetailRow("To", to.short)
                        DetailRow("Amount", "\(NumberStyle.units(raw, decimals: token.decimals)) \(token.symbol)")
                        DetailRow("Network", "Monad")
                    }
                }
            }
        }
    }

    private func transfer(to: Address, amount: BigUInt) -> TransactionRequest {
        if token.isNative { return TransactionRequest(to: to, value: amount) }
        return TransactionRequest(to: token.address, data: (try? ERC20.transferCalldata(to: to, amount: amount)) ?? Data())
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
