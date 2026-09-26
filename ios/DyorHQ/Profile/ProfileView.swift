import BigInt
import CoreImage.CIFilterBuiltins
import DyorKit
import SwiftUI

/// The account hub: who is signed in, the wallet actions, and every setting — wallets, security (passkeys and
/// two-factor), notifications, appearance, language, support — then sign out. Modeled on a settings screen: a
/// grouped list with a symbol per row, in DyorHQ's system.
struct ProfileView: View {
    /// True when opened as a full-screen page from the home header or the menu (adds a Close control).
    var presented = false
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(SocialSession.self) private var social
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showAppearance = false
    @State private var confirmSignOut = false
    @State private var confirmForget = false
    @State private var signingOut = false
    @State private var showDeleteAccount = false

    /// Sign-out removes the signing key from this device, so say what that means for each kind of wallet: an imported
    /// key exists nowhere else unless the user saved it, so it must never read as "your wallet stays with your account".
    private var signOutMessage: String {
        switch session.account?.method {
        case .watchOnly?, nil:
            return "Balances and positions for this address will no longer be shown."
        case .imported?:
            return "This removes the imported key from this iPhone. You'll need its recovery phrase or private key to use this wallet again — export it first (Manage Wallets → Export Wallet) if you haven't saved it."
        case .emailPassword?:
            return "Sign in again with your email and password to use this wallet."
        default:
            return "Your wallet stays with your account. Sign in again to use it."
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let account = session.account { header(account) }

                Section {
                    Button { showReceive = true } label: { SettingsRow("Receive", symbol: "qrcode", tint: .accent) }
                    Button { showSend = true } label: { SettingsRow("Send", symbol: "paperplane", tint: .accent) }
                        .disabled(!session.canSign)
                    NavigationLink { RecentActivityView() } label: { SettingsRow("Recent Activity", symbol: "clock.arrow.circlepath", tint: .accent) }
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
                    NavigationLink {
                        ScrollView { GetHelpContent().padding(16) }
                            .background(Color(.systemGroupedBackground))
                            .navigationTitle("Support")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: { SettingsRow("Support", symbol: "questionmark.circle", tint: .accent) }
                    Link(destination: SupportLinks.terms) { SettingsRow("Terms of Use", symbol: "doc.text", tint: .accent) }
                }

                Section("Network") {
                    LabeledContent("Chain", value: "Monad mainnet")
                    LabeledContent("RPC", value: env.config.rpcURL.host() ?? env.config.rpcURL.absoluteString)
                }

                // A passkey account keeps nothing on the device that the passkey can't bring back, so signing out of one
                // is forgetting this device: the whole local copy is erased (`AccountDeletion.eraseThisDevice`), and the
                // passkey provider is never told anything — the passkey is the account (MERA-PLAN §6).
                if session.isPasskeyAccount {
                    Section {
                        Button(role: .destructive) { confirmForget = true } label: {
                            Label("Forget This Device", systemImage: "iphone.slash")
                        }
                        .disabled(signingOut)
                    } footer: {
                        Text("Removes this account from this iPhone. Your passkey keeps it — sign in again anytime.")
                    }
                }

                Section {
                    if !session.isPasskeyAccount {
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            Label(session.canSign ? "Sign Out" : "Stop Watching", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(signingOut)
                    }
                    Button(role: .destructive) { showDeleteAccount = true } label: {
                        Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .disabled(signingOut)
                } footer: {
                    Text("DyorHQ \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · \(SupportLinks.tagline) · Self-custodial.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(presented ? .inline : .large)
            .foregroundStyle(.primary)
            .toolbar {
                if presented {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Haptics.tap(); dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }.accessibilityLabel("Close")
                    }
                }
            }
            .sheet(isPresented: $showReceive) { if let address = session.address { ReceiveSheet(address: address) } }
            .sheet(isPresented: $showSend) { SendSheet() }
            .sheet(isPresented: $showAppearance) { AppearanceSheet() }
            .sheet(isPresented: $showDeleteAccount) { DeleteAccountView() }
            .confirmationDialog(session.canSign ? "Sign out of DyorHQ?" : "Stop watching this address?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(session.canSign ? "Sign Out" : "Stop Watching", role: .destructive) {
                    signingOut = true
                    let address = session.address
                    Task { @MainActor in
                        // The Perpl trading key on this device is a delegate for this wallet: it goes with the session.
                        if let address { perplTrading.forget(address: address) }
                        await session.signOut()
                        signingOut = false
                    }
                }
            } message: {
                Text(signOutMessage)
            }
            .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget This Device", role: .destructive) {
                    guard let address = session.address else { return }
                    signingOut = true
                    Task {
                        await AccountDeletion.eraseThisDevice(address: address, session: session, social: social, env: env)
                        signingOut = false
                    }
                }
            } message: {
                Text("This iPhone's copy of the account is erased. Your passkey keeps the account and its funds; sign in with it again anytime.")
            }
        }
    }

    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func initials(_ account: Session.Account) -> String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? account.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    private func header(_ account: Session.Account) -> some View {
        Section {
            HStack(spacing: 14) {
                if account.method == .watchOnly {
                    ZStack {
                        Circle().fill(Color(.tertiarySystemFill)).frame(width: 56, height: 56)
                        Image(systemName: "eye").font(.title2).foregroundStyle(.secondary)
                    }
                } else {
                    Avatar(url: avatarURL, initials: initials(account), size: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(social.profile?.display_name ?? account.label ?? account.address.short).font(.title3.weight(.semibold))
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
    /// What the review shows and signs, frozen when Review is tapped (RT-7): a Max that lands late or an edit behind
    /// the sheet can't change the amount signed after it was shown.
    @State private var review: SendReview?
    /// The pasted text hidden characters were removed from (GR-4), while it is still what the field holds.
    @State private var cleanedPaste: String?
    /// Whether the recipient has contract code (GR-3): nil until read, or when it couldn't be read.
    @State private var recipientIsContract: Bool?
    @State private var recipientCheckFailed = false
    /// Sending to a contract (or to an address that couldn't be checked) takes this acknowledgement.
    @State private var sendToContract = false

    /// What was typed or pasted, without surrounding whitespace or invisible characters (GR-4).
    private var recipientText: String { Address.cleanedInput(recipient).text }
    /// Nil for a mixed-case address whose EIP-55 checksum is wrong: a mistyped character must never become the recipient.
    private var recipientAddress: Address? { Address.inputProblem(recipientText) == nil ? Address(recipientText) : nil }
    private var rawAmount: BigUInt? { Amount.parse(amount, decimals: token.decimals) }

    /// Why this can't be sent, in words: nil when it can. Nothing is said about a field still empty.
    private var problem: String? {
        if let issue = Address.inputProblem(recipientText) { return issue }
        if let to = recipientAddress {
            if to.isZero { return "That's the zero address: anything sent there is lost for good." }
            // Tokens sent to their own contract are stuck there: almost no token can send them back (GR-3).
            if !token.isNative, to == token.address { return "That's the \(token.symbol) token contract itself. Tokens sent to it are almost always lost for good." }
        }
        if let rawAmount, let balance, rawAmount > balance {
            return "More than your \(NumberStyle.units(balance, decimals: token.decimals)) \(token.symbol)."
        }
        return nil
    }

    /// A contract recipient, or one whose code couldn't be read, needs the acknowledgement.
    private var needsContractAcknowledgement: Bool { recipientIsContract == true || recipientCheckFailed }

    private var valid: Bool {
        guard problem == nil, let recipientAddress, !recipientAddress.isZero, let rawAmount, rawAmount > 0 else { return false }
        guard recipientIsContract != nil || recipientCheckFailed else { return false } // still checking
        return !needsContractAcknowledgement || sendToContract
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $recipient)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        guard let pasted = UIPasteboard.general.string else { return }
                        let cleaned = Address.cleanedInput(pasted)
                        recipient = cleaned.text
                        cleanedPaste = cleaned.removedInvisible ? cleaned.text : nil
                    }
                    if needsContractAcknowledgement {
                        Toggle(recipientIsContract == true ? "Send to this contract anyway" : "Send without that check", isOn: $sendToContract)
                            .tint(Color.attention)
                    }
                } header: {
                    Text("To")
                } footer: {
                    if let cleanedPaste, cleanedPaste == recipient { Text("Hidden characters were removed from the pasted address. Check it matches the source.") }
                    if let to = recipientAddress, to == session.address { Text("That's your own address.") }
                    if recipientIsContract == true {
                        Text("This address is a contract, not a wallet. Most contracts can't send tokens back, so funds sent to the wrong one are lost. Send only if you know this contract accepts \(token.symbol).")
                    } else if recipientCheckFailed {
                        Text("Couldn't check whether this address is a contract. Check it before sending.")
                    }
                }
                Section {
                    Picker("Token", selection: $token) {
                        ForEach(Token.core.filter { !$0.symbol.hasPrefix("W") || $0.symbol == "WETH" }) { Text($0.symbol).tag($0) }
                    }
                    AmountField(title: "Amount", text: $amount, token: token) { useMax() }
                } header: {
                    Text("Amount")
                } footer: {
                    if let problem { Text(problem).foregroundStyle(Color.attention) }
                    else if let balance { Text("Available: \(NumberStyle.units(balance, decimals: token.decimals)) \(token.symbol)") }
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        guard let to = recipientAddress, let raw = rawAmount else { return }
                        review = SendReview(token: token, to: to, amount: raw, toContract: recipientIsContract == true)
                    }
                    .disabled(!valid)
                }
            }
            .task(id: token) {
                guard let address = session.address else { return }
                balance = try? await ERC20.balances(of: [token], owner: address, rpc: env.rpc, multicall: env.multicall)[token.address]
            }
            .task(id: recipientAddress) { await checkRecipient() }
            .sheet(item: $review) { review in
                ConfirmationSheet(title: "Send \(review.token.symbol)", confirmTitle: "Send", build: { [.call(review.request, label: "Send \(review.token.symbol)")] }, onDone: { dismiss() },
                                  onCompleted: { hash in
                    // A send out of the wallet is a withdrawal in the journey. USD is exact for the USD stables the
                    // send picker offers; left unknown otherwise rather than guessed.
                    let stable = ["USDC", "USDT0", "USDT", "AUSD", "USDe", "USD1", "mUSD"].contains(review.token.symbol)
                    Activity.record(ActivityRecord(kind: .withdraw, title: "Sent \(review.token.symbol)",
                        subtitle: "\(NumberStyle.units(review.amount, decimals: review.token.decimals)) \(review.token.symbol) → \(review.to.short)",
                        hash: hash, section: "wallet", usd: stable ? Amount.units(review.amount, decimals: review.token.decimals) : nil), owner: session.address)
                }, intent: .alwaysAsks(.send)) {
                    DetailRow("To", review.to.checksummed) // in full: this review is the last check before funds leave
                    if review.toContract { DetailRow("Recipient", "A contract, not a wallet", tint: .attention) }
                    DetailRow("Amount", "\(NumberStyle.units(review.amount, decimals: review.token.decimals)) \(review.token.symbol)")
                    DetailRow("Network", "Monad")
                }
            }
        }
    }

    /// Reads whether the recipient has code. An EIP-7702-delegated account (Monad accounts can carry a `0xef0100`
    /// delegation) is still a wallet its key controls, so only other code counts as a contract.
    private func checkRecipient() async {
        recipientIsContract = nil
        recipientCheckFailed = false
        sendToContract = false
        guard let to = recipientAddress, !to.isZero else { return }
        do {
            let code = try await env.rpc.code(at: to)
            guard to == recipientAddress else { return }
            recipientIsContract = !code.isEmpty && !(code.count == 23 && code.prefix(3) == Data([0xef, 0x01, 0x00]))
        } catch {
            guard !Task.isCancelled, to == recipientAddress else { return }
            recipientCheckFailed = true
        }
    }

    /// The whole balance; for MON, less the send's network fee (MERA-PLAN §5), estimated for the recipient once one is
    /// entered.
    private func useMax() {
        guard let balance else { return }
        guard token.isNative else { amount = Amount.exact(balance, decimals: token.decimals); return }
        let native = token
        let like = recipientAddress.map { TransactionRequest(to: $0, value: 1) }
        Task {
            let max = await env.sender.maxValue(balance: balance, like: like, from: session.address, budget: NetworkFeeReserve.transferGasLimit)
            // The token or balance changed, or the review opened, while the fee was read: that Max no longer applies.
            guard token == native, self.balance == balance, review == nil else { return }
            amount = Amount.exact(max, decimals: native.decimals)
        }
    }
}

/// A send as the review sheet shows and signs it, frozen when Review is tapped.
private struct SendReview: Identifiable {
    let id = UUID()
    let token: Token
    let to: Address
    let amount: BigUInt
    var toContract = false

    init(token: Token, to: Address, amount: BigUInt, toContract: Bool = false) {
        self.token = token
        self.to = to
        self.amount = amount
        self.toContract = toContract
    }

    var request: TransactionRequest {
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
