import BigInt
import XCTest
@testable import DyorKit

/// The Launch tab's public board lists the live launchpad's coins and a retired launchpad's only once graduated
/// (`Launch.listsOnBoard`, owner decision 2026-09-29): QT stays in Graduated, without the "Retired launchpad" caption; the
/// retired sell-only coins leave the board, and only a wallet holding one sees it, under "Your Sell-Only Coins"
/// (`LaunchBoard.heldSellOnly`). Home and My Launchpad no longer list a created sell-only coin at a zero balance. Every
/// route to a coin's page without its launch goes by reference (`LaunchpadCurveRoutingTests`).
final class LaunchBoardTests: XCTestCase {
    private static let deployerA = Address(literal: "0x6115cAF237026B45B037191B20056d1e4AfAfFa3")
    private static let deployerB = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")
    private static let abil = Address(literal: "0x4FC5B9f8933597D3ecf84d0611687E1Dc8DD576f")

    private static func launch(_ symbol: String, token: Address, factory: Address, phase: LaunchPhase = .bonding, completed: Bool = false, rescued: Bool = false,
                               pair: Address = .zero, deployer: Address = deployerA, launchedAt: Int = 1_789_000_000) -> Launch {
        let info = pair.isZero ? PairInfo.mon : PairInfo(address: pair, symbol: "aBIL", decimals: 18, isNative: false)
        return Launch(token: token, curve: .zero, deployer: deployer, creatorFeeRecipient: deployer, pairToken: pair, graduationThreshold: 1_000, creatorTaxBps: 0,
                      poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .monday, phase: phase, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
                      poolId: Data(count: 32), name: symbol, symbol: symbol, logo: "", description: "", socials: .none, pair: info, price: 0, realQuoteReserve: 0,
                      completed: completed, rescued: rescued, launchedAt: launchedAt, supply: 0, marketCap: 0, progressBps: 0, factory: factory)
    }

    /// A launch's states as the chain leaves them: climbing, completed with its graduation stuck (the record still says
    /// NotGraduated), swept mid-migration, graduated, and rescued into refund mode.
    private static let states: [(name: String, phase: LaunchPhase, completed: Bool, rescued: Bool)] = [
        ("climbing", .bonding, false, false), ("stuck", .bonding, true, false), ("migrating", .migrating, true, false),
        ("graduated", .graduated, true, false), ("refund", .refund, true, true),
    ]

    private static let coin = Address(literal: "0x00000000000000000000000000000000000b0a2d")

    // MARK: The rule

    /// Every retired stack, in every state: listed only once graduated. The live stack (v2, or `.zero` for the live one):
    /// listed in every state.
    func testOnlyGraduatedRetiredCoinsListOnBoard() {
        for stack in LaunchpadAddresses.retiredStacks {
            for state in Self.states {
                let launch = Self.launch("OLD", token: Self.coin, factory: stack.factory, phase: state.phase, completed: state.completed, rescued: state.rescued)
                let label = "\(stack.factory.short) \(state.name)"
                XCTAssertEqual(launch.listsOnBoard, state.phase == .graduated, label)
                XCTAssertEqual(launch.listsOnBoard, !launch.isSellOnly, label)
            }
        }
        for factory in [V2Fixture.launchpad.factory, LaunchpadAddresses.monadMainnet.factory, .zero] {
            for state in Self.states {
                let launch = Self.launch("NEW", token: Self.coin, factory: factory, phase: state.phase, completed: state.completed, rescued: state.rescued)
                XCTAssertTrue(launch.listsOnBoard, "\(factory.short) \(state.name): the live launchpad's coins all list")
            }
        }
    }

    /// Mainnet as read on 2026-09-29 (block ~109,001,778, `retired_scan.sh`): no launch on v2 or 0x6B1C; LP on 0x10F3;
    /// GMGM and BPP on 0x2F02; QT (graduated on Monday Trade), JUST, BB and BP on 0xad3d. The board lists exactly QT; the
    /// other six are sell-only.
    static let mainnet: [Launch] = {
        let (v1, preAudit, legacy) = (LaunchpadAddresses.retiredStacks[1].factory, LaunchpadAddresses.retiredStacks[2].factory, LaunchpadAddresses.retiredStacks[3].factory)
        return [
            launch("LP", token: Address(literal: "0xA4D9b2697254292ad30e06Ce968a7e18De6fF884"), factory: v1, launchedAt: 1_789_723_646),
            launch("GMGM", token: Address(literal: "0x74b215C1788A90aAF45A33f83584C1a04ba402b8"), factory: preAudit, launchedAt: 1_789_246_995),
            launch("BPP", token: Address(literal: "0xB281906b67b6EFed8C805c8595888255a0F46979"), factory: preAudit, launchedAt: 1_789_304_794),
            launch("QT", token: Address(literal: "0x73F942e084Ab047a94e4E3B5D6ae571e23A51856"), factory: legacy, phase: .graduated, completed: true, deployer: deployerB, launchedAt: 1_789_044_098),
            launch("JUST", token: Address(literal: "0xCD83D45F985BB42b7d6ABB1f2cC12860B4610c3D"), factory: legacy, pair: abil, deployer: deployerB, launchedAt: 1_789_084_173),
            launch("BB", token: Address(literal: "0x40C5bebd974fb622A42ce68823F514ca03f48666"), factory: legacy, pair: abil, launchedAt: 1_789_145_677),
            launch("BP", token: Address(literal: "0x959B3a85a1Db6a60595Ce7B31Dd1e91acfa977bf"), factory: legacy, pair: abil, launchedAt: 1_789_214_558),
        ]
    }()

