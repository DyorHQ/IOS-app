import BigInt
import Foundation

/// One token the wallet holds: its balance and, when a pool prices it, its dollar value. The Portfolio's Assets and
/// the Send sheet's list are both made of these, from the same read (`WalletHoldings.ranked`), so the two hold the same
/// tokens and can't drift; each keeps its own order.
public struct HeldToken: Hashable, Sendable, Identifiable {
    public let token: Token
    public let balance: BigUInt
    /// USD per whole token; nil when no pool prices it.
    public let usd: Double?
    /// Reached the wallet without being chosen in the app (sent, airdropped): its name and symbol prove nothing, so it
    /// is marked Unverified wherever it is listed (security audit 2026-09-26, IOST-12).
    public let unverified: Bool

    public init(token: Token, balance: BigUInt, usd: Double?, unverified: Bool = false) {
        self.token = token
        self.balance = balance
        self.usd = usd
        self.unverified = unverified
    }

    public var id: Address { token.address }
    /// The curated token this one could pass for, by its symbol or name (`WalletHoldings.imitated(by:)`); nil for the
    /// curated tokens and anything named otherwise.
    public var imitates: Token? { WalletHoldings.imitated(by: token) }
    /// Its symbol is plain printable ASCII (`WalletHoldings.isPlain`), as MON's and every curated token's is: one with any
    /// other character — invisible, direction-changing, a letter from another script — can read as a symbol it isn't.
    public var plainSymbol: Bool { token.isNative || Token.core(token.address) != nil || WalletHoldings.isPlain(token.symbol) }
    /// Whole tokens held.
    public var units: Double { Amount.units(balance, decimals: token.decimals) }
    /// Dollar value: nil when the price is unknown, never $0 in its place.
    public var value: Double? {
        guard let usd else { return nil }
        let value = units * usd
        return value.isFinite ? value : nil
    }
}

/// Which tokens the wallet holds, in what order, and which one a send starts on. Pure, so it is tested here; the app
/// reads the balances and prices it works on (`WalletTokens`).
public enum WalletHoldings {
    /// The tokens of `universe` the wallet holds — a balance above zero — each once, in `universe` order. A token whose
    /// balance is missing (its read failed) is left out, as it always was on the Portfolio.
    public static func held(_ universe: [Token], balances: [Address: BigUInt]) -> [Token] {
        var seen = Set<Address>()
        return universe.filter { (balances[$0.address] ?? 0) > 0 && seen.insert($0.address).inserted }
    }

    /// `tokens` with their balances and prices (USD per whole token), ranked by `order`: the Send list's (`precedes`)
    /// unless another is given (the Portfolio's, `portfolioPrecedes`). Tokens with no balance are left out here too.
    public static func ranked(_ tokens: [Token], balances: [Address: BigUInt], prices: [Address: Double], unverified: Set<Address>,
                              by order: (HeldToken, HeldToken) -> Bool = precedes) -> [HeldToken] {
        held(tokens, balances: balances)
            .map { HeldToken(token: $0, balance: balances[$0.address] ?? 0, usd: prices[$0.address], unverified: unverified.contains($0.address)) }
            .sorted(by: order)
    }

    /// The order the Portfolio's Assets has always used, unchanged: dollar value, highest first, a token with no price
    /// counted as $0, then the larger amount held.
    public static func portfolioPrecedes(_ a: HeldToken, _ b: HeldToken) -> Bool {
        (a.value ?? 0, a.units) > (b.value ?? 0, b.units)
    }

