import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The launchpad v2 against a real v2 deployment on a LOCAL anvil fork of Monad, through the plans DyorKit builds and
/// `TransactionSender`, the path the app takes. Skipped unless both are set:
///
///   DYOR_V2_FORK_RPC      a local RPC (127.0.0.1 / localhost) of chain 143, e.g. `anvil --fork-url https://rpc3.monad.xyz
///                         --no-rate-limit --auto-impersonate --disable-code-size-limit --port 8652 --gas-limit 20000000`
///                         (a block gas limit under 22,062,500 lets `InsufficientGasForGraduation` be triggered for real;
///                         with a higher one that check is skipped)
///   DYOR_V2_FORK_RECORDS  a folder with the fork deploy's `pending-143.json` (`contracts/script/Deploy.s.sol` against the
///                         fork writes it: modules sealed, config 0, MON/USDC/AUSD/aBIL with aBIL Monday-only)
///
///   DYOR_V2_FORK_RPC=http://127.0.0.1:8652 DYOR_V2_FORK_RECORDS=<folder> swift test --filter LaunchpadV2ForkTests
///
/// The wallet is a fresh in-memory key funded with anvil cheats; the owner is impersonated on the fork only, and the
/// Monday executor's code is swapped out on the fork only to make one graduation fail. Nothing here reaches a public RPC.
final class LaunchpadV2ForkTests: XCTestCase {
    struct Fork {
        let rpc: RPCClient
        let launchpad: LaunchpadAddresses
        let owner: Address
        let mondayExecutor: Address
        var service: LaunchpadService { LaunchpadService(rpc: rpc, addresses: launchpad, logsRPC: rpc) }
        var sender: TransactionSender { TransactionSender(rpc: rpc) }
    }

