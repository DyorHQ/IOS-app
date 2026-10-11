import XCTest
@testable import DyorKit

/// The app's wiring of the alerts while it is open (build 17, N2; the rules are `AppAlertsTests`): one app-wide watcher
/// bound to the account signed in, price alerts and Perps positions checked on any screen, the Perps screen posting
/// nothing of its own, the "Perps Margin Warnings" switch, the copy, and App Lock's fresh-install default (R4).
final class AppAlertsWiringTests: XCTestCase {
    /// The text of the function that starts at `signature`, up to its closing brace at the indentation it opened at.
    private func function(_ signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let line = text[..<start.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(line.prefix { $0 == " " })
        let end = try XCTUnwrap(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex), signature)
        return AppSource.squeezed(String(text[start.lowerBound..<end.upperBound]))
    }

    /// One watcher for the whole app: made once with the environment, bound to the account signed in next to the
    /// notification center (started, kept, stopped by `AlertLoop`), paused in the background and woken on the way back.
    /// It starts its loop in one place only, after stopping the previous one, and checks its run after every read.
    func testOneAppWideWatcher() throws {
        let environment = AppSource.squeezed(try AppSource.app("App/AppEnvironment.swift"))
        XCTAssertTrue(environment.contains("let alerts = AlertCenter()"))
        let root = AppSource.squeezed(try AppSource.app("App/RootView.swift"))
        XCTAssertTrue(root.contains("NotificationHub.shared.bind(owner: session.address) // The one alert watcher follows the account with the notification center:"))
        XCTAssertTrue(root.contains("env.alerts.bind(owner: session.address, env: env, signedIn: { session.address }, canAct: { session.canSign })"))
        XCTAssertEqual(root.components(separatedBy: "env.alerts.bind(").count - 1, 1)
        XCTAssertTrue(root.contains("LogScanClock.suspended() // Alerts arrive while the app is open: checks pause until it is back. env.alerts.enteredBackground()"))
        XCTAssertTrue(root.contains("env.alerts.enteredForeground()"))
        let raw = try AppSource.app("Notifications/AlertCenter.swift")
        let center = AppSource.squeezed(try AppSource.app("Notifications/AlertCenter.swift"))
        XCTAssertEqual(center.components(separatedBy: "task = Task").count - 1, 1, "one place starts a loop")
        let bind = try function("func bind(owner: Address?,", in: raw)
        XCTAssertTrue(bind.contains("switch loop.bind(owner) { case .keep: return case .stop: stopRun() case .start(let run): stopRun() guard let owner else { return } task = Task { [weak self] in await self?.watch(run: run, owner: owner) }"))
        let stop = try function("private func stopRun() {", in: raw)
        XCTAssertTrue(stop.contains("task?.cancel() task = nil sleeper?.task.cancel()"))
        for field in ["positions = PerpPositionWatch()", "risk = PerpRiskWatch()", "pendingEndings = [:]", "userCloses = PerpUserCloses()", "firedPriceAlerts = []",
                      "expectedFills = PerpExpectedFills()", "pendingFills = [:]"] {
            XCTAssertTrue(stop.contains(field), "a new run starts with nothing of the last one's: \(field)")
        }
        let watch = try function("private func watch(run: Int, owner: Address) async {", in: raw)
        XCTAssertTrue(watch.contains("while !Task.isCancelled, loop.mayPost(run: run, owner: owner) {"))
        XCTAssertTrue(watch.contains("if foreground {"), "nothing is checked in the background")
        let pause = try function("private func pause(_ seconds: TimeInterval, run: Int) async -> Bool {", in: raw)
        XCTAssertTrue(pause.contains("guard loop.run == run else { return false } if wakeRequested { wakeRequested = false; return true }"),
                      "a run that was replaced never takes the new run's wake or sleep")
        let wake = try function("func enteredForeground() {", in: raw)
        XCTAssertTrue(wake.contains("guard !foreground else { return } foreground = true wakeRequested = true sleeper?.task.cancel()"))
        // Every read is followed by the run check before anything is posted or changed.
        let prices = try function("private func checkPrices(run: Int, owner: Address) async {", in: raw)
        XCTAssertTrue(prices.contains("guard let prices = try? await env.prices.prices(for: tokens) else { return } // The account may have changed during the read: its alerts are not this one's to fire. guard loop.mayPost(run: run, owner: owner), NotificationHub.shared.owner == owner,"))
        let perps = try function("private func checkPerps(run: Int, owner: Address) async {", in: raw)
        XCTAssertTrue(perps.contains("guard loop.mayPost(run: run, owner: owner), signedIn() == owner, let preferences else { return }"))
        let readsEnd = try XCTUnwrap(perps.range(of: "guard loop.mayPost(run: run, owner: owner), signedIn() == owner, let preferences else { return }"))
        XCTAssertFalse(perps[readsEnd.upperBound...].contains("await"), "nothing awaits between the run check and the posts")
        XCTAssertFalse(prices[try XCTUnwrap(prices.range(of: "guard loop.mayPost(run: run, owner: owner)")).upperBound...].contains("await"))
        // The old watchers are gone.
        for (path, text) in try AppSource.allAppFiles() {
            XCTAssertFalse(text.contains("AlertWatcher"), path)
            XCTAssertFalse(text.contains("alertWatcher"), path)
        }
    }

