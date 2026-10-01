import BigInt
import Charts
import DyorKit
import SwiftUI

/// Perpetuals on Perpl, as a single-screen trading app: the Trade screen renders the ticket, live book, chart and
/// positions for the currently-selected market, and the market header's chevron swaps markets in place through a
/// Select Perpetual sheet — no drilling into a list. Account, positions, open orders and markets are all read from
/// the Exchange contract; deposit/withdraw and the portfolio live in the header's ⋯ menu.
struct PerpsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = PerpsModel()
    @State private var selectedId: Int?

    /// The market to trade: the explicit selection, else the deep-linked one, else BTC, else the first listed.
    private var currentMarket: PerpMarket? {
        if let selectedId, let m = model.markets.first(where: { $0.id == selectedId }) { return m }
        return model.markets.first { $0.asset == "BTC" } ?? model.markets.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let market = currentMarket {
                    PerpTradeView(market: market, model: model, onSelectMarket: { id in
                        withAnimation(.easeInOut(duration: 0.15)) { selectedId = id }
                    })
                    .id(market.id)   // reset the ticket/feed cleanly when the market changes
                } else if model.loading {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No Markets", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Perpl's markets couldn't be loaded. DyorHQ keeps retrying every few seconds.")
                    } actions: {
                        Button("Try Again") { Haptics.tap(); Task { await model.load(env: env, address: session.address) } }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TradeModeSwitcher() }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            .onChange(of: router.pendingPerpMarket) { _, id in
                if let id { selectedId = id; router.pendingPerpMarket = nil }
            }
            // Fallback for when this view is created *after* the deep link is set — e.g. opening a perp from Home
            // while the Trade tab is in Swap mode, which builds PerpsView fresh with pendingPerpMarket already set,
            // so `.onChange` never fires.
            .onAppear {
                if let id = router.pendingPerpMarket { selectedId = id; router.pendingPerpMarket = nil }
            }
        }
    }
}

enum PerpsSheet: Identifiable { case deposit, withdraw; var id: Self { self } }

@Observable
@MainActor
final class PerpsModel {
    private(set) var markets: [PerpMarket] = []
    private(set) var context: [Int: MarketContext] = [:]
    private(set) var account: PerpAccount?
    private(set) var positions: [PerpPosition] = []
    private(set) var orders: [PerpOrder] = []
    /// App-placed TP/SL the user set, reconciled against open positions/orders each poll (Perpl has no read-back API).
    private(set) var triggers: [PlacedTrigger] = []
    private(set) var collateral: (wallet: BigUInt, allowance: BigUInt) = (0, 0)
    private(set) var loading = false
    private(set) var error: String?
    var closing: PerpPosition?
    var cancelling: PerpOrder?
    private var perpl: PerplService?

    /// Fill detection: increments whenever an open order fills (a position appears or grows between polls), with
    /// `lastFilledPerpId` naming the market so the trade screen can jump to Positions. Position size is in base
    /// contracts — it moves only on fills and closes, never with the mark — so a size increase is an unambiguous
    /// fill signal that never fires on a cancel or a price move.
    private(set) var fillSignal = 0
    private(set) var lastFilledPerpId: Int?
    private var lastPositionSize: [Int: Double] = [:]
    private var fillPrimed = false
    /// The positions at the last good read, and the markets that had a resting reduce-only (close) order then — to
    /// tell a position that closed from one that is merely missing from a failed read.
    private var lastPositions: [Int: PerpPosition] = [:]
    private var restingCloseMarkets: Set<Int> = []
    /// Markets the user closed, or sent a close for, from this app — and when.
    private var userCloses: [Int: Date] = [:]
    /// Whose positions the diff state above describes; a different account starts over.
    private var diffOwner: Address?

    var unrealizedTotal: Double { positions.reduce(0) { $0 + $1.unrealized } }
    var equity: Double? { account.map { Amount.units($0.balance, decimals: 6) + unrealizedTotal } }

    func change24h(for market: PerpMarket) -> Double? {
        guard let c = context[market.id], c.prev24h > 0 else { return nil }
        return (market.mark - c.prev24h) / c.prev24h * 100
    }

    func poll(env: AppEnvironment, address: Address?) async {
        while !Task.isCancelled {
            await load(env: env, address: address)
            try? await Task.sleep(for: .seconds(8))
        }
    }

    /// The user closed this market's position, or sent a close for it, from this app: its disappearance is expected.
    /// Noted when the close is sent, before the next poll can see the position gone (GT-9).
    func noteUserClose(_ perpId: Int) { userCloses[perpId] = Date() }

    /// A close noted as sent never left the device: the position's disappearance is news again.
    func forgetUserClose(_ perpId: Int) { userCloses[perpId] = nil }