    private func fork() async throws -> Fork {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["DYOR_V2_FORK_RPC"], let url = URL(string: text), let folder = env["DYOR_V2_FORK_RECORDS"] else {
            throw XCTSkip("set DYOR_V2_FORK_RPC (a local fork of Monad) and DYOR_V2_FORK_RECORDS (its v2 deploy records)")
        }
        let file = URL(fileURLWithPath: folder).appendingPathComponent("pending-143.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("no v2 launchpad record (pending-143.json) in DYOR_V2_FORK_RECORDS") }
        let rpc = RPCClient(url: url)
        guard rpc.isLocal else { throw XCTSkip("DYOR_V2_FORK_RPC must be a local fork (127.0.0.1 or localhost), never a public RPC") }
        let chain = try await rpc.call("eth_chainId")
        XCTAssertEqual(chain.string.flatMap { BigUInt(hexQuantity: $0) }, 143, "a fork of Monad mainnet")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func address(_ key: String) throws -> Address { try XCTUnwrap((record[key] as? String).flatMap(Address.init), key) }
        let launchpad = LaunchpadAddresses(factory: try address("factory"), router: try address("launchAndBuyRouter"), escrow: try address("escrow"),
                                           holderFeeSharing: try address("holderFeeSharing"), hook: try address("hook"), poolManager: try address("poolManager"), generation: .v2)
        return Fork(rpc: rpc, launchpad: launchpad, owner: try address("owner"), mondayExecutor: try address("mondayExecutor"))
    }

    private func wallet(_ fork: Fork) async throws -> V2ForkTests.ForkWallet {
        let wallet = V2ForkTests.ForkWallet()
        _ = try await fork.rpc.call("anvil_setBalance", [.string(wallet.address.hex), .string("0xd3c21bcecceda1000000")]) // 1,000,000 fork MON
        return wallet
    }

    /// Fork only: a transaction from an impersonated account (the owner).
    private func sendAs(_ fork: Fork, _ from: Address, to: Address, _ signature: String, _ args: [ABIValue] = []) async throws {
        _ = try await fork.rpc.call("anvil_setBalance", [.string(from.hex), .string("0x3635c9adc5dea00000")])
        _ = try await fork.rpc.call("anvil_impersonateAccount", [.string(from.hex)])
        let data = try ABI.encodeCall(signature, args)
        let hash = try await fork.rpc.call("eth_sendTransaction", [.object(["from": .string(from.hex), "to": .string(to.hex), "data": .string(data.hexString)])])
        let receipt = try await fork.rpc.waitForReceipt(try XCTUnwrap(hash.string.flatMap { Data(hex: $0) }))
        _ = try await fork.rpc.call("anvil_stopImpersonatingAccount", [.string(from.hex)])
        XCTAssertTrue(receipt.success, "\(signature) as \(from.short)")
    }

    private func run(_ fork: Fork, _ steps: [TransactionStep], _ wallet: V2ForkTests.ForkWallet) async throws -> Data {
        try await fork.sender.run(steps, from: wallet, onEvent: { _ in })
    }

    /// The sentence `TransactionSender.prepare` refuses a step with (its simulation reverted), or nil when it would send.
    private func refusal(_ fork: Fork, _ steps: [TransactionStep], _ wallet: V2ForkTests.ForkWallet) async -> String? {
        do {
            _ = try await run(fork, steps, wallet)
            return nil
        } catch TransactionError.rejected(let why) {
            return why
        } catch {
            return "\(error)"
        }
    }

    private func sentence(_ error: String) -> String? { RevertReason.knownErrors[ABI.selector("\(error)()").hexString] }

    private func info(_ fork: Fork, _ wallet: Address) async throws -> ProtocolInfo {
        let read = try await fork.service.protocolInfo(extraPairTokens: Token.launchpadPairAssets, account: wallet)
        return try XCTUnwrap(read)
    }

    private func input(_ symbol: String, pair: Address = .zero, venue: GraduationVenue = .uniswapV4, sharing: Bool = true) -> LaunchInput {
        LaunchInput(name: "Fork \(symbol)", symbol: symbol, description: "v2 fork rehearsal", creatorTaxBps: 100, holderFeeSharing: sharing, graduationVenue: venue, pairToken: pair)
    }

    /// Launches through the app's plan, bound to the terms the screen would show, and returns the new coin.
    private func launch(_ fork: Fork, _ input: LaunchInput, _ wallet: V2ForkTests.ForkWallet) async throws -> Launch {
        let terms = try await info(fork, wallet.address)
        let shown = try XCTUnwrap(terms.pairs.first { $0.pair.address == input.pairToken }?.economicsHash)
        let plan = try await fork.service.launchPlan(input, from: wallet.address, expectedLaunchFee: terms.launchFee, expectedEconomics: shown)
        let hash = try await run(fork, plan, wallet)
        let resultRead = try await fork.service.launchResult(transaction: hash)
        let result = try XCTUnwrap(resultRead)
        XCTAssertEqual(result.deployer, wallet.address)
        let detail = try await fork.service.launch(token: result.token)
        return try XCTUnwrap(detail).launch
    }

    /// Buys what is left of the curve, which completes it and starts the graduation.
    private func completeCurve(_ fork: Fork, _ launch: Launch, _ wallet: V2ForkTests.ForkWallet) async throws {
        let rest = launch.graduationThreshold > launch.realQuoteReserve ? launch.graduationThreshold - launch.realQuoteReserve : 0
        let quoteIn = rest * 11 / 10 + BigUInt(10).power(18) // fees and tax on top; the curve refunds what it doesn't take
        _ = try await run(fork, await fork.service.buyPlan(launch: launch, quoteIn: quoteIn, minTokensOut: 0, recipient: wallet.address), wallet)
    }

    // MARK: Reads

    /// The new getters on a real v2 factory: sealed modules equal to the record's, the wallet allowed, the constants the
    /// copy relies on, and aBIL Monday-only.
    func testTheWiringAndTheNewGettersOnARealV2Factory() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        let terms = try await info(fork, wallet.address)
        XCTAssertEqual(terms.modulesSealed, true)
        XCTAssertEqual(terms.moduleMismatches, [])
        XCTAssertEqual(terms.accountCanLaunch, true)
        XCTAssertNil(terms.launchBlocker)
        XCTAssertTrue(terms.pairs.first { $0.pair.address == Token.abil.address }?.mondayOnly ?? false)
        let constants = try await Multicall(rpc: fork.rpc).readAll([
            LaunchpadABI.call(fork.launchpad.factory, LaunchpadABI.Factory.mondayRetryGas, returns: "uint256"),
            LaunchpadABI.call(fork.launchpad.factory, LaunchpadABI.Factory.mondayOnlyFallbackDelay, returns: "uint256"),
        ])
        XCTAssertEqual(constants[0][0].uint, 20_000_000)
        XCTAssertEqual(constants[1][0].uint, 86_400)

        // A build baked with another hook refuses to offer Launch on this factory.
        var other = fork.launchpad
        other.hook = Address(literal: "0x00000000000000000000000000000000000bad00")
        let mismatched = try await LaunchpadService(rpc: fork.rpc, addresses: other, logsRPC: fork.rpc).protocolInfo(account: wallet.address)
        XCTAssertEqual(mismatched?.launchBlocker, .modulesChanged(["hook"]))
    }

    // MARK: Launch gate and refusals

