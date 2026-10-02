import Foundation
import XCTest
@testable import DyorKit

/// The Perps and Wallet screens' text (L2, the Perps and Wallet folders), read from the app's sources: text written in
/// the code reaches the screen in the app's language. A `String` the code builds (a model's label, an error, an Activity
/// row, a notification) goes through `tr()`; a word is never chosen inside another string's interpolation (it would
/// never be looked up); text with nothing to translate ("/", "%", "5x") is shown verbatim, never as a key; durations,
/// dates and the chart's dates follow the app's language; and the strings that must stay English (what a server
/// reparses, what is matched against input, identifiers) are left as they are.
final class PerpsWalletStringsTests: XCTestCase {
    private static func ios() throws -> URL {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard FileManager.default.fileExists(atPath: ios.appendingPathComponent("DyorHQ").path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return ios
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: try ios().appendingPathComponent(path), encoding: .utf8)
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The Swift files of the Perps and Wallet folders, by their path under ios/DyorHQ. The Simulator's stub passkey
    /// provider is left out: it compiles only into DEBUG Simulator builds, and its messages are for developers.
    private static func scopedSources() throws -> [(path: String, text: String)] {
        let app = try ios().appendingPathComponent("DyorHQ")
        var out: [(String, String)] = []
        for folder in ["Perps", "Wallet"] {
            let files = FileManager.default.enumerator(at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" && file.lastPathComponent != "StubPasskeyAuthenticator.swift" {
                out.append((String(file.path.dropFirst(app.path.count + 1)), try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// One string literal on a line: what it says outside its interpolations, how deep it sits inside other literals'
    /// interpolations (0 for one written in the code), and the code before and after it.
    struct Literal {
        let text: String
        let depth: Int
        let before: String
        let after: String
    }

    /// The literals of one line of Swift, nested ones included. A `//` comment outside a literal ends the line.
    static func literals(in line: String) -> [Literal] {
        let chars = Array(line)
        var found: [Literal] = []
        var i = 0
        func code(depth: Int) {
            var parens = 0
            while i < chars.count {
                let c = chars[i]
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" { i = chars.count; return }
                if c == "\"" { string(depth: depth); continue }
                if c == "(" { parens += 1 }
                if c == ")" {
                    if parens == 0, depth > 0 { i += 1; return }
                    parens -= 1
                }
                i += 1
            }
        }
        func string(depth: Int) {
            let start = i
            i += 1
            var own = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" { i += 2; code(depth: depth + 1); continue }
                    i += 2
                    continue
                }
                if c == "\"" { i += 1; break }
                own.append(c)
                i += 1
            }
            found.append(Literal(text: own, depth: depth, before: String(chars[..<start]), after: String(chars[min(i, chars.count)...])))
        }
        code(depth: 0)
        return found
    }

    /// Whether a literal's own text reads as words for a person: two words, or one capitalised word ("Unknown"). An
    /// identifier ("perp.triggers.v1.", "faceid") or a symbol ("AUSD", "-PERP") doesn't.
    static func isWords(_ text: String) -> Bool {
        text.range(of: #"[A-Za-z]{2,}\S*\s+\S*[A-Za-z]"#, options: .regularExpression) != nil
            || text.range(of: #"^[A-Z][a-z]+[.…!?]?$"#, options: .regularExpression) != nil
    }

    /// The lines of the scoped sources with their literals; a line marked "not localized" (or under such a marker) is
    /// left out.
    private static func scannedLines() throws -> [(at: String, line: String, literals: [Literal])] {
        var out: [(String, String, [Literal])] = []
        for (path, text) in try scopedSources() {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let previous = index > 0 ? lines[index - 1] : ""
                if line.contains("not localized") || previous.contains("// not localized") { continue }
                out.append(("\(path):\(index + 1)", line, literals(in: line)))
            }
        }
        return out
    }

    func testTheLiteralReaderSeesNestedLiterals() {
        let line = #"Text("Up \(above ? "above" : "below") \(x)") // "comment""#
        let found = Self.literals(in: line)
        XCTAssertEqual(found.map(\.text), ["above", "below", "Up  "])
        XCTAssertEqual(found.map(\.depth), [1, 1, 0])
        XCTAssertTrue(Self.isWords("Not sent."))
        XCTAssertTrue(Self.isWords("Unknown"))
        XCTAssertFalse(Self.isWords("perp.triggers.v1."))
        XCTAssertFalse(Self.isWords("-PERP"))
        XCTAssertFalse(Self.isWords(" · "))
    }

    /// A word chosen inside another string's interpolation (`"\(isLong ? "long" : "short") …"`) is never looked up:
    /// each choice is a sentence of its own, a key with its words, or a `tr()` of the word.
    func testNoWordIsChosenInsideAnInterpolation() throws {
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth > 0 && Self.isWords(literal.text) || literal.depth > 0 && literal.text.range(of: "^[a-z]{2,}$", options: .regularExpression) != nil {
                found.append("\(at): \"\(literal.text)\"")
            }
        }
        XCTAssertEqual(found, [], "a word inside an interpolation is shown in English in every language")
    }

    /// Text built as a `String` (a returned label, an assigned error, a failure, an Activity row, a notification, a step's
    /// label, a fallback after `??`) goes through `tr()`: a bare literal there is shown in English in every language.
    func testStringTextGoesThroughTr() throws {
        let sink = try NSRegularExpression(pattern: #"(return |(?<![=!<>])= |\+= |\?\? |\.failed\(|\.unavailable\(|\.invalidOrder\(|\.rejected\(|\.unknown\(|\.doneWarning\(|\.append\(|error: |TriggerSheetLine\(text: )$"#)
        let record = try NSRegularExpression(pattern: #"(title: |subtitle: |body: |label: |side: )$"#)
        var found: [String] = []
        for (at, line, literals) in try Self.scannedLines() {
            let recordLine = ["ActivityRecord(", "ProtectionNotice(", "post(kind:", ".call(", "Notifications."].contains { line.contains($0) }
            for literal in literals where literal.depth == 0 && Self.isWords(literal.text) {
                let before = NSRange(literal.before.startIndex..., in: literal.before)
                if sink.firstMatch(in: literal.before, range: before) != nil || (recordLine && record.firstMatch(in: literal.before, range: before) != nil) {
                    found.append("\(at): \"\(literal.text)\"")
                }
            }
        }
        XCTAssertEqual(found, [], "String text written in the code goes through tr()")
    }

    /// Text with nothing to translate ("/", "%", "—", "5x", "0.5") is shown as it is, never looked up as a key.
    func testNoPlaceholderOnlyKey() throws {
        let key = try NSRegularExpression(pattern: #"(Text|Label|Button|TextField|Toggle|\.accessibilityLabel|\.accessibilityValue|\.navigationTitle)\($"#)
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth == 0 && literal.text.range(of: "[A-Za-z]{2,}", options: .regularExpression) == nil {
                let before = NSRange(literal.before.startIndex..., in: literal.before)
                if key.firstMatch(in: literal.before, range: before) != nil, !literal.after.hasPrefix(" as String") {
                    found.append("\(at): \"\(literal.text)\"")
                }
            }
        }
        XCTAssertEqual(found, [], "a key with nothing to translate: show it verbatim")
    }

    /// A tab's or a case's name on screen is a written key, never its raw value (an identifier).
    func testNoRawValueIsShown() throws {
        let shown = try NSRegularExpression(pattern: #"(Text|Label|Button)\([^()]*\.rawValue(\.capitalized)?\)"#)
        for (path, text) in try Self.scopedSources() {
            XCTAssertNil(shown.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(path): a raw value shown as text")
            XCTAssertFalse(text.contains(".capitalized"), path)
        }
        let trade = try Self.source("DyorHQ/Perps/PerpTradeView.swift")
        XCTAssertTrue(trade.contains("ForEach(ChartDataTab.allCases) { $0.title.tag($0) }"))
        XCTAssertTrue(trade.contains("tab.title\n"))
        XCTAssertTrue(trade.contains("priceType.title.font("))
        XCTAssertTrue(try Self.source("DyorHQ/Perps/PerpsPortfolioView.swift").contains("ForEach(HistoryTab.allCases) { $0.title.tag($0) }"))
    }

    /// Durations are in the app language's own units, and every date written as a `String` is in the app's language
    /// (`L10n.locale`), not the device's.
    func testDurationsAndDatesFollowTheAppLanguage() throws {
        let scope = Self.squeezed(try Self.source("DyorHQ/Wallet/Mera/SessionScopeViews.swift"))
        XCTAssertTrue(scope.contains("Duration.seconds(Int(left.rounded(.up))).formatted(.units(allowed: [.seconds], width: .narrow).locale(L10n.locale))"))
        XCTAssertTrue(scope.contains("Duration.seconds(Int((left / 60).rounded(.up)) * 60).formatted(.units(allowed: [.minutes], width: .narrow).locale(L10n.locale))"))
        XCTAssertTrue(scope.contains("return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))"))
        XCTAssertFalse(scope.contains("? \"1 hour\" :"), "no English-only length")
        XCTAssertFalse(scope.contains(")) minutes\""))
        let phrase = try Self.source("DyorHQ/Wallet/Mera/RecoveryPhraseView.swift")
        XCTAssertTrue(phrase.contains("Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow).locale(L10n.locale))"))
        XCTAssertTrue(phrase.contains("Text(\"Hides in \\(Self.seconds("))
        for (path, text) in try Self.scopedSources() {
            for line in text.components(separatedBy: "\n") where line.contains(".formatted(") && !line.contains(".units(") {
                XCTAssertTrue(line.contains("L10n.locale"), "\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // English is unchanged: these are the strings the code wrote before.
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(Duration.seconds(720).formatted(.units(allowed: [.minutes], width: .narrow).locale(en)), "12m")
        XCTAssertEqual(Duration.seconds(45).formatted(.units(allowed: [.seconds], width: .narrow).locale(en)), "45s")
        XCTAssertEqual(Duration.seconds(0).formatted(.units(allowed: [.seconds], width: .narrow).locale(en)), "0s")
        XCTAssertEqual(Duration.seconds(3600).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(en)), "1 hour")
        XCTAssertEqual(Duration.seconds(900).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(en)), "15 minutes")
    }

    /// The Perps chart's dates follow the app's language: the app sends its locale (and the legend's labels) to the page,
    /// which writes its time scale and crosshair dates in it. Prices keep the app's one style.
    func testTheChartDatesFollowTheAppLanguage() throws {
        let chart = Self.squeezed(try Self.source("DyorHQ/Perps/TradingViewChart.swift"))
        XCTAssertTrue(chart.contains("@Environment(\\.locale) private var locale"))
        XCTAssertTrue(chart.contains("language: ChartLanguage(locale)"))
        XCTAssertTrue(chart.contains("self.locale = locale.identifier(.bcp47)"))
        XCTAssertTrue(chart.contains("if pendingScheme != lastScheme || pendingLanguage != lastLanguage {"), "re-sent when the language changes")
        XCTAssertTrue(chart.contains("config[\"locale\"] = language.locale"))
        let page = try Self.source("DyorHQ/Resources/Web/chart.html")
        XCTAssertTrue(page.contains("if (p.locale) chart.applyOptions({ localization: { locale: p.locale, priceFormatter: (v) => formatPrice(v) } });"))
        XCTAssertTrue(page.contains("palette = Object.assign(palette, p.palette || {});"))
        XCTAssertTrue(page.contains("escapeHTML(legendLabels.o)"))
        XCTAssertFalse(page.contains("<span class=\"k\">O</span>"), "the legend's labels come from the app")
        XCTAssertTrue(page.contains("p.toLocaleString('en-US'"), "prices keep the app's one style")
    }

    // MARK: What stays English

    /// What a server reparses, what is matched against what someone types, and the values a page or the store reads
    /// stay English, never translated.
    func testTheEnglishMatchersAreUntouched() throws {
        let session = try Self.source("DyorHQ/Wallet/Session.swift")
        XCTAssertTrue(session.contains("return \"DyorHQ Email Rebind\\n\\nEmail: \\(email)\\nAddress: \\(address.checksummed.lowercased())\\nIssued At: \\(issued)\""))
        XCTAssertTrue(session.contains("trimmed.lowercased().hasSuffix(\"@privaterelay.appleid.com\")"))
        XCTAssertTrue(session.contains("oAuth.login(with: provider, appUrlScheme: \"dyorhq\")"))
        let password = try Self.source("DyorHQ/Wallet/PasswordWallet.swift")
        XCTAssertTrue(password.contains("for weak in [\"password\", \"dyorhq\", \"qwerty\", \"letmein\", \"monad\", \"crypto\", \"wallet\"] where lower.contains(weak) {"))
        let export = try Self.source("DyorHQ/Wallet/WalletExportView.swift")
        XCTAssertTrue(export.contains("if result == \"success\" { dismiss() }"))
        XCTAssertTrue(export.contains("guard message.name == \"exportResult\" else { return }"))
        XCTAssertTrue(export.contains("json[\"status\"] as? String"))
        let log = try Self.source("DyorHQ/Wallet/ActivityLog.swift")
        for status in ["pendingStatus = \"pending\"", "confirmedStatus = \"confirmed\"", "revertedStatus = \"reverted\"", "notFoundStatus = \"notFound\""] {
            XCTAssertTrue(log.contains(status), status)
        }
        XCTAssertTrue(log.contains("case .perp: return \"perps\""))
        XCTAssertTrue(log.contains("case \"moments\": return .moments"))
        // Cancelling is told by type, never by an error's text.
        XCTAssertTrue(session.contains("if case .cancelled? = error as? PasskeyCeremony.Failure { return true }"))
        for (path, text) in try Self.scopedSources() {
            XCTAssertFalse(text.contains("tr(\"pending\")") || text.contains("tr(\"success\")"), path)
            XCTAssertFalse(text.contains("localizedDescription.contains("), "\(path): an error told apart by its (translated) text")
        }
    }

    /// The Perps order's notification names its side in the app's language; Activity rows and notifications are written
    /// in the language in use when they are recorded.
    func testRecordsAndNotificationsAreWrittenInTheAppLanguage() throws {
        let trade = try Self.source("DyorHQ/Perps/PerpTradeView.swift")
        XCTAssertFalse(trade.contains("side: input.side == .long ? \"Long\" : \"Short\""))
        XCTAssertTrue(Self.squeezed(trade).contains("Notifications.perpOrder(PerpOrderNotice(acknowledged: input.kind), side: side, market: \"\\(market.asset)-PERP\", perpId: market.id)"))
        let notifications = try Self.source("DyorHQ/Wallet/Notifications.swift")
        XCTAssertTrue(notifications.contains("post(kind: .swap, title: tr(\"Swap complete\"), body: tr(\"Swapped \\(paid) → \\(got)\"), route: .trade)"))
        XCTAssertTrue(notifications.contains("title: tr(\"Bridge complete\")"))
        XCTAssertTrue(notifications.contains("title: tr(\"Price alert: \\(symbol)\")"))
        let run = try Self.source("DyorHQ/Wallet/TransactionRun.swift")
        XCTAssertTrue(run.contains("static var notSent: String { tr(\"Not sent. Nothing left your account.\") }"))
        XCTAssertTrue(run.contains("return tr(\"Up to \\(fee) + \\(unestimated) more steps\")"), "one plural key, not an English-only \"1 more step\"")
    }

    /// The Perps and Wallet keys with a count (an `Int`, so `%lld`), as the app's catalog spells them. Their singular
    /// comes from the catalog's plural forms, English included: without them a count of 1 reads "1 more steps".
    static let pluralKeys = [
        "Up to %@ + %lld more steps",
        "Use at least %lld characters.",
        "%lld take-profit/stop-loss orders from an earlier %@ long are still armed on Perpl and would act on this new position. Cancel them from Orders first.",
        "%lld take-profit/stop-loss orders from an earlier %@ short are still armed on Perpl and would act on this new position. Cancel them from Orders first.",
        "%@ · %lld orders from the closed long",
        "%@ · %lld orders from the closed short",
        "Your recovery phrase hides in %lld seconds. Choose Keep Showing for more time.",
        "%lld %@ candles. Last %@, up %@ over the period. High %@, low %@.",
        "%lld %@ candles. Last %@, down %@ over the period. High %@, low %@.",
        "%lld TP/SL on %@ have no position to close. Left armed, they would fire on your next position here.",
        "This position has %lld TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next long here).",
        "This position has %lld TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next short here).",
        "This position has %lld TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next long here. Check Orders afterwards.",
        "This position has %lld TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next short here. Check Orders afterwards.",
        "The limit price can have at most %lld decimal places on %@.",
        "%lld take profits are live. A new one replaces all of them.",
        "%lld stop losses are live. A new one replaces all of them.",
        "Cancel %lld Triggers",
        "Cancelled %lld TP/SL",
        "%lld percent",
        "%lld times",
        "Maximum leverage, %lld times",
        "%lld times leverage",
    ]

    /// Every listed plural key is still written in the Perps or Wallet code, so the list stays the code's.
    func testThePluralKeysAreTheCodes() throws {
        let code = try Self.scopedSources().map(\.text).joined(separator: "\n")
        let value = #"\\\(.+?\)"# // one interpolation, `\(…)`, nested parentheses included
        for key in Self.pluralKeys {
            let pattern = NSRegularExpression.escapedPattern(for: key)
                .replacingOccurrences(of: "%lld", with: value).replacingOccurrences(of: "%@", with: value)
            XCTAssertNotNil(code.range(of: "\"" + pattern + "\"", options: .regularExpression), "not in the Perps or Wallet code: \(key)")
        }
    }

    /// A plural key the app's catalog carries has English `one` and `other` forms, so a count of 1 reads right in
    /// English too: the catalog step adds them with every language's. A release (`DYORHQ_RELEASE_GATE=1`) needs every
    /// plural key in the catalog, since a key that isn't there shows its English as written, "1 more steps".
    func testThePluralKeysHaveEnglishPluralForms() throws {
        let url = try Self.ios().appendingPathComponent("DyorHQ/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = catalog["strings"] as? [String: Any] ?? [:]
        let release = ProcessInfo.processInfo.environment["DYORHQ_RELEASE_GATE"] == "1"
        for key in Self.pluralKeys {
            guard let entry = strings[key] as? [String: Any] else {
                if release { XCTFail("not in the app's catalog (run scripts/dev/strings-sync.sh, then add its plural forms): \(key)") }
                continue
            }
            let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any] ?? [:]
            let substitutions = (english["substitutions"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
            let plurals = ([english] + substitutions).compactMap { ($0["variations"] as? [String: Any])?["plural"] as? [String: Any] }
            let complete = plurals.contains { forms in
                ["one", "other"].allSatisfy { form in
                    let unit = (forms[form] as? [String: Any])?["stringUnit"] as? [String: Any]
                    return !((unit?["value"] as? String) ?? "").isEmpty
                }
            }
            XCTAssertTrue(complete, "no English one/other plural forms in the app's catalog: \(key)")
        }
    }
}
