import BigInt
import XCTest
@testable import DyorKit

/// The v2 launchpad's new reads, on a stubbed chain (`MomentsChainStub`): the hook's `pendingProtocolFees` in the fee
/// figure, and a stuck Monday launch's Uniswap v4 fallback rule. Each is sent to a v2 stack only; an older contract has
/// no such getter, and its revert would fail the whole read.
final class LaunchpadV2Tests: XCTestCase {
    private let auditFix = LaunchpadAddresses.retiredStack(for: Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"))!

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func detail(_ chain: OneLaunchChain) async throws -> LaunchDetail {
        MomentsChainStub.install(chain.answer)
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.launchpad, logsRPC: MomentsChainStub.rpc())
        let detail = try await service.launch(token: chain.token, factory: chain.stack.factory)
        return try XCTUnwrap(detail)
    }

    private func asked(_ signature: String) -> [Address] {
        let selector = ABI.selector(signature).hexString
        return MomentsChainStub.calls().filter { $0.selector == selector }.map(\.to)
    }

    // MARK: Hook fees

    func testAV2PoolCountsPendingProtocolFees() async throws {
        let chain = OneLaunchChain(stack: V2Fixture.launchpad, venue: .uniswapV4, phase: .graduated)
        let d = try await detail(chain)
        XCTAssertEqual(asked(LaunchpadABI.Hook.pendingProtocolFees), [V2Fixture.launchpad.hook])
        XCTAssertEqual(d.hookPendingFees, 0, "a v2 fee-sharing pool keeps nothing in pendingFees for the pair asset")
        XCTAssertEqual(d.hookPendingTax, 3)
        XCTAssertEqual(d.hookPendingProtocolFees, 40)
        XCTAssertEqual(d.hookFeesAwaitingSweep, 43)
        XCTAssertEqual(d.queuedRewards, 7)
        XCTAssertNil(d.fallbackRule)
        XCTAssertEqual(d.launch.generation, .v2)
    }

    func testAV1StackIsNeverAskedAV2Getter() async throws {
        let graduated = try await detail(OneLaunchChain(stack: auditFix, venue: .uniswapV4, phase: .graduated))
        XCTAssertTrue(asked(LaunchpadABI.Hook.pendingProtocolFees).isEmpty)
        XCTAssertEqual(graduated.hookPendingFees, 20)
        XCTAssertEqual(graduated.hookFeesAwaitingSweep, 23)
        XCTAssertEqual(graduated.hookPendingProtocolFees, 0)

        let stuck = try await detail(OneLaunchChain(stack: auditFix, venue: .monday, phase: .bonding, completed: true, stuckSince: 1_790_000_000, mondayOnly: true))
        XCTAssertTrue(asked(LaunchpadABI.Factory.launchMondayOnly).isEmpty)
        XCTAssertTrue(asked(LaunchpadABI.Factory.mondayOnlyFallbackDelay).isEmpty)
        XCTAssertNil(stuck.fallbackRule)
        XCTAssertNil(stuck.v4FallbackOpensAt)
        XCTAssertTrue(stuck.launch.appSendsGraduateFallback, "v1: the app's own fallback")
    }

    // MARK: Fallback rule

    func testAStuckV2MondayLaunchReadsItsFallbackRule() async throws {
        let stuckSince = 1_790_000_000
        let d = try await detail(OneLaunchChain(stack: V2Fixture.launchpad, venue: .monday, phase: .bonding, completed: true, stuckSince: stuckSince, mondayOnly: true))
        XCTAssertEqual(asked(LaunchpadABI.Factory.launchMondayOnly), [V2Fixture.launchpad.factory])
        XCTAssertEqual(d.fallbackRule, GraduationFallbackRule(mondayOnly: true, allowed: false, delay: 86_400))
        XCTAssertEqual(d.v4FallbackOpensAt, stuckSince + 86_400)
        XCTAssertTrue(d.launch.keepersTakeGraduateFallback)
        XCTAssertFalse(d.launch.appSendsGraduateFallback)

        // Still climbing (curve not complete): nothing to fall back from, nothing read.
        let climbing = try await detail(OneLaunchChain(stack: V2Fixture.launchpad, venue: .monday, phase: .bonding))
        XCTAssertTrue(asked(LaunchpadABI.Factory.launchMondayOnly).isEmpty)
        XCTAssertNil(climbing.fallbackRule)
        // A v4 venue has no fallback.
        let v4 = try await detail(OneLaunchChain(stack: V2Fixture.launchpad, venue: .uniswapV4, phase: .bonding, completed: true, stuckSince: stuckSince))
        XCTAssertNil(v4.fallbackRule)
    }

