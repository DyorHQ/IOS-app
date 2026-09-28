import BigInt
import XCTest
@testable import DyorKit

/// Swap never buys a coin still on a retired launchpad's curve (owner decision 2026-09-28): for a coin on each of the four
/// retired stacks, in each phase before graduation, every venue is refused with the same notice before any is asked —
/// paying with MON or USDC — while selling it is never checked. A coin that graduated from a retired stack routes both
/// ways: through its Uniswap v4 pool (0x6B1C, 0x10F3, 0x2F02) or its Monday Trade pool (the legacy 0xad3d). Contract
/// reads are answered by `MomentsChainStub`; Kuru Flow by `SwapNetStub` (its fixed MON → USDC quote, which it blocks for
/// any other pair).
final class SwapRetiredLaunchpadTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let amount = BigUInt(10).power(18)

    override func setUp() {
        super.setUp()
        SwapNetStub.reset()
        MomentsChainStub.install { _, _ in nil }
    }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    /// The engine as the app builds it: Uniswap v4 routes through the graduated pools of the live stack (the v2 fixture
    /// here) and of the retired stacks with the current record.
    private func engine() -> SwapEngine {
        SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(), launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad))
    }

    private func coin(_ chain: RetiredCoinChain) -> Token {
        Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
    }

    private func request(_ tokenIn: Token, _ tokenOut: Token) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount, slippageBps: 50, account: account, exactApprovals: true)
    }

    /// The only reads a refused buy makes: one aggregate asking each retired factory for the coin's record.
    private func assertOnlyTheRecordsWereRead(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let selector = ABI.selector(LaunchpadABI.Factory.getLaunchedToken).hexString
        XCTAssertEqual(MomentsChainStub.batches().map { $0.map(\.to) }, [LaunchpadAddresses.retiredFactories], label, file: file, line: line)
        XCTAssertTrue(MomentsChainStub.calls().allSatisfy { $0.selector == selector }, label, file: file, line: line)
        XCTAssertEqual(SwapNetStub.recorded(), [], "\(label): Kuru Flow was never asked", file: file, line: line)
    }

    // MARK: Sell-only coins

    func testNoVenueQuotesABuyOfACoinOnARetiredCurve() async {
        let engine = engine()
        for stack in LaunchpadAddresses.retiredStacks {
            for phase in [LaunchPhase.bonding, .migrating, .refund] {
                let chain = RetiredCoinChain(stack: stack, phase: phase)
                let coin = coin(chain)
                for pay in [Token.mon, Token.usdc] {
                    let label = "\(stack.factory.short) \(phase.title) \(pay.symbol) → coin"
                    MomentsChainStub.install(chain.answer)
                    SwapNetStub.reset()
                    let result = await engine.quotes(for: request(pay, coin))
                    XCTAssertTrue(result.quotes.isEmpty, label)
                    XCTAssertEqual(Set(result.errors.keys), Set(SwapEngine.quoteVenues), label)
                    for venue in SwapEngine.quoteVenues { XCTAssertEqual(result.errors[venue], RetiredLaunchpad.notice, "\(label) \(venue)") }
                    assertOnlyTheRecordsWereRead(label)

                    for venue in SwapEngine.quoteVenues {
                        MomentsChainStub.install(chain.answer)
                        do {
                            let quote = try await engine.quote(venue, for: request(pay, coin))
                            XCTFail("\(label): \(venue) quoted \(String(describing: quote?.route))")
                        } catch {
                            XCTAssertEqual(error as? SwapError, .retiredLaunchpad(chain.coin), "\(label) \(venue)")
                        }
                        assertOnlyTheRecordsWereRead("\(label) \(venue)")
                    }
                    let refusal = await engine.buyRefusal(coin)
                    XCTAssertEqual(refusal, .retiredLaunchpad(chain.coin), label)
                }
            }
        }
        XCTAssertEqual(SwapError.retiredLaunchpad(.zero).errorDescription, "This coin's launchpad is retired: you can sell, but not buy.")
    }

    /// Selling it is never checked: the coin as the pay side reaches the venues (none has a pool for it, since it never
    /// graduated), and no venue answers with the retired-launchpad notice.
    func testSellingACoinOnARetiredCurveIsNotRefused() async {
        let engine = engine()
        for stack in LaunchpadAddresses.retiredStacks {
            let chain = RetiredCoinChain(stack: stack, phase: .bonding)
            MomentsChainStub.install(chain.answer)
            for receive in [Token.mon, Token.usdc] {
                let result = await engine.quotes(for: request(coin(chain), receive))
                XCTAssertEqual(Set(result.errors.keys), Set(SwapEngine.quoteVenues))
                XCTAssertFalse(result.errors.values.contains(RetiredLaunchpad.notice), "\(stack.factory.short) → \(receive.symbol): \(result.errors)")
            }
            XCTAssertTrue(SwapNetStub.recorded().contains("\(Kuru.api.host ?? "")/api/quote"), "the venues were asked")
        }
    }

    // MARK: Graduated coins

    /// A coin that graduated from each retired stack is an ordinary pool token: bought and sold against MON through its
    /// pool — Uniswap v4 on the stack's hook, or Monday Trade for the legacy stack's coins.
    func testAGraduatedRetiredCoinRoutesBothWays() async throws {
        let engine = engine()
        for stack in LaunchpadAddresses.retiredStacks {
            let chain = RetiredCoinChain(stack: stack, phase: .graduated)
            let coin = coin(chain)
            MomentsChainStub.install(chain.answer)
            let refusal = await engine.buyRefusal(coin)
            XCTAssertNil(refusal, stack.factory.short)
            let venue: Venue = chain.venue == .monday ? .monday : .uniswap
            for (tokenIn, tokenOut) in [(Token.mon, coin), (coin, Token.mon)] {
                let label = "\(stack.factory.short) \(tokenIn.symbol) → \(tokenOut.symbol)"
                let result = await engine.quotes(for: request(tokenIn, tokenOut))
                let quote = try XCTUnwrap(result.quotes.first { $0.venue == venue }, "\(label): \(result.errors)")
                XCTAssertEqual(quote.amountOut, RetiredCoinChain.out, label)
                XCTAssertFalse(result.errors.values.contains(RetiredLaunchpad.notice), label)
                if venue == .uniswap {
                    XCTAssertEqual(quote.route, "v4 · \(tokenIn.symbol) → \(tokenOut.symbol) · launchpad", label)
                } else {
                    XCTAssertTrue(quote.route.hasSuffix("· 1%"), "\(label): \(quote.route)")
                }
                let steps = try await quote.build(account)
                XCTAssertEqual(steps.last?.request?.to, venue == .uniswap ? Uniswap.universalRouter : MondayTrade.swapRouter, label)
            }
        }
    }

    // MARK: Reads

    /// A read that fails refuses the buy (nothing could rule the coin out); the app's own tokens are never read.
    func testAFailedReadRefusesAndTheAppsOwnTokensAreNeverRead() async {
        let engine = engine()
        let unknown = Token(address: Address(literal: "0x00000000000000000000000000000000000c0100"), symbol: "NEW", name: "New coin", decimals: 18)
        let refusal = await engine.buyRefusal(unknown)
        XCTAssertEqual(refusal, .launchpadUnchecked)
        let result = await engine.quotes(for: request(.mon, unknown))
        XCTAssertTrue(result.quotes.isEmpty)
        XCTAssertEqual(result.errors[.kuru], SwapError.launchpadUnchecked.errorDescription)

        MomentsChainStub.install { _, _ in nil }
        for token in Token.core + [Token.mon] {
            let none = await engine.buyRefusal(token)
            XCTAssertNil(none, token.symbol)
        }
        XCTAssertTrue(MomentsChainStub.calls().isEmpty, "MON, WMON, the stablecoins and pair assets are no launchpad coin")
        XCTAssertFalse(SwapEngine.mayBeLaunchCoin(.usdc))
        XCTAssertTrue(SwapEngine.mayBeLaunchCoin(unknown))
    }

    /// The record check itself, per layout: a record that exists and has no pool is sell-only, a graduated or missing one
    /// is not, and a missing answer throws.
    func testSellOnlyRecords() throws {
        let coin = Address(literal: "0x00000000000000000000000000000000000c0100")
        for stack in LaunchpadAddresses.retiredStacks {
            let legacy = stack.generation.legacyRecord
            func record(_ phase: LaunchPhase, exists: Bool = true) -> Result<[ABIValue], Error> {
                .success([RetiredCoinChain.record(token: coin, curve: coin, phase: phase, venue: legacy ? .monday : .uniswapV4, exists: exists, legacy: legacy)])
            }
            for phase in LaunchPhase.allCases {
                let found = try RetiredLaunchpad.sellOnlyCoins(queries: [(coin, legacy)], results: [record(phase)])
                XCTAssertEqual(found, phase == .graduated ? [] : [coin], "\(stack.factory.short) \(phase.title)")
            }
            XCTAssertEqual(try RetiredLaunchpad.sellOnlyCoins(queries: [(coin, legacy)], results: [record(.bonding, exists: false)]), [])
            struct Down: Error {}
            XCTAssertThrowsError(try RetiredLaunchpad.sellOnlyCoins(queries: [(coin, legacy)], results: [.failure(Down())]))
            XCTAssertThrowsError(try RetiredLaunchpad.sellOnlyCoins(queries: [(coin, legacy)], results: []))
        }
    }
}

