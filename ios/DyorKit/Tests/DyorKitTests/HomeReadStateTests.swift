import XCTest
@testable import DyorKit

/// Home never shows a figure it hasn't read as $0.00 (`HomeReadState`): each of its four parts of the wallet is unread
/// until a read of it answers for the wallet, a figure from an unread part is a placeholder, a tab says "none" only once
/// its part was read, and a read that fails before any answered says so, with Retry. A part once read keeps its last good
/// figures through a later failure.
final class HomeReadStateTests: XCTestCase {
    /// A wallet nothing has been read for: every part still reading, no figure to show, nothing failed.
    func testANewWalletHasNothingRead() {
        let state = HomeReadState()
        for part in HomeReadState.Part.allCases {
            XCTAssertEqual(state.status(part), .reading, "\(part)")
            XCTAssertFalse(state.isRead(part), "\(part)")
            XCTAssertFalse(state.showsValue(of: part), "\(part): a placeholder, never $0.00")
        }
        XCTAssertEqual(state.failed, [])
    }

    /// A part is read once a read of it answers. Perps, Launch and Moments then show their own figure; Spot's waits for
    /// the Launch and Moments tabs as well, since what they count is taken out of it (`HomeTotals`).
    func testEachPartShowsOnceReadAndSpotWaitsForLaunchAndMoments() {
        var state = HomeReadState()
        state.record(.spot, answered: true)
        XCTAssertTrue(state.isRead(.spot))
        XCTAssertFalse(state.showsValue(of: .spot), "Spot's figure still holds the coins Launch and Moments will count")
        state.record(.perps, answered: true)
        XCTAssertTrue(state.showsValue(of: .perps))
        XCTAssertFalse(state.showsValue(of: .launch))
        state.record(.launch, answered: true)
        XCTAssertTrue(state.showsValue(of: .launch))
        XCTAssertFalse(state.showsValue(of: .spot), "Moments not read yet")
        state.record(.moments, answered: true)
        XCTAssertTrue(state.showsValue(of: .moments))
        XCTAssertTrue(state.showsValue(of: .spot))
        XCTAssertTrue(HomeReadState.Part.allCases.allSatisfy(state.showsValue(of:)), "every figure, so the total too")
        XCTAssertEqual(state.failed, [])
    }

    /// A read that fails before any answered marks its part failed (its tab says so, with Retry), in `Part` order, and the
    /// part stays unread: a failed Perps read is a placeholder, never $0.00. The read that then answers clears it.
    func testAFailedFirstReadIsUnreadUntilOneAnswers() {
        var state = HomeReadState()
        state.record(.moments, answered: false)
        state.record(.perps, answered: false)
        state.record(.spot, answered: true)
        state.record(.launch, answered: true)
        XCTAssertEqual(state.status(.perps), .failed)
        XCTAssertEqual(state.failed, [.perps, .moments], "in Part order")
        XCTAssertFalse(state.showsValue(of: .perps), "a failed read is unread, not 0")
        XCTAssertFalse(state.showsValue(of: .spot), "Spot waits for Moments")
        state.record(.perps, answered: false)
        XCTAssertEqual(state.status(.perps), .failed, "still failed while no read answers")
        state.record(.perps, answered: true)
        state.record(.moments, answered: true)
        XCTAssertEqual(state.failed, [])
        XCTAssertTrue(HomeReadState.Part.allCases.allSatisfy(state.showsValue(of:)))
    }

    /// Once read, a part stays read for the wallet: a later read that fails keeps the last good figures (the screen says
    /// so), never going back to a placeholder or to $0.00. Another wallet starts again from nothing.
    func testAFailureAfterAReadKeepsTheLastGoodFigures() {
        var state = HomeReadState()
        for part in HomeReadState.Part.allCases { state.record(part, answered: true) }
        for part in HomeReadState.Part.allCases { state.record(part, answered: false) }
        for part in HomeReadState.Part.allCases {
            XCTAssertEqual(state.status(part), .read, "\(part)")
            XCTAssertTrue(state.showsValue(of: part), "\(part)")
        }
        XCTAssertEqual(state.failed, [])
        XCTAssertNotEqual(state, HomeReadState())
        state = HomeReadState()
        XCTAssertEqual(state.failed, [])
        XCTAssertFalse(state.showsValue(of: .perps), "another wallet: unread again")
    }

    // MARK: The app's wiring

    private static func homeModel(_ home: String) throws -> String {
        let model = try XCTUnwrap(home.range(of: "final class HomeModel {")).upperBound
        let end = try XCTUnwrap(home.range(of: "struct TokenDetailView: View {")).lowerBound
        return String(home[model..<end])
    }

