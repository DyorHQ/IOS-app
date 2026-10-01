import XCTest
@testable import DyorKit

/// The owner's remote switches (`RemoteFlags`): the optional `flags` of the public `app_config` row 'ios', read with the
/// minimum build. Each is on unless the row says JSON `false` for it, so nothing is written to production to ship, and a
/// row that is missing, malformed or mistyped never turns a feature off.
final class RemoteFlagsTests: XCTestCase {
    private let base = "https://fmnjqrguvopusfufmirs.supabase.co"
    private lazy var backend = SupabaseClient(url: URL(string: base)!, anonKey: "sb_publishable_test", session: WalletAuthCapture.session())

    override func setUp() {
        super.setUp()
        WalletAuthCapture.reset()
    }

    private func parse(_ json: String) -> RemoteFlags { RemoteFlags.parse(Data(json.utf8)) }

    /// Absent: the row as it is today (no `flags`), no row at all, or a switch left out — every switch on.
    func testAbsentIsOn() {
        XCTAssertEqual(RemoteFlags.on, RemoteFlags(dyorVenuePrices: true, dyorBadges: true))
        XCTAssertEqual(parse(#"[{"value":{"min_build":16}}]"#), .on, "today's row")
        XCTAssertEqual(parse(#"[]"#), .on, "no row")
        XCTAssertEqual(parse(#"[{"value":{"min_build":16,"flags":{}}}]"#), .on, "no switch named")
        XCTAssertEqual(parse(#"[{"value":{"flags":{"dyorBadges":false}}}]"#), RemoteFlags(dyorVenuePrices: true, dyorBadges: false), "one left out stays on")
    }

    /// True is on and false is off, each switch on its own.
    func testTrueAndFalse() {
        XCTAssertEqual(parse(#"[{"value":{"min_build":16,"flags":{"dyorVenuePrices":true,"dyorBadges":true}}}]"#), .on)
        XCTAssertEqual(parse(#"[{"value":{"min_build":16,"flags":{"dyorVenuePrices":false,"dyorBadges":true}}}]"#), RemoteFlags(dyorVenuePrices: false, dyorBadges: true))
        XCTAssertEqual(parse(#"[{"value":{"min_build":16,"flags":{"dyorVenuePrices":true,"dyorBadges":false}}}]"#), RemoteFlags(dyorVenuePrices: true, dyorBadges: false))
        XCTAssertEqual(parse(#"[{"value":{"flags":{"dyorVenuePrices":false,"dyorBadges":false}}}]"#), RemoteFlags(dyorVenuePrices: false, dyorBadges: false))
    }

    /// Malformed is on: a value that isn't JSON true or false, a `flags` that isn't an object, a body that isn't the
    /// row's answer.
    func testMalformedIsOn() {
        for value in [#""false""#, "0", "1", "null", "[]", "{}", #""off""#, "-1"] {
            XCTAssertEqual(parse(#"[{"value":{"flags":{"dyorVenuePrices":\#(value),"dyorBadges":\#(value)}}}]"#), .on, value)
        }
        for flags in [#""dyorVenuePrices""#, "false", "[false]", "null", "7"] {
            XCTAssertEqual(parse(#"[{"value":{"min_build":16,"flags":\#(flags)}}]"#), .on, flags)
        }
        for body in ["", "not json", "{}", #"{"value":{"flags":{"dyorVenuePrices":false}}}"#, #"[{"value":{"flags":{"dyorVenuePrices":false}}},{"value":{}}]"#,
                     #"[{"flags":{"dyorVenuePrices":false}}]"#, #"[{"value":"{\"flags\":{\"dyorVenuePrices\":false}}"}]"#] {
            XCTAssertEqual(parse(body), .on, body)
        }
    }

    /// The minimum build and the switches come from one read of the row, and a malformed minimum doesn't hide the switches.
    func testOneReadGivesTheMinimumAndTheSwitches() async throws {
        WalletAuthCapture.replies = [(200, #"[{"value":{"min_build":16,"message":"","flags":{"dyorVenuePrices":false}}}]"#)]
        let config = try await backend.iosAppConfig()
        XCTAssertEqual(config.minimum?.minBuild, 16)
        XCTAssertEqual(config.flags, RemoteFlags(dyorVenuePrices: false, dyorBadges: true))
        XCTAssertEqual(WalletAuthCapture.requests.count, 1)
        XCTAssertEqual(WalletAuthCapture.requests.first?.url?.absoluteString, "\(base)/rest/v1/app_config?key=eq.ios&select=value")

        WalletAuthCapture.reset()
        WalletAuthCapture.replies = [(200, #"[{"value":{"min_build":"sixteen","flags":{"dyorBadges":false}}}]"#)]
        let mistyped = try await backend.iosAppConfig()
        XCTAssertNil(mistyped.minimum)
        XCTAssertEqual(mistyped.flags, RemoteFlags(dyorVenuePrices: true, dyorBadges: false))
    }

    /// The app applies them: the gate reads them with the minimum (a failed read keeps what it had), the environment
    /// turns DyorHQ venue prices on at launch and hands the switch to the price service in order, and the DyorHQ labels'
    /// switch is applied in the one place every label comes from. The price service has the registry and the session's
    /// one clock, which every service that shows a time shares.
    func testTheAppAppliesTheSwitches() throws {
        let gate = try DocsLinksTests.appSource("App/UpdateGate.swift")
        XCTAssertTrue(gate.contains("guard let config = try? await client.iosAppConfig() else { return }\n        flags = config.flags\n        onFlags?(config.flags)"))
        XCTAssertTrue(gate.contains("private(set) var flags = RemoteFlags.on"))
        XCTAssertFalse(gate.contains("client.minimumBuild()"), "one read of the row")

        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        for part in ["clock = BlockClock(rpc: rpc)", "prices = PriceService(rpc: rpc, registry: registry, clock: clock, dyorVenues: true)",
                     "launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad, clock: clock)",
                     "moments = MomentsService(rpc: rpc, addresses: config.moments, clock: clock)",
                     "RetiredMoments(rpc: rpc, addresses: $0, clock: clock)",
                     "activity = TokenActivityService(rpc: RPCClient(url: logsURL), clock: clock)",
                     "swapHistory = SwapHistoryService(rpc: RPCClient(url: logsURL), clock: clock)",
                     "dyorCoins = DyorCoinsModel(registry: registry, policy: ImageSourcePolicy(supabaseURL: config.supabaseURL))",
                     "updateGate.onFlags = { [weak self] flags in self?.apply(flags) }",
                     "dyorCoins.showsDyorBadges = flags.dyorBadges",
                     "await previous?.value\n            await prices.setUsesDyorVenues(flags.dyorVenuePrices)"] {
            XCTAssertTrue(environment.contains(part), part)
        }
        XCTAssertEqual(environment.components(separatedBy: "BlockClock(").count - 1, 1, "one clock")
        XCTAssertEqual(environment.components(separatedBy: "clock: clock").count - 1, 6, "prices, the launchpad, Moments, past cohorts, activity, swap history")

        let coins = try DocsLinksTests.appSource("App/DyorCoinsModel.swift")
        XCTAssertTrue(coins.contains("var showsDyorBadges = true"))
        XCTAssertTrue(coins.contains("TokenBadge.of(token, coin: showsDyorBadges ? coins[token.address] : nil, receivedUnasked: receivedUnasked)"))
        XCTAssertEqual(coins.components(separatedBy: "TokenBadge.of(").count - 1, 1, "every label in one place")
    }

    /// With the labels off a DyorHQ coin judges as build 16 judged it: no DyorHQ label, Unverified when it was sent.
    func testLabelsOffIsBuild16sDisplay() {
        let coin = Address(literal: "0x00000000000000000000000000000000000c0074")
        let token = Token(address: coin, symbol: "QT", name: "Quiet", decimals: 18)
        XCTAssertEqual(TokenBadge.of(token, coin: nil, receivedUnasked: true), .unverified)
        XCTAssertEqual(TokenBadge.of(token, coin: nil, receivedUnasked: false), .none)
    }
}
