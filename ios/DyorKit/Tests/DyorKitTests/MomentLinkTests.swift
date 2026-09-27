import BigInt
@testable import DyorKit
import XCTest

final class MomentLinkTests: XCTestCase {
    private func parse(_ text: String) -> MomentLink? { URL(string: text).flatMap(MomentLink.init(url:)) }
    private func key(_ cohort: MomentLink.Cohort, _ id: Int) -> MomentKey { MomentKey(factory: cohort.factory, id: BigUInt(id)) }

    /// The cohort table is the app's Moments deployments, in publish order (the order names are given out in): cohort 1,
    /// cohort 2, then the live factory.
    func testCohortTableMatchesTheDeploymentsInPublishOrder() {
        XCTAssertEqual(MomentLink.Cohort.allCases, [.c1, .c2, .live])
        XCTAssertEqual(MomentLink.Cohort.live.factory, MomentsAddresses.monadMainnet.factory)
        XCTAssertEqual(MomentLink.Cohort.c2.factory, MomentsAddresses.retiredMainnet[0].factory)
        XCTAssertEqual(MomentLink.Cohort.c1.factory, MomentsAddresses.retiredMainnet[1].factory)
        XCTAssertLessThan(MomentsAddresses.retiredMainnet[1].deployBlock, MomentsAddresses.retiredMainnet[0].deployBlock)
        XCTAssertLessThan(MomentsAddresses.retiredMainnet[0].deployBlock, MomentsAddresses.monadMainnet.deployBlock)
        XCTAssertEqual(MomentLink.Cohort(factory: MomentsAddresses.monadMainnet.factory), .live)
        XCTAssertNil(MomentLink.Cohort(factory: .zero))
        XCTAssertNil(MomentLink(key: MomentKey(factory: MomentsAddresses.monadMainnet.collect, id: 1)))
    }

    // MARK: Names

    func testSlugBase() {
        let cases: [(String, String)] = [
            ("Bitcoin Diva", "bitcoin-diva"),
            ("Spectacular", "spectacular"),
            ("0N1 Force", "0n1-force"),
            ("0N1 Force NFT", "0n1-force-nft"),
            ("RWA", "rwa"),
            ("Logan Paul\u{2019}s Portfolio", "logan-paul-s-portfolio"),
            ("Beyoncé Live!!", "beyonce-live"),
            ("naïve café", "naive-cafe"),
            ("\u{FF26}\u{FF35}\u{FF2C}\u{FF2C} width", "full-width"), // fullwidth letters
            ("\u{FB01}re", "fire"), // the "fi" ligature
            ("  --Hello__World-- ", "hello-world"),
            ("C1", "c1"),
            ("2024", "moment-2024"),
            ("1 2 3", "moment-1-2-3"),
            ("🔥🔥", "moment"),
            ("", "moment"),
            ("Биткоин", "moment"), // no Latin letters survive
            ("Moon 🚀 Landing", "moon-landing"),
        ]
        for (name, slug) in cases {
            XCTAssertEqual(MomentSlug.base(name), slug, name)
            XCTAssertTrue(MomentSlug.isValid(slug), slug)
        }
        let long = MomentSlug.base(String(repeating: "abcdefghi ", count: 12))
        XCTAssertLessThanOrEqual(long.count, MomentSlug.maxBase)
        XCTAssertFalse(long.hasSuffix("-"))
        XCTAssertTrue(MomentSlug.isValid(long))
    }

    /// The first Moment with a name gets it plain, later ones the first free "-2", "-3"…, and publishing more never
    /// changes an earlier Moment's slug.
    func testSlugAssignment() {
        let ordered: [(key: MomentKey, name: String)] = [
            (key(.c1, 1), "Bitcoin Diva"),
            (key(.c1, 2), "bitcoin diva"),
            (key(.c1, 3), "Bitcoin-Diva 2"),
            (key(.c2, 1), "Bitcoin Diva"),
            (key(.live, 1), "🔥"),
            (key(.live, 2), "🚀"),
        ]
        let slugs = MomentSlug.assign(ordered)
        XCTAssertEqual(slugs[key(.c1, 1)], "bitcoin-diva")
        XCTAssertEqual(slugs[key(.c1, 2)], "bitcoin-diva-2")
        XCTAssertEqual(slugs[key(.c1, 3)], "bitcoin-diva-2-2")
        XCTAssertEqual(slugs[key(.c2, 1)], "bitcoin-diva-3")
        XCTAssertEqual(slugs[key(.live, 1)], "moment")
        XCTAssertEqual(slugs[key(.live, 2)], "moment-2")
        XCTAssertEqual(Set(slugs.values).count, ordered.count, "unique")
        for n in 1...ordered.count {
            let prefix = MomentSlug.assign(Array(ordered.prefix(n)))
            for (k, slug) in prefix { XCTAssertEqual(slugs[k], slug, "stable as more are published") }
        }
    }