    /// Each part is recorded from its own read in Home's load, after the load is known to stand (the account unchanged,
    /// not cancelled), and starts again for another account. A failed Perps read is nil (unread), and an account
    /// without a Perpl account is $0 read; every figure is nil while its part can't be told.
    func testHomeRecordsEachPartAndNeverTakesUnreadForZero() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let model = try Self.homeModel(home)
        XCTAssertTrue(model.contains("perpEquity = nil; momentRows = []; updatedAt = nil; reads = HomeReadState()"), "another account starts unread")
        let publish = try XCTUnwrap(model.range(of: "guard !Task.isCancelled, address == loadedFor else { return }"))
        for record in ["next.record(.spot, answered: priceMap != nil && balanceMap != nil)", "next.record(.perps, answered: perpState != nil)",
                       "next.record(.launch, answered: holdings != nil && priceMap != nil && listing.factories.allSatisfy(listedFactories.contains))",
                       "next.record(.moments, answered: momentState != nil)", "if next != reads { reads = next }"] {
            let at = try XCTUnwrap(model.range(of: record), record)
            XCTAssertLessThan(publish.upperBound, at.lowerBound, "recorded only for a load that stands: \(record)")
        }
        XCTAssertTrue(model.contains("listedFactories.formUnion(listing.factories.filter { listing.unread[$0] == nil })"))
        XCTAssertTrue(model.contains("var perpsValue: Double? { reads.showsValue(of: .perps) ? perpEquity : nil }"))
        XCTAssertFalse(model.contains("perpEquity ?? 0"), "a Perps figure not read is never $0.00")
        XCTAssertTrue(model.contains("guard let account = found else { return ([], 0) }"), "no Perpl account: $0, read")
        XCTAssertTrue(model.contains("do { found = try await env.perpl.account(address) } catch { return nil }"), "a failed read: unread")
        XCTAssertTrue(model.contains("var availableBalance: Double? { spotValue }"))
        XCTAssertTrue(model.contains("var inUse: Double? { perpsValue }"))
        XCTAssertTrue(model.contains("guard let spot = spotValue, let perps = perpsValue, let launch = launchpadValue, let moments = momentsValue else { return nil }"))
        // A part never read whose read failed is the header's warning too, so the screen isn't said to be up to date.
        XCTAssertTrue(model.contains("} else if let part = reads.failed.first {\n            // A part not read for the wallet yet: its tab says so, with Retry, and the total waits for it.\n            error = tr(Self.unreadMessage(part))"))
    }

    /// The hero's total and its day's move, Avail. Balance, In Use and the four split figures are placeholders while
    /// unread, which VoiceOver says are loading; the allocation ring waits for every part; and each holdings tab shows a
    /// loading row, or that its part couldn't be read with Retry, before it would say it holds none.
    func testHomeShowsUnreadFiguresAsPlaceholdersAndTabsAsLoading() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let hero = try XCTUnwrap(home.range(of: "private var heroCard: some View {"))
        let heroEnd = try XCTUnwrap(home.range(of: "private var changeAmount: Double {", range: hero.upperBound..<home.endIndex))
        let card = String(home[hero.upperBound..<heroEnd.lowerBound])
        XCTAssertTrue(card.contains("let unread = model.totalValue == nil"))
        XCTAssertEqual(card.components(separatedBy: ".unreadFigure(unread)").count - 1, 2, "the total and the change line")
        XCTAssertTrue(card.contains("ChangeBadge(value: unread ? 0 : model.change24h ?? 0)"))
        XCTAssertTrue(card.contains("statColumn(\"Avail. Balance\", value: model.availableBalance, tint: .primary)"))
        XCTAssertTrue(card.contains("statColumn(\"In Use\", value: model.inUse, tint: (model.inUse ?? 0) > 0 ? .positive : .primary, alignment: .trailing)"))
        XCTAssertFalse(card.contains(".redacted(reason: model.totalValue == nil"), "through unreadFigure, which VoiceOver says is loading")
        XCTAssertTrue(home.contains("private func statColumn(_ title: LocalizedStringKey, value: Double?, tint: Color,"))
        XCTAssertTrue(home.contains("private func splitStat(_ category: HoldingCategory, _ value: Double?, _ dot: Color) -> some View {"))
        XCTAssertEqual(home.components(separatedBy: ".unreadFigure(value == nil)").count - 1, 2, "statColumn and splitStat")
        let modifier = try XCTUnwrap(home.range(of: "@ViewBuilder func unreadFigure(_ unread: Bool) -> some View {"))
        let modifierBody = String(home[modifier.upperBound...].prefix(300))
        XCTAssertTrue(modifierBody.contains("redacted(reason: .placeholder)"))
        XCTAssertTrue(modifierBody.contains(".accessibilityLabel(Text(\"Loading…\"))"), "never read out as $0.00")
        XCTAssertTrue(home.contains("if let split = model.split, split.total > 0 || !model.holdings.isEmpty { allocationCard(split) }"))

        for (part, empty, reading) in [("spot", "No spot balances", "Reading your balances…"), ("perps", "No open positions", "Reading your positions…"),
                                       ("launch", "No launch holdings", "Reading your balances…"), ("moments", "No Moments yet", "Reading your Moments…")] {
            XCTAssertTrue(home.contains("if model.reads.isRead(.\(part)) { holdingsEmpty(\"\(empty)\""), "\(part): none only once read")
            XCTAssertTrue(home.contains("else { holdingsUnreadRow(.\(part), reading: \"\(reading)\") }"), "\(part): a loading row before")
            XCTAssertEqual(home.components(separatedBy: "holdingsEmpty(\"\(empty)\"").count - 1, 1, empty)
        }
        let row = try XCTUnwrap(home.range(of: "@ViewBuilder private func holdingsUnreadRow(_ part: HomeReadState.Part, reading: LocalizedStringKey) -> some View {"))
        let rowBody = String(home[row.upperBound...].prefix(400))
        XCTAssertTrue(rowBody.contains("if model.reads.status(part) == .failed {\n            holdingsRetryRow(HomeModel.unreadMessage(part))"))
        XCTAssertTrue(home.contains("Button(\"Retry\") { Task { await model.load(env: env, address: session.address) } }"))
    }
}