    /// Price alerts are read on the prices every screen shows (DyorHQ coins on their own curve or pool), fire through
    /// `PriceAlertCheck` for the account signed in, are removed once fired, and say the price in the one style.
    func testPriceAlertWiring() throws {
        let raw = try AppSource.app("Notifications/AlertCenter.swift")
        let prices = try function("private func checkPrices(run: Int, owner: Address) async {", in: raw)
        XCTAssertTrue(prices.contains("guard let env, preferences?.checksPriceAlerts == true else { return }"))
        XCTAssertTrue(prices.contains("let firing = PriceAlertCheck.firing(checks, prices: prices.mapValues(\\.usd), readFor: owner, signedIn: signedIn(), alreadyFired: firedPriceAlerts)"))
        XCTAssertTrue(prices.contains("Notifications.priceAlert(symbol: alert.symbol, above: alert.above, target: alert.target, price: price) firedPriceAlerts.insert(alert.id)"))
        XCTAssertTrue(prices.contains("PriceAlertStore.removeFired(Set(firing.map(\\.id)), owner: owner)"))
        let environment = AppSource.squeezed(try AppSource.app("App/AppEnvironment.swift"))
        XCTAssertTrue(environment.contains("prices = PriceService(rpc: rpc, registry: registry, clock: clock, dyorVenues: true, cache: chainCache, store: chainStore)"),
                      "the venue prices (C3), shared with every screen")
    }

