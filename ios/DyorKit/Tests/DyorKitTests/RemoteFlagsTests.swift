import XCTest
@testable import DyorKit

/// The owner's remote switches (`RemoteFlags`): the optional `flags` of the public `app_config` row 'ios', read with the
/// minimum build. Each is on unless the row says JSON `false` for it, so nothing is written to production to ship, and a
/// row that is missing, malformed or mistyped never turns a feature off — the server's history included (the owner's
/// decision, 2026-10-09). The history epoch is a whole number from 0, anything else 0.
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
        XCTAssertEqual(RemoteFlags.on, RemoteFlags(dyorVenuePrices: true, dyorBadges: true, serverHistory: true, historyEpoch: 0))
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
        XCTAssertEqual(parse(#"[{"value":{"flags":{"serverHistory":false}}}]"#), RemoteFlags(serverHistory: false), "the server's history off, the rest on")
        XCTAssertEqual(parse(#"[{"value":{"flags":{"serverHistory":true,"historyEpoch":2}}}]"#), RemoteFlags(serverHistory: true, historyEpoch: 2))
        XCTAssertEqual(parse(#"[{"value":{"flags":{"dyorBadges":false,"historyEpoch":7}}}]"#), RemoteFlags(dyorBadges: false, historyEpoch: 7), "the switch left out stays on")
    }

    /// The server's history is on unless the row says JSON `false`, like every switch (the owner's decision, against the
    /// contract's opt-in): the server has its own instant switch, and the app fails open.
    func testTheServersHistoryIsOnUnlessTheRowTurnsItOff() {
        XCTAssertTrue(RemoteFlags.on.serverHistory)
        XCTAssertTrue(parse(#"[{"value":{"min_build":16}}]"#).serverHistory, "today's row")
        XCTAssertTrue(parse(#"[{"value":{"flags":{}}}]"#).serverHistory)
        for value in ["true", #""false""#, "0", "null", "{}", "[]"] {
            XCTAssertTrue(parse(#"[{"value":{"flags":{"serverHistory":\#(value)}}}]"#).serverHistory, value)
        }
        XCTAssertFalse(parse(#"[{"value":{"flags":{"serverHistory":false}}}]"#).serverHistory)
    }

    /// The history epoch: a whole number from 0 to 2^31 - 1 as given (JSON has no integers apart: 3.0 is 3); anything
    /// else — a fraction, a negative, a string, a boolean, null, too large, left out — 0.
    func testTheHistoryEpochIsAWholeNumberElseZero() {
        func epoch(_ value: String) -> Int { parse(#"[{"value":{"flags":{"historyEpoch":\#(value)}}}]"#).historyEpoch }
        XCTAssertEqual(epoch("0"), 0)
        XCTAssertEqual(epoch("1"), 1)
        XCTAssertEqual(epoch("42"), 42)
        XCTAssertEqual(epoch("3.0"), 3)
        XCTAssertEqual(epoch("1e2"), 100)
        XCTAssertEqual(epoch("2147483647"), 2_147_483_647)
        XCTAssertEqual(RemoteFlags.largestEpoch, 2_147_483_647)
        for value in ["2147483648", "1e20", "-1", "-0.5", "2.5", #""3""#, "true", "false", "null", "[3]", #"{"n":3}"#] {
            XCTAssertEqual(epoch(value), 0, value)
        }
        XCTAssertEqual(parse(#"[{"value":{"flags":{"serverHistory":false}}}]"#).historyEpoch, 0, "left out")
        XCTAssertEqual(parse("not json").historyEpoch, 0)
        // The switches beside it stay as the row says.
        XCTAssertEqual(parse(#"[{"value":{"flags":{"historyEpoch":"9","dyorVenuePrices":false}}}]"#), RemoteFlags(dyorVenuePrices: false, historyEpoch: 0))
    }

    /// Malformed is on: a value that isn't JSON true or false, a `flags` that isn't an object, a body that isn't the
    /// row's answer.
    func testMalformedIsOn() {
        for value in [#""false""#, "0", "1", "null", "[]", "{}", #""off""#, "-1"] {
            XCTAssertEqual(parse(#"[{"value":{"flags":{"dyorVenuePrices":\#(value),"dyorBadges":\#(value),"serverHistory":\#(value)}}}]"#), .on, value)
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
    /// switch is applied in the one place every label comes from. The server's history's switch goes to the history model
    /// and its epoch to the store, in order and whatever the switch says, both kept for the next launch and applied from
    /// it before the flags are read again. The price service has the registry and the session's one clock, which every
    /// service that shows a time shares.
    func testTheAppAppliesTheSwitches() throws {
        let gate = try DocsLinksTests.appSource("App/UpdateGate.swift")
        XCTAssertTrue(gate.contains("guard let config = try? await client.iosAppConfig() else { return }\n        flags = config.flags\n        onFlags?(config.flags)"))
        XCTAssertTrue(gate.contains("private(set) var flags = RemoteFlags.on"))
        XCTAssertFalse(gate.contains("client.minimumBuild()"), "one read of the row")

        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        for part in ["clock = BlockClock(rpc: rpc)", "prices = PriceService(rpc: rpc, registry: registry, clock: clock, dyorVenues: true)",
                     "launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad, logsRPC: logsClient, clock: clock)",
                     "moments = MomentsService(rpc: rpc, addresses: config.moments, logsRPC: logsClient, clock: clock)",
                     "RetiredMoments(rpc: rpc, addresses: $0, logsRPC: logsClient, clock: clock)",
                     "activity = TokenActivityService(rpc: logsClient, clock: clock)",
                     "swapHistory = SwapHistoryService(rpc: logsClient, clock: clock, archive: archiveClient)",
                     "walletHistory = WalletHistoryService(store: historyStore, swapHistory: swapHistory, clock: clock,",
                     "dyorCoins = DyorCoinsModel(registry: registry, policy: ImageSourcePolicy(supabaseURL: config.supabaseURL))",
                     "updateGate.onFlags = { [weak self] flags in self?.apply(flags) }",
                     "dyorCoins.showsDyorBadges = flags.dyorBadges",
                     "await previous?.value\n            await prices.setUsesDyorVenues(flags.dyorVenuePrices)"] {
            XCTAssertTrue(environment.contains(part), part)
        }
        // The server's history: the switch and the epoch from each read of the flags, kept for the next launch; the epoch
        // applied to the store in the order read, outside any test of the switch, and the rounds started over when it
        // dropped an entry.
        let apply = try XCTUnwrap(environment.range(of: "    func apply(_ flags: RemoteFlags) {"))
        let applyEnd = try XCTUnwrap(environment.range(of: "\n    }\n", range: apply.upperBound..<environment.endIndex))
        let applied = String(environment[apply.upperBound..<applyEnd.lowerBound])
        for part in ["serverHistoryDefaults.keep(flags)\n        history.setServerHistory(flags.serverHistory)",
                     "epochSwitch = Task { [weak self, historyStore] in\n            await previousEpoch?.value\n            let reset = await historyStore.apply(epoch: flags.historyEpoch)\n            guard reset > 0, let self else { return }\n            history.epochReset(env: self)"] {
            XCTAssertTrue(applied.contains(part), part)
        }
        XCTAssertFalse(applied.contains("if flags.serverHistory"), "the epoch applies with the switch off too")
        XCTAssertFalse(applied.contains("guard flags.serverHistory"), "the epoch applies with the switch off too")
        for part in ["let keptSwitches = serverHistoryDefaults.kept\n        historyStore = HistoryStore(router: logsRouter, directory: historyDirectory, epoch: keptSwitches.historyEpoch)",
                     "history.setServerHistory(keptSwitches.serverHistory)",
                     "serverHistory = isFork || !config.hasSupabase ? nil\n            : ServerHistorySync(client: HistoryServerClient(supabase: social.client), history: walletHistory, router: logsRouter, defaults: serverHistoryDefaults)"] {
            XCTAssertTrue(environment.contains(part), part)
        }
        XCTAssertEqual(environment.components(separatedBy: "BlockClock(").count - 1, 1, "one clock")
        XCTAssertEqual(environment.components(separatedBy: "clock: clock").count - 1, 7, "prices, the launchpad, Moments, past cohorts, activity, swap history, the wallet's history")

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