    /// The Send list's order:
    /// 1. dollar value, highest first; every token with no price comes after every priced one, never ranked as $0;
    /// 2. then tokens the user chose before Unverified ones;
    /// 3. then the larger amount held (whole tokens);
    /// 4. then symbol A–Z, ignoring case, then contract address — so the order never depends on the order of the reads.
    public static func precedes(_ a: HeldToken, _ b: HeldToken) -> Bool {
        switch (a.value, b.value) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.unverified != b.unverified { return !a.unverified }
        if a.units != b.units { return a.units > b.units }
        switch a.token.symbol.compare(b.token.symbol, options: .caseInsensitive) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.token.address.hex < b.token.address.hex
        }
    }

    /// The asset a send starts on: the highest-ranked one the user chose. Never an Unverified token — a fake "USDC"
    /// with a seeded pool can outrank everything — nor one carrying a curated token's name (`imitates`), even one the
    /// user tapped in Swap, nor one whose symbol isn't plain (`plainSymbol`): it may be a look-alike, and a send must
    /// never start on it unasked. So when every held token is one of those, or nothing is held, there is none and the
    /// user picks. None either when the prices couldn't be read (`pricesRead` false), and never a token with no price:
    /// the list below the priced tokens is by amount, not value, and the token with the most units is not the one worth
    /// the most.
    public static func defaultChoice(_ ranked: [HeldToken], pricesRead: Bool = true) -> HeldToken? {
        guard pricesRead else { return nil }
        return ranked.first { ($0.usd ?? 0) > 0 && !$0.unverified && $0.imitates == nil && $0.plainSymbol }
    }

    /// After the list is read: with nothing chosen yet, the default choice; with a choice, that token while the wallet
    /// still holds it, and none once it doesn't — the user picks again, rather than a send switching to another asset
    /// under an amount already typed.
    public static func selection(keeping current: Address?, in ranked: [HeldToken], pricesRead: Bool = true) -> HeldToken? {
        guard let current else { return defaultChoice(ranked, pricesRead: pricesRead) }
        return ranked.first { $0.id == current }
    }

    /// The held tokens a search matches, in `held` order: a pasted address matches that contract only; other text
    /// matches the symbol or name, or — starting with 0x — the start of the contract address.
    public static func matching(_ held: [HeldToken], query: String) -> [HeldToken] {
        let text = Address.cleanedInput(query).text
        guard !text.isEmpty else { return held }
        if let address = Address(text) { return held.filter { $0.token.address == address } }
        let hex = text.lowercased()
        return held.filter { item in
            item.token.symbol.localizedCaseInsensitiveContains(text) || item.token.name.localizedCaseInsensitiveContains(text)
                || (hex.hasPrefix("0x") && hex.count >= 4 && item.token.address.hex.hasPrefix(hex))
        }
    }

    /// `prices` (USD per whole token, from the pool finder) with DyorHQ's own coins valued as the app values them, which
    /// the pool finder can't: a launch coin (`launches`, found by its factory's record) at its live price in its pair
    /// asset (`HeldLaunches.pairPerCoin`: its curve's, or its pool's once graduated) times that asset's dollar price in
    /// `prices`; a Moment coin (`moments`) at its pool's live USDC price (`momentPrice`). Such a coin is never valued at a
    /// price another pool quotes for it: without the app's own value (a launch or price that couldn't be read, a pair
    /// asset with no price, a Moment whose pool wasn't read) it is unpriced.
    public static func pricing(_ prices: [Address: Double], launches: HeldLaunches, moments: [Address: Double?]) -> [Address: Double] {
        var out = prices
        for (coin, pair) in launches.pairAssets {
            // MON's price is under its address, 0 — the pair asset a native launch records.
            let usd = launches.pairPerCoin[coin].flatMap { perCoin in prices[pair].map { perCoin * $0 } }
            out[coin] = usd.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        for (coin, usdcPerCoin) in moments { out[coin] = usdcPerCoin }
        return out
    }

    /// A Moment coin's dollar price for `pricing`: its pool's USDC price as read live. Nil when that read failed — never
    /// the pool's opening price in its place — or the Moment has no pool.
    public static func momentPrice(_ info: MomentInfo) -> Double? {
        guard let pool = info.pool, pool.livePriceRead, pool.usdcPerCoin.isFinite, pool.usdcPerCoin > 0 else { return nil }
        return pool.usdcPerCoin
    }

    /// The DyorHQ coins that are `owner`'s own: a launch coin it launched (its factory records the wallet as deployer —
    /// the factory's caller, or the launch router's, never an argument) and a Moment coin whose Moment it collected or
    /// created (`staked`: a stake in the Moment's vesting). The factories name each coin by its address, so no look-alike
    /// passes for one; a coin that was only sent to the wallet is not its own.
    public static func ownCoins(owner: Address, launches: HeldLaunches, staked: Set<Address>) -> Set<Address> {
        Set(launches.deployers.filter { $0.value == owner }.keys).union(staked)
    }

    /// `unverified` without the DyorHQ coins that are `owner`'s own (`ownCoins`): a coin that was only sent to the wallet
    /// stays Unverified.
    public static func unverified(_ unverified: Set<Address>, owner: Address, launches: HeldLaunches, staked: Set<Address>) -> Set<Address> {
        unverified.subtracting(ownCoins(owner: owner, launches: launches, staked: staked))
    }

    /// The token `token` could pass for: a curated one, or a widely traded one DyorHQ doesn't list (`majorTokens`).
    /// `token` is none of them, yet
    /// - its symbol or name reads as one of their symbols or names (`readings`) — a second "USDC", a "Monad" that isn't
    ///   MON, a "USDC" with a zero-width space or a Cyrillic "С" in it, "M0N", "m0nad", a Lisu "ꓟꓳꓠ", a "USDT";
    /// - or its symbol holds one of their symbols or names with no letter right before or after it — "USDC.e", "$MON",
    ///   "MON2", "USDC" padded with spaces and a dot — while letters around it make another word ("MONKE", "xMON");
    /// - or its name is one of their symbols or names with nothing but non-letters around it ("$MON", "USDC 2").
    /// Being chosen proves nothing here: tapping a search result in Swap stores a token as chosen. Nil for MON, the
    /// curated tokens and every other name. The wallet's warnings, the badge (`TokenBadge`) and the create forms'
    /// guard (`SymbolSafety.createRefusal`) all go by this one rule. Only the first `maxJudged` characters that show of
    /// each are judged, so its cost doesn't grow with what a creator writes.
    public static func imitated(by token: Token) -> Token? {
        guard !token.isNative, Token.core(token.address) == nil else { return nil }
        let own = Set([token.symbol, token.name].flatMap(readings))
        guard !own.isEmpty else { return nil }
        let targets = lookAlikeTargets
        if let target = targets.first(where: { !own.isDisjoint(with: $0.readings) }) { return target.token }
        let symbol = forms(token.symbol).map(Text.init)
        let name = forms(token.name).map(Text.init)
        return targets.first { target in
            target.forms.contains { wanted in symbol.contains { $0.standsApart(wanted) } || name.contains { $0.standsAlone(wanted) } }
        }?.token
    }

    /// Widely traded tokens DyorHQ doesn't list, which a coin may not pass for either: BTC, ETH, SOL, USDT, DAI and BNB,
    /// each with its usual name. None has a contract on Monad the app knows, so each carries a placeholder address no key
    /// or contract has (`placeholder`): it names what a look-alike imitates, and is never read, priced or sent.
    public static let majorTokens: [Token] = majors.map(\.token)

    /// Each major token with the names it goes by.
    private static let majors: [(token: Token, names: [String])] = [
        (major("BTC", "Bitcoin"), ["Bitcoin"]), (major("ETH", "Ethereum"), ["Ethereum"]), (major("SOL", "Solana"), ["Solana"]),
        (major("USDT", "Tether USD"), ["Tether", "Tether USD"]), (major("DAI", "Dai"), ["Dai"]), (major("BNB", "BNB"), ["BNB"]),
    ]

    private static func major(_ symbol: String, _ name: String) -> Token {
        Token(address: placeholder(symbol), symbol: symbol, name: name, decimals: 18)
    }

    /// The last 20 bytes of keccak-256("DyorHQ major token <symbol>"): an address nobody holds a key or code for.
    static func placeholder(_ symbol: String) -> Address {
        Address(data: Keccak.hash256(Data("DyorHQ major token \(symbol)".utf8)).suffix(20))!
    }

    /// A token a coin may not pass for, with the readings (`readings`) and lower-case forms (`forms`) of its symbol and
    /// names, worked out once.
    private struct LookAlikeTarget {
        let token: Token
        let readings: Set<String>
        let forms: [Text]

        init(_ token: Token, names: [String]) {
            self.token = token
            readings = Set(([token.symbol] + names).flatMap(WalletHoldings.readings))
            forms = Set(([token.symbol] + names).flatMap(WalletHoldings.forms)).map(Text.init)
        }
    }

    /// The curated tokens, then the major ones.
    private static let lookAlikeTargets: [LookAlikeTarget] = Token.core.map { LookAlikeTarget($0, names: [$0.name]) }
        + majors.map { LookAlikeTarget($0.token, names: $0.names) }

    /// The most of a symbol or name `imitated(by:)` judges: its first 128 characters that show (`visible`), or, when a
    /// direction override can show its end first, its last 128 too. No curated or major token's symbol or name comes
    /// near that (the longest, "Lombard Staked Bitcoin", has 22), a screen shows fewer, and a DyorHQ coin keeps fewer
    /// of a name (`DyorCoin.maxStoredName`); so a 40 KB name an airdropped token computes costs what a short one does.
    static let maxJudged = 128

    /// A form of a symbol or name (`forms`), as scalars, for finding one in another: at most `maxJudged` characters and
    /// a few more a compatibility form spells out, so each search is short. Letters are what `Character.isLetter` calls
    /// one (alphabetic).
    struct Text {
        let scalars: [Unicode.Scalar]
        let letters: Int

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
            letters = scalars.reduce(0) { $0 + ($1.properties.isAlphabetic ? 1 : 0) }
        }

        /// Whether `wanted` is in it with no letter right before or after it.
        func standsApart(_ wanted: Text) -> Bool {
            occurrences(of: wanted).contains { start in
                let end = start + wanted.scalars.count
                return !(start > 0 && scalars[start - 1].properties.isAlphabetic) && !(end < scalars.count && scalars[end].properties.isAlphabetic)
            }
        }

        /// Whether `wanted` is in it with no letter anywhere else in it: every letter it has is one of `wanted`'s.
        func standsAlone(_ wanted: Text) -> Bool {
            letters == wanted.letters && !occurrences(of: wanted).isEmpty
        }

        /// Where `wanted` starts in it, each place, in one pass.
        private func occurrences(of wanted: Text) -> [Int] {
            let count = wanted.scalars.count
            guard count > 0, count <= scalars.count else { return [] }
            return (0 ... scalars.count - count).filter { start in
                scalars[start] == wanted.scalars[0] && scalars[start ..< start + count].elementsEqual(wanted.scalars)
            }
        }
    }

    /// Whether `wanted` is in `text` with no letter right before or after it (`Text.standsApart`).
    static func standsApart(_ wanted: String, in text: String) -> Bool { Text(text).standsApart(Text(wanted)) }

    /// Whether `wanted` is in `text` with no letter anywhere else in it (`Text.standsAlone`).
    static func standsAlone(_ wanted: String, in text: String) -> Bool { Text(text).standsAlone(Text(wanted)) }

    /// The ways `text` reads to the eye, for `imitated(by:)`: `visible(text)` ignoring case (tagged "a"); with the digits
    /// and letters that pass for one another made one — 0 as O; 1, I and | as l — keeping case (tagged "b"), so "USDL"
    /// stays apart from "USD1"; and ignoring case with only 0 read as o (tagged "c"), so "M0n", "wm0n" and "usdto" read as
    /// MON, WMON and USDT0 while "USDL" still isn't "USD1". Text with a direction-changing character is read backwards
    /// too: an override can show "CDSU" as "USDC". Empty text has no reading.
    static func readings(_ text: String) -> [String] {
        shownForms(text).flatMap { form in
            ["a:" + form.lowercased(), "b:" + String(String.UnicodeScalarView(form.unicodeScalars.map { lookAlikeDigits[$0] ?? $0 })),
             "c:" + zeroAsO(form.lowercased())]
        }
    }

    /// `text`'s readings "a" and "c" untagged, for finding a token's symbol or name inside other text.
    static func forms(_ text: String) -> [String] {
        shownForms(text).flatMap { [$0.lowercased(), zeroAsO($0.lowercased())] }
    }

    /// `visible(text)`, and backwards too when a direction-changing character can show it so (its end, then, is what
    /// shows first); none for empty text.
    private static func shownForms(_ text: String) -> [String] {
        let base = visible(text)
        guard !base.isEmpty else { return [] }
        guard text.unicodeScalars.contains(where: { bidiControls.contains($0.value) }) else { return [base] }
        return [base, String(visible(text, fromTheEnd: true).reversed())]
    }

    private static func zeroAsO(_ text: String) -> String { text.replacingOccurrences(of: "0", with: "o") }

    /// `text` as it shows, at most `maxJudged` characters of it (the first, or `fromTheEnd` the last): compatibility forms
    /// (full-width and mathematical letters) as their plain letters; invisible, format and direction characters
    /// (zero-width spaces and joiners, soft hyphen, byte-order mark, overrides), control characters, combining marks,
    /// spaces and the blank Braille pattern U+2800 removed; U+FFFD removed too, which is what bytes that aren't text
    /// read as (`ABI.StringDecoding.lossy`) and draws as a mark, not a letter, so "USDC" and one such byte still reads as
    /// "USDC"; letters from other scripts that look like Latin ones (Cyrillic "С", Greek "Ο", Armenian "օ", Lisu "ꓟ",
    /// small capital "ᴏ": `lookAlikeLetters`) as those Latin letters, before the compatibility forms are folded (which
    /// would turn a Greek lunate "Ϲ" into a "Σ" nobody mistakes for C) and after; accents and width ignored. Case is
    /// kept (`readings` decides on it).
    static func visible(_ text: String, fromTheEnd: Bool = false) -> String {
        // What shows, at most `maxJudged` of it, taken before anything else, so a long text costs no more.
        var shown: [Unicode.Scalar] = []
        for scalar in fromTheEnd ? AnyIterator(text.unicodeScalars.reversed().makeIterator()) : AnyIterator(text.unicodeScalars.makeIterator()) {
            if isUnseen(scalar) { continue }
            shown.append(lookAlikeLetters[scalar] ?? scalar)
            if shown.count >= maxJudged { break }
        }
        if fromTheEnd { shown.reverse() }
        let composed = String(String.UnicodeScalarView(shown)).precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in composed.unicodeScalars where !isUnseen(scalar) { scalars.append(lookAlikeLetters[scalar] ?? scalar) }
        let folded = String(scalars).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.filter { !$0.isWhitespace }.prefix(maxJudged))
    }

    /// What doesn't show as a character of its own: spaces, line breaks and tabs; format, control and default-ignorable
    /// characters; combining marks; the invisible ones `Address.isInvisible` names; U+FFFD and the blank Braille pattern
    /// U+2800.
    private static func isUnseen(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .format, .control, .nonspacingMark, .enclosingMark, .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        return properties.isWhitespace || properties.isDefaultIgnorableCodePoint || Address.isInvisible(scalar) || scalar.value == 0xFFFD || scalar.value == 0x2800
    }

    /// Whether `text` is plain printable ASCII — letters, digits, punctuation and spaces — and not empty.
    public static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069: they change the order text shows in.
    private static let bidiControls: Set<UInt32> = Set([0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069))

    /// Letters of other scripts drawn like Latin ones, each with the letter it passes for: Unicode's confusables
    /// (`LookAlikeLetters`, generated from UTS #39 data), with the few below kept as they were written here, case for case
    /// (Unicode reads a Cyrillic "І" or Greek "Ι" as "l", which `readings` "b" does anyway).
    static let lookAlikeLetters: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (code, latin) in LookAlikeLetters.confusables { if let scalar = Unicode.Scalar(code) { map[scalar] = latin.unicodeScalars.first! } }
        return map.merging(handLookAlikes) { _, kept in kept }
    }()

    /// Cyrillic and Greek letters drawn like Latin ones (Unicode's confusables, the unambiguous ones), case for case.
    private static let handLookAlikes: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(UInt32, Character)] = [
            // Cyrillic capitals, then small letters.
            (0x0410, "A"), (0x0412, "B"), (0x0415, "E"), (0x041A, "K"), (0x041C, "M"), (0x041D, "H"), (0x041E, "O"), (0x0420, "P"),
            (0x0421, "C"), (0x0422, "T"), (0x0425, "X"), (0x0423, "Y"), (0x04AE, "Y"), (0x0405, "S"), (0x0406, "I"), (0x0408, "J"), (0x0417, "3"),
            (0x0430, "a"), (0x0435, "e"), (0x043E, "o"), (0x0440, "p"), (0x0441, "c"), (0x0443, "y"), (0x0445, "x"), (0x0455, "s"),
            (0x0456, "i"), (0x0458, "j"), (0x04BB, "h"), (0x0501, "d"), (0x051B, "q"), (0x051D, "w"), (0x04AF, "y"),
            // Greek capitals, then small letters.
            (0x0391, "A"), (0x0392, "B"), (0x0395, "E"), (0x0396, "Z"), (0x0397, "H"), (0x0399, "I"), (0x039A, "K"), (0x039C, "M"),
            (0x039D, "N"), (0x039F, "O"), (0x03A1, "P"), (0x03A4, "T"), (0x03A5, "Y"), (0x03A7, "X"),
            (0x03BF, "o"), (0x03BD, "v"), (0x03C1, "p"), (0x03B9, "i"), (0x03C5, "u"), (0x03C7, "x"), (0x03B1, "a"),
            // Latin letters from other blocks: dotless i, small capital I, script g.
            (0x0131, "i"), (0x026A, "I"), (0x0261, "g"),
        ]
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (code, latin) in pairs { if let scalar = Unicode.Scalar(code) { map[scalar] = latin.unicodeScalars.first! } }
        return map
    }()

    /// Digits and letters drawn alike in most fonts: 0 as O; 1, I and | as l.
    private static let lookAlikeDigits: [Unicode.Scalar: Unicode.Scalar] = ["0": "O", "1": "l", "I": "l", "|": "l"]

    /// The curated dollar stables, by contract address. A token is one of them only by its address: anyone can deploy a
    /// token called "USDC".
    public static let dollarStables: Set<Address> = Set(Token.core.filter { ["USDC", "USDT0", "AUSD", "USDe", "USD1", "mUSD"].contains($0.symbol) }.map(\.address))

    /// `amount` in dollars when `token` is one of the curated dollar stables; nil for any other token, whatever its
    /// symbol.
    public static func stableUSD(_ token: Token, amount: BigUInt) -> Double? {
        dollarStables.contains(token.address) ? Amount.units(amount, decimals: token.decimals) : nil
    }

    /// `prices` with each of `tokens` that is a curated dollar stable (`dollarStables`, by address) and has no price at
    /// $1, as the price finder values USDC and AUSD: USDe, USD1 and mUSD have no pool it looks for, and each is a dollar.
    /// A stable a pool prices keeps that price.
    public static func stablesAtPar(_ prices: [Address: Double], tokens: [Token]) -> [Address: Double] {
        var out = prices
        for token in tokens where dollarStables.contains(token.address) && out[token.address] == nil { out[token.address] = 1 }
        return out
    }

    /// The curated tokens among `tokens`, MON included, with no usable price in `prices`, in `tokens` order: cbBTC, LBTC,
    /// ezETH, rETH and aprMON have no pool the price finder looks for, and any curated token's price read can fail on its
    /// own. Their value is missing, never $0.
    public static func unpricedCurated(_ tokens: [Token], prices: [Address: Double]) -> [Token] {
        tokens.filter { token in
            Token.core(token.address) != nil && !(prices[token.address].map { $0.isFinite && $0 > 0 } ?? false)
        }
    }

    /// `unpricedCurated`, split by why. `noPool`: those the price finder found no pool for (`PriceService.withoutPool`:
    /// cbBTC, LBTC, ezETH, rETH, aprMON), which simply have no price. A list names them and leaves them out of its total,
    /// and a send still starts on the top priced token, so holding any amount of one — a speck anyone can send included —
    /// changes nothing else. `unread`: those whose price read failed (MON's included), whose price is unknown. A list
    /// says so, shows no total and preselects nothing, as when the whole price read fails.
    public static func unpricedCurated(_ tokens: [Token], prices: [Address: Double], noPool: Set<Address>) -> (noPool: [Token], unread: [Token]) {
        let unpriced = unpricedCurated(tokens, prices: prices)
        return (unpriced.filter { noPool.contains($0.address) }, unpriced.filter { !noPool.contains($0.address) })
    }

    /// Symbols as a list in words: "cbBTC", "cbBTC and LBTC", "cbBTC, LBTC and rETH".
    public static func symbolList(_ tokens: [Token]) -> String {
        let symbols = tokens.map(\.symbol)
        guard let last = symbols.last else { return "" }
        return symbols.count == 1 ? last : symbols.dropLast().joined(separator: ", ") + " and " + last
    }
}
