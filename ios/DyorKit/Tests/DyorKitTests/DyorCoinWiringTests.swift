import BigInt
import CoreGraphics
import XCTest
@testable import DyorKit

/// Build 17: DyorHQ's coins in every screen — their pictures, their labels and the create guard. The rules are tested
/// here directly (`TokenPickerList`, `CoinIcon`, `SymbolSafety`, `LaunchImage`); the app's wiring of them is read from
/// its sources (R10: update these with the code they pin). A DyorHQ coin sent to the wallet is labelled for what it is
/// and is still what IOST-12 protects against: never where a send starts, never in Top Tokens, never funds arriving,
/// never in the picker's main list.
final class DyorCoinWiringTests: XCTestCase {
    private let creator = Address(literal: "0x6115cAF237026B45B037191B20056d1e4AfAfFa3")

    private func launchCoin(_ token: Token, logo: String = "") -> DyorCoin {
        DyorCoin(address: token.address, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: token.symbol,
                 name: token.name, creator: creator, logo: logo, pair: .zero)
    }

    // MARK: The rules

    /// A received DyorHQ coin keeps its DyorHQ label and stays out of the picker's main list, however much of it is held
    /// (held tokens float to the top); a search finds it in its own section, never under Unverified. A DyorHQ coin with a
    /// warning, and any other received token, is under Unverified. And it is never where a send starts.
    func testAReceivedDyorHQCoinNeverEntersThePickersMainList() {
        let qt = Token(address: DyorCoinChain.qt, symbol: "QT", name: "Quet", decimals: 18)
        let quack = Token(address: Address(literal: "0x0000000000000000000000000000000000000d01"), symbol: "QUACK", name: "Quack", decimals: 18)
        let fakeUSDC = Token(address: Address(literal: "0x0000000000000000000000000000000000000d02"), symbol: "USDC.e", name: "Quick Dollar", decimals: 6)
        let chosen = Token(address: Address(literal: "0x0000000000000000000000000000000000000d03"), symbol: "MEME", name: "Meme", decimals: 18)
        let coins = [qt.address: launchCoin(qt), fakeUSDC.address: launchCoin(fakeUSDC)]
        let isDyorHQ = { (token: Token) in TokenBadge.of(token, coin: coins[token.address], receivedUnasked: true).isDyorHQ }
        let universe = Token.core + [qt, quack, fakeUSDC, chosen]
        let received: Set<Address> = [qt.address, quack.address, fakeUSDC.address]
        let lots = BigUInt(10).power(30)
        let balances = [qt.address: lots, quack.address: lots, fakeUSDC.address: lots, chosen.address: 1]

        XCTAssertTrue(isDyorHQ(qt), "labelled DyorHQ Launch")
        for query in ["", "Q", "QT", "Quet"] {
            let main = TokenPickerList.main(universe, unverified: received, balances: balances, query: query, tradableOnly: true)
            XCTAssertFalse(main.contains(qt), "never in the main list: \(query)")
            XCTAssertTrue(main.allSatisfy { !received.contains($0.address) }, query)
        }
        XCTAssertEqual(TokenPickerList.main(universe, unverified: received, balances: balances, query: "", tradableOnly: true).first, chosen,
                       "a chosen token the wallet holds floats to the top")
        XCTAssertTrue(TokenPickerList.received(universe, unverified: received, query: "", excluding: nil, tradableOnly: true, isDyorHQ: isDyorHQ) == ([], []),
                      "only a search shows received tokens")
        let found = TokenPickerList.received(universe, unverified: received, query: "Q", excluding: nil, tradableOnly: true, isDyorHQ: isDyorHQ)
        XCTAssertEqual(found.dyorHQ, [qt], "its own section")
        XCTAssertEqual(found.unverified, [quack, fakeUSDC], "every other one, a DyorHQ look-alike included, under Unverified")
        XCTAssertTrue(TokenPickerList.received(universe, unverified: received, query: "Q", excluding: qt.address, tradableOnly: true, isDyorHQ: isDyorHQ).dyorHQ.isEmpty,
                      "not twice when a pasted address shows it")
        // Chosen in the app (a swap into it, or the wallet's own coin), it is listed like any other.
        XCTAssertTrue(TokenPickerList.main(universe, unverified: [], balances: balances, query: "", tradableOnly: true).contains(qt))

        let held = HeldToken(token: qt, balance: lots, usd: 1_000, unverified: true)
        XCTAssertEqual(held.badge(coins[qt.address]), .dyorLaunch)
        XCTAssertNil(WalletHoldings.defaultChoice([held]), "never preselected to send")
        XCTAssertEqual(WalletHoldings.defaultChoice([held, HeldToken(token: .usdc, balance: 1_000_000, usd: 1)])?.token, .usdc)
    }