    /// `block.timestamp < stuckSince + MONDAY_ONLY_FALLBACK_DELAY` reverts `PairRequiresMonday` for a Monday-only
    /// launch the owner hasn't allowed: closed one second before the day is up, open on the second.
    func testMondayOnlyFallbackOpensADayAfterItGotStuck() {
        let stuckSince = 1_790_000_000
        func detail(_ rule: GraduationFallbackRule?, stuckSince: Int = stuckSince) -> LaunchDetail {
            let launch = Launch(token: .zero, curve: .zero, deployer: .zero, creatorFeeRecipient: .zero, pairToken: Token.abil.address, graduationThreshold: 0, creatorTaxBps: 0,
                                poolFeeBps: 0, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .monday, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
                                poolId: Data(count: 32), name: "", symbol: "", logo: "", description: "", socials: .none, pair: PairInfo(address: Token.abil.address, symbol: "aBIL", decimals: 18, isNative: false), price: 0, realQuoteReserve: 0,
                                completed: true, rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 10_000, generation: .v2)
            return LaunchDetail(launch: launch, feeBps: 0, snipeSchedule: [], quoteReserve: 0, tokenReserve: 0, sellableTokens: 0, phantomQuote: 0, reservedTokens: 0,
                                swept: false, stuckSince: stuckSince, poolKey: nil, hookPendingFees: 0, hookPendingTax: 0, fallbackRule: rule)
        }
        let aBIL = detail(GraduationFallbackRule(mondayOnly: true, allowed: false, delay: 86_400))
        XCTAssertEqual(aBIL.v4FallbackOpensAt, stuckSince + 86_400)
        XCTAssertFalse(aBIL.isV4FallbackOpen(at: stuckSince))
        XCTAssertFalse(aBIL.isV4FallbackOpen(at: stuckSince + 86_399))
        XCTAssertTrue(aBIL.isV4FallbackOpen(at: stuckSince + 86_400))
        XCTAssertTrue(aBIL.isV4FallbackOpen(at: stuckSince + 86_401))

        // The owner's allowance opens it at once; so does a pair that wasn't Monday-only at launch.
        let allowed = detail(GraduationFallbackRule(mondayOnly: true, allowed: true, delay: 86_400))
        XCTAssertEqual(allowed.v4FallbackOpensAt, stuckSince)
        XCTAssertTrue(allowed.isV4FallbackOpen(at: stuckSince))
        let mon = detail(GraduationFallbackRule(mondayOnly: false, allowed: false, delay: 86_400))
        XCTAssertEqual(mon.v4FallbackOpensAt, stuckSince)
        XCTAssertFalse(mon.fallbackRule!.waits)

        // Not stuck, or no v2 rule: no fallback time.
        XCTAssertNil(detail(GraduationFallbackRule(mondayOnly: true, allowed: false, delay: 86_400), stuckSince: 0).v4FallbackOpensAt)
        XCTAssertFalse(detail(nil).isV4FallbackOpen(at: stuckSince + 1_000_000))
    }

    // MARK: ABI

    /// The v2 selectors and event topics, against `cast sig` / `cast keccak`.
    func testV2SignaturesMatchCast() {
        let selectors: [(String, String)] = [
            (LaunchpadABI.Factory.launchMondayOnly, "0x9411ab4c"),
            (LaunchpadABI.Factory.mondayRetryGas, "0xa3ca2635"),
            (LaunchpadABI.Factory.mondayOnlyFallbackDelay, "0xfc3816f3"),
            (LaunchpadABI.Factory.v4FallbackAllowed, "0x20ce224f"),
            (LaunchpadABI.Factory.stuckSince, "0x068e9faf"),
            (LaunchpadABI.Factory.graduate, "0xff6d8d05"),
            (LaunchpadABI.Factory.graduateFallback, "0xcd229645"),
            (LaunchpadABI.Factory.getLaunchedToken, "0x3cf28b5a"),
            (LaunchpadABI.Hook.pendingProtocolFees, "0x91389945"),
        ]
        for (signature, selector) in selectors { XCTAssertEqual(ABI.selector(signature).hexString, selector, signature) }
        XCTAssertEqual(LaunchpadABI.Events.holderFeesForwardedTopic.hexString, "0x83e97fbae38483aadb29f84486122b2fa6c5e0300247bd7f0a502aa88842b08e")
    }
}

