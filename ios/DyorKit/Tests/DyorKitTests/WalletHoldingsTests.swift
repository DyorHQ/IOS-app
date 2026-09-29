import BigInt
import XCTest
@testable import DyorKit

/// The held-token list the Portfolio's Assets and the Send sheet share: what is in it, its order, where a send starts,
/// search, and which tokens count as dollars.
final class WalletHoldingsTests: XCTestCase {
    private let meme = Token(address: Address(literal: "0x1111111111111111111111111111111111111111"), symbol: "MEME", name: "Meme Coin", decimals: 18)
    private let fakeUSDC = Token(address: Address(literal: "0x2222222222222222222222222222222222222222"), symbol: "USDC", name: "USD Coin", decimals: 6)
    private let launch = Token(address: Address(literal: "0x3333333333333333333333333333333333333333"), symbol: "LAUNCH", name: "Launch Coin", decimals: 18, isLaunchpad: true)
    private let spam = Token(address: Address(literal: "0x4444444444444444444444444444444444444444"), symbol: "VISIT", name: "Claim at visit.example", decimals: 18)

    private func units(_ whole: Double, _ token: Token) -> BigUInt { Amount.raw(whole, decimals: token.decimals) }

    func testZeroBalancesAndUnreadBalancesAreLeftOut() {
        let universe = [Token.mon, Token.wmon, Token.usdc, meme, launch]
        let balances: [Address: BigUInt] = [Monad.native: 0, Monad.wmon: units(2, .wmon), Monad.usdc: 0, meme.address: units(5, meme)]
        let held = WalletHoldings.held(universe, balances: balances)
        XCTAssertEqual(held.map(\.symbol), ["WMON", "MEME"], "zero balances and a balance that couldn't be read are not held")
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: [Monad.native: 0.03, Monad.usdc: 1], unverified: [])
        XCTAssertFalse(ranked.contains { $0.balance == 0 })
        XCTAssertEqual(Set(ranked.map(\.id)), [Monad.wmon, meme.address])
    }

    func testDuplicateTokensAreListedOnce() {
        let held = WalletHoldings.held([Token.usdc, meme, Token.usdc], balances: [Monad.usdc: 1, meme.address: 1])
        XCTAssertEqual(held.map(\.address), [Monad.usdc, meme.address])
    }

    func testPricedTokensAreOrderedByDollarValueHighestFirst() {
        let universe = [Token.mon, Token.usdc, Token.wmon, meme]
        let balances: [Address: BigUInt] = [Monad.native: units(100, .mon), Monad.usdc: units(40, .usdc), Monad.wmon: units(1_000, .wmon), meme.address: units(40, meme)]
        let prices: [Address: Double] = [Monad.native: 0.5, Monad.usdc: 1, Monad.wmon: 0.5, meme.address: 0.25]
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: prices, unverified: [])
        // WMON $500, MON $50, USDC $40, MEME $10.
        XCTAssertEqual(ranked.map(\.token.symbol), ["WMON", "MON", "USDC", "MEME"])
        XCTAssertEqual(ranked.compactMap(\.value), [500, 50, 40, 10])
    }

    func testUnpricedTokensComeAfterEveryPricedOneChosenBeforeUnverifiedThenByAmount() {
        let universe = [spam, launch, meme, Token.usdc, Token.mon]
        let balances: [Address: BigUInt] = [spam.address: units(9_000_000, spam), launch.address: units(10, launch), meme.address: units(500, meme),
                                            Monad.usdc: units(0.01, .usdc), Monad.native: units(1, .mon)]
        // Only USDC ($0.01) and MON ($0.02) have prices; an infinite price is no price at all.
        let prices: [Address: Double] = [Monad.usdc: 1, Monad.native: 0.02, launch.address: .infinity]
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: prices, unverified: [spam.address])
        XCTAssertEqual(ranked.map(\.token.symbol), ["MON", "USDC", "MEME", "LAUNCH", "VISIT"],
                       "priced first, however small; then chosen tokens by amount; the Unverified spam last despite its huge amount")
        XCTAssertNil(ranked.first { $0.token == launch }?.value, "an unusable price reads as unknown, never as a value")
        XCTAssertEqual(ranked.filter { $0.value == nil }.count, 3)
    }

    func testTiesAreBrokenTheSameWayWhateverTheReadOrder() {
        let twin = Token(address: Address(literal: "0x0000000000000000000000000000000000000abc"), symbol: "meme", name: "Twin", decimals: 18)
        let other = Token(address: Address(literal: "0x5555555555555555555555555555555555555555"), symbol: "ALPHA", name: "Alpha", decimals: 18)
        let tokens = [meme, twin, other, launch]
        // Same value for all four; LAUNCH holds more; MEME and "meme" tie on value and amount, so the address decides.
        let balances: [Address: BigUInt] = [meme.address: units(10, meme), twin.address: units(10, twin), other.address: units(10, other), launch.address: units(20, launch)]
        let prices: [Address: Double] = [meme.address: 1, twin.address: 1, other.address: 1, launch.address: 0.5]
        let expected = ["LAUNCH", "ALPHA", "meme", "MEME"]
        for order in permutations(tokens) {
            XCTAssertEqual(WalletHoldings.ranked(order, balances: balances, prices: prices, unverified: []).map(\.token.symbol), expected)
        }
        // An exact tie on value between a chosen and an Unverified token: the chosen one first.
        let tied = WalletHoldings.ranked([fakeUSDC, Token.usdc], balances: [fakeUSDC.address: 5_000_000, Monad.usdc: 5_000_000],
                                         prices: [fakeUSDC.address: 1, Monad.usdc: 1], unverified: [fakeUSDC.address])
        XCTAssertEqual(tied.map(\.id), [Monad.usdc, fakeUSDC.address])
    }

    func testNativeMonIsListedAndIsTheDefaultOnlyWhenItIsTheTopAsset() {
        let universe = [Token.mon, Token.usdc]
        let monTop = WalletHoldings.ranked(universe, balances: [Monad.native: units(1_000, .mon), Monad.usdc: units(5, .usdc)], prices: [Monad.native: 0.03, Monad.usdc: 1], unverified: [])
        XCTAssertEqual(monTop.first?.token, .mon)
        XCTAssertEqual(WalletHoldings.defaultChoice(monTop)?.token, .mon)
        let usdcTop = WalletHoldings.ranked(universe, balances: [Monad.native: units(10, .mon), Monad.usdc: units(5, .usdc)], prices: [Monad.native: 0.03, Monad.usdc: 1], unverified: [])
        XCTAssertEqual(usdcTop.map(\.token.symbol), ["USDC", "MON"], "MON is listed, below the higher-value USDC")
        XCTAssertEqual(WalletHoldings.defaultChoice(usdcTop)?.token, .usdc)
    }

    func testSpoofedUSDCIsMarkedNeverTheDefaultAndNeverDollars() {
        let universe = [Token.mon, Token.usdc, fakeUSDC]
        // The fake "USDC" has a seeded pool pricing it far above everything real.
        let balances: [Address: BigUInt] = [Monad.native: units(10, .mon), Monad.usdc: units(20, .usdc), fakeUSDC.address: units(1_000_000, fakeUSDC)]
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: [Monad.native: 0.03, Monad.usdc: 1, fakeUSDC.address: 1], unverified: [fakeUSDC.address])
        XCTAssertEqual(ranked.first?.id, fakeUSDC.address, "listed by its (claimed) value…")
        XCTAssertTrue(ranked.first?.unverified == true, "…and marked")
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.id, Monad.usdc, "a send starts on the real USDC, never the look-alike")

        XCTAssertNil(WalletHoldings.stableUSD(fakeUSDC, amount: 1_500_000), "a token named USDC is not dollars")
        XCTAssertEqual(WalletHoldings.stableUSD(.usdc, amount: 1_500_000), 1.5)
        XCTAssertNil(WalletHoldings.stableUSD(.mon, amount: units(3, .mon)))
        XCTAssertEqual(WalletHoldings.dollarStables, Set(["USDC", "USDT0", "AUSD", "USDe", "USD1", "mUSD"].map { symbol in Token.core.first { $0.symbol == symbol }!.address }))
        XCTAssertFalse(WalletHoldings.dollarStables.contains(fakeUSDC.address))
    }

    func testDefaultChoiceSkipsUnverifiedAndIsNoneWhenNothingIsChosen() {
        let onlySent = WalletHoldings.ranked([spam, fakeUSDC], balances: [spam.address: 1, fakeUSDC.address: 1], prices: [:], unverified: [spam.address, fakeUSDC.address])
        XCTAssertEqual(onlySent.count, 2, "still listed")
        XCTAssertNil(WalletHoldings.defaultChoice(onlySent), "but the user picks one")
    }

    /// A price read that fails leaves only the prices known by definition (USDC and AUSD at $1): the list is then ranked
    /// by amount, so a send preselects nothing rather than the token with the most units.
    func testAFailedPriceReadPreselectsNothing() {
        let universe = [Token.mon, Token.usdc, meme]
        let balances: [Address: BigUInt] = [Monad.native: units(20, .mon), Monad.usdc: units(500, .usdc), meme.address: units(1_000_000, meme)]
        let defined = PriceService.definedPrices(for: universe).mapValues(\.usd)
        XCTAssertEqual(defined, [Monad.usdc: 1], "USDC at $1 without a read; MON and MEME need one")
        XCTAssertEqual(PriceService.definedPrices(for: [Token.ausd, fakeUSDC]).mapValues(\.usd), [Monad.ausd: 1], "a token named USDC is not priced by definition")
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: defined, unverified: [])
        XCTAssertEqual(ranked.map(\.token.symbol), ["USDC", "MEME", "MON"], "USDC valued; the rest unpriced, by amount")
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.token.symbol, "USDC", "(with prices read, the top chosen token)")
        XCTAssertNil(WalletHoldings.defaultChoice(ranked, pricesRead: false))
        XCTAssertNil(WalletHoldings.selection(keeping: nil, in: ranked, pricesRead: false), "nothing picked for the user")
        XCTAssertEqual(WalletHoldings.selection(keeping: meme.address, in: ranked, pricesRead: false)?.id, meme.address, "the user's own pick stays")
    }

    func testEmptyWallet() {
        let ranked = WalletHoldings.ranked([Token.mon, Token.usdc], balances: [Monad.native: 0, Monad.usdc: 0], prices: [Monad.native: 0.03], unverified: [])
        XCTAssertTrue(ranked.isEmpty)
        XCTAssertTrue(WalletHoldings.ranked([], balances: [:], prices: [:], unverified: []).isEmpty)
        XCTAssertNil(WalletHoldings.defaultChoice(ranked))
        XCTAssertNil(WalletHoldings.selection(keeping: Monad.usdc, in: ranked))
        XCTAssertTrue(WalletHoldings.matching(ranked, query: "usdc").isEmpty)
    }

    func testSelectionKeepsTheCurrentTokenWhileItIsHeldAndNeverSwitchesToAnother() throws {
        let ranked = WalletHoldings.ranked([Token.mon, meme], balances: [Monad.native: units(100, .mon), meme.address: units(1, meme)], prices: [Monad.native: 0.03], unverified: [])
        XCTAssertEqual(WalletHoldings.selection(keeping: meme.address, in: ranked)?.id, meme.address)
        XCTAssertNil(WalletHoldings.selection(keeping: Monad.usdc, in: ranked), "no longer held: cleared, never swapped for the default under a typed amount")
        XCTAssertEqual(WalletHoldings.selection(keeping: nil, in: ranked)?.id, Monad.native, "nothing chosen yet: the default")
        // A re-read carries the kept token's fresh balance and marks.
        let reread = WalletHoldings.ranked([Token.mon, meme], balances: [Monad.native: units(100, .mon), meme.address: units(3, meme)], prices: [Monad.native: 0.03], unverified: [meme.address])
        let kept = try XCTUnwrap(WalletHoldings.selection(keeping: meme.address, in: reread))
        XCTAssertEqual(kept.balance, units(3, meme))
        XCTAssertTrue(kept.unverified)
    }

    func testSearchMatchesSymbolNameOrAddress() {
        let ranked = WalletHoldings.ranked([Token.mon, Token.usdc, fakeUSDC, meme], balances: [Monad.native: 1, Monad.usdc: 1, fakeUSDC.address: 1, meme.address: 1],
                                           prices: [:], unverified: [fakeUSDC.address])
        XCTAssertEqual(WalletHoldings.matching(ranked, query: "").count, 4)
        XCTAssertEqual(Set(WalletHoldings.matching(ranked, query: "usdc").map(\.id)), [Monad.usdc, fakeUSDC.address], "both, the look-alike marked")
        XCTAssertEqual(WalletHoldings.matching(ranked, query: "meme coin").map(\.id), [meme.address], "by name")
        // A pasted address, with the spaces and invisible characters a copy can carry, matches that contract only.
        XCTAssertEqual(WalletHoldings.matching(ranked, query: " \u{200B}\(Monad.usdc.checksummed)\n").map(\.id), [Monad.usdc])
        XCTAssertEqual(WalletHoldings.matching(ranked, query: fakeUSDC.address.hex.uppercased().replacingOccurrences(of: "0X", with: "0x")).map(\.id), [fakeUSDC.address])
        XCTAssertEqual(WalletHoldings.matching(ranked, query: "0x2222").map(\.id), [fakeUSDC.address], "the start of an address")
        XCTAssertTrue(WalletHoldings.matching(ranked, query: "0x9999999999999999999999999999999999999999").isEmpty)
        XCTAssertTrue(WalletHoldings.matching(ranked, query: "nothing like it").isEmpty)
    }

    /// The sources wire it in: the Portfolio's Assets and the Send sheet read the wallet the same way (`WalletTokens`),
    /// the Send sheet starts on `selection`/`defaultChoice`, and a send's dollars come from the stables' addresses.
    func testThePortfolioAndTheSendSheetShareOneList() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let assets = try String(contentsOf: app.appendingPathComponent("Portfolio/AssetsModel.swift"), encoding: .utf8)
        let profile = try String(contentsOf: app.appendingPathComponent("Profile/ProfileView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(profile.range(of: "struct SendSheet: View {"))
        let end = try XCTUnwrap(profile.range(of: "enum QRCode", range: start.upperBound..<profile.endIndex))
        let send = String(profile[start.upperBound..<end.lowerBound])
        for source in [assets, send] {
            XCTAssertTrue(source.contains("WalletTokens.read(env: env, address: address)"))
            XCTAssertTrue(source.contains("WalletTokens.ranked(read, env: env"))
            XCTAssertFalse(source.contains("heldTokens("), "no screen reads the wallet's tokens its own way")
        }
        XCTAssertTrue(send.contains("let kept = WalletHoldings.selection(keeping: choice?.id, in: ranked.tokens, pricesRead: !ranked.pricesFailed)"))
        XCTAssertTrue(send.contains("usd: WalletHoldings.stableUSD(review.token, amount: review.amount)"))
        // Coming back from the token list restarts the form's tasks: the list is read once per wallet and attempt, a
        // finished recipient check stands, and Review takes only a pick from the list as read, with its Unverified mark.
        XCTAssertTrue(send.contains("guard key != assetsKey else { return }"))
        XCTAssertTrue(send.contains("if let to, to == checkedRecipient { return }"))
        XCTAssertTrue(send.contains("guard case .loaded = assets, choice != nil else { return false }"))
        XCTAssertTrue(send.contains("review = SendReview(asset: choice,"))
        XCTAssertTrue(send.contains("unverified = asset.unverified"))
        XCTAssertFalse(send.contains("Token.core.filter"), "no fixed short list")
        XCTAssertFalse(send.contains("\"USDC\", \"USDT0\""), "dollars are never decided by symbol")
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[T]] in
            var rest = items
            let head = rest.remove(at: i)
            return permutations(rest).map { [head] + $0 }
        }
    }
}