    /// Fills and closes come from the watcher only, on any screen: the fill notice respects "Swaps & Fills", an ending is
    /// decided with the trading stream (`endingExplained`), and the Perps screen keeps its own fill signal and the TP/SL
    /// clean-up but posts nothing.
    func testPerpsWiring() throws {
        let raw = try AppSource.app("Notifications/AlertCenter.swift")
        let perps = try function("private func checkPerps(run: Int, owner: Address) async {", in: raw)
        // One notice per fill: a growth an order sent from here announced itself is quiet, one an order still waiting for
        // its result may explain waits for it, anything else is the watcher's (`PerpExpectedFills`, real-time spec I5).
        XCTAssertTrue(perps.contains("if preferences.postsFills { // Growths that waited for an order's own result: past its deadline they are the watcher's to announce. postPendingFills(now: now) for position in changes.filled {"))
        XCTAssertTrue(perps.contains("let growth = changes.growth[position.perpId] ?? position.size switch expectedFills.decide(perpId: position.perpId, side: position.side, growth: growth, tolerance: lotTolerance(position.perpId), now: now) { case .quiet: continue case .wait: holdFill(position, growth: growth, now: now); continue case .announce: expectedFills.watcherAnnounced(perpId: position.perpId, side: position.side, at: now) } Notifications.perpOrder(.filled,"))
        let reconsider = try function("func reconsiderFills() {", in: raw)
        XCTAssertTrue(reconsider.contains("guard !pendingFills.isEmpty, preferences?.postsFills == true, signedIn() != nil else { return } postPendingFills(now: Date())"), "decided at once, no read")
        let pending = try function("private func postPendingFills(now: Date) {", in: raw)
        XCTAssertTrue(pending.contains("case .wait: continue case .quiet: pendingFills[perpId] = nil case .announce: pendingFills[perpId] = nil expectedFills.watcherAnnounced(perpId: perpId, side: side, at: now) Notifications.perpOrder(.filled,"))
        XCTAssertTrue(perps.contains("explainedByStream: env.perplTrading.endingExplained(marketId: perpId), streamLive: env.perplTrading.positionsAreLive"))
        XCTAssertTrue(perps.contains("if notice == .wait { continue } pendingEndings[perpId] = nil"))
        // A close is any order that closes the position: reduce-only, or on its other side (Perpl nets them).
        XCTAssertTrue(perps.contains("resting = PerpCloseOrder.restingCloseMarkets(orders: orders, positions: fresh)"))
        XCTAssertTrue(perps.contains("userClosedAt: userCloses.closedAt(ending.position),"))
        XCTAssertFalse(perps.contains("filter(\\.reduceOnly)"), "not only reduce-only orders")
        XCTAssertTrue(perps.contains("guard preferences.checksMargin else { risk.reset(); return }"))
        XCTAssertTrue(perps.contains("canAct: canAct()"))
        XCTAssertTrue(perps.contains("route: .perps, reference: PerpAlertText.reference(perpId: notice.position.perpId), owner: owner)"))

        let screen = try AppSource.app("Perps/PerpsView.swift")
        let model = try function("private func detectChanges(", in: screen)
        XCTAssertFalse(model.contains("Notifications."), "the screen posts no notice of its own")
        XCTAssertFalse(model.contains("Activity.record"), "nor records one")
        XCTAssertTrue(model.contains("trading.positionClosedOnChain(marketId: ended.perpId, isLong: ended.side == .long)"))
        XCTAssertTrue(model.contains("fillSignal &+= 1"))
        let squeezed = AppSource.squeezed(try AppSource.app("Perps/PerpsView.swift"))
        XCTAssertTrue(squeezed.contains("func noteUserClose(_ perpId: Int, closing side: PositionSide) { alerts?.noteUserClose(perpId, closing: side) }"))
        XCTAssertTrue(squeezed.contains("func forgetUserClose(_ perpId: Int) { alerts?.forgetUserClose(perpId) }"))
        XCTAssertFalse(squeezed.contains("sawEnding"))
        // The ticket notes every order that closes the position, reduce-only or on its other side, decided at Review.
        let ticket = AppSource.squeezed(try AppSource.app("Perps/PerpTradeView.swift"))
        XCTAssertTrue(ticket.contains("reviewCloses = PerpCloseOrder.closes(orderSide: side, reduceOnly: ticket.effectiveReduceOnly, held: position?.side)"))
        XCTAssertEqual(ticket.components(separatedBy: "if let reviewCloses { model.noteUserClose(market.id, closing: reviewCloses) }").count - 1, 2,
                       "the one-click sheet and the on-chain sheet")
        // Only a close of the whole position (the 100% chip) notes a close of it; a partial one never does (p4 spec #5).
        XCTAssertTrue(ticket.contains("onSending: { whole in if whole { model.noteUserClose(market.id, closing: position.side) } }"))
        let closeSheet = String(ticket[try XCTUnwrap(ticket.range(of: "struct ClosePositionSheet: View {")).lowerBound..<(try XCTUnwrap(ticket.range(of: "struct AddMarginSheet: View {"))).lowerBound])
        XCTAssertEqual(closeSheet.components(separatedBy: "onSending(percent == 100)").count - 1, 2, "both on-chain sites: at the start and at the receipt")
        XCTAssertFalse(closeSheet.contains("onSending()"), "never a bare note")
        XCTAssertFalse(ticket.contains("if ticket.effectiveReduceOnly { model.noteUserClose"))
        XCTAssertEqual(ticket.components(separatedBy: "model.noteUserClose(").count - 1, 3)

        let trading = try AppSource.app("Wallet/PerplTrading.swift")
        let ended = try function("private func positionEnded(_ position: PerplLivePosition) {", in: trading)
        XCTAssertTrue(ended.contains("if position.endedByProtocol { explainedEndings[position.marketId] = Date()"), "a liquidation, ADL or unwind explains the ending")
        let trigger = try function("private func triggerChanged(_ event: PerplTriggerEvent) {", in: trading)
        XCTAssertTrue(trigger.contains("warning = false explainedEndings[order.marketId] = Date()"), "a triggered TP/SL explains it")
        XCTAssertEqual(trading.components(separatedBy: "explainedEndings[").count - 1, 3, "set by those two, read by endingExplained")
    }

    /// The screens say plainly that alerts arrive while DyorHQ is open, on any screen, and never while it's closed.
    func testTheCopySaysAlertsArriveWhileOpen() throws {
        let settings = AppSource.squeezed(try AppSource.app("Profile/Settings.swift"))
        XCTAssertTrue(settings.contains("Paragraph(\"Alerts arrive while DyorHQ is open. iOS pauses the app in the background, so nothing reaches your lock screen while DyorHQ is closed.\")"))
        XCTAssertTrue(settings.contains("Paragraph(\"Alerts arrive while DyorHQ is open, on any screen:"))
        XCTAssertFalse(settings.contains("while the Perps screen is open"))
        let alerts = AppSource.squeezed(try AppSource.app("Wallet/PriceAlerts.swift"))
        XCTAssertTrue(alerts.contains("Paragraph(\"Alerts arrive while DyorHQ is open: it checks prices every 30 seconds"))
        XCTAssertTrue(alerts.contains("Alerts arrive while DyorHQ is open: it checks every 30 seconds.\")"))
        XCTAssertFalse(alerts.contains("once a minute"))
    }