    /// The owner closes launching two ways; each shows the right reason, the plan is refused before anything is signed,
    /// and a launch sent anyway is refused by `prepare` with the factory's own error, decoded.
    func testTheLaunchGateFollowsTheOwnersSwitches() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        let factory = fork.launchpad.factory
        let open = try await info(fork, wallet.address)
        let mon = try XCTUnwrap(open.pairs.first { $0.pair.isNative })
        // What a build that skipped the gate would send: the sync plan, with the current terms.
        func raw(_ symbol: String) async -> [TransactionStep] {
            var bound = input(symbol)
            bound.expectedEconomics = mon.economicsHash ?? Data()
            return await fork.service.launchPlan(bound, launchFee: open.launchFee, from: wallet.address)
        }

        try await sendAs(fork, fork.owner, to: factory, "setWhitelistEnabled(bool)", [.bool(true)])
        let whitelisted = try await info(fork, wallet.address)
        XCTAssertEqual(whitelisted.launchBlocker, .notAllowed)
        do {
            _ = try await fork.service.launchPlan(input("GATE"), from: wallet.address, expectedLaunchFee: open.launchFee, expectedEconomics: mon.economicsHash)
            XCTFail("the plan must refuse a launch the factory would refuse")
        } catch {
            XCTAssertEqual(error as? LaunchpadError, .launchBlocked(.notAllowed))
        }
        let notWhitelisted = await refusal(fork, await raw("GATE"), wallet)
        XCTAssertEqual(notWhitelisted, sentence("NotWhitelisted"))
        try await sendAs(fork, fork.owner, to: factory, "setWhitelistEnabled(bool)", [.bool(false)])

        try await sendAs(fork, fork.owner, to: factory, "setLaunchConfigEnabled(uint256,bool)", [.uint(0), .bool(false)])
        let closed = try await info(fork, wallet.address)
        XCTAssertEqual(closed.launchBlocker, .configDisabled)
        let disabled = await refusal(fork, await raw("SHUT"), wallet)
        XCTAssertEqual(disabled, sentence("LaunchConfigDisabled"))
        try await sendAs(fork, fork.owner, to: factory, "setLaunchConfigEnabled(uint256,bool)", [.uint(0), .bool(true)])