    func load(env: AppEnvironment, address: Address?) async {
        perpl = env.perpl
        loading = true
        defer { loading = false }
        async let ctx = env.perpl.context()
        if address != diffOwner {
            // Another account: its positions are not "new fills" or "closes" of the previous one's.
            diffOwner = address
            lastPositionSize = [:]
            fillPrimed = false
            lastPositions = [:]
            restingCloseMarkets = []
            userCloses = [:]
        }
        do {
            let fetched = try await env.perpl.markets()
            markets = fetched
            env.perplTrading.noteMarkets(fetched)
            error = nil
            if let address {
                async let collateralTask = env.perpl.collateral(of: address)
                let acct = try await env.perpl.account(address)
                account = acct
                if let acct {
                    async let p = env.perpl.positions(acct, markets: fetched)
                    async let o = env.perpl.openOrders(acct, markets: fetched)
                    // A failed read returns nil (keep the last good list); only diff for fills on a successful read.
                    if let fresh = try? await p {
                        detectFills(fresh)
                        detectCloses(fresh, stillOpen: Set(acct.positionPerpIds), trading: env.perplTrading, owner: address)
                        positions = fresh
                    }
                    if let freshOrders = try? await o {
                        orders = freshOrders
                        restingCloseMarkets = Set(freshOrders.filter(\.reduceOnly).map(\.perpId))
                    }
                    // Reconcile the app's recorded TP/SL: a trigger lives while its market has a position or a resting
                    // entry, so a fired/closed trigger drops off instead of lingering — pruned only while Perpl's live
                    // list can confirm it (offline, an echo may be the only trace of a trigger still armed).
                    let openPerpIds = Set(positions.map(\.perpId)).union(orders.map(\.perpId))
                    triggers = TriggerStore.reconcile(owner: address, openPerpIds: openPerpIds, verified: env.perplTrading.ordersAreLive)
                } else {
                    positions = []
                    orders = []
                    triggers = TriggerStore.reconcile(owner: address, openPerpIds: [], verified: env.perplTrading.ordersAreLive)
                    lastPositionSize = [:]
                    fillPrimed = false
                    lastPositions = [:]
                }
                collateral = (try? await collateralTask) ?? collateral
            } else {
                account = nil
                positions = []
                orders = []
                triggers = []
                lastPositions = [:]
            }
        } catch {
            self.error = describe(error)
        }
        if let list = try? await ctx { context = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }) }
    }

    /// A position that was open at the last good read and that the account no longer holds (security audit GT-9).
    /// The trading stream reports a fired TP/SL or a liquidation precisely when it is live (`PerplTrading`); this is the
    /// fallback for when it isn't — no one-click trading, or a dropped socket — and can only say the position closed,
    /// not how. Quiet when the user closed it from here, or the stream already reported the ending. It also has
    /// Perpl trading cancel the TP/SL that position leaves behind, in case the stream's own report was missed (GT-2).
    private func detectCloses(_ fresh: [PerpPosition], stillOpen: Set<Int>, trading: PerplTrading, owner: Address) {
        let freshIds = Set(fresh.map(\.perpId))
        defer {
            // A position the account still holds but this read missed stays known, so its close is still noticed later.
            var next = Dictionary(fresh.map { ($0.perpId, $0) }, uniquingKeysWith: { first, _ in first })
            for (perpId, old) in lastPositions where !freshIds.contains(perpId) && stillOpen.contains(perpId) { next[perpId] = old }
            lastPositions = next
        }
        // Gone from the read AND from the account's own position bitmap: closed, not a sub-call that failed.
        for (perpId, old) in lastPositions where !freshIds.contains(perpId) && !stillOpen.contains(perpId) {
            trading.positionClosedOnChain(marketId: perpId, isLong: old.side == .long)
            if let at = userCloses[perpId], Date().timeIntervalSince(at) < 600 { continue }
            if trading.sawEnding(marketId: perpId) { continue }
            let asset = markets.first { $0.id == perpId }?.asset ?? old.symbol
            let side = old.side == .long ? "long" : "short"
            let size = "\(NumberStyle.number(old.size)) \(asset)"
            let record = restingCloseMarkets.contains(perpId)
                ? ActivityRecord(kind: .perp, title: "Close order filled", subtitle: "Your \(asset)-PERP \(side) (\(size)) is closed.", hash: nil, section: "perps")
                : ActivityRecord(kind: .perp, title: "\(asset)-PERP \(side) closed",
                                 subtitle: "Your \(size) \(side) is no longer open, and it wasn't closed from this app. It may have hit a take-profit or stop-loss, been liquidated, or been closed on another device. Trade History shows how.",
                                 hash: nil, section: "perps")
            Activity.record(record, owner: owner)
        }
    }

    /// Compares the fresh positions against the previous snapshot and fires a fill signal + local notification for
    /// any market whose position opened or grew. Skips the very first snapshot so an already-open position on launch
    /// isn't reported as a new fill. Only this screen's poll reads positions, so a fill is noticed only while the Perps
    /// screen is open (security audit 2026-09-26, GL-4: the copy says so).
    private func detectFills(_ fresh: [PerpPosition]) {
        let sizes = Dictionary(fresh.map { ($0.perpId, $0.size) }, uniquingKeysWith: +)
        defer { lastPositionSize = sizes; fillPrimed = true }
        guard fillPrimed else { return }
        for position in fresh where position.size > (lastPositionSize[position.perpId] ?? 0) + 1e-9 {
            lastFilledPerpId = position.perpId
            fillSignal &+= 1
            Notifications.perpOrder(.filled, side: position.side == .long ? "Long" : "Short", market: position.symbol)
        }
    }
}