/// Whether a send would go through, asked of the chain before the review offers Send.
final class TokenTransferTests: XCTestCase {
    private let token = Token(address: Address(literal: "0x6666666666666666666666666666666666666666"), symbol: "ABC", name: "Abc", decimals: 18)
    private let owner = Address(literal: "0x7777777777777777777777777777777777777777")
    private let recipient = Address(literal: "0x8888888888888888888888888888888888888888")

    func testRequestIsTheValueForMonAndTransferForAToken() throws {
        let mon = try TokenTransfer.request(.mon, to: recipient, amount: 5)
        XCTAssertEqual(mon, TransactionRequest(to: recipient, value: 5))
        let erc20 = try TokenTransfer.request(token, to: recipient, amount: 5)
        XCTAssertEqual(erc20, TransactionRequest(to: token.address, data: try ERC20.transferCalldata(to: recipient, amount: 5)))
    }

    func testATransferThatGoesThroughIsNotRefused() async {
        let contract = token.address
        MomentsChainStub.install { to, _ in to == contract ? try! ABI.encode([.bool(true)], "bool") : nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertNil(refusal)
        XCTAssertEqual(MomentsChainStub.calls().map(\.selector), [ABI.selector("transfer(address,uint256)").hexString])
    }

    func testATokenThatReturnsNothingIsNotRefused() async {
        let contract = token.address
        MomentsChainStub.install { to, _ in to == contract ? Data() : nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertNil(refusal, "a token that returns no bool (USDT-style) still moved the funds")
    }

    func testARevertIsRefused() async {
        MomentsChainStub.install { _, _ in nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertEqual(refusal, "This send would fail: execution reverted.")
    }

    func testATokenThatReturnsFalseIsRefused() async {
        let contract = token.address
        MomentsChainStub.install { to, _ in to == contract ? try! ABI.encode([.bool(false)], "bool") : nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertEqual(refusal, "The ABC contract refused this transfer, so nothing would be sent.")
    }

    func testMonToAWalletIsNotRefused() async {
        let payee = recipient
        MomentsChainStub.install { to, data in to == payee && data.isEmpty ? Data() : nil }
        let refusal = await TokenTransfer.refusal(.mon, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertNil(refusal)
    }

    func testOnlyARevertCountsAsARefusal() {
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: 3, message: "execution reverted", data: "0x08c379a0")))
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: -32000, message: "execution reverted")))
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: -32000, message: "insufficient funds for transfer")))
        XCTAssertFalse(TokenTransfer.isRevert(RPCError(code: 429, message: "Too many requests")))
        XCTAssertFalse(TokenTransfer.isRevert(RPCError(code: -1, message: "Missing response")))
    }
}