    func testTheMainnetBoardListsOnlyQT() throws {
        XCTAssertEqual(LaunchpadAddresses.retiredStacks.map(\.generation), [.v1, .v1, .preAudit, .legacy], "the fixture's stacks")
        let listed = Self.mainnet.filter(\.listsOnBoard)
        XCTAssertEqual(listed.map(\.symbol), ["QT"])
        XCTAssertEqual(listed.first?.phase.boardSection, .graduated)
        XCTAssertEqual(Self.mainnet.filter(\.isSellOnly).map(\.symbol), ["LP", "GMGM", "BPP", "JUST", "BB", "BP"])
        XCTAssertTrue(Self.mainnet.allSatisfy(\.isRetiredLaunchpad))
        // What a card and a page say: QT has no "Retired launchpad" caption (it trades both ways on Swap), a sell-only coin
        // has it, and buys on the curve are closed for all.
        let qt = try XCTUnwrap(listed.first)
        XCTAssertFalse(qt.isSellOnly)
        XCTAssertEqual(qt.statusTitle, "Graduated")
        XCTAssertNil(RetiredLaunchpad.tokenPageNotice(qt), "an ordinary pool coin")
        XCTAssertTrue(Self.mainnet.allSatisfy { !$0.curveBuysOpen })

        // Home and My Launchpad: a created coin at a zero balance is listed only while the board lists it. 0x90f3 (QT and
        // JUST) keeps QT; 0x6115 (LP, GMGM, BPP, BB, BP) keeps none.
        XCTAssertEqual(Self.mainnet.filter { $0.deployer == Self.deployerB && $0.listsOnBoard }.map(\.symbol), ["QT"])
        XCTAssertEqual(Self.mainnet.filter { $0.deployer == Self.deployerA && $0.listsOnBoard }.map(\.symbol), [])
    }

    // MARK: Your Sell-Only Coins

    /// Only a held sell-only coin, newest first; nothing for a wallet holding none, and QT, held or not, stays on the board
    /// instead. A balance missing from the read (it failed) gives nil: the section keeps what it showed.
    func testTheHolderSectionListsOnlyHeldSellOnlyCoins() throws {
        let lpHolder: [Address: BigUInt] = Dictionary(uniqueKeysWithValues: Self.mainnet.map { ($0.token, $0.symbol == "LP" ? BigUInt("53767618731390950444223") : 0) })
        XCTAssertEqual(try XCTUnwrap(LaunchBoard.heldSellOnly(Self.mainnet, balances: lpHolder)).map(\.symbol), ["LP"])

        let none = Dictionary(uniqueKeysWithValues: Self.mainnet.map { ($0.token, BigUInt(0)) })
        XCTAssertEqual(LaunchBoard.heldSellOnly(Self.mainnet, balances: none), [])

        var everything = Dictionary(uniqueKeysWithValues: Self.mainnet.map { ($0.token, BigUInt(1)) })
        let held = try XCTUnwrap(LaunchBoard.heldSellOnly(Self.mainnet, balances: everything))
        XCTAssertEqual(held.map(\.symbol), ["LP", "BPP", "GMGM", "BP", "BB", "JUST"], "newest first, QT left on the board")

        // QT's balance isn't needed; a sell-only coin's is.
        everything[Self.mainnet[3].token] = nil
        XCTAssertNotNil(LaunchBoard.heldSellOnly(Self.mainnet, balances: everything))
        var partial = lpHolder
        partial[Self.mainnet[1].token] = nil
        XCTAssertNil(LaunchBoard.heldSellOnly(Self.mainnet, balances: partial), "a failed balance read changes nothing")
        XCTAssertEqual(LaunchBoard.heldSellOnly([], balances: [:]), [])
    }

    // MARK: The screens

