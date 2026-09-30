import XCTest
@testable import DyorKit

/// The look-alike rule (`WalletHoldings.imitated(by:)`), display safety and the create guard (`SymbolSafety`): what reads
/// as a curated or widely traded token, what shows as itself, and what the create forms refuse. The badge and the icon
/// go by the same rule (`DyorCoinBadgeTests`).
final class LookAlikeRuleTests: XCTestCase {
    private let address = Address(literal: "0x00000000000000000000000000000000000c0ffe")

    private func token(_ symbol: String, _ name: String = "Some Coin") -> Token {
        Token(address: address, symbol: symbol, name: name, decimals: 18)
    }

    private func label(_ text: String) -> String { text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ") }

    /// Symbols and names that are imitations, with what they imitate (shared with `DyorCoinBadgeTests`).
    static let imitatingSymbols: [(String, Token)] = [
        ("M0n", .mon), ("m0n", .mon), ("wm0n", .wmon), ("Wm0N", .wmon), ("M0NAD", .mon), ("usdto", Token.core.first { $0.symbol == "USDT0" }!),
        ("USDC.e", .usdc), ("USDC'", .usdc), ("USDC`", .usdc), ("$MON", .mon), ("MON2", .mon), ("USDC" + String(repeating: " ", count: 40) + ".", .usdc),
        ("\u{A4F4}\u{A4E2}\u{A4D3}\u{A4DA}", .usdc), ("\u{A4DF}\u{A4F3}\u{A4E0}", .mon), ("USD\u{0106}", .usdc), ("USD\u{03F9}", .usdc), ("USD\u{13DF}", .usdc),
    ]
    static let majorSymbols = ["USDT", "ETH", "BTC", "SOL", "DAI", "BNB"]
    static let imitatingNames: [(String, Token)] = [
        ("M0nad", .mon), ("\u{13B7}\u{13BE}NAD", .mon), ("M\u{0585}nad", .mon), ("M\u{1D0F}nad", .mon), ("\u{A4DF}\u{A4F3}\u{A4E0}", .mon),
        ("\u{A4F4}\u{A4E2}\u{A4D3}\u{A4DA}", .usdc), ("$MON", .mon), ("USDC 2", .usdc),
    ]
    static let ownSymbols = ["USDL", "PEPE", "MONKE", "DOGE", "CAFÉ", "xMON", "BTCD", "0N1", "0N1F", "GMGM", "ETHX", "SOLAR", "DAISY"]
    static let ownNames = ["Pepe Coin", "\u{03A9}mega", "\u{03BC}Swap", "\u{03C0}DAO", "Russian \u{0420}\u{0443}\u{0431}\u{043B}\u{044C}", "Monad Frogs", "Pepe on MON",
                           "Bitcoin Diva", "Good Morning", "\u{0394}Neutral", "Lambda \u{03BB}", "Pepe \u{041F}\u{0435}\u{043F}\u{0435}"]

    // MARK: Look-alikes (F4)

    /// Each of these is an imitation, as a symbol or a name: the wallet marks it, and the create forms refuse it.
    func testLookAlikesAreImitations() {
        for (symbol, expect) in Self.imitatingSymbols {
            XCTAssertEqual(WalletHoldings.imitated(by: token(symbol)), expect, "\(symbol) \(label(symbol))")
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), .symbolImitates(expect), symbol)
        }
        for symbol in Self.majorSymbols {
            let major = WalletHoldings.majorTokens.first { $0.symbol == symbol }!
            XCTAssertEqual(WalletHoldings.imitated(by: token(symbol)), major, symbol)
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Coin", symbol: symbol), .symbolImitates(major), symbol)
            XCTAssertTrue(SymbolSafety.CreateRefusal.symbolImitates(major).message.contains("widely traded"), symbol)
            XCTAssertNil(Token.core(major.address), "a placeholder address, never a curated one")
        }
        for (name, expect) in Self.imitatingNames {
            XCTAssertEqual(WalletHoldings.imitated(by: token("SAFE", name)), expect, "\(name) \(label(name))")
            XCTAssertEqual(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), .nameImitates(expect), name)
        }
        for name in ["Bitcoin", "Ethereum", "Solana", "Tether", "Tether USD", "Dai"] {
            XCTAssertNotNil(WalletHoldings.imitated(by: token("SAFE", name)), name)
        }
    }

    /// And these are not: other words that hold a ticker among letters, names in other alphabets, accents. The curated
    /// tokens themselves are never flagged.
    func testOtherWordsAreNotImitations() {
        for symbol in Self.ownSymbols {
            XCTAssertNil(WalletHoldings.imitated(by: token(symbol)), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), symbol)
        }
        for name in Self.ownNames {
            XCTAssertNil(WalletHoldings.imitated(by: token("SAFE", name)), name)
            XCTAssertNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), name)
        }
        for curated in Token.core {
            XCTAssertNil(WalletHoldings.imitated(by: curated), "\(curated.symbol) itself is never flagged")
        }
    }

    /// The look-alike letters come from Unicode's confusables: Armenian, Cherokee, Lisu, Coptic and the Latin small
    /// capitals and IPA letters read as the Latin letters they are drawn like; accented Latin letters are not in the
    /// table (their accents are folded where a reading needs it).
    func testTheLookAlikeTableCoversTheScriptsDrawnLikeLatin() {
        let expected: [(UInt32, Unicode.Scalar)] = [(0x0585, "o"), (0x13B7, "M"), (0x13BE, "O"), (0xA4DF, "M"), (0xA4F3, "O"), (0x2C9F, "o"), (0x1D0F, "o"), (0x0261, "g"),
                                                    (0x0421, "C"), (0x0406, "I"), (0x03F9, "C")]
        for (code, latin) in expected {
            XCTAssertEqual(WalletHoldings.lookAlikeLetters[Unicode.Scalar(code)!], latin, String(format: "%04X", code))
        }
        for accented in ["É", "Ñ", "Ç", "Ð", "Ć", "ø", "ß"] {
            XCTAssertNil(WalletHoldings.lookAlikeLetters[accented.unicodeScalars.first!], accented)
        }
        for own in ["\u{03BC}", "\u{03C0}", "\u{03A9}", "\u{0394}", "\u{03BB}"] {
            XCTAssertNil(WalletHoldings.lookAlikeLetters[own.unicodeScalars.first!], "\(own) is drawn like no Latin letter")
        }
    }

    // MARK: Display safety and the create guard (F5, F6)

    /// Accented Latin letters are Latin letters: display-safe and allowed ("USDĆ" still reads as USDC).
    func testAccentedLatinSymbolsAreAllowed() {
        for symbol in ["CAFÉ", "PIÑA", "ÇA", "NIÑO", "ÐOGE", "CAFE\u{0301}", "ȘTEFAN", "ÆON"] {
            XCTAssertTrue(SymbolSafety.isDisplaySafe(symbol), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), symbol)
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: "USDĆ"), .symbolImitates(.usdc))
        for symbol in ["\u{0131}QT", "Q\u{1D1B}", "\u{01C0}QT", "\u{017F}QT", "PEPE\u{72D7}", "\u{72D7} \u{72D7}", "\u{72D7}\u{FF12}"] {
            XCTAssertFalse(SymbolSafety.isDisplaySafe(symbol), label(symbol))
        }
    }

    /// The symbol refusal says what is allowed, in plain words.
    func testTheSymbolRefusalSaysWhatIsAllowed() {
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: "PEPE\u{72D7}"), .symbolNotDisplaySafe)
        XCTAssertEqual(SymbolSafety.CreateRefusal.symbolNotDisplaySafe.message,
                       "A symbol can use A–Z, 0–9 and accented Latin letters, or Chinese, Japanese or Korean characters with 0–9, not mixed.")
    }

    /// A name mixing alphabets is judged word by word, counting only letters drawn like Latin ones.
    func testTheMixedAlphabetRuleIsPerWordAndOnlyForLookAlikes() {
        for name in ["\u{03A9}mega", "\u{03C0}DAO", "\u{03BC}Swap", "\u{0394}Neutral", "Lambda \u{03BB}", "Pepe \u{041F}\u{0435}\u{043F}\u{0435}",
                     "Russian \u{0420}\u{0443}\u{0431}\u{043B}\u{044C}", "K\u{0131}rm\u{0131}z\u{0131}", "Αθηνά"] {
            XCTAssertFalse(SymbolSafety.mixesLookAlikeAlphabets(name), name)
            XCTAssertNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), name)
        }
        for name in ["P\u{0430}ypal", "M\u{0585}nad", "Coin P\u{0430}y", "Gr\u{1D0F}ve"] {
            XCTAssertTrue(SymbolSafety.mixesLookAlikeAlphabets(name), name)
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "P\u{0430}ypal", symbol: "PAY"), .nameMixesAlphabets)
        XCTAssertEqual(SymbolSafety.createRefusal(name: "M\u{0585}nad", symbol: "SAFE"), .nameImitates(.mon), "reads as Monad first")
    }

    /// A joiner, a variation selector, a keycap mark or tags only where an emoji uses them; the blank Braille pattern and
    /// the Hangul fillers are hidden.
    static let hiddenNames = ["USD1\u{200D}", "Coin1" + englandTags, "Doge\u{1F436}\u{E0068}", "Doge \u{1F436}\u{200D}", "USDC\u{2800}", "A\u{20E3}", "\u{1F3F4}\u{E007F}",
                              "Coin #\u{FE0F}\u{200D}", "\u{1F436}\u{200D}A", "Q\u{115F}", "Q\u{1160}", "Q\u{3164}", "Q\u{FFA0}",
                              "\u{1F3F4}" + String(repeating: "\u{E0061}", count: 20) + "\u{E007F}"]
    static let englandTags = "\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"

    func testHiddenCharactersOutsideEmoji() {
        for name in Self.hiddenNames {
            XCTAssertTrue(SymbolSafety.hasHiddenCharacters(name), label(name))
            XCTAssertNotNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), label(name))
        }
        for name in ["\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{2764}\u{FE0F}", "1\u{FE0F}\u{20E3}", "#\u{20E3}", "\u{1F3F4}" + Self.englandTags,
                     "\u{1F468}\u{1F3FD}\u{200D}\u{1F4BB}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
                     "Skin \u{1F44D}\u{1F3FD}", "Flag \u{1F1EC}\u{1F1ED}", "Café Crème"] {
            XCTAssertFalse(SymbolSafety.hasHiddenCharacters(name), label(name))
        }
        XCTAssertEqual(WalletHoldings.imitated(by: token("SAFE", "USDC\u{2800}")), .usdc, "the blank Braille pattern reads as nothing")
    }

    /// The create forms refuse a symbol or name longer than they allow: a symbol 10 characters, a launch's name 32 (its
    /// form sets none), a Moment's 48.
    func testTheCreateGuardRefusesWhatTheFormsDont() {
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Coin", symbol: "ABCDEFGHIJK"), .symbolTooLong)
        XCTAssertNil(SymbolSafety.createRefusal(name: String(repeating: "n", count: 32), symbol: "ABCDEFGHIJ"))
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "n", count: 33), symbol: "SAFE"), .nameTooLong(32))
        XCTAssertNil(SymbolSafety.createRefusal(name: String(repeating: "n", count: 48), symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength))
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "n", count: 49), symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength), .nameTooLong(48))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "A" + String(repeating: "\u{0301}", count: 200), symbol: "SAFE"), .nameTooLong(32),
                       "one character piled with marks is not short")
        XCTAssertEqual(SymbolSafety.CreateRefusal.nameTooLong(32).message, "A name can be at most 32 characters.")
        XCTAssertTrue(SymbolSafety.CreateRefusal.symbolTooLong.isAboutSymbol)
        XCTAssertFalse(SymbolSafety.CreateRefusal.nameTooLong(32).isAboutSymbol)
    }
}