        // Terms that aren't the factory's: LaunchEconomicsMismatch, in the launch screen's own words.
        var stale = input("STALE")
        stale.expectedEconomics = Data(repeating: 0x5a, count: 32)
        let mismatch = await refusal(fork, await fork.service.launchPlan(stale, launchFee: open.launchFee, from: wallet.address), wallet)
        XCTAssertEqual(mismatch, LaunchpadError.termsChanged.errorDescription)
        XCTAssertEqual(wallet.signatures, 0, "nothing was signed")
        let reopened = try await info(fork, wallet.address)
        XCTAssertNil(reopened.launchBlocker)
    }

    // MARK: Hook fees

    /// A fee-sharing MON launch graduates on Uniswap v4; a swap through the app's route pays the holders' cut to fee
    /// sharing in the swap (HolderFeesForwarded, queued for the next block) and keeps DyorHQ's in pendingProtocolFees,
    /// which the coin page counts.
    func testAV4SwapOnAFeeSharingLaunchPaysHoldersInTheSwap() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        let launched = try await launch(fork, input("SHARE"), wallet)
        XCTAssertEqual(launched.generation, .v2)
        try await completeCurve(fork, launched, wallet)
        let graduatedRead = try await fork.service.launch(token: launched.token)
        let graduated = try XCTUnwrap(graduatedRead)
        XCTAssertEqual(graduated.launch.phase, .graduated)
        XCTAssertEqual(graduated.launch.graduationVenue, .uniswapV4)

        let multicall = Multicall(rpc: fork.rpc)
        let venue = UniswapVenue(multicall: multicall, v3: V3Router(multicall: multicall), launchpadFactories: [fork.launchpad.factory])
        let coin = Token(address: launched.token, symbol: launched.symbol, name: launched.name, decimals: 18, isLaunchpad: true)
        let quoteRead = try await venue.quote(SwapRequest(tokenIn: .mon, tokenOut: coin, amountIn: BigUInt(100) * BigUInt(10).power(18), slippageBps: 500, account: wallet.address))
        let quote = try XCTUnwrap(quoteRead, "the graduated pool is a v4 route")
        XCTAssertTrue(quote.route.hasPrefix("v4"), quote.route)
        let hash = try await run(fork, try await quote.build(wallet.address), wallet)
        let logsRead = try await fork.rpc.transactionLogs(hash)
        let logs = try XCTUnwrap(logsRead)
        XCTAssertTrue(logs.contains { $0.address == fork.launchpad.hook && $0.topics.first == LaunchpadABI.Events.holderFeesForwardedTopic }, "HolderFeesForwarded in the swap")

        let afterRead = try await fork.service.launch(token: launched.token)
        let after = try XCTUnwrap(afterRead)
        XCTAssertEqual(after.hookPendingFees, 0, "the holders' cut left in the swap")
        XCTAssertGreaterThan(after.hookPendingProtocolFees, 0)
        XCTAssertGreaterThan(after.queuedRewards, 0)
        XCTAssertEqual(after.hookFeesAwaitingSweep, after.hookPendingTax + after.hookPendingProtocolFees)
    }

    // MARK: Graduation fallback

    /// The fallback rule's reads on a real factory: an aBIL launch is Monday-only from launch, a stuck MON Monday launch is
    /// not, so its fallback is open at once; the app plans no fallback (the keepers send it), a fallback sent anyway under
    /// 22,062,500 gas is refused with its sentence, and Retry Graduation finishes on Monday once the venue works again.
    func testAStuckMondayLaunchOnARealV2Factory() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        typealias F = LaunchpadABI.Factory
        let abil = try await launch(fork, input("RWA", pair: Token.abil.address, venue: .monday, sharing: false), wallet)
        XCTAssertEqual(abil.graduationVenue, .monday)
        let snapshot = try await Multicall(rpc: fork.rpc).readAll([
            LaunchpadABI.call(fork.launchpad.factory, F.launchMondayOnly, [.address(abil.token)], returns: "bool"),
            LaunchpadABI.call(fork.launchpad.factory, F.v4FallbackAllowed, [.address(abil.token)], returns: "bool"),
        ])
        XCTAssertTrue(snapshot[0][0].bool, "launchMondayOnly: the launch-time snapshot")
        XCTAssertFalse(snapshot[1][0].bool)

        // A MON launch on Monday Trade whose graduation fails: the Monday executor is broken on the fork only.
        let monday = try await launch(fork, input("STUCK", venue: .monday, sharing: false), wallet)
        let code = try await fork.rpc.call("eth_getCode", [.string(fork.mondayExecutor.hex), .string("latest")])
        _ = try await fork.rpc.call("anvil_setCode", [.string(fork.mondayExecutor.hex), .string("0xfe")])
        try await completeCurve(fork, monday, wallet)
        let stuckRead = try await fork.service.launch(token: monday.token)
        let stuck = try XCTUnwrap(stuckRead)
        XCTAssertEqual(stuck.launch.phase, .bonding)
        XCTAssertTrue(stuck.launch.completed)
        XCTAssertGreaterThan(stuck.stuckSince, 0)
        XCTAssertEqual(stuck.fallbackRule, GraduationFallbackRule(mondayOnly: false, allowed: false, delay: 86_400))
        XCTAssertEqual(stuck.v4FallbackOpensAt, stuck.stuckSince, "not Monday-only: open as soon as it is stuck")
        XCTAssertTrue(stuck.launch.keepersTakeGraduateFallback)
        let plan = await fork.service.graduateFallbackPlan(launch: stuck.launch)
        XCTAssertTrue(plan.isEmpty, "the app never sends v2's graduateFallback")

        let head = try await fork.rpc.call("eth_getBlockByNumber", [.string("latest"), .bool(false)])
        if let gas = head["gasLimit"].string.flatMap({ BigUInt(hexQuantity: $0) }), gas < 22_062_500 {
            let fallback = TransactionStep.call(TransactionRequest(to: fork.launchpad.factory, data: LaunchpadABI.calldata(F.graduateFallback, [.address(monday.token)])), label: "Fallback")
            let why = await refusal(fork, [fallback], wallet)
            XCTAssertEqual(why, sentence("InsufficientGasForGraduation"))
        } else {
            print("LaunchpadV2ForkTests: the fork's block gas limit is 22,062,500 or more, so InsufficientGasForGraduation isn't triggered here")
        }
        XCTAssertEqual(wallet.signatures, 3, "two launches and one curve buy signed; no fallback")

        // Retry Graduation: plain graduate, gas estimated, on the creator's venue once it works again.
        _ = try await fork.rpc.call("anvil_setCode", [.string(fork.mondayExecutor.hex), code])
        _ = try await run(fork, await fork.service.graduatePlan(launch: stuck.launch), wallet)
        let doneRead = try await fork.service.launch(token: monday.token)
        let done = try XCTUnwrap(doneRead)
        XCTAssertEqual(done.launch.phase, .graduated)
        XCTAssertEqual(done.launch.graduationVenue, .monday)
        XCTAssertEqual(done.stuckSince, 0)
    }
}