    /// The board shows the holder section last, only for the signed-in wallet's coins (cleared on an account change, kept
    /// on a failed read), and an Explore card inviting a launch when nothing is on the live curve; a card and a page carry
    /// "Retired launchpad" only for a sell-only coin, and the old copy that sent holders to the board is gone.
    func testTheBoardHidesSellOnlyCoinsAndShowsTheirHolders() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadView.swift"), encoding: .utf8)

        // The holder section: after the public sections, searched, counted in the empty check.
        let refund = try XCTUnwrap(source.range(of: "section(title: \"Refund & Migrating\""))
        let holders = try XCTUnwrap(source.range(of: "section(title: \"Your Sell-Only Coins\", count: sellOnly.count,"))
        XCTAssertLessThan(refund.lowerBound, holders.lowerBound, "shown last")
        XCTAssertTrue(source.contains("private var sellOnly: [Launch] { searched(model.heldSellOnly) }"))
        XCTAssertTrue(source.contains("if graduated.isEmpty, climbing.isEmpty, refundAndMigrating.isEmpty, sellOnly.isEmpty, !model.loading {"))

        // The model: cleared on another account before any read, published only for the account it was read for, kept
        // when the balances can't be read, and decided by `LaunchBoard.heldSellOnly`.
        let model = try XCTUnwrap(source.range(of: "final class LaunchpadModel {"))
        let modelEnd = try XCTUnwrap(source.range(of: "struct LaunchDetailView: View {", range: model.upperBound..<source.endIndex))
        let modelSource = String(source[model.upperBound..<modelEnd.lowerBound])
        let cleared = try XCTUnwrap(modelSource.range(of: "if account != loadedFor {\n            heldSellOnly = []\n            loadedFor = account\n        }"))
        let read = try XCTUnwrap(modelSource.range(of: "launches = try await env.launchpad.allLaunches(limit: 60)"))
        XCTAssertLessThan(cleared.lowerBound, read.lowerBound, "cleared before any read")
        XCTAssertTrue(modelSource.contains("if let held = await Self.heldSellOnly(env: env, account: account, launches: launches), !Task.isCancelled, account == loadedFor {\n            heldSellOnly = held\n        }"))
        XCTAssertTrue(modelSource.contains("guard let balances = try? await ERC20.balances(of: tokens, owner: account, rpc: env.rpc, multicall: env.multicall) else { return nil }"))
        XCTAssertTrue(modelSource.contains("return LaunchBoard.heldSellOnly(sellOnly, balances: balances)"))
        XCTAssertEqual(modelSource.components(separatedBy: "heldSellOnly = ").count - 1, 2, "set only when cleared and when read for this account")

        // The Explore card: only on the live launchpad, without a search, after the first load; Launch a Coin needs a
        // wallet that signs.
        XCTAssertTrue(source.contains("if env.config.launchpad.isDeployed, !searching, !(model.loading && model.launches.isEmpty) {\n                exploreEmptyCard"))
        XCTAssertTrue(source.contains("private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }"))
        // A search that finds nothing (a hidden coin's name, say) says so, instead of "No Launches Yet".
        XCTAssertTrue(source.contains("if searching { ContentUnavailableView.search(text: query).padding(.top, 40) } else { emptyState }"))
        let card = try XCTUnwrap(source.range(of: "private var exploreEmptyCard: some View {"))
        let cardEnd = try XCTUnwrap(source.range(of: "private func sectionHeader(", range: card.upperBound..<source.endIndex))
        let cardSource = String(source[card.upperBound..<cardEnd.lowerBound])
        XCTAssertTrue(cardSource.contains("Text(\"No coins on the curve yet: launch the first one.\")"))
        XCTAssertTrue(cardSource.contains("Button { Haptics.tap(); showCreate = true } label: { Text(\"Launch a Coin\").fontWeight(.semibold) }\n                    .buttonStyle(.borderedProminent).disabled(!session.canSign)"))

        // Captions: a sell-only coin's only. QT reads "Graduated".
        XCTAssertTrue(source.contains("if launch.isSellOnly { Text(\"Retired launchpad\")"))
        XCTAssertTrue(source.contains("Text(launch.isSellOnly ? \"\\(launch.statusTitle) · Retired launchpad\" : launch.statusTitle)"))
        XCTAssertFalse(source.contains("if launch.isRetiredLaunchpad { Text(\"Retired launchpad\")"))
        XCTAssertTrue(source.contains("if launch.isSellOnly {\n            // Only under Your Sell-Only Coins: the public board lists none.\n            Text(\"Sell only\")"))

        // No copy sends anyone to the board for a hidden coin, and the unused list row is gone.
        XCTAssertTrue(source.contains("Label(\"New launches open soon.\", systemImage: \"clock\")"))
        XCTAssertFalse(source.contains("can be sold here, but not bought"))
        XCTAssertFalse(source.contains("CurveRoute.launchTab"))
        XCTAssertFalse(source.contains("struct LaunchRow"))
    }
}