    func testSlugValidity() {
        for good in ["a", "bitcoin-diva", "0n1-force", "moment-2024", "c1", "a1-b2-c3"] { XCTAssertTrue(MomentSlug.isValid(good), good) }
        for bad in ["", "2024", "-a", "a-", "a--b", "A", "bitcoin_diva", "bitcoin diva", "é", "a.b", "a/b",
                    String(repeating: "a", count: MomentSlug.maxLength + 1)] {
            XCTAssertFalse(MomentSlug.isValid(bad), bad)
        }
    }

    // MARK: Links

    func testNameLinks() throws {
        let link = try XCTUnwrap(MomentLink(name: "bitcoin-diva"))
        XCTAssertEqual(link.url.absoluteString, "https://dyorhq.fun/moments/bitcoin-diva")
        XCTAssertEqual(link.appURL.absoluteString, "dyorhq://moments/bitcoin-diva")
        XCTAssertEqual(MomentLink(url: link.url), link)
        XCTAssertEqual(MomentLink(url: link.appURL), link)
        XCTAssertNil(MomentLink(name: "Bitcoin Diva"))
        XCTAssertNil(MomentLink(name: "2024"))
    }

    /// The NFTs' on-chain `external_url` values (read 2026-09-27) resolve to their cohort and id, and round-trip.
    func testOnChainExternalURLsResolve() throws {
        let onChain: [(String, MomentLink.Cohort, Int)] = [
            ("https://dyorhq.fun/moments/c1/1", .c1, 1), ("https://dyorhq.fun/moments/c1/2", .c1, 2),
            ("https://dyorhq.fun/moments/c1/3", .c1, 3), ("https://dyorhq.fun/moments/c2/1", .c2, 1),
            ("https://dyorhq.fun/moments/c2/2", .c2, 2), ("https://dyorhq.fun/moments/7", .live, 7),
        ]
        for (text, cohort, id) in onChain {
            let link = try XCTUnwrap(parse(text), text)
            XCTAssertEqual(link.target, .key(key(cohort, id)), text)
            XCTAssertEqual(link.url.absoluteString, text)
        }
        for cohort in MomentLink.Cohort.allCases {
            for id in [1, 9, 10, 123_456_789, 999_999_999_999_999_999] as [BigUInt] {
                let link = try XCTUnwrap(MomentLink(cohort: cohort, id: id))
                XCTAssertEqual(MomentLink(url: link.url), link)
                XCTAssertEqual(MomentLink(url: link.appURL), link)
            }
        }
        XCTAssertNil(MomentLink(cohort: .live, id: 0))
        XCTAssertNil(MomentLink(cohort: .live, id: BigUInt(10).power(18)))
    }

    /// Spellings that mean the same thing: host case, port 443, one trailing slash, any query or fragment (ignored), a
    /// name in capitals, and the app scheme.
    func testAcceptedVariants() {
        let name: [(String, String)] = [
            ("https://dyorhq.fun/moments/bitcoin-diva/", "bitcoin-diva"),
            ("https://DYORHQ.FUN/moments/bitcoin-diva", "bitcoin-diva"),
            ("https://dyorhq.fun:443/moments/Bitcoin-Diva", "bitcoin-diva"),
            ("https://dyorhq.fun/moments/bitcoin-diva-2?utm_source=x&fbclid=y#web", "bitcoin-diva-2"),
            ("https://dyorhq.fun/moments/moment-2024", "moment-2024"),
            ("https://dyorhq.fun/moments/c1", "c1"), // a Moment named "C1"; the cohort form has two segments
            ("https://dyorhq.fun/moments/c1/", "c1"),
            ("dyorhq://moments/bitcoin-diva", "bitcoin-diva"),
            ("DYORHQ://moments/Bitcoin-Diva/", "bitcoin-diva"),
        ]
        for (text, slug) in name { XCTAssertEqual(parse(text)?.target, .name(slug), text) }
        let keyed: [(String, MomentLink.Cohort, Int)] = [
            ("https://dyorhq.fun/moments/2024", .live, 2024),
            ("https://dyorhq.fun/moments/c2/2/?ref=abc#top", .c2, 2),
            ("dyorhq://moments/3", .live, 3),
            ("dyorhq://moments/c1/3", .c1, 3),
        ]
        for (text, cohort, id) in keyed { XCTAssertEqual(parse(text)?.target, .key(key(cohort, id)), text) }
    }