/// Deposit into or withdraw from the Perpl account.
struct CollateralSheet: View {
    enum Kind { case deposit, withdraw }
    let kind: Kind
    let model: PerpsModel
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var showConfirm = false

    private var raw: BigUInt { Amount.parse(amountText, decimals: 6) ?? 0 }
    private var limit: BigUInt { kind == .deposit ? model.collateral.wallet : (model.account.map { $0.balance - min($0.balance, $0.locked) } ?? 0) }
    /// A first deposit with no account yet is really account creation — the plan calls `createAccount`, not `depositCollateral`.
    private var isCreating: Bool { kind == .deposit && model.account == nil }
    private var problem: String? {
        if raw == 0 { return nil }
        if raw > limit { return kind == .deposit ? "Not enough AUSD in your wallet." : "More than your available balance." }
        if kind == .deposit, model.account == nil, raw < Perpl.minimumDeposit { return "The first deposit must be at least 10 AUSD." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: "0", text: $amountText, token: .ausd) { Haptics.selection(); amountText = Amount.exact(limit, decimals: 6) }
                } header: {
                    Text(isCreating ? "Open your Perpl account" : (kind == .deposit ? "Deposit AUSD" : "Withdraw AUSD"))
                } footer: {
                    if isCreating {
                        // The Perps screen's first run: opening the account is where someone new to Perps starts. A problem
                        // with the amount takes the explanation's place, and the link stays while it's typed.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(problem ?? "Your first deposit opens your Perpl account. Minimum 10 AUSD. In wallet: \(NumberStyle.units(limit, decimals: 6)) AUSD.")
                            LearnMoreLink(.depositAndWithdraw)
                        }
                    }
                    else if let problem { Text(problem) }
                    else { Text("\(kind == .deposit ? "In wallet" : "Available"): \(NumberStyle.units(limit, decimals: 6)) AUSD") }
                }
            }
            .navigationTitle(isCreating ? "Create Account" : (kind == .deposit ? "Deposit" : "Withdraw"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(raw == 0 || problem != nil) }
            }
            .sheet(isPresented: $showConfirm) {
                ConfirmationSheet(title: isCreating ? "Create Trading Account" : (kind == .deposit ? "Confirm Deposit" : "Confirm Withdrawal"), confirmTitle: isCreating ? "Create Account" : (kind == .deposit ? "Deposit" : "Withdraw"), build: { kind == .deposit ? env.perpl.depositPlan(amountCNS: raw, hasAccount: model.account != nil) : env.perpl.withdrawPlan(amountCNS: raw) }, onDone: { dismiss(); Task { await model.load(env: env, address: session.address) } },
                                  onCompleted: { hash in Activity.record(ActivityRecord(kind: kind == .deposit ? .deposit : .withdraw, title: isCreating ? "Opened trading account" : (kind == .deposit ? "Deposited to Perps" : "Withdrew from Perps"), subtitle: "\(NumberStyle.units(raw, decimals: 6)) AUSD", hash: hash, section: "perps", usd: Amount.units(raw, decimals: 6)), owner: session.address) },
                                  intent: kind == .deposit ? .perplDeposit(amount: raw) : .perplWithdraw) {
                    DetailRow("Amount", "\(NumberStyle.units(raw, decimals: 6)) AUSD")
                    DetailRow(kind == .deposit ? "To" : "From", "Perpl Exchange")
                    if kind == .deposit, model.account == nil { DetailRow("Account", "Opens a new trading account") }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Mark price sampled from the Exchange contract at evenly spaced blocks over the past day, at `clock`'s pace.
enum MarkPriceHistory {
    static func load(market: PerpMarket, rpc: RPCClient, clock: BlockClock, points: Int = 48) async -> [PricePoint] {
        guard let data = try? ABI.encodeCall("getPerpetualInfo(uint256)", [.uint(market.id)]), let latest = try? await rpc.blockNumber() else { return [] }
        let secondsPerBlock = await clock.secondsPerBlock()
        let span = min(latest, BlockClock.blocks(in: 86_400, secondsPerBlock: secondsPerBlock))
        let step = span / UInt64(points)
        let blocks = (0...points).map { latest - span + UInt64($0) * step }
        let call = CallRequest(to: Perpl.exchange, data: data)
        guard let results = try? await rpc.ethCalls(blocks.map { (call, BlockTag.number($0)) }) else { return [] }
        let types = try? ABIType.parseList("(string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool)")
        guard let types else { return [] }
        let now = Date()
        return zip(blocks, results).compactMap { block, result in
            guard case .success(let raw) = result, let info = try? ABI.decode(raw, types).first else { return nil }
            let mark = Amount.units(info[11].uint, decimals: market.priceDecimals)
            guard mark > 0 else { return nil }
            let age = Double(latest - block) * secondsPerBlock
            return PricePoint(block: block, time: now.addingTimeInterval(-age), usd: mark)
        }
    }
}
