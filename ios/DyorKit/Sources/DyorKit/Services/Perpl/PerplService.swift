import BigInt
import Foundation

/// Reads markets, accounts, positions and orders from Perpl's Exchange contract and builds the transaction
/// plans the app runs with `TransactionSender`. Mirrors app/lib/perps/perpl.ts in the web repository.
public actor PerplService {
    /// The markets the app lists, in display order. Symbols are the app's; the contract's own symbol (for
    /// example `SOL_v2`) is what `PerpMarket.symbol` carries.
    public static let markets: [(id: Int, symbol: String, name: String)] = [
        (1, "BTC", "Bitcoin"),
        (10, "MON", "Monad"),
        (20, "ETH", "Ether"),
        (31, "SOL", "Solana"),
        (40, "HYPE", "Hyperliquid"),
        (50, "ZEC", "Zcash"),
    ]

    /// Perpl's public REST API. `Perpl.api` (api.perpl.xyz) has no DNS record; the web app proxies
    /// app.perpl.xyz/api, which is what this defaults to.
    public static let restBase = URL(string: "https://app.perpl.xyz/api")!

    public let rpc: RPCClient
    private let multicall: Multicall
    private let session: URLSession
    private let apiBase: URL
    private let contextURL: URL

    public init(rpc: RPCClient, session: URLSession = .shared, restBase: URL = PerplService.restBase) {
        self.rpc = rpc
        multicall = Multicall(rpc: rpc)
        self.session = session
        apiBase = restBase
        contextURL = restBase.appending(path: "v1/pub/context")
    }

    // MARK: Reads

    /// Markets in the order of `ids`; markets the contract fails to report are left out, and a market whose
    /// margin read fails gets Perpl's usual 10% / 5% requirements.
    public func markets(ids: [Int]? = nil) async throws -> [PerpMarket] {
        let ids = ids ?? Self.markets.map(\.id)
        async let infoReads = multicall.read(ids.map { PerplExchange.read(PerplExchange.Signature.getPerpetualInfo, [.uint($0)], returns: PerplExchange.Returns.perpetualInfo) })
        async let marginReads = multicall.read(ids.map { PerplExchange.read(PerplExchange.Signature.getMarginFractions, [.uint($0), .uint(0)], returns: PerplExchange.Returns.marginFractions) })
        let (infos, margins) = try await (infoReads, marginReads)
        var out: [PerpMarket] = []
        for (i, id) in ids.enumerated() {
            guard case .success(let info) = infos[i] else { continue }
            var margin: [ABIValue]?
            if case .success(let values) = margins[i] { margin = values }
            out.append(PerplExchange.market(id: id, info: info[0], margins: margin))
        }
        return out
    }

    /// Nil when the address has no Exchange account: the contract reverts with `AccountNotFound(address)`
    /// rather than returning an empty record.
    public func account(_ address: Address) async throws -> PerpAccount? {
        let data = PerplExchange.calldata(PerplExchange.Signature.getAccountByAddr, [.address(address)])
        let raw: Data
        do {
            raw = try await rpc.ethCall(CallRequest(to: PerplExchange.address, data: data))
        } catch let error as RPCError where PerplExchange.isAccountNotFound(error) {
            return nil
        }
        let values = try ABI.decode(raw, PerplExchange.Returns.account)
        return PerplExchange.account(values[0])
    }

    public func positions(_ account: PerpAccount, markets: [PerpMarket]) async throws -> [PerpPosition] {
        if account.positionPerpIds.isEmpty { return [] }
        let calls = account.positionPerpIds.map { PerplExchange.read(PerplExchange.Signature.getPosition, [.uint($0), .uint(account.accountId)], returns: PerplExchange.Returns.position) }
        let results = try await multicall.read(calls)
        var out: [PerpPosition] = []
        for (perpId, result) in zip(account.positionPerpIds, results) {
            guard case .success(let values) = result, let perp = markets.first(where: { $0.id == perpId }), let position = PerplExchange.position(perp: perp, values: values) else { continue }
            out.append(position)
        }
        return out
    }

    /// Open orders of an account: for every market where the account holds an order lock, walk the market's
    /// order-id index, read each order in chunks, and keep the account's own.
    public func openOrders(_ account: PerpAccount, markets: [PerpMarket]) async throws -> [PerpOrder] {
        let lockCalls = markets.map { PerplExchange.read(PerplExchange.Signature.getPerpOrderLocks, [.uint(account.accountId), .uint($0.id)], returns: PerplExchange.Returns.orderLocks) }
        let locks = try await multicall.read(lockCalls)
        let active = zip(markets, locks).compactMap { market, result -> PerpMarket? in
            guard case .success(let values) = result, !values[0].elements.isEmpty else { return nil }
            return market
        }
        var out: [PerpOrder] = []
        for perp in active {
            let indexData = PerplExchange.calldata(PerplExchange.Signature.getOrderIdIndex, [.uint(perp.id)])
            let raw = try await rpc.ethCall(CallRequest(to: PerplExchange.address, data: indexData))
            let index = try ABI.decode(raw, PerplExchange.Returns.orderIdIndex)
            let ids = PerplExchange.orderIds(leaves: index[1].elements.map(\.uint))
            for start in stride(from: 0, to: ids.count, by: PerplExchange.orderChunkSize) {
                let chunk = Array(ids[start..<min(start + PerplExchange.orderChunkSize, ids.count)])
                let orderCalls = chunk.map { PerplExchange.read(PerplExchange.Signature.getOrder, [.uint(perp.id), .uint($0)], returns: PerplExchange.Returns.order) }
                let orders = try await multicall.read(orderCalls)
                for (orderId, result) in zip(chunk, orders) {
                    guard case .success(let values) = result else { continue }
                    let parsed = PerplExchange.order(perp: perp, orderId: orderId, values: values[0])
                    guard parsed.accountId == account.accountId, let order = parsed.order else { continue }
                    out.append(order)
                }
            }
        }
        return out
    }

    /// AUSD in the wallet and the allowance already granted to the Exchange, both in collateral units.
    public func collateral(of address: Address) async throws -> (wallet: BigUInt, allowance: BigUInt) {
        let results = try await multicall.readAll([
            try ERC20.balanceOf(Perpl.collateral, address),
            try ERC20.allowance(Perpl.collateral, owner: address, spender: Perpl.exchange),
        ])
        return (results[0][0].uint, results[1][0].uint)
    }

    /// Perpl's public market context: 24h reference price, volume, open interest and funding per market.
    public func context() async throws -> [MarketContext] {
        var request = URLRequest(url: contextURL)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NetworkError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PerplError.contextUnavailable(status: http.statusCode)
        }
        let body: ContextResponse
        do {
            body = try JSONDecoder().decode(ContextResponse.self, from: data)
        } catch {
            throw PerplError.malformedResponse("market context")
        }
        return (body.markets ?? []).compactMap { market in
            guard let config = market.config, let state = market.state else { return nil }
            let priceScale = pow(10, Double(config.priceDecimals))
            let sizeScale = pow(10, Double(config.sizeDecimals))
            var fundingRate = 0.0
            if let funding = market.funding {
                let divisor = funding.div ?? 0
                fundingRate = funding.rate / (divisor == 0 ? 1 : divisor) / 100_000
            }
            return MarketContext(
                id: market.id,
                name: market.name ?? "",
                priceDecimals: config.priceDecimals,
                sizeDecimals: config.sizeDecimals,
                mark: state.mrk / priceScale,
                last: state.lst / priceScale,
                prev24h: state.prv / priceScale,
                volume24h: state.dv / sizeScale,
                openInterest: state.oi / sizeScale,
                fundingRate: fundingRate,
                isOpen: config.isOpen
            )
        }
    }

    /// OHLCV candles for a market's chart, straight from Perpl's public REST feed (no auth). `from`/`to` are
    /// milliseconds; `resolution` is one of Perpl's supported second-intervals; at most 1024 candles per call.
    /// Prices are scaled by the market's `priceDecimals`; volume arrives as a decimal string.
    public func candles(marketId: Int, resolution: Int, from: Date, to: Date, priceDecimals: Int) async throws -> [PerpCandle] {
        let fromMs = Int(from.timeIntervalSince1970 * 1000)
        let toMs = Int(to.timeIntervalSince1970 * 1000)
        let url = apiBase.appending(path: "v1/market-data/\(marketId)/candles/\(resolution)/\(fromMs)-\(toMs)")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw NetworkError.transport(error) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw PerplError.contextUnavailable(status: http.statusCode) }
        let series: CandleSeriesResponse
        do { series = try JSONDecoder().decode(CandleSeriesResponse.self, from: data) } catch { throw PerplError.malformedResponse("candles") }
        let scale = pow(10.0, Double(priceDecimals))
        return (series.d ?? []).map { candle in
            PerpCandle(
                time: Date(timeIntervalSince1970: Double(candle.t) / 1000),
                open: Double(candle.o) / scale, high: Double(candle.h) / scale, low: Double(candle.l) / scale, close: Double(candle.c) / scale,
                volume: Double(candle.v ?? "0") ?? 0, trades: candle.n ?? 0
            )
        }
    }

    // MARK: Transaction plans

    /// Approves AUSD to the Exchange when needed (the sender skips a sufficient allowance), then opens the
    /// account with the first deposit or tops an existing one up.
    public nonisolated func depositPlan(amountCNS: BigUInt, hasAccount: Bool) -> [TransactionStep] {
        let signature = hasAccount ? PerplExchange.Signature.depositCollateral : PerplExchange.Signature.createAccount
        let request = TransactionRequest(to: PerplExchange.address, data: PerplExchange.calldata(signature, [.uint(amountCNS)]))
        return [
            .approve(token: Perpl.collateral, spender: Perpl.exchange, amount: amountCNS, label: "Approve AUSD"),
            .call(request, label: hasAccount ? "Deposit AUSD" : "Open Perpl account"),
        ]
    }

    public nonisolated func withdrawPlan(amountCNS: BigUInt) -> [TransactionStep] {
        let request = TransactionRequest(to: PerplExchange.address, data: PerplExchange.calldata(PerplExchange.Signature.withdrawCollateral, [.uint(amountCNS)]))
        return [.call(request, label: "Withdraw AUSD")]
    }

    /// `execOrders([desc], revertOnFail: true)` for one order.
    public nonisolated func orderPlan(_ input: OrderInput) -> [TransactionStep] {
        let data = PerplExchange.execOrdersCalldata([Self.buildOrderDesc(input)], revertOnFail: true)
        let verb = input.reduceOnly ? "Close" : input.side == .long ? "Long" : "Short"
        return [.call(TransactionRequest(to: PerplExchange.address, data: data), label: "\(verb) \(input.market.symbol)")]
    }

    public nonisolated func cancelPlan(perpId: Int, orderId: Int) -> [TransactionStep] {
        let desc = PerplExchange.cancelDesc(perpId: perpId, orderId: orderId, descId: BigUInt(OrderDescIDs.shared.next()))
        let data = PerplExchange.execOrdersCalldata([desc], revertOnFail: true)
        return [.call(TransactionRequest(to: PerplExchange.address, data: data), label: "Cancel order")]
    }

    /// Closes a position with a reduce-only market order on the opposite side.
    public nonisolated func closePositionPlan(market: PerpMarket, position: PerpPosition, slippageBps: Int) -> [TransactionStep] {
        let rounded = PerplExchange.jsRound(position.leverage)
        let leverage = max(1, rounded == 0 || rounded.isNaN ? 1 : rounded)
        let input = OrderInput(market: market, side: position.side.opposite, kind: .market, size: position.size, leverage: leverage, reduceOnly: true, slippageBps: slippageBps)
        return orderPlan(input)
    }

    // MARK: Pure helpers

    /// Price at which the position's equity would fall to the maintenance requirement; nil for an empty
    /// position, never below zero.
    public nonisolated static func liquidationPrice(side: PositionSide, entry: Double, size: Double, margin: Double, premium: Double, maintenanceFraction: Double) -> Double? {
        PerplExchange.liquidationPrice(side: side, entry: entry, size: size, margin: margin, premium: premium, maintenanceFraction: maintenanceFraction)
    }

    /// The 15 `OrderDesc` fields for `execOrders`, with a fresh strictly increasing `orderDescId`.
    public nonisolated static func buildOrderDesc(_ input: OrderInput) -> [ABIValue] {
        PerplExchange.orderDesc(input, descId: BigUInt(OrderDescIDs.shared.next()))
    }

    /// Collateral units (AUSD, 6 decimals) to a display number and back.
    public nonisolated static func fromCNS(_ value: BigUInt) -> Double { PerplExchange.fromCNS(value) }
    public nonisolated static func toCNS(_ value: Double) -> BigUInt { PerplExchange.toCNS(value) }
}

