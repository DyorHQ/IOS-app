import BigInt
import XCTest
@testable import DyorKit

/// Coins on a retired launchpad's curve are sell-only (owner decision 2026-09-28): on each of the four retired stacks a
/// curve buy is refused at the plan, whatever the pair or phase, and so is a developer buy through a retired router,
/// while a sell on the same curve still plans. The live (v2) stack's buys are unaffected. The coin page trades on the
/// curve only while it takes a sell (refund mode included), and Home's token page and the Portfolio's holdings find a
/// sell-only coin's launch so they can send the holder there: no Swap venue routes a bonding curve.
final class RetiredLaunchpadTests: XCTestCase {
    private let token = Address(literal: "0x00000000000000000000000000000000000d1100")
    private let curve = Address(literal: "0x00000000000000000000000000000000000d11c0")
    private let recipient = Address(literal: "0x000000000000000000000000000000000000beef")
    private let quoteIn = BigUInt(750_000_000)
    private var usdcPair: PairInfo { PairInfo(address: Monad.usdc, symbol: "USDC", decimals: 6, isNative: false) }

    private var retired: [LaunchpadAddresses] { LaunchpadAddresses.retiredStacks }

    override func setUp() {
        super.setUp()
        MomentsChainStub.install { _, _ in nil }
    }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func service(_ addresses: LaunchpadAddresses = V2Fixture.launchpad) -> LaunchpadService {
        LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: addresses, logsRPC: MomentsChainStub.rpc())
    }

    private func launch(on factory: Address, pair: PairInfo = .mon, phase: LaunchPhase = .bonding, completed: Bool = false, rescued: Bool = false) -> Launch {
        Launch(token: token, curve: curve, deployer: recipient, creatorFeeRecipient: recipient, pairToken: pair.address, graduationThreshold: 1_000, creatorTaxBps: 0,
               poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: true, graduationVenue: .uniswapV4, phase: phase, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
               poolId: Data(count: 32), name: "Old", symbol: "OLD", logo: "", description: "", socials: .none, pair: pair, price: 0, realQuoteReserve: 0,
               completed: completed, rescued: rescued, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0, factory: factory)
    }

    /// A launch's states as the chain leaves them: climbing, completed with its graduation stuck (the record still says
    /// NotGraduated), swept mid-migration, graduated, and rescued into refund mode.
    private static let states: [(name: String, phase: LaunchPhase, completed: Bool, rescued: Bool)] = [
        ("climbing", .bonding, false, false), ("stuck", .bonding, true, false), ("migrating", .migrating, true, false),
        ("graduated", .graduated, true, false), ("refund", .refund, true, true),
    ]

    private func sellOnlyInput(initialBuy: BigUInt) -> LaunchInput {
        LaunchInput(name: "Old", symbol: "OLD", pairToken: .zero, initialBuy: initialBuy, minTokensOut: 1, expectedEconomics: Data(repeating: 0xab, count: 32))
    }

    // MARK: Which coins

    func testEveryRetiredStackIsSellOnlyUntilItsCoinsGraduate() {
        XCTAssertEqual(retired.map(\.factory), [
            Address(literal: "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB"),
            Address(literal: "0x10F34A174d9C393a90aFf94BDED7E1Db185446D7"),
            Address(literal: "0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4"),
            Address(literal: "0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea"),
        ])
        XCTAssertEqual(LaunchpadAddresses.retiredRouters, retired.map(\.router))
        for stack in retired {
            XCTAssertTrue(LaunchpadAddresses.isRetired(stack.factory))
            for phase in LaunchPhase.allCases {
                let coin = launch(on: stack.factory, phase: phase)
                XCTAssertTrue(coin.isRetiredLaunchpad)
                XCTAssertEqual(coin.isSellOnly, phase != .graduated, "\(stack.factory.short) \(phase.title): a graduated coin trades both ways")
            }
        }
        // The live stack (v2; `.zero` means the live one) and a stack the app doesn't know are not retired.
        for factory in [Address.zero, V2Fixture.launchpad.factory, Address(literal: "0x00000000000000000000000000000000000f00d0")] {
            XCTAssertFalse(LaunchpadAddresses.isRetired(factory))
            for phase in LaunchPhase.allCases {
                XCTAssertFalse(launch(on: factory, phase: phase).isRetiredLaunchpad)
                XCTAssertFalse(launch(on: factory, phase: phase).isSellOnly)
            }
        }
        XCTAssertEqual(RetiredLaunchpad.notice, "This coin's launchpad is retired: you can sell, but not buy.")
    }

    // MARK: Plans

    /// A curve buy on each retired stack, MON or ERC-20 pair, in every phase: refused before any step is built, so not even
    /// the approval is signed.
    func testABuyOnEveryRetiredCurveIsRefusedAtThePlan() async {
        let service = service()
        for stack in retired {
            for pair in [PairInfo.mon, usdcPair] {
                for phase in LaunchPhase.allCases {
                    let label = "\(stack.factory.short) \(pair.symbol) \(phase.title)"
                    do {
                        let plan = try await service.buyPlan(launch: launch(on: stack.factory, pair: pair, phase: phase), quoteIn: quoteIn, minTokensOut: 1, recipient: recipient)
                        XCTFail("\(label): a buy on a retired curve was planned: \(plan.map(\.label))")
                    } catch {
                        XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad, label)
                    }
                }
            }
        }
        XCTAssertEqual(LaunchpadError.retiredLaunchpad.errorDescription, "This coin's launchpad is retired: you can sell, but not buy. Nothing was sent.")
        XCTAssertTrue(MomentsChainStub.calls().isEmpty, "refused without asking the chain")
    }

    /// Holders can still sell into each retired curve: approve the coin for the curve, then `sell`, paid to them.
    func testASellOnEveryRetiredCurveStillPlans() async {
        let service = service()
        for stack in retired {
            for phase in [LaunchPhase.bonding, .refund] {
                let plan = await service.sellPlan(launch: launch(on: stack.factory, phase: phase), tokensIn: 5_000, minQuoteOut: 1, recipient: recipient)
                XCTAssertEqual(plan.count, 2, stack.factory.short)
                XCTAssertEqual(plan[0].kind, .approve(token: token, spender: curve, amount: 5_000))
                XCTAssertEqual(plan[1].request?.to, curve)
                XCTAssertEqual(plan[1].request?.data, LaunchpadABI.calldata(LaunchpadABI.Curve.sell, [.uint(5_000), .uint(1), .address(recipient)]))
                XCTAssertEqual(plan[1].request?.value, 0)
            }
        }
    }

    /// The live (v2) stack's curve buys are unaffected: native MON on `value`, an ERC-20 pair approved first.
    func testAV2CurveBuyStillPlans() async throws {
        let service = service()
        for factory in [Address.zero, V2Fixture.launchpad.factory] {
            let native = try await service.buyPlan(launch: launch(on: factory), quoteIn: quoteIn, minTokensOut: 1, recipient: recipient)
            XCTAssertEqual(native.count, 1)
            XCTAssertEqual(native[0].request?.to, curve)
            XCTAssertEqual(native[0].request?.data, LaunchpadABI.calldata(LaunchpadABI.Curve.buy, [.uint(quoteIn), .uint(1), .address(recipient)]))
            XCTAssertEqual(native[0].request?.value, quoteIn)
            let erc20 = try await service.buyPlan(launch: launch(on: factory, pair: usdcPair), quoteIn: quoteIn, minTokensOut: 1, recipient: recipient)
            XCTAssertEqual(erc20.map(\.kind), [.approve(token: Monad.usdc, spender: curve, amount: quoteIn), .call])
            XCTAssertEqual(erc20[1].request?.value, 0)
        }
    }

    /// A build pointed at a retired stack (a misconfigured Debug override, say) plans no developer buy through its
    /// router: the sync plan and the app's async plan refuse it, the latter before any read. A launch without one is not
    /// a buy (the retired factory refuses it on chain anyway: its whitelist is on). v2's developer buy still plans.
    func testADeveloperBuyThroughARetiredRouterIsRefused() async throws {
        for stack in retired {
            let service = service(stack)
            do {
                let plan = try await service.launchPlan(sellOnlyInput(initialBuy: quoteIn), launchFee: 0, from: recipient)
                XCTFail("\(stack.router.short): launchAndBuy was planned: \(plan.map(\.label))")
            } catch {
                XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad)
            }
            do {
                let plan = try await service.launchPlan(sellOnlyInput(initialBuy: quoteIn), from: recipient)
                XCTFail("\(stack.router.short): launchAndBuy was planned: \(plan.map(\.label))")
            } catch {
                XCTAssertEqual(error as? LaunchpadError, .retiredLaunchpad)
            }
            let plain = try await service.launchPlan(sellOnlyInput(initialBuy: 0), launchFee: 0, from: recipient)
            XCTAssertEqual(plain.map { $0.request?.to }, [stack.factory])
        }
        XCTAssertTrue(MomentsChainStub.calls().isEmpty, "refused before the fee, the terms or the gate were read")
        let live = try await service().launchPlan(sellOnlyInput(initialBuy: quoteIn), launchFee: 5, from: recipient)
        XCTAssertEqual(live.map { $0.request?.to }, [V2Fixture.launchpad.router])
        XCTAssertEqual(live[0].request?.value, 5 + quoteIn)
    }

    // MARK: The coin page

    /// The curve ticket shows while the curve takes a sell: climbing, or in refund mode (fee-free, and on every stack
    /// without Buy). A completed curve still waiting to graduate refuses sells (`CurveNotTrading`): it is "Graduation
    /// pending", with Retry Graduation and the keepers' note, as is nothing mid-migration or graduated. Buying is open only
    /// on a climbing curve of the live stack.
    func testTheCoinPageTradesOnTheCurveOnlyWhileItTakesSells() {
        for factory in [V2Fixture.launchpad.factory] + retired.map(\.factory) {
            let isRetired = LaunchpadAddresses.isRetired(factory)
            for state in Self.states {
                let coin = launch(on: factory, phase: state.phase, completed: state.completed, rescued: state.rescued)
                let label = "\(factory.short) \(state.name)"
                XCTAssertEqual(coin.curveSellsOpen, ["climbing", "refund"].contains(state.name), label)
                XCTAssertEqual(coin.curveBuysOpen, state.name == "climbing" && !isRetired, label)
                XCTAssertEqual(coin.awaitsGraduation, state.name == "stuck", label)
                XCTAssertEqual(coin.statusTitle, state.name == "stuck" ? "Graduation pending" : state.phase.title, label)
                // Sell-only (no buy) on a retired launchpad until it graduates; graduated, it trades both ways on Swap.
                XCTAssertEqual(coin.isSellOnly, isRetired && state.phase != .graduated, label)
            }
        }
    }

    /// The sources wire those answers in: the coin page picks its ticket by `curveSellsOpen` and offers Retry Graduation
    /// only while the launch awaits it; Home's token page and the Portfolio's holdings send a sell-only coin to its Launch
    /// page, never to Swap.
    func testTheScreensFollowTheCurveState() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let launchpad = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadView.swift"), encoding: .utf8)
        XCTAssertTrue(launchpad.contains("if launch.curveSellsOpen { ticketSection } else { graduatedSection }"))
        XCTAssertTrue(launchpad.contains("private var isStuck: Bool { launch.awaitsGraduation && (detail?.stuckSince ?? 0) > 0 }"))
        XCTAssertFalse(launchpad.contains("if launch.phase == .bonding { ticketSection }"))
        let home = try String(contentsOf: app.appendingPathComponent("Home/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("env.launchpad.retiredLaunch(token: row.token.address)"))
        XCTAssertTrue(home.contains("router.openLaunch(retiredLaunch)"))
        XCTAssertFalse(home.contains("router.openSwap(tokenIn: row.token,"), "no Swap that sells the page's coin: none routes a curve")

        // The Portfolio's holdings: the check lands before the list shows, and a sell-only coin's row opens its Launch
        // page (or, unread, opens nothing); only the other coins reach Swap.
        let assets = try String(contentsOf: app.appendingPathComponent("Portfolio/AssetsModel.swift"), encoding: .utf8)
        XCTAssertTrue(assets.contains("async let sellOnlyTask = try? env.launchpad.retiredCurveHoldings(held)"))
        let checked = try XCTUnwrap(assets.range(of: "if let found = await sellOnlyTask {"))
        let listed = try XCTUnwrap(assets.range(of: "tokens = held.map {"))
        XCTAssertLessThan(checked.lowerBound, listed.lowerBound, "known before the token list shows")
        let sellOnlyRow = try XCTUnwrap(assets.range(of: "} else if model.sellOnly.contains(asset.token.address) {"))
        let swapRow = try XCTUnwrap(assets.range(of: "Button { router.openSwap(tokenIn: asset.token,"))
        XCTAssertLessThan(sellOnlyRow.lowerBound, swapRow.lowerBound, "a sell-only coin is caught before the Swap row")
        let branch = String(assets[sellOnlyRow.upperBound..<swapRow.lowerBound])
        XCTAssertTrue(branch.contains("if let launch = model.retiredLaunches[asset.token.address] {"))
        XCTAssertTrue(branch.contains("Button { router.openLaunch(launch); dismiss() }"))
        XCTAssertTrue(branch.contains("tokenRow(asset, note: \"Sell it from its page on the Launch tab\""))
        XCTAssertFalse(branch.contains("openSwap"))
        XCTAssertEqual(assets.components(separatedBy: "router.openSwap(").count - 1, 1, "one Swap row, for the other coins")
    }

    // MARK: Home's token page

    /// Home knows only the coin: its launch is found on whichever retired stack recorded it (one aggregate over the four
    /// factories, then that launch's own reads), in every phase, and says what the page shows. A coin no retired
    /// factory launched has none.
    func testHomeFindsASellOnlyCoinsLaunch() async throws {
        let service = service()
        for stack in retired {
            for state in Self.states {
                let chain = RetiredLaunchChain(base: RetiredCoinChain(stack: stack, phase: state.phase), completed: state.completed, rescued: state.rescued)
                MomentsChainStub.install(chain.answer)
                let label = "\(stack.factory.short) \(state.name)"
                let found = try await service.retiredLaunch(token: chain.base.coin)
                let launch = try XCTUnwrap(found, label)
                XCTAssertEqual(launch.token, chain.base.coin, label)
                XCTAssertEqual(launch.curve, chain.base.curve, label)
                XCTAssertEqual(launch.factory, stack.factory, label)
                XCTAssertEqual(launch.generation, stack.generation, label)
                XCTAssertEqual(launch.phase, state.phase, label)
                XCTAssertEqual(launch.symbol, "OLD", label)
                XCTAssertEqual(launch.curveSellsOpen, ["climbing", "refund"].contains(state.name), label)
                XCTAssertEqual(MomentsChainStub.batches().first?.map(\.to), LaunchpadAddresses.retiredFactories, "\(label): every retired factory, in one read")

                let notice = RetiredLaunchpad.tokenPageNotice(launch)
                switch state.name {
                case "climbing", "refund": XCTAssertEqual(notice, RetiredLaunchpad.sellOnLaunchPage, label)
                case "graduated": XCTAssertNil(notice, "\(label): trades both ways on Swap")
                default: XCTAssertEqual(notice, RetiredLaunchpad.graduationPending, label)
                }
            }
        }
        // A coin no retired factory launched: only the records are read.
        MomentsChainStub.install(RetiredCoinChain(stack: retired[0], phase: .bonding).answer)
        let stranger = try await service.retiredLaunch(token: token)
        XCTAssertNil(stranger)
        XCTAssertEqual(MomentsChainStub.batches().map { $0.map(\.to) }, [LaunchpadAddresses.retiredFactories])
        // Unread, the page still says where to sell it.
        XCTAssertEqual(RetiredLaunchpad.tokenPageNotice(nil), RetiredLaunchpad.sellOnLaunchPage)
        XCTAssertEqual(RetiredLaunchpad.sellOnLaunchPage, "This coin's launchpad is retired: you can sell it on its Launch page, but not buy.")
    }

    // MARK: The Portfolio's holdings

    /// The Portfolio lists every coin the wallet holds, and tapping one opened Swap, which can't trade a coin still on a
    /// retired curve. Among the holdings, such a coin is found on each retired stack, before graduation in every state,
    /// from one aggregate asking the four factories for each coin once (MON and the app's own tokens are never asked),
    /// with the launch its row opens. A graduated coin isn't: it trades on Swap.
    func testThePortfolioFindsASellOnlyHoldingsLaunch() async throws {
        let service = service()
        let other = Token(address: token, symbol: "NEW", name: "New coin", decimals: 18)
        for stack in retired {
            for state in Self.states {
                let chain = RetiredLaunchChain(base: RetiredCoinChain(stack: stack, phase: state.phase), completed: state.completed, rescued: state.rescued)
                MomentsChainStub.install(chain.answer)
                let label = "\(stack.factory.short) \(state.name)"
                let coin = Token(address: chain.base.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
                let found = try await service.retiredCurveHoldings([.mon, .usdc, coin, other, .wmon, coin])
                XCTAssertEqual(MomentsChainStub.batches().first?.map(\.to), LaunchpadAddresses.retiredFactories + LaunchpadAddresses.retiredFactories,
                               "\(label): the coin and the other token, each asked of every retired factory, in one read")
                if state.phase == .graduated {
                    XCTAssertEqual(found, RetiredCurveHoldings(coins: [], launches: [:]), label)
                    XCTAssertEqual(MomentsChainStub.batches().count, 1, "\(label): no launch is read")
                    continue
                }
                XCTAssertEqual(found.coins, [chain.base.coin], label)
                let launch = try XCTUnwrap(found.launches[chain.base.coin], label)
                XCTAssertEqual(Array(found.launches.keys), [chain.base.coin], label)
                XCTAssertEqual(launch.token, chain.base.coin, label)
                XCTAssertEqual(launch.curve, chain.base.curve, label)
                XCTAssertEqual(launch.factory, stack.factory, label)
                XCTAssertTrue(launch.isSellOnly, label)
                XCTAssertEqual(launch.curveSellsOpen, ["climbing", "refund"].contains(state.name), label)
            }
        }

        // Only MON and the app's own tokens: nothing is read.
        MomentsChainStub.install { _, _ in nil }
        let none = try await service.retiredCurveHoldings(Token.core + [.mon])
        XCTAssertEqual(none, RetiredCurveHoldings(coins: [], launches: [:]))
        XCTAssertTrue(MomentsChainStub.calls().isEmpty)
        // The check fails (every read reverts): it throws, and the screen keeps what it knew.
        do {
            let unchecked = try await service.retiredCurveHoldings([other])
            XCTFail("a failed check returned \(unchecked)")
        } catch {}
    }

    /// A coin still on its curve when the holdings were checked, graduated by the time its launch is read: an ordinary
    /// pool token again, left out so its row opens Swap. A coin whose launch can't be read stays sell-only, with no launch.
    func testAHoldingThatGraduatesOrCantBeReadMeanwhile() async throws {
        let service = service()
        for stack in retired {
            let climbing = RetiredLaunchChain(base: RetiredCoinChain(stack: stack, phase: .bonding), completed: false, rescued: false)
            let graduated = RetiredLaunchChain(base: RetiredCoinChain(stack: stack, phase: .graduated), completed: true, rescued: false)
            let coin = Token(address: climbing.base.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
            let records = RecordCount()
            let recordSelector = ABI.selector(LaunchpadABI.Factory.getLaunchedToken)
            // The holdings' aggregate (one record per retired factory) sees the curve; every read after it, the pool.
            MomentsChainStub.install { to, data in
                if data.prefix(4) == recordSelector { return (records.next() < LaunchpadAddresses.retiredFactories.count ? climbing : graduated).answer(to, data) }
                return graduated.answer(to, data)
            }
            let found = try await service.retiredCurveHoldings([coin])
            XCTAssertEqual(found, RetiredCurveHoldings(coins: [], launches: [:]), stack.factory.short)

            // The launch's own reads fail (only the records answer): still sell-only, never Swap; the row opens nothing.
            MomentsChainStub.install { to, data in data.prefix(4) == recordSelector ? climbing.answer(to, data) : nil }
            let unread = try await service.retiredCurveHoldings([coin])
            XCTAssertEqual(unread.coins, [climbing.base.coin], stack.factory.short)
            XCTAssertEqual(unread.launches, [:], stack.factory.short)
        }
    }
}

/// Counts calls across the stub's threads.
private final class RecordCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The number of calls before this one.
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { count += 1 }
        return count
    }
}

/// `RetiredCoinChain` plus the reads a launch is built from: the coin's name, symbol, token info and supply, and the
/// curve's price, reserve, launch time and its `completed` / `rescued` flags.
private struct RetiredLaunchChain: Sendable {
    let base: RetiredCoinChain
    let completed: Bool
    let rescued: Bool

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        typealias T = LaunchpadABI.Token
        typealias C = LaunchpadABI.Curve
        if to == base.coin {
            if is_(T.name) { return encode([.string("Old coin")], "string") }
            if is_(T.symbol) { return encode([.string("OLD")], "string") }
            if is_(T.totalSupply) { return encode([.uint(BigUInt(10).power(27))], "uint256") }
            if is_(T.getTokenInfo) { return encode([.address(base.coin), .string(""), .string(""), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,\(LaunchpadABI.socialsTuple)") }
        }
        if to == base.curve {
            if is_(C.price) || is_(C.realQuoteReserve) { return encode([.uint(1_000)], "uint256") }
            if is_(C.completed) { return encode([.bool(completed)], "bool") }
            if is_(C.rescued) { return encode([.bool(rescued)], "bool") }
            if is_(C.launchedAt) { return encode([.uint(1_789_000_000)], "uint64") }
        }
        return base.answer(to, data)
    }
}