    /// Everything else is nil.
    func testRejected() {
        let rejected = [
            // origin
            "http://dyorhq.fun/moments/bitcoin-diva", "https://www.dyorhq.fun/moments/bitcoin-diva", "https://m.dyorhq.fun/moments/1",
            "https://accounts.dyorhq.fun/moments/1", "https://dyorhq.fun.evil.example/moments/1", "https://evil.example/moments/1",
            "https://u@dyorhq.fun/moments/1", "https://u:p@dyorhq.fun/moments/1", "https://dyorhq.fun:8443/moments/1",
            "ftp://dyorhq.fun/moments/1", "https://dyorhq.fun./moments/1",
            // shape
            "https://dyorhq.fun", "https://dyorhq.fun/", "https://dyorhq.fun/bitcoin-diva", "https://dyorhq.fun/moments",
            "https://dyorhq.fun/moments/", "https://dyorhq.fun/Moments/bitcoin-diva", "https://dyorhq.fun/moment/bitcoin-diva",
            "https://dyorhq.fun/x/moments/1", "https://dyorhq.fun/moments//1", "https://dyorhq.fun/moments/1//",
            "https://dyorhq.fun/moments/bitcoin-diva/buy", "https://dyorhq.fun/moments/c1/1/2", "https://dyorhq.fun/moments/c1//",
            // names
            "https://dyorhq.fun/moments/bitcoin%20diva", "https://dyorhq.fun/moments/bitcoin_diva", "https://dyorhq.fun/moments/-diva",
            "https://dyorhq.fun/moments/diva-", "https://dyorhq.fun/moments/a--b", "https://dyorhq.fun/moments/%E2%9C%93",
            "https://dyorhq.fun/moments/caf%C3%A9", "https://dyorhq.fun/moments/a.b",
            "https://dyorhq.fun/moments/" + String(repeating: "a", count: MomentSlug.maxLength + 1),
            // ids and cohorts
            "https://dyorhq.fun/moments/0", "https://dyorhq.fun/moments/01", "https://dyorhq.fun/moments/-1",
            "https://dyorhq.fun/moments/%31", "https://dyorhq.fun/moments/%D9%A1", "https://dyorhq.fun/moments/1234567890123456789",
            "https://dyorhq.fun/moments/c3/1", "https://dyorhq.fun/moments/c4/1", "https://dyorhq.fun/moments/C1/1",
            "https://dyorhq.fun/moments/live/1", "https://dyorhq.fun/moments/c1/0", "https://dyorhq.fun/moments/c1/bitcoin-diva",
            // the scheme
            "dyorhq://oauth?code=x", "dyorhq://moments", "dyorhq://moments/", "dyorhq://moment/1", "dyorhq:moments/1",
            "dyorhq://moments:80/1",
        ]
        for text in rejected { XCTAssertNil(parse(text), text) }
        XCTAssertTrue(("١" as Character).isNumber, "why the digit check is ASCII, not isNumber")
    }

    /// Only the website's Moments paths and the scheme's `moments` host are ours: Privy's callback on the same scheme
    /// is not, so it gets no "not a Moment" notice.
    func testIsOurs() {
        XCTAssertTrue(MomentLink.isOurs(URL(string: "https://dyorhq.fun/moments/whatever_x")!))
        XCTAssertTrue(MomentLink.isOurs(URL(string: "dyorhq://moments/abc_x")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "https://dyorhq.fun/privacy")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "dyorhq://oauth?code=x")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "https://accounts.dyorhq.fun/")!))
        XCTAssertFalse(MomentLink.isOurs(URL(string: "https://evil.example/moments/1")!))
    }

    /// Every row of the gate.
    func testGate() {
        typealias G = MomentLinkGate
        XCTAssertEqual(G.decide(phase: .loading, updateRequired: false, deletionScreen: false, busy: false), .hold)
        XCTAssertEqual(G.decide(phase: .loading, updateRequired: true, deletionScreen: false, busy: true), .hold)
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: false, deletionScreen: false, busy: false), .banner)
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: false, deletionScreen: true, busy: false), .hold)
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: true, deletionScreen: true, busy: false), .hold, "the deletion screens come before the update gate")
        XCTAssertEqual(G.decide(phase: .signedOut, updateRequired: true, deletionScreen: false, busy: false), .drop)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: false), .deliver)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: false, deletionScreen: false, busy: true), .hold)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: true, deletionScreen: false, busy: false), .drop)
        XCTAssertEqual(G.decide(phase: .signedIn, updateRequired: true, deletionScreen: false, busy: true), .drop)
    }
}