// MARK: - Context payload

private struct ContextResponse: Decodable {
    let markets: [ContextMarket]?
}

private struct CandleSeriesResponse: Decodable {
    let d: [RawCandle]?
    struct RawCandle: Decodable {
        let t: Int
        let o: Int64
        let c: Int64
        let h: Int64
        let l: Int64
        let v: String?
        let n: Int?
    }
}

private struct ContextMarket: Decodable {
    struct Config: Decodable {
        let priceDecimals: Int
        let sizeDecimals: Int
        let isOpen: Bool

        enum CodingKeys: String, CodingKey {
            case priceDecimals = "price_decimals"
            case sizeDecimals = "size_decimals"
            case isOpen = "is_open"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            priceDecimals = try c.decode(Int.self, forKey: .priceDecimals)
            sizeDecimals = try c.decode(Int.self, forKey: .sizeDecimals)
            isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        }
    }

    struct State: Decodable {
        let mrk: Double
        let lst: Double
        let prv: Double
        let dv: Double
        let oi: Double

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mrk = try c.decodeIfPresent(Double.self, forKey: .mrk) ?? 0
            lst = try c.decodeIfPresent(Double.self, forKey: .lst) ?? 0
            prv = try c.decodeIfPresent(Double.self, forKey: .prv) ?? 0
            dv = try c.decodeIfPresent(Double.self, forKey: .dv) ?? 0
            oi = try c.decodeIfPresent(Double.self, forKey: .oi) ?? 0
        }

        enum CodingKeys: String, CodingKey { case mrk, lst, prv, dv, oi }
    }

    struct Funding: Decodable {
        let rate: Double
        let div: Double?
    }

    let id: Int
    let name: String?
    let config: Config?
    let state: State?
    let funding: Funding?
}
