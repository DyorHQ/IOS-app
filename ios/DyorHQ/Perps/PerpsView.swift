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
                    ContentUnavailableView("No Markets", systemImage: "chart.bar.xaxis", description: Text("Perpl markets are unavailable right now."))
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

    func load(env: AppEnvironment, address: Address?) async {
        perpl = env.perpl
        loading = true
        defer { loading = false }
        async let ctx = env.perpl.context()
        do {
            let fetched = try await env.perpl.markets()
            markets = fetched
            error = nil
            if let address {
                async let collateralTask = env.perpl.collateral(of: address)
                let acct = try await env.perpl.account(address)
                account = acct
                if let acct {
                    async let p = env.perpl.positions(acct, markets: fetched)
                    async let o = env.perpl.openOrders(acct, markets: fetched)
                    // A failed read returns nil (keep the last good list); only diff for fills on a successful read.
                    if let fresh = try? await p { detectFills(fresh); positions = fresh }
                    orders = (try? await o) ?? orders
                } else {
                    positions = []
                    orders = []
                    lastPositionSize = [:]
                    fillPrimed = false
                }
                collateral = (try? await collateralTask) ?? collateral
            } else {
                account = nil
                positions = []
                orders = []
            }
        } catch {
            self.error = describe(error)
        }
        if let list = try? await ctx { context = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }) }
    }

    /// Compares the fresh positions against the previous snapshot and fires a fill signal + local notification for
    /// any market whose position opened or grew. Skips the very first snapshot so an already-open position on launch
    /// isn't reported as a new fill.
    private func detectFills(_ fresh: [PerpPosition]) {
        let sizes = Dictionary(fresh.map { ($0.perpId, $0.size) }, uniquingKeysWith: +)
        defer { lastPositionSize = sizes; fillPrimed = true }
        guard fillPrimed else { return }
        for position in fresh where position.size > (lastPositionSize[position.perpId] ?? 0) + 1e-9 {
            lastFilledPerpId = position.perpId
            fillSignal &+= 1
            Notifications.perpOrder(side: position.side == .long ? "Long" : "Short", market: position.symbol, filled: true)
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
                    Text(kind == .deposit ? "Deposit AUSD" : "Withdraw AUSD")
                } footer: {
                    if let problem { Text(problem) } else { Text("\(kind == .deposit ? "In wallet" : "Available"): \(NumberStyle.units(limit, decimals: 6)) AUSD") }
                }
            }
            .navigationTitle(kind == .deposit ? "Deposit" : "Withdraw")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(raw == 0 || problem != nil) }
            }
            .sheet(isPresented: $showConfirm) {
                ConfirmationSheet(title: kind == .deposit ? "Confirm Deposit" : "Confirm Withdrawal", confirmTitle: kind == .deposit ? "Deposit" : "Withdraw", build: { kind == .deposit ? env.perpl.depositPlan(amountCNS: raw, hasAccount: model.account != nil) : env.perpl.withdrawPlan(amountCNS: raw) }, onDone: { dismiss(); Task { await model.load(env: env, address: session.address) } }) {
                    DetailRow("Amount", "\(NumberStyle.units(raw, decimals: 6)) AUSD")
                    DetailRow(kind == .deposit ? "To" : "From", "Perpl Exchange")
                    if kind == .deposit, model.account == nil { DetailRow("Account", "Opens a new trading account") }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Mark price sampled from the Exchange contract at evenly spaced blocks over the past day.
enum MarkPriceHistory {
    static func load(market: PerpMarket, rpc: RPCClient, points: Int = 48) async -> [PricePoint] {
        guard let data = try? ABI.encodeCall("getPerpetualInfo(uint256)", [.uint(market.id)]), let latest = try? await rpc.blockNumber() else { return [] }
        let span = Monad.blocksPerDay
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
            let age = Double(latest - block) * 0.4
            return PricePoint(block: block, time: now.addingTimeInterval(-age), usd: mark)
        }
    }
}