    /// The switch: "Perps Margin Warnings", on by default, next to the others, mirrored to the backend with them.
    func testTheMarginSwitch() throws {
        let settings = AppSource.squeezed(try AppSource.app("Profile/Settings.swift"))
        XCTAssertTrue(settings.contains("Toggle(\"Swaps & Fills\", isOn: $settings.notifyFills) Toggle(\"Perps Margin Warnings\", isOn: $settings.notifyMargin) Toggle(\"Price Alerts\", isOn: $settings.notifyPriceAlerts)"))
        let appSettings = AppSource.squeezed(try AppSource.declaration(of: "AppSettings").text)
        XCTAssertTrue(appSettings.contains("var notifyMargin: Bool { didSet { store(notifyMargin, \"settings.notifyMargin\") } }"))
        XCTAssertTrue(appSettings.contains("notifyMargin = defaults.object(forKey: \"settings.notifyMargin\") as? Bool ?? true"))
        XCTAssertTrue(appSettings.contains("\"notifyMargin\": notifyMargin,"))
        XCTAssertTrue(appSettings.contains("if let v = restored.notifyMargin { notifyMargin = v }"))
        XCTAssertEqual(BackendRestore.settings(from: ["notifyMargin": false], appearances: []).notifyMargin, false)
        XCTAssertNil(BackendRestore.settings(from: ["notifyMargin": 1], appearances: []).notifyMargin, "a number is not a boolean")
        XCTAssertNil(BackendRestore.settings(from: [:], appearances: []).notifyMargin)
    }

    /// R4: a fresh install must start with App Lock ON, which `AppSettings.appLockDefault` decides from whether any key
    /// with an earlier run's prefix exists (`AppLockStore.isEarlierInstall`). The new switch's key has the "settings."
    /// prefix (like "settings.notifyFills"), so it must never be written before that decision: `init` only reads it,
    /// and only its `didSet` writes it (Swift runs no `didSet` during `init`), through `store`. N2's other files write
    /// no key with such a prefix at all.
    func testTheNewKeyCantTurnAppLockOff() throws {
        let prefixes = AppLockStore.earlierRunPrefixes
        XCTAssertTrue(prefixes.contains("settings.") && prefixes.contains("perp.") && prefixes.contains("priceAlerts."), "\(prefixes)")

        // In `init`, every key is read; the only write is App Lock's own decision, after which `store` may write.
        let settings = try AppSource.declaration(of: "AppSettings")
        let raw = settings.text
        let initBody = try function("init(defaults: UserDefaults = .standard) {", in: raw)
        XCTAssertFalse(initBody.contains("defaults.set("), "init writes nothing")
        XCTAssertFalse(initBody.contains("store("), "init writes nothing")
        XCTAssertTrue(initBody.contains("requireBiometrics = defaults.object(forKey: AppLockStore.key) as? Bool ?? Self.appLockDefault(defaults)"))
        XCTAssertTrue(initBody.contains("notifyMargin = defaults.object(forKey: \"settings.notifyMargin\") as? Bool ?? true"))
        // The key is written in one place: its didSet.
        XCTAssertEqual(raw.components(separatedBy: "\"settings.notifyMargin\"").count - 1, 2, "read in init, written in didSet")
        for (path, text) in try AppSource.allAppFiles() where path != settings.file {
            XCTAssertFalse(text.contains("\"settings.notifyMargin\""), path)
        }

        /// Every string literal in `text` that starts with one of the prefixes, up to its closing quote.
        func prefixed(_ text: String) -> Set<String> {
            var found: Set<String> = []
            for prefix in prefixes {
                for piece in text.components(separatedBy: "\"" + prefix).dropFirst() { found.insert(prefix + piece.prefix { $0 != "\"" }) }
            }
            return found
        }
        XCTAssertEqual(prefixed(try AppSource.app("Notifications/AlertCenter.swift")), [])
        XCTAssertFalse(try AppSource.app("Notifications/AlertCenter.swift").contains("UserDefaults"))
        XCTAssertEqual(prefixed(try AppSource.app("Perps/PerpsView.swift")), [])
        // The price alerts keep their build-16 key.
        XCTAssertEqual(prefixed(try AppSource.app("Wallet/PriceAlerts.swift")), ["priceAlerts.v1.\\(owner.hex)", "priceAlerts.v1"])
        for file in ["Services/Perpl/PerpRisk.swift", "Services/Notifications/AppAlerts.swift"] {
            let text = try AppSource.kit(file)
            XCTAssertFalse(text.contains("UserDefaults"), file)
            XCTAssertEqual(prefixed(text), [], file)
        }
    }
}
