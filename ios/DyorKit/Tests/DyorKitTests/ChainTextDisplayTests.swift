import BigInt
import XCTest
@testable import DyorKit

/// Creator text as the app shows it (`ChainText.shown`): no character that changes direction or hides can reach the
/// screen, emoji and every script still draw, and nothing that is hashed, compared or made into a Moment's link slug
/// changes (`ChainTextBidiTests` lays the result out with CoreText).
final class ChainTextDisplayTests: XCTestCase {
    /// The 13 coins DyorHQ lists on mainnet today (read 2026-09-30): the six named Moments of cohorts 1–3 (cohort 4 has
    /// none yet) and the seven launches of the retired launchpads (the v2 launchpad has none yet).
    static let liveMomentNames = ["Spectacular", "Bitcoin Diva", "0N1 Force NFT", "0N1 Force", "RWA", "Nature"]
    static let liveLaunchNames = ["Laptop", "Good Morning", "Pons", "Quet", "Justice", "Binance Boy", "Baby Pons"]

    func testDirectionAndInvisibleCharactersAreRemoved() {
        let removed: [UInt32] = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C, // direction
                                 0x200B, 0x200C, 0x2060, 0xFEFF, 0x00AD, 0x034F, 0x115F, 0x3164, 0x180E, // invisible
                                 0x00, 0x07, 0x1B, 0x7F, 0x9B] // control
        for value in removed {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(ChainText.shown("PE\(Character(scalar))PE"), "PEPE", String(format: "U+%04X", value))
        }
        XCTAssertEqual(ChainText.shown("PEPE\u{202E} · 10.5 MON"), "PEPE · 10.5 MON")
        XCTAssertEqual(ChainText.shown("\u{2067}\u{202B}Pepe\u{202C}\u{2069}"), "Pepe")
    }

    func testLineBreaksAreSpacesExceptInADescription() {
        XCTAssertEqual(ChainText.shown("Pepe\nCoin"), "Pepe Coin")
        XCTAssertEqual(ChainText.shown("Pepe\r\nCoin\tX"), "Pepe Coin X")
        XCTAssertEqual(ChainText.shown("Pepe\u{2029}Coin"), "Pepe Coin")
        XCTAssertEqual(ChainText.shown("First line\r\nSecond\u{2028}Third\n\nFourth", multiline: true), "First line\nSecond\nThird\n\nFourth")
    }

    func testEmojiAccentsAndEveryScriptStillShow() {
        for text in ["👨‍👩‍👧 Family", "❤️ Love", "❤️‍🔥", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "1️⃣", "👍🏽", "Café", "Cafe\u{0301}", "日本語", "שלום", "مرحبا", "Ελληνικά", "Кириллица", "\u{FFFD}", "A\u{FFFD}Z", "$PEPE · 1.5%"] {
            XCTAssertEqual(ChainText.shown(text), text, text)
        }
        // A joiner or variation selector that follows no emoji is dropped like any other.
        XCTAssertEqual(ChainText.shown("A\u{200D}B\u{FE0F}C"), "ABC")
    }

    /// No name DyorHQ lists today changes as it shows, so no screen and no link slug changes with this: the six named
    /// Moments keep the slugs their links have always had.
    func testNoLiveCoinChangesAndNoSlugMoves() {
        for name in Self.liveMomentNames + Self.liveLaunchNames {
            XCTAssertEqual(ChainText.shown(name), name)
            XCTAssertEqual(MomentSlug.base(ChainText.shown(name)), MomentSlug.base(name))
        }
        let cohorts: [MomentLink.Cohort] = [.c1, .c1, .c1, .c2, .c2, .c3]
        let ids = [1, 2, 3, 1, 2, 1]
        let keys = zip(cohorts, ids).map { MomentKey(factory: $0.factory, id: BigUInt($1)) }
        let slugs = MomentSlug.assign(zip(keys, Self.liveMomentNames).map { (key: $0, name: $1) })
        XCTAssertEqual(keys.map { slugs[$0] }, ["spectacular", "bitcoin-diva", "0n1-force-nft", "0n1-force", "rwa", "nature"])
    }

    /// A Moment's name shows without its direction characters, while its link slug is still made from the name as the
    /// chain has it: "Bit" U+202E "coin" keeps `bit-coin`, and a later plain "Bitcoin" keeps `bitcoin`.
    func testNamesShowCleanedButSlugsReadTheChainsText() async throws {
        let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                     nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Bit\u{202E}coin", "Bitcoin"])
        MomentsChainStub.install { to, data in
            if to == stack.nft(1), data.prefix(4) == ABI.selector(MomentsABI.NFT.provenance) {
                return try! ABI.encode([.tuple([.string("ipfs://x\u{202E}"), .bytes(Data(count: 32)), .string("Accra\u{202E}\n"), .uint(0), .string("")])], MomentsABI.provenanceTuple)
            }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let listed = try await service.moments()
        XCTAssertEqual(listed.map(\.name), ["Bitcoin", "Bitcoin"])
        XCTAssertEqual(listed.last?.provenance.place, "Accra ")
        XCTAssertEqual(listed.last?.provenance.mediaURI, "ipfs://x\u{202E}", "a link is kept as read: it is only opened")
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc(), cohorts: [.c4])
        let first = try await directory.link(for: MomentKey(factory: stack.addresses.factory, id: 1))
        let second = try await directory.link(for: MomentKey(factory: stack.addresses.factory, id: 2))
        XCTAssertEqual(first, MomentLink(name: "bit-coin"))
        XCTAssertEqual(second, MomentLink(name: "bitcoin"))
    }
}
