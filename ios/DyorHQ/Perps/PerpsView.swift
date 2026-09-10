import BigInt
import Charts
import DyorKit
import SwiftUI

/// Perpetuals on Perpl: account, positions, open orders and markets, all read from the Exchange contract.
struct PerpsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = PerpsModel()
    @State private var sheet: PerpsSheet?
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                accountSection
                if !model.positions.isEmpty { positionsSection }
                if !model.orders.isEmpty { ordersSection }
                marketsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Trade")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TradeModeSwitcher() }
            .navigationDestination(for: Int.self) { id in
                if let market = model.markets.first(where: { $0.id == id }) {
                    PerpTradeView(market: market, model: model)
                }
            }
            .refreshable { await model.load(env: env, address: session.address) }
            .task(id: session.address) { await model.poll(env: env, address: session.address) }
            .overlay { if model.markets.isEmpty, model.loading { ProgressView().controlSize(.large) } }
            .sheet(item: $sheet) { which in
                switch which {
                case .deposit: CollateralSheet(kind: .deposit, model: model)
                case .withdraw: CollateralSheet(kind: .withdraw, model: model)
                }
            }
            .onChange(of: router.pendingPerpMarket) { _, id in
                if let id { path = [id]; router.pendingPerpMarket = nil }
            }
            // Fallback for when this view is created *after* the deep link is set — e.g. opening a perp from Home
            // while the Trade tab is in Swap mode, which builds PerpsView fresh with pendingPerpMarket already set,
            // so `.onChange` never fires. Mirrors SwapView's `applyPending()` on appear.
            .onAppear {
                if let id = router.pendingPerpMarket { path = [id]; router.pendingPerpMarket = nil }
            }
        }
    }

    private var accountSection: some View {
        Section {
            if let account = model.account {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trading Balance").font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        USDText(value: model.equity, font: .system(.largeTitle, design: .rounded).weight(.semibold))
                        if model.unrealizedTotal != 0 {
                            Text(model.unrealizedTotal, format: .currency(code: "USD").sign(strategy: .always()))
                                .font(.subheadline.weight(.medium)).monospacedDigit()
                                .foregroundStyle(model.unrealizedTotal < 0 ? Color.negative : Color.positive)
                        }
                    }
                    HStack(spacing: 16) {
                        Label("\(NumberStyle.units(account.balance - min(account.balance, account.locked), decimals: 6)) AUSD available", systemImage: "circle.lefthalf.filled")
                        if account.frozen { Label("Frozen", systemImage: "snowflake").foregroundStyle(Color.attention) }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if session.address != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Trading Account Yet").font(.headline)
                    Text("New to Perpl? Create your account on the web first, then deposit at least 10 AUSD to open a trading account. Collateral stays in the Perpl Exchange contract under your address.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link(destination: PerplLinks.signup) {
                        Label("Create a Perpl Account", systemImage: "arrow.up.forward.square").font(.subheadline.weight(.medium))
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 12) {
                Button("Deposit", systemImage: "plus") { sheet = .deposit }
                    .buttonStyle(.borderedProminent)
                Button("Withdraw", systemImage: "minus") { sheet = .withdraw }
                    .buttonStyle(.bordered)
                    .disabled(model.account == nil)
            }
            .controlSize(.regular)
            .disabled(!session.canSign)
        } footer: {
            if !session.canSign { Text("Sign in to deposit and trade.") }
            else if let error = model.error { InlineError(message: error) }
        }
    }

    private var positionsSection: some View {
        Section("Positions") {
            ForEach(model.positions) { position in
                NavigationLink(value: position.perpId) { PositionRow(position: position) }
                    .swipeActions {
                        Button("Close") { model.closing = position }
                            .tint(Color.negative)
                    }
            }
        }
        .sheet(item: $model.closing) { position in
            if let market = model.markets.first(where: { $0.id == position.perpId }) {
                ConfirmationSheet(title: "Close Position", confirmTitle: "Close \(position.symbol) \(position.side.rawValue.capitalized)", build: { env.perpl.closePositionPlan(market: market, position: position, slippageBps: 100) }, onDone: { Task { await model.load(env: env, address: session.address) } }) {
                    DetailRow("Size", "\(NumberStyle.number(position.size)) \(position.symbol)")
                    DetailRow("Mark price", NumberStyle.number(position.mark))
                    DetailRow("Unrealized", position.unrealized.formatted(.currency(code: "USD").sign(strategy: .always())), tint: position.unrealized < 0 ? Color.negative : Color.positive)
                    DetailRow("Order", "Market, reduce only, 1% slippage")
                }
            }
        }
    }

    private var ordersSection: some View {
        Section("Open Orders") {
            ForEach(model.orders) { order in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(order.side == .buy ? "Buy" : "Sell") \(NumberStyle.number(order.size)) \(order.symbol)").font(.headline)
                        Text("Limit \(NumberStyle.number(order.price)) · \(NumberStyle.number(order.leverage, maximumFractionDigits: 1))×\(order.reduceOnly ? " · Reduce only" : "")")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text("#\(order.orderId)").font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .swipeActions {
                    Button("Cancel Order") { model.cancelling = order }.tint(Color.negative)
                }
            }
        }
        .sheet(item: $model.cancelling) { order in
            ConfirmationSheet(title: "Cancel Order", confirmTitle: "Cancel Order", build: { env.perpl.cancelPlan(perpId: order.perpId, orderId: order.orderId) }, onDone: { Task { await model.load(env: env, address: session.address) } }) {
                DetailRow("Market", order.symbol)
                DetailRow("Order", "\(order.side == .buy ? "Buy" : "Sell") \(NumberStyle.number(order.size)) at \(NumberStyle.number(order.price))")
            }
        }
    }

    private var marketsSection: some View {
        Section("Markets") {
            ForEach(model.markets) { market in
                NavigationLink(value: market.id) {
                    HStack(spacing: 12) {
                        TokenLogo(symbol: market.asset, url: nil, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(market.asset).font(.headline)
                            Text(market.name).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(NumberStyle.number(market.mark)).font(.body.weight(.medium)).monospacedDigit()
                            HStack(spacing: 6) {
                                ChangeBadge(value: model.change24h(for: market))
                                Text("\(NumberStyle.percent(Double(market.fundingRatePct100k) / 1_000, fractionDigits: 3)) fund.")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PositionRow: View {
    let position: PerpPosition

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(position.symbol).font(.headline)
                    Text("\(position.side == .long ? "Long" : "Short") \(NumberStyle.number(position.leverage, maximumFractionDigits: 1))×")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((position.side == .long ? Color.positive : Color.negative).opacity(0.14), in: Capsule())
                        .foregroundStyle(position.side == .long ? Color.positive : Color.negative)
                }
                Text("\(NumberStyle.number(position.size)) at \(NumberStyle.number(position.entry)) · Liq. \(position.liquidation.map { NumberStyle.number($0) } ?? "—")")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(position.unrealized, format: .currency(code: "USD").sign(strategy: .always()))
                    .monospacedDigit().fontWeight(.medium)
                    .foregroundStyle(position.unrealized < 0 ? Color.negative : Color.positive)
                Text("Margin \(NumberStyle.number(position.margin, maximumFractionDigits: 2))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
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
                    positions = (try? await p) ?? positions
                    orders = (try? await o) ?? orders
                } else {
                    positions = []
                    orders = []
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
