import XCTest
@testable import DyorKit

/// What a DyorHQ coin shows, by the one look-alike and display rule (`LookAlikeRuleTests`): an imitation warns and
/// shows letters, a coin whose own symbol or name doesn't show as itself or is longer than the forms allow warns, a
/// warning never shows the creator's picture, the text kept is the chain's (cut to a size), and every check reads that
/// text, never the text a screen shows.
final class DyorCoinBadgeTests: XCTestCase {
    private let address = Address(literal: "0x00000000000000000000000000000000000c0ffe")

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
    }

    private func token(_ symbol: String, _ name: String = "Some Coin") -> Token {
        Token(address: address, symbol: symbol, name: name, decimals: 18)
    }

    private func coin(_ symbol: String, _ name: String = "Some Coin", moment: Bool = false, logo: String = "") -> DyorCoin {
        DyorCoin(address: address, origin: moment ? .moment(factory: MomentsAddresses.monadMainnet.factory, id: 1, retired: false)
                     : .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false),
                 symbol: symbol, name: name, creator: DyorCoinChain.creator, logo: logo, pair: .zero)
    }

    private func label(_ text: String) -> String { text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ") }

    // MARK: The same rule as the wallet and the forms (F4)

    /// A DyorHQ coin carrying a look-alike symbol or name gets the imitation warning, received or chosen, and shows its
    /// letters; one reading as a major token DyorHQ doesn't list says so.
    func testLookAlikesWarnEverywhere() {
        let art = DyorCoinChain.media(DyorCoinChain.creator, "usdc.png")
        func check(_ token: Token, _ coin: DyorCoin, _ expect: Token, _ text: String) {
            XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: true), .imitates(expect), text)
            XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: false), .imitates(expect), text)
            XCTAssertEqual(CoinIcon.resolve(token, coin: coin, policy: .dyorhq), .letters, text)
        }
        for (symbol, expect) in LookAlikeRuleTests.imitatingSymbols { check(token(symbol), coin(symbol, logo: art), expect, label(symbol)) }
        for (name, expect) in LookAlikeRuleTests.imitatingNames { check(token("SAFE", name), coin("SAFE", name, logo: art), expect, label(name)) }
        for symbol in LookAlikeRuleTests.majorSymbols {
            let major = WalletHoldings.majorTokens.first { $0.symbol == symbol }!
            check(token(symbol), coin(symbol, logo: art), major, symbol)
            XCTAssertEqual(TokenBadge.imitates(major).title, "Not the real \(symbol)")
        }
        XCTAssertEqual(TokenBadge.imitates(.usdc).title, "Not the USDC DyorHQ lists")
    }

    /// The words that aren't imitations keep their DyorHQ label; the curated tokens have none.
    func testOtherWordsKeepTheirLabel() {
        for symbol in LookAlikeRuleTests.ownSymbols {
            XCTAssertEqual(TokenBadge.of(token(symbol), coin: coin(symbol), receivedUnasked: true), .dyorLaunch, symbol)
        }
        for name in LookAlikeRuleTests.ownNames {
            XCTAssertEqual(TokenBadge.of(token("SAFE", name), coin: coin("SAFE", name), receivedUnasked: true), .dyorLaunch, name)
        }
        for curated in Token.core { XCTAssertEqual(TokenBadge.of(curated, coin: nil, receivedUnasked: true), .none, curated.symbol) }
    }

    // MARK: The badge reads the name (F7)

    /// A DyorHQ coin whose name has a direction override — "USDC COIN" drawn from "NIOC CDSU" — a hidden character, a
    /// word mixing look-alike alphabets, or text that couldn't be read is Unverified, never "DyorHQ Launch"; so is one
    /// whose symbol couldn't be read. The create forms refuse each of those names.
    func testTheBadgeChecksTheCoinsName() {
        for name in ["\u{202E}NIOC CDSU", "P\u{0430}ypal", "Doge\u{200B}", "\u{FFFD}", "Coin\u{2800}"] + LookAlikeRuleTests.hiddenNames {
            let entry = coin("SAFE", name)
            XCTAssertTrue(TokenBadge.of(entry.token, coin: entry, receivedUnasked: false).isWarning, label(name))
            XCTAssertNotNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), label(name))
        }
        XCTAssertEqual(TokenBadge.of(coin("SAFE", "\u{202E}NIOC CDSU").token, coin: coin("SAFE", "\u{202E}NIOC CDSU"), receivedUnasked: false), .unverified)
        let unreadable = coin(ChainText.unreadable, "Fine")
        XCTAssertEqual(TokenBadge.of(unreadable.token, coin: unreadable, receivedUnasked: false), .unverified)
    }

    // MARK: Lengths (F6)

    /// A DyorHQ coin whose symbol or name is longer than the forms allow is not display-safe; what is kept of its text is
    /// cut (a symbol 32 characters, a name 64, within 128 and 256 bytes; a link over 2,048 bytes dropped), and what is
    /// cut still reads as too long.
    func testLengthsTheFormsAllow() {
        XCTAssertEqual(TokenBadge.of(coin("ABCDEFGHIJ").token, coin: coin("ABCDEFGHIJ"), receivedUnasked: false), .dyorLaunch)
        let longSymbol = coin(String(repeating: "A", count: 11))
        XCTAssertEqual(TokenBadge.of(longSymbol.token, coin: longSymbol, receivedUnasked: false), .unverified)
        let longLaunchName = coin("SAFE", String(repeating: "n", count: 33))
        XCTAssertEqual(TokenBadge.of(longLaunchName.token, coin: longLaunchName, receivedUnasked: false), .unverified)
        let momentName = coin("SAFE", String(repeating: "n", count: 48), moment: true)
        XCTAssertEqual(TokenBadge.of(momentName.token, coin: momentName, receivedUnasked: false), .dyorMoment)
        let piled = coin("SAFE", "A" + String(repeating: "\u{0301}", count: 200))
        XCTAssertEqual(TokenBadge.of(piled.token, coin: piled, receivedUnasked: false), .unverified, "one character piled with marks is not short")
        let huge = coin(String(repeating: "A", count: 12_000), String(repeating: "B", count: 12_000), logo: "https://x.example/" + String(repeating: "a", count: 3_000))
        XCTAssertEqual(huge.symbol.count, DyorCoin.maxStoredSymbol.characters, "kept cut")
        XCTAssertEqual(huge.name.count, DyorCoin.maxStoredName.characters)
        XCTAssertEqual(huge.logo, "", "a link over 2,048 bytes is dropped")
        XCTAssertEqual(TokenBadge.of(huge.token, coin: huge, receivedUnasked: false), .unverified, "still too long once cut")
        let zalgo = coin("SAFE", String(repeating: "Z" + String(repeating: "\u{0301}", count: 100), count: 5))
        XCTAssertLessThanOrEqual(zalgo.name.utf8.count, DyorCoin.maxStoredName.bytes)
        XCTAssertGreaterThan(zalgo.name.utf8.count, 4 * SymbolSafety.maxLaunchNameLength, "cut, and still over what a form allows")
        XCTAssertEqual(TokenBadge.of(zalgo.token, coin: zalgo, receivedUnasked: false), .unverified)
        let decoded = try? JSONDecoder().decode(DyorCoin.self, from: JSONEncoder().encode(DyorCoin(address: address,
            origin: .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false), symbol: "S", name: "N", creator: .zero, logo: "", pair: .zero)))
        XCTAssertEqual(decoded?.symbol, "S", "an entry round-trips through the file's form")
    }

    // MARK: The icon follows the badge (F8)

    /// A coin whose badge is a warning shows its letters, never its creator's picture: a symbol drawn like "USDC" in
    /// another script, a symbol with a hidden character, a name with a direction override.
    func testAWarningShowsLettersNeverTheCreatorsPicture() {
        let art = DyorCoinChain.media(DyorCoinChain.creator, "usdc.png")
        for (symbol, name) in [("USD\u{03F9}", "USD Coin"), ("USD\u{13DF}", "USD Coin"), ("PEPE\u{200B}", "Pepe"), ("SAFE", "\u{202E}NIOC CDSU")] {
            let entry = coin(symbol, name, logo: art)
            XCTAssertTrue(TokenBadge.of(entry.token, coin: entry, receivedUnasked: false).isWarning, label(symbol))
            XCTAssertEqual(CoinIcon.resolve(entry.token, coin: entry, policy: .dyorhq), .letters, label(symbol))
        }
        let fine = coin("SAFE", "Safe Coin", logo: art)
        XCTAssertEqual(CoinIcon.resolve(fine.token, coin: fine, policy: .dyorhq), .remote([RemoteImageSource(url: URL(string: art)!)], fill: true))
    }

    // MARK: Chain text, not shown text (F13)

    /// A coin keeps its text as the chain has it, and every check reads that: a Hebrew symbol gets the same verdict raw
    /// as shown, a Hebrew name isn't mistaken for hidden characters by the isolates `ChainText.shown` adds around it, and
    /// direction characters the chain holds are caught though `shown` removes them. The shown text is for screens alone.
    func testChecksReadTheChainsTextNeverTheShownText() async throws {
        var chain = DyorCoinChain()
        func launch(_ n: Int, _ symbol: String, _ name: String) -> DyorCoinChain.LaunchCoin {
            let token = Address(literal: String(format: "0x0000000000000000000000000000000000%06x", 0xc0d000 + n))
            return DyorCoinChain.LaunchCoin(token: token, name: name, symbol: symbol, logo: "", deployer: DyorCoinChain.creator, curve: Address(data: Data(token.data.reversed()))!)
        }
        let hebrewSymbol = launch(1, "\u{05D0}\u{05D1}\u{05D2}", "Aleph")
        let hebrewName = launch(2, "SHLM", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}")
        let isolated = launch(3, "\u{2066}QT\u{2069}", "Quiet")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [hebrewSymbol, hebrewName, isolated]
        chain.install()
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        await registry.refresh()
        let coins = await registry.all
        let symbolCoin = try XCTUnwrap(coins[hebrewSymbol.token])
        XCTAssertEqual(symbolCoin.symbol, "\u{05D0}\u{05D1}\u{05D2}", "kept as read")
        XCTAssertEqual(symbolCoin.displaySymbol, "\u{2068}\u{05D0}\u{05D1}\u{05D2}\u{2069}", "isolated for showing")
        XCTAssertEqual(SymbolSafety.isDisplaySafe(symbolCoin.symbol), SymbolSafety.isDisplaySafe(symbolCoin.displaySymbol), "the same verdict raw as shown")
        XCTAssertEqual(TokenBadge.of(symbolCoin.token, coin: symbolCoin, receivedUnasked: false), .unverified)

        let nameCoin = try XCTUnwrap(coins[hebrewName.token])
        XCTAssertEqual(nameCoin.name, "\u{05E9}\u{05DC}\u{05D5}\u{05DD}")
        XCTAssertEqual(nameCoin.displayName, "\u{2068}\u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{2069}")
        XCTAssertTrue(SymbolSafety.hasHiddenCharacters(nameCoin.displayName), "what a check reading the shown text would see")
        XCTAssertEqual(TokenBadge.of(nameCoin.token, coin: nameCoin, receivedUnasked: false), .dyorLaunch, "the check read the chain's text")

        let isolatedCoin = try XCTUnwrap(coins[isolated.token])
        XCTAssertEqual(isolatedCoin.displaySymbol, "QT", "shown without its isolates")
        XCTAssertEqual(TokenBadge.of(isolatedCoin.token, coin: isolatedCoin, receivedUnasked: false), .unverified, "the isolates the chain holds are caught")

        for coin in coins.values {
            for text in [coin.symbol, coin.name, coin.token.symbol, coin.token.name] {
                XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x2068 }, "no check is handed an isolate ChainText added")
            }
        }
    }
}
