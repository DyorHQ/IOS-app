import DyorKit
import SwiftUI

/// Copy Trading: follow Perpl perps traders and top memecoin wallets by address. The watcher turns each copied
/// trader's trade into a pending signal here; the user confirms (which hands off to Swap/Perps preloaded, to enter an
/// amount and execute) or declines. Spot and Perps are separate lists, switched by a segmented control.
struct CopyTradingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings

    @State private var venue: CopyVenue = .perps
    @State private var venueInitialized = false
    @State private var traders: [CopiedTrader] = []
    @State private var signals: [CopySignal] = []
    @State private var addressText = ""
    @State private var nicknameText = ""
    @State private var fundingToken: Token = .usdc
    @State private var marginPerTradeText = "100"
    @State private var maxLeverage = 10.0
    @State private var addError: String?
    @State private var validating = false

    private var venueTraders: [CopiedTrader] { traders.filter { $0.venue == venue }.sorted { $0.addedAt > $1.addedAt } }
    private var venueSignals: [CopySignal] { signals.filter { $0.venue == venue }.sorted { $0.detectedAt > $1.detectedAt } }

    var body: some View {
        List {
            Section {
                Picker("Market", selection: $venue) {
                    ForEach(CopyVenue.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
                .listRowBackground(Color.clear)
            } footer: {
                Text(venue.blurb)
            }

            if !venueSignals.isEmpty { pendingSection }
            addSection
            tradersSection
            howItWorks
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Copy Trading")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task(id: session.address) {
            reload()
            // Open on whichever side actually has signals waiting, so a banner tap never lands on an empty tab.
            if !venueInitialized {
                venueInitialized = true
                if let newest = signals.max(by: { $0.detectedAt < $1.detectedAt }) { venue = newest.venue }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .copySignalsChanged)) { _ in reload() }
        .refreshable { reload() }
    }

    private func reload() {
        traders = CopyStore.traders(owner: session.address)
        signals = CopyStore.signals(owner: session.address)
    }

    // MARK: Pending signals

    private var pendingSection: some View {
        Section {
            ForEach(venueSignals) { signal in
                PendingSignalRow(signal: signal, onCopy: { copy(signal) }, onDecline: { decline(signal) })
            }
        } header: {
            Label("Waiting for you", systemImage: "bell.badge")
        } footer: {
            Text("Confirm to open the trade preloaded — you set the amount before it executes. You stay in control of every copy.")
        }
    }

    private func copy(_ signal: CopySignal) {
        Haptics.tap()
        switch signal.venue {
        case .spot:
            let bought = Token(address: signal.token, symbol: signal.symbol, name: signal.symbol, decimals: signal.decimals, logoURL: signal.logo)
            let funding = traders.first { $0.id == signalTraderId(signal) }.map { Token.core($0.fundingToken) ?? .usdc } ?? .usdc
            KnownTokenStore.add(bought, owner: session.address)
            router.openSwap(tokenIn: funding, tokenOut: bought)
        case .perps:
            if let id = signal.marketId {
                let side: PositionSide? = signal.side == "short" ? .short : signal.side == "long" ? .long : nil
                router.openPerp(id: id, side: side, leverage: signal.leverage, size: signal.suggestedSize)
            }
        }
        decline(signal) // clear it from the pending list once acted on
    }

    private func decline(_ signal: CopySignal) {
        CopyStore.removeSignal(id: signal.id, owner: session.address)
        reload()
    }

    private func signalTraderId(_ signal: CopySignal) -> String { signal.venue.rawValue + ":" + signal.traderAddress.hex }

    // MARK: Add a trader

    private var addSection: some View {
        Section {
            TextField(venue == .spot ? "Paste a memecoin trader's wallet" : "Paste a Perpl trader's wallet", text: $addressText)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            TextField("Nickname (optional)", text: $nicknameText)
                .autocorrectionDisabled()
            if venue == .spot {
                Picker("Fund buys with", selection: $fundingToken) {
                    ForEach(fundingChoices) { Text($0.symbol).tag($0) }
                }
            } else {
                HStack {
                    Text("Budget per trade")
                    Spacer()
                    TextField("100", text: $marginPerTradeText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 80)
                    Text("AUSD").foregroundStyle(.secondary)
                }
                Stepper(value: $maxLeverage, in: 1...25, step: 1) {
                    LabeledContent("Max leverage", value: "\(NumberStyle.number(maxLeverage, maximumFractionDigits: 0))×")
                }
            }
            if let addError {
                Label(addError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Color.attention)
            }
            Button {
                Task { await addTrader() }
            } label: {
                HStack {
                    if validating { ProgressView().controlSize(.small) }
                    Text(validating ? "Checking…" : "Copy this trader").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.brand)
            .disabled(validating || Address(addressText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } header: {
            Label("Add a trader", systemImage: "plus.circle")
        } footer: {
            if venue == .perps {
                Text("Perpl has no public leaderboard yet, so paste any trader's address — the app reads their live positions on-chain and alerts you when they open a new one.")
            } else {
                Text("Paste the wallet of a memecoin trader. You'll be alerted whenever they buy a token, to confirm or decline copying the buy.")
            }
        }
    }

    private var fundingChoices: [Token] {
        [.usdc, .mon] + Token.core.filter { ["USDT0", "AUSD"].contains($0.symbol) }
    }

    private func addTrader() async {
        addError = nil
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = Address(trimmed) else { addError = "Enter a valid 0x wallet address."; return }
        if address == session.address { addError = "That's your own wallet."; return }
        if traders.contains(where: { $0.address == address && $0.venue == venue }) { addError = "You're already copying this trader."; return }

        validating = true
        defer { validating = false }
        // For perps, confirm the address actually has a Perpl account so the copy isn't a dead follow.
        if venue == .perps {
            let account = try? await env.perpl.account(address)
            if account == nil {
                addError = "No Perpl account found for that address."
                return
            }
        }
        let trader = CopiedTrader(
            address: address, venue: venue,
            nickname: nicknameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : nicknameText,
            fundingToken: venue == .spot ? fundingToken.address : Monad.ausd,
            marginPerTrade: max(1, min(5000, Double(marginPerTradeText) ?? 100)),
            maxLeverage: maxLeverage
        )
        CopyStore.upsert(trader, owner: session.address)
        Haptics.success()
        addressText = ""; nicknameText = ""
        // Turn on copy notifications the first time someone copies a trader.
        if !settings.notifyCopyTrades { settings.notifyCopyTrades = true }
        if !settings.notificationsEnabled { settings.notificationsEnabled = true }
        _ = await Notifications.requestAuthorization()
        reload()
    }

    // MARK: Copied traders

    @ViewBuilder private var tradersSection: some View {
        Section {
            if venueTraders.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No \(venue.label.lowercased()) traders yet").font(.subheadline.weight(.medium))
                    Text("Add a wallet above to start copying.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(venueTraders) { trader in
                    CopiedTraderRow(
                        trader: trader,
                        onToggle: { toggle(trader) },
                        onRemove: { remove(trader) }
                    )
                }
            }
        } header: {
            Text(venue == .spot ? "Copied memecoin traders" : "Copied Perpl traders")
        }
    }

    private func toggle(_ trader: CopiedTrader) {
        var updated = trader
        updated.enabled.toggle()
        if updated.enabled {
            // Re-baseline on re-enable so we don't replay trades the trader made while copying was paused.
            updated.lastBlock = 0
            updated.perpsBaselined = false
            updated.seenPositions = []
        }
        CopyStore.upsert(updated, owner: session.address)
        Haptics.selection()
        reload()
    }

    private func remove(_ trader: CopiedTrader) {
        CopyStore.remove(id: trader.id, owner: session.address)
        Haptics.tap()
        reload()
    }

    private var howItWorks: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                StepRow(number: 1, text: "Add a trader's wallet to copy their \(venue.label.lowercased()) moves.")
                StepRow(number: 2, text: venue == .spot ? "We watch their on-chain buys and alert you on each one." : "We read their live Perpl positions and alert you on new opens.")
                StepRow(number: 3, text: "Confirm to open the trade preloaded, set your amount, and execute — or decline.")
            }
            .padding(.vertical, 2)
        } header: {
            Text("How copy trading works")
        }
    }
}

// MARK: - Rows

private struct PendingSignalRow: View {
    let signal: CopySignal
    let onCopy: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                if signal.venue == .spot {
                    Avatar(url: signal.logo, initials: String(signal.symbol.prefix(2)).uppercased(), size: 38)
                } else {
                    Image(systemName: (signal.side == "short") ? "arrow.down.right" : "arrow.up.right")
                        .font(.headline).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background((signal.side == "short") ? Color.negative : Color.positive, in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(signal.action).font(.subheadline.weight(.semibold))
                    Text("\(signal.traderName) · \(RelativeTime.short(signal.detectedAt)) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button(action: onDecline) { Text("Decline").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.secondary)
                Button(action: onCopy) { Text("Copy").fontWeight(.semibold).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.brand)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CopiedTraderRow: View {
    let trader: CopiedTrader
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: nil, initials: String(trader.displayName.prefix(2)).uppercased(), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(trader.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(trader.address.short).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { trader.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(Color.brand)
                .frame(width: 22, height: 22).background(Color.brand.opacity(0.14), in: Circle())
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