/// One coin launched on one retired stack, in `phase`, answered from memory: every retired factory's `getLaunchedToken`
/// (an empty record, in its own layout, from the others), and once graduated its pool — a Uniswap v4 pool on the stack's
/// hook, quoted by the V4Quoter, or for the legacy stack a 1% Monday Trade pool against WMON, quoted by Monday's QuoterV2.
/// Every other pool lookup answers "none"; every other call reverts.
struct RetiredCoinChain: Sendable {
    let stack: LaunchpadAddresses
    let phase: LaunchPhase
    let coin = Address(literal: "0x00000000000000000000000000000000000c01d0")
    let curve = Address(literal: "0x00000000000000000000000000000000000c01c0")
    let mondayPool = Address(literal: "0x00000000000000000000000000000000000c0b00")
    static let out = BigUInt(777_000)

    var venue: GraduationVenue { stack.generation.legacyRecord ? .monday : .uniswapV4 }

    static func record(token: Address, curve: Address, phase: LaunchPhase, venue: GraduationVenue, exists: Bool, legacy: Bool) -> ABIValue {
        var fields: [ABIValue] = [.address(token), .address(curve), .address(token), .address(token), .address(.zero), .uint(1_000), .uint(0), .uint(100), .int(60), .bool(false),
                                  .uint(BigUInt(venue.rawValue)), .uint(BigUInt(phase.rawValue)), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(exists)]
        if legacy { fields.remove(at: 10) }
        return .tuple(fields)
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let graduated = phase == .graduated
        if is_(LaunchpadABI.Factory.getLaunchedToken), let retired = LaunchpadAddresses.retiredStack(for: to) {
            let legacy = retired.generation.legacyRecord
            let ours = to == stack.factory && args.address(0) == coin
            return encode([Self.record(token: ours ? coin : .zero, curve: ours ? curve : .zero, phase: ours ? phase : .bonding, venue: venue, exists: ours, legacy: legacy)],
                          LaunchpadABI.launchedTokenReturns(legacy: legacy))
        }
        if is_(LaunchpadABI.Factory.poolKeyOf), to == stack.factory, graduated, venue == .uniswapV4, args.address(0) == coin {
            return encode([.tuple([.address(.zero), .address(coin), .uint(0), .int(60), .address(stack.hook)])], LaunchpadABI.poolKeyTuple)
        }
        if to == Uniswap.v4Quoter, is_("quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))"), graduated, venue == .uniswapV4 {
            return encode([.uint(Self.out), .uint(150_000)], "uint256,uint256")
        }
        if is_("getPool(address,address,uint24)"), to == Uniswap.v3Factory || to == MondayTrade.factory {
            let pair = Set([args.address(0), args.address(1)].compactMap { $0 })
            let ours = to == MondayTrade.factory && graduated && venue == .monday && pair == [Monad.wmon, coin] && args.uint(2) == 10_000
            return encode([.address(ours ? mondayPool : .zero)], "address")
        }
        if to == mondayPool, is_("liquidity()") { return encode([.uint(BigUInt(10).power(21))], "uint128") }
        if to == MondayTrade.quoterV2, is_("quoteExactInputSingle((address,address,uint256,uint24,uint160))") {
            return encode([.uint(Self.out), .uint(0), .uint(0), .uint(150_000)], "uint256,uint160,uint32,uint256")
        }
        return nil
    }
}