/// One launch on `stack`, answered from memory: a MON launch with holder fee sharing, at the given phase and venue.
/// v2-only getters are answered only when the stack is v2, so an older stack asked for one reverts, as on chain.
struct OneLaunchChain: Sendable {
    let stack: LaunchpadAddresses
    var venue: GraduationVenue
    var phase: LaunchPhase
    var completed = false
    var stuckSince = 0
    var mondayOnly = false
    var allowed = false

    let token = Address(literal: "0x00000000000000000000000000000000000d1100")
    let curve = Address(literal: "0x00000000000000000000000000000000000d11c0")
    let poolId = Data(repeating: 0x77, count: 32)

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let v2 = stack.generation.hasV2Getters
        typealias F = LaunchpadABI.Factory
        typealias C = LaunchpadABI.Curve
        typealias T = LaunchpadABI.Token
        switch to {
        case stack.factory:
            if is_(F.getLaunchedToken) {
                let fields: [ABIValue] = [.address(token), .address(curve), .address(token), .address(token), .address(.zero), .uint(1_000), .uint(100), .uint(100), .int(60), .bool(true),
                                          .uint(BigUInt(venue.rawValue)), .uint(BigUInt(phase.rawValue)), .uint(0), .uint(0), .uint(0), .bytes(poolId), .bool(true)]
                return encode([.tuple(fields)], LaunchpadABI.launchedTokenTuple)
            }
            if is_(F.stuckSince) { return encode([.uint(BigUInt(stuckSince))], "uint256") }
            if is_(F.poolKeyOf) { return encode([.tuple([.address(.zero), .address(token), .uint(0), .int(60), .address(stack.hook)])], LaunchpadABI.poolKeyTuple) }
            if is_(F.v4FallbackAllowed) { return encode([.bool(allowed)], "bool") }
            if v2, is_(F.launchMondayOnly) { return encode([.bool(mondayOnly)], "bool") }
            if v2, is_(F.mondayOnlyFallbackDelay) { return encode([.uint(86_400)], "uint256") }
            return nil
        case stack.hook:
            // v1 keeps everything in pendingFees; v2 forwards the holders' cut and keeps DyorHQ's apart.
            if is_(LaunchpadABI.Hook.pendingFees) { return encode([.uint(v2 ? 0 : 20)], "uint256") }
            if is_(LaunchpadABI.Hook.pendingCreatorTax) { return encode([.uint(3)], "uint256") }
            if v2, is_(LaunchpadABI.Hook.pendingProtocolFees) { return encode([.uint(40)], "uint256") }
            return nil
        case stack.holderFeeSharing:
            return is_(LaunchpadABI.Sharing.queuedRewards) ? encode([.uint(7), .uint(2)], "uint256,uint256") : nil
        case token:
            if is_(T.name) { return encode([.string("Stuck")], "string") }
            if is_(T.symbol) { return encode([.string("STK")], "string") }
            if is_(T.totalSupply) { return encode([.uint(1_000_000)], "uint256") }
            if is_(T.getTokenInfo) { return encode([.address(token), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,\(LaunchpadABI.socialsTuple)") }
            return nil
        case curve:
            if is_(C.completed) { return encode([.bool(completed)], "bool") }
            if is_(C.rescued) || is_(C.swept) { return encode([.bool(false)], "bool") }
            if is_(C.launchedAt) { return encode([.uint(1_789_000_000)], "uint64") }
            if is_(C.feeBps) { return encode([.uint(100)], "uint16") }
            if is_(C.snipeTaxSchedule) { return encode([.array([])], "uint16[]") }
            if is_(C.getReserves) { return encode([.uint(1), .uint(2)], "uint256,uint256") }
            if is_(C.price) || is_(C.realQuoteReserve) || is_(C.sellableTokens) || is_(C.phantomQuote) || is_(C.reservedTokens) { return encode([.uint(1_000)], "uint256") }
            return nil
        default:
            return nil
        }
    }
}