    /// A bundled logo is a curated address's alone: a token that carries a curated token's symbol or name — a list token,
    /// a DyorHQ launch, one with a list logo of its own — never wears it.
    func testABundledLogoIsOnlyEverACuratedAddresss() {
        let policy = ImageSourcePolicy.dyorhq
        var n = 0
        for curated in Token.core where !curated.isNative {
            XCTAssertEqual(CoinIcon.resolve(curated, coin: nil, policy: policy), curated.logoURL == nil ? .letters : .bundled(symbol: curated.symbol))
            n += 1
            let address = Address(literal: "0x" + String(repeating: "0", count: 36) + String(format: "%04x", 0xe000 + n))
            let copy = Token(address: address, symbol: curated.symbol, name: curated.name, decimals: curated.decimals, logoURL: curated.logoURL)
            let kuru = Token(address: address, symbol: curated.symbol, name: "Anything", decimals: 18,
                             logoURL: URL(string: "https://dsvxs4ecepqgj.cloudfront.net/\(curated.symbol).png"))
            let launch = Token(address: address, symbol: curated.symbol, name: "A coin", decimals: 18, isLaunchpad: true)
            for token in [copy, kuru, launch] {
                for coin in [nil, launchCoin(launch, logo: DyorCoinChain.media(creator, "art.jpg"))] {
                    if case .bundled = CoinIcon.resolve(token, coin: coin, policy: policy) { XCTFail("\(curated.symbol) at \(address.hex) wears the curated logo") }
                }
            }
        }
        XCTAssertGreaterThan(n, 10)
        // A DyorHQ launch with any other symbol shows its own art, filled.
        let qt = Token(address: DyorCoinChain.qt, symbol: "QT", name: "Quet", decimals: 18)
        if case .remote(_, let fill) = CoinIcon.resolve(qt, coin: launchCoin(qt, logo: DyorCoinChain.media(creator, "qt.jpg")), policy: policy) {
            XCTAssertTrue(fill)
        } else {
            XCTFail("QT shows its art")
        }
    }

    /// The create forms' guard allows what their ticker filter lets through in the scripts the owner asked for, and refuses
    /// a curated or major token's name or a ticker that doesn't show as itself.
    func testTheCreateGuardKeepsAccentedLatinAndEastAsianTickers() {
        for symbol in ["QT", "CAFÉ", "PIÑA", "狗狗", "강아지", "ドージ", "PEPE2"] {
            XCTAssertNil(SymbolSafety.createRefusal(name: "My Coin", symbol: symbol), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "My Coin", symbol: symbol, maxName: SymbolSafety.maxMomentNameLength), symbol)
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "My Coin", symbol: "USDC"), .symbolImitates(.usdc))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Quiet", symbol: "Q\u{0422}"), .symbolNotDisplaySafe)
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "n", count: 33), symbol: "SAFE"), .nameTooLong(32))
        XCTAssertNil(SymbolSafety.createRefusal(name: String(repeating: "n", count: 33), symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength))
    }

    /// The uploaded launch picture is the photo's middle square.
    func testALaunchPictureIsTheMiddleSquare() {
        XCTAssertEqual(LaunchImage.side, 512)
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: 4000, height: 3000)), CGRect(x: 500, y: 0, width: 3000, height: 3000))
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: 300, height: 600)), CGRect(x: 0, y: 150, width: 300, height: 300))
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: 512, height: 512)), CGRect(x: 0, y: 0, width: 512, height: 512))
        XCTAssertEqual(LaunchImage.centreSquare(.zero), .zero)
        XCTAssertEqual(LaunchImage.centreSquare(CGSize(width: CGFloat.nan, height: 10)), .zero)
    }

    // MARK: The app's wiring

    /// The app's sources (ios/DyorHQ), whitespace squeezed to single spaces, or a skip when this checkout has only the
    /// package.
    private static func app() throws -> URL {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return app
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func source(_ path: String) throws -> String {
        squeezed(try String(contentsOf: try app().appendingPathComponent(path), encoding: .utf8))
    }

    /// Every Swift file of the app, by its path under ios/DyorHQ, squeezed.
    private static func sources() throws -> [(path: String, text: String)] {
        let root = try app()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { file in
            (String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)), squeezed(try String(contentsOf: file, encoding: .utf8)))
        }
    }

    /// The text of `source` from `start` to `end`.
    private static func between(_ source: String, _ start: String, _ end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), start)
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex), end)
        return String(source[from.lowerBound..<to.lowerBound])
    }

    /// Deleting the account (or this device's data) clears every image cache — the logo loader's, the Moments loader's
    /// and URLCache's, on disk — and deletes the registry's file, before the sign-out.
    func testErasingThisDeviceClearsTheImageCachesAndTheRegistry() throws {
        let session = try Self.source("Wallet/Session.swift")
        let erase = try Self.between(session, "func eraseLocalData() async {", "private var relyingParty")
        let signedOut = try XCTUnwrap(erase.range(of: "state = .signedOut"))
        for step in ["RemoteImageLoader.shared.removeAll()", "MomentMediaLoader.shared.removeAll()", "URLCache.shared.removeAllCachedResponses()",
                     "await dyorCoins?.erase()"] {
            let found = try XCTUnwrap(erase.range(of: step), step)
            XCTAssertLessThan(found.upperBound, signedOut.lowerBound, step)
        }
        XCTAssertTrue(try Self.source("App/AppEnvironment.swift").contains("session.dyorCoins = dyorCoins"))
        let model = try Self.source("App/DyorCoinsModel.swift")
        XCTAssertTrue(try Self.between(model, "func erase() async {", "extension ImageSourcePolicy").contains("await registry.erase() coins = [:]"))
        let images = try Self.source("Design/RemoteImage.swift")
        XCTAssertTrue(try Self.between(images, "func removeAll() {", "static func cost(").contains("images.removeAllObjects() misses = RecentMisses()"))
        let moments = try Self.source("Moments/MomentsUI.swift")
        XCTAssertTrue(try Self.between(moments, "func removeAll() {", "func load(key:").contains("images.removeAllObjects() misses = [:]"))
    }

    /// The registry erase deletes its file.
    func testTheRegistrysEraseDeletesItsFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "b2-erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DyorCoinStore(url: folder.appending(path: DyorCoinStore.fileName()))
        try store.save(DyorCoinStore.Snapshot(coins: [], checkpoints: [.init(factory: DyorCoinChain.legacy, count: 1)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc(), store: store)
        await registry.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(DyorCoinStore.fileName(), "dyor-coins-143.json")
    }
}
