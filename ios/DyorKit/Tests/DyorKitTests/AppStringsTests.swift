import Foundation
import XCTest
@testable import DyorKit

/// The text of the app's remaining folders (L2: Onboarding, Profile, Notifications, Support, News, App, Menu, Design,
/// Social, Backend, Config, Trade), read from the app's sources. Text written in the code reaches the screen in the app's
/// language: a `String` the code builds (a label returned by a model, an error, a notice, an Activity row, a step's
/// label) goes through `tr()`; a word is never chosen inside another string's interpolation; text with nothing to
/// translate ("·", "@", a count) is shown verbatim, never as a key; a count with a noun is one key with the count as its
/// argument, whose English plural forms a release needs in the catalog; a label is never derived from a raw value; an
/// ambiguous or tight label carries a translator comment; dates and durations follow the app's language; errors are told
/// apart by type, never by text. What must stay English is left as it is: the server's own words the app matches, the
/// word typed to delete an account, and the subjects and device details of a mail to support.
final class AppStringsTests: XCTestCase {
    private static let folders = ["App", "Backend", "Config", "Design", "Menu", "News", "Notifications", "Onboarding", "Profile",
                                  "Social", "Support", "Trade"]

    /// The Swift files of the folders, by their path under ios/DyorHQ.
    private static func sources() throws -> [(path: String, text: String)] {
        let all = try FormattedTextIsolationTests.appSources().filter { source in folders.contains { source.path.hasPrefix($0 + "/") } }
        XCTAssertEqual(all.count, 29, "the folders' files")
        return all
    }

    private static func source(_ path: String) throws -> String { try DocsLinksTests.appSource(path) }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The lines of the folders with their literals; a line marked "not localized", or right under such a marker, is
    /// left out.
    private static func scannedLines() throws -> [(at: String, line: String, literals: [PerpsWalletStringsTests.Literal])] {
        var out: [(String, String, [PerpsWalletStringsTests.Literal])] = []
        for (path, text) in try sources() {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let previous = index > 0 ? lines[index - 1] : ""
                if line.contains("not localized") || previous.contains("// not localized") { continue }
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                out.append(("\(path):\(index + 1)", line, PerpsWalletStringsTests.literals(in: line)))
            }
        }
        return out
    }

    /// The body of the first `{ … }` after `declaration` (itself after `after`, when given), its comments removed.
    private static func body(of declaration: String, after: String? = nil, in file: String) throws -> String {
        let code = String(TradeStringsTests.uncommented(Array(try source(file))))
        let from = try after.map { try XCTUnwrap(code.range(of: $0), "\(file): \($0)").upperBound } ?? code.startIndex
        let start = try XCTUnwrap(code.range(of: declaration, range: from..<code.endIndex), "\(file): \(declaration)")
        let open = try XCTUnwrap(code[start.upperBound...].firstIndex(of: "{"))
        let chars = Array(code)
        let openIndex = code.distance(from: code.startIndex, to: open)
        let close = try XCTUnwrap(TradeStringsTests.closing(chars, openIndex))
        return String(chars[openIndex...close])
    }

    // MARK: Text built as a String

    /// A word chosen inside another string's interpolation (`"\(n == 1 ? "it" : "them")"`, `?? "this token"`) is never
    /// looked up: each choice is a sentence of its own, or a `tr()`.
    func testNoWordIsChosenInsideAnInterpolation() throws {
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth > 0
                && (PerpsWalletStringsTests.isWords(literal.text) || literal.text.range(of: "^[a-z]{2,}$", options: .regularExpression) != nil) {
                found.append("\(at): \"\(literal.text)\"")
            }
        }
        XCTAssertEqual(found, [], "a word inside an interpolation is shown in English in every language")
    }

    /// Text built as a `String` (a returned label, an assigned error or notice, a fallback after `??`, a thrown failure's
    /// reason, an Activity row, a feed row, a step's label) goes through `tr()`: a bare literal there is shown in English in
    /// every language.
    func testStringTextGoesThroughTr() throws {
        let sink = try NSRegularExpression(pattern: #"(return |(?<![=!<>])= |\?\? |\.unavailable\(|\.backendSignInNeeded\(|\.emailSignInNotDeleted\(|\.bindFailed\(|\.append\(|error: )$"#)
        let record = try NSRegularExpression(pattern: #"(title: |subtitle: |body: |label: |side: )$"#)
        var found: [String] = []
        var checked = 0
        for (at, line, literals) in try Self.scannedLines() {
            let recordLine = ["ActivityRecord(", "FeedItem(", "post(kind:", ".call(", "Notifications.", "AppNotification("].contains { line.contains($0) }
            for literal in literals where literal.depth == 0 && PerpsWalletStringsTests.isWords(literal.text) {
                checked += 1
                let before = NSRange(literal.before.startIndex..., in: literal.before)
                if sink.firstMatch(in: literal.before, range: before) != nil || (recordLine && record.firstMatch(in: literal.before, range: before) != nil) {
                    found.append("\(at): \"\(literal.text)\"")
                }
            }
        }
        XCTAssertEqual(found, [], "String text written in the code goes through tr()")
        XCTAssertGreaterThan(checked, 400, "the scan reads the folders' text")
    }

    /// The `String`s these folders build are written inside `tr()`, one sentence per case: the notices a deletion leaves
    /// (`DeletionNoticeView`), the Send sheet's problems, the log-in messages, the feed's rows.
    func testBuiltTextIsWrittenInTr() throws {
        let deletion = Self.squeezed(try Self.source("Profile/AccountDeletion.swift"))
        for assignment in deletion.components(separatedBy: "notice = ").dropFirst() {
            XCTAssertTrue(assignment.hasPrefix("tr(") || assignment.hasPrefix("Failure.privyNotConfigured.localizedDescription")
                          || assignment.hasPrefix("try await deleteEmailSignIn("), "a deletion notice: \(assignment.prefix(60))")
        }
        XCTAssertEqual(try Self.body(of: "var errorDescription: String?", in: "Profile/AccountDeletion.swift").components(separatedBy: "return tr(").count - 1, 3)
        let onboarding = try Self.source("Onboarding/OnboardingView.swift")
        let acknowledgement = try Self.body(of: "private func replaceAcknowledgement(", in: "Onboarding/OnboardingView.swift")
        XCTAssertEqual(acknowledgement.components(separatedBy: "return tr(\"I understand").count - 1, 4, "one whole sentence per case")
        XCTAssertFalse(onboarding.contains("let beyond"), "no sentence glued from pieces")
        XCTAssertFalse(onboarding.contains("let retry ="))
        XCTAssertTrue(onboarding.contains(#"return tr("\(message) If you made this password with it shown"#))
        // A wallet that holds nothing is a sentence of its own, never a fragment dropped into "%@ holds %@."
        XCTAssertTrue(onboarding.contains(#"Label("\(conflict.current.short) holds no MON or tokens.", systemImage: "circle.dashed")"#))
        XCTAssertFalse(onboarding.contains(#"tr("no MON or tokens")"#))
        // An HTTP status is no count: it goes in as text, never as a plural argument.
        XCTAssertTrue(try Self.source("Profile/AccountDeletion.swift").contains(#"tr("error \(String(code))")"#))
        let send = try Self.body(of: "private var problem: String?", in: "Profile/ProfileView.swift")
        XCTAssertEqual(send.components(separatedBy: "return tr(").count - 1, 3)
        let feed = try Self.source("Profile/RecentActivityView.swift")
        for title in [#"title: tr("Swapped")"#, #"title: tr("Launched $\(symbol)")"#, #"title: isBuy ? tr("Bought \(symbol)") : tr("Sold \(symbol)")"#,
                      #"title: tr("\(symbol) graduated")"#] {
            XCTAssertTrue(feed.contains(title), title)
        }
        let profile = try Self.source("Profile/ProfileView.swift")
        XCTAssertTrue(profile.contains(#"return [.call(request, label: tr("Send \(review.token.symbol)"))]"#), "the step's label")
        XCTAssertTrue(profile.contains(#"title: tr("Sent \(review.token.symbol)")"#), "the Activity row")
    }

    /// Text with nothing to translate ("·", "@", "—", a count, "0x…") is shown as it is, never looked up as a key.
    func testNoPlaceholderOnlyKey() throws {
        let key = try NSRegularExpression(pattern: #"(Text|Label|Button|TextField|SecureField|Toggle|Section|LabeledContent|Link|ProgressView|\.accessibilityLabel|\.accessibilityValue|\.navigationTitle)\($"#)
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
        // A key placed inside another's interpolation would be a key with nothing to translate ("%@. %@").
        for (path, text) in try Self.sources() {
            XCTAssertFalse(text.contains(#"Text("\(Text("#), "\(path): a key made only of other text")
        }
        let help = try Self.source("Support/GetHelpView.swift")
        XCTAssertTrue(help.contains(#".accessibilityLabel(title + Text(verbatim: ". ") + detail)"#))
        XCTAssertTrue(help.contains(#"HelpRow(symbol: "at", title: Text(verbatim: "X"), detail: Text(verbatim: SupportLinks.xHandle))"#), "a name")
        XCTAssertTrue(help.contains(#"title: Text(verbatim: "dyorhq.fun")"#), "an address")
        XCTAssertTrue(help.contains(#"detail: Text(verbatim: "dyorhq.fun/terms")"#))
        XCTAssertTrue(help.contains(#"detail: Text(verbatim: "dyorhq.fun/privacy")"#))
        XCTAssertTrue(try Self.source("Menu/SideMenuView.swift").contains("Text(verbatim: SupportLinks.name)"), "the app's name")
        XCTAssertTrue(try Self.source("Onboarding/OnboardingView.swift").contains(#".accessibilityLabel(Text(verbatim: "\(SupportLinks.name). \(SupportLinks.tagline)."))"#))
    }

    // MARK: Labels

    /// A label that used to be written in English per case, or derived from a raw value, is a `tr()` per case (the app's
    /// name, DyorHQ, excepted), and a picker shows a case's title, never its raw value.
    func testLabelsAreLocalizedPerCase() throws {
        let labels: [(file: String, after: String?, declaration: String, cases: Int)] = [
            ("Design/Theme.swift", "enum AppearanceMode", "var label: String", 3),
            ("App/Router.swift", "enum TradeMode", "var label: String", 2),
            ("App/Router.swift", "enum VolumePeriod", "var label: String", 4),
            ("App/Router.swift", "enum VolumePeriod", "var shortLabel: String", 4),
            ("App/Router.swift", "enum MenuItem", "var title: String", 8),
            ("App/Router.swift", "enum MenuItem", "var subtitle: String", 8),
            ("Notifications/NotificationHub.swift", "enum Kind", "var title: String", 5),
            ("Onboarding/OnboardingView.swift", "struct StrengthMeter", "private var label: String", 4),
        ]
        for (file, after, declaration, cases) in labels {
            let body = try Self.body(of: declaration, after: after, in: file)
            XCTAssertFalse(body.contains("capitalized"), "\(file): \(declaration)")
            XCTAssertEqual(body.components(separatedBy: "tr(").count - 1, cases, "\(file): \(declaration): one tr() per label")
            for line in body.components(separatedBy: "\n") where !line.contains("tr(") {
                let bare = PerpsWalletStringsTests.literals(in: line).filter { PerpsWalletStringsTests.isWords($0.text) }
                XCTAssertEqual(bare.map(\.text), [], "\(file): \(declaration): words outside tr()")
            }
        }
        XCTAssertTrue(try Self.body(of: "var title: String", after: "enum Kind", in: "Notifications/NotificationHub.swift")
            .contains(#"case .system: return "DyorHQ""#), "the app's name is never translated")
        for (path, text) in try Self.sources() {
            XCTAssertFalse(text.contains(".capitalized"), "\(path): a label derived from a raw value")
            XCTAssertNil(text.range(of: #"Text\(\$0\.rawValue\)"#, options: .regularExpression), "\(path): a raw value shown as text")
        }
        // A segmented switch shows each case's title, a key with its [tight] comment, never the case's raw value.
        let onboarding = try Self.source("Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains("ForEach(Mode.allCases) { $0.title.tag($0) }"))
        XCTAssertTrue(onboarding.contains("case signUp, logIn\n"), "raw values are identifiers, never shown")
        let importer = try Self.source("Onboarding/ImportWalletView.swift")
        XCTAssertTrue(importer.contains("ForEach(Kind.allCases) { $0.title.tag($0) }"))
        XCTAssertTrue(importer.contains("case phrase, key\n"))
        for (file, declaration, cases) in [("Onboarding/OnboardingView.swift", "var title: Text", 2), ("Onboarding/ImportWalletView.swift", "var title: Text", 2)] {
            let titles = try Self.body(of: declaration, in: file)
            XCTAssertEqual(titles.components(separatedBy: "[tight]\")").count - 1, cases, "\(file): each side is tight")
        }
        // English is as before.
        XCTAssertEqual(AppLanguage.en.endonym, "English", "the language names stay in their own language")
    }

    // MARK: Plurals

    /// The keys with a count (an `Int`, so `%lld`) in these folders, as the app's catalog spells them, and what each says
    /// for a count of one. Their singular comes from the catalog's plural forms, English included: without them a count of
    /// 1 reads "1 words", "1 transactions" or "1 take-profit/stop-loss orders … them".
    static let pluralKeys: [PerpsWalletStringsTests.PluralKey] = [
        .init("%lld words. Words are separated by spaces.", one: ["word."], notOne: ["words."]),
        .init("It has sent %lld transactions, so it may also hold positions, collateral or coins not shown here.",
              one: ["transaction,"], notOne: ["transactions"]),
        .init("You have %lld take-profit/stop-loss orders live on Perpl. Removing the key doesn't cancel them: they stay armed, and this device can't show or cancel them until you connect again.",
              one: ["order live", "cancel it"], notOne: ["orders", "them", "they"]),
    ]

    /// A count with a noun is one key with the count as its argument, which the catalog gives its plural forms (and the
    /// pronouns that follow it, "it" or "them"); English is never chosen by hand (`count == 1 ? "" : "s"`). Every listed key
    /// is still written in the code, so the list stays the code's.
    func testPluralsAreKeysWithTheirCount() throws {
        for (path, text) in try Self.sources() {
            XCTAssertNil(text.range(of: #"== 1 \? ""#, options: .regularExpression), "\(path): a plural chosen by hand")
        }
        let code = try Self.sources().map(\.text).joined(separator: "\n")
        let value = #"\\\(.+?\)"# // one interpolation, `\(…)`, nested parentheses included
        for key in Self.pluralKeys.map(\.key) {
            let pattern = NSRegularExpression.escapedPattern(for: key)
                .replacingOccurrences(of: "%lld", with: value).replacingOccurrences(of: "%@", with: value)
            XCTAssertNotNil(code.range(of: "\"" + pattern + "\"", options: .regularExpression), "not in the code: \(key)")
        }
        // The count is an Int: the wallet's transaction count, a UInt64, would make the key "%llu".
        XCTAssertTrue(try Self.source("Onboarding/OnboardingView.swift").contains(#"It has sent \(Int(clamping: holdings.transactions)) transactions"#))
    }

    /// The app's catalog gives each plural key English forms whose "one" differs from the "other" and says the singular
    /// ("%lld word.", "%lld transaction,", "order … it"), as the catalog step writes them with every language's
    /// (`PerpsWalletStringsTests.checkEnglishPlurals`). Until then the test is skipped, naming the keys still pending; a
    /// release (`DYORHQ_RELEASE_GATE=1`) refuses a key the catalog doesn't have, since it reads "1 words".
    func testThePluralKeysHaveEnglishPluralForms() throws {
        try PerpsWalletStringsTests.checkEnglishPlurals(Self.pluralKeys, catalog: Data(try Self.source("Resources/Localizable.xcstrings").utf8))
    }

    /// Each key takes the singular English says for a count of one, and refuses the plural as written ("1 words").
    func testEachPluralKeyTakesItsEnglishSingular() {
        let singular = [
            "%lld word. Words are separated by spaces.",
            "It has sent %lld transaction, so it may also hold positions, collateral or coins not shown here.",
            "You have %lld take-profit/stop-loss order live on Perpl. Removing the key doesn't cancel it: it stays armed, and this device can't show or cancel it until you connect again.",
        ]
        XCTAssertEqual(Self.pluralKeys.count, singular.count)
        for (key, one) in zip(Self.pluralKeys, singular) {
            XCTAssertNil(PerpsWalletStringsTests.englishPluralProblem(PerpsWalletStringsTests.englishPlural(one: one, other: key.key), key), key.key)
            XCTAssertNotNil(PerpsWalletStringsTests.englishPluralProblem(PerpsWalletStringsTests.englishPlural(one: key.key, other: key.key), key),
                            "the plural for one: \(key.key)")
        }
    }

    // MARK: Translator comments

    /// A short key whose meaning depends on where it stands carries a translator comment there: "All" sources or all
    /// notifications, "Close" a screen (and elsewhere a position), "Watch" an address, "To" an address, a status ("Locked",
    /// "Enrolled", "Ready", "Error", "Now"); a label in a tight place (the menu, the switches, the chips, the statuses)
    /// says "[tight]". English is unchanged: a comment is only for the translator.
    func testAmbiguousKeysCarryTheirComments() throws {
        let bare = [#"chip("All""#, #"Text("All")"#, #".accessibilityLabel("Close")"#, #"Button("Watch")"#, #"Text("To")"#,
                    #"LabeledContent("Session")"#, #"LabeledContent("Sign-in""#, #"Text("Locked")"#, #"Text("Enrolled")"#,
                    #"Text("Now")"#, #"Text("Ready")"#, #"Text("Error")"#]
        var tight = 0
        for (path, text) in try Self.sources() {
            for occurrence in bare { XCTAssertFalse(text.contains(occurrence), "\(path): \(occurrence) without its comment") }
            tight += text.components(separatedBy: "[tight]").count - 1
        }
        XCTAssertGreaterThanOrEqual(tight, 40, "the tight labels say so")
        // A position's side reads as the Perps screens' own key and comment, which also name the order button.
        let alerts = try Self.source("Notifications/AlertCenter.swift")
        let trade = try Self.source("Perps/PerpTradeView.swift")
        for side in [#"LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]")"#,
                     #"LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]")"#] {
            XCTAssertTrue(alerts.contains(side), side)
            XCTAssertTrue(trade.contains(side), "the Perps screen's own: \(side)")
        }
        // One key is one translation: the Trade switch's "Swap" (the screen's name, a noun) is a key of its own, and the
        // key "Swap" is the swap review's button, a verb. English reads "Swap" for both.
        let mode = Self.squeezed(try Self.body(of: "var label: String", after: "enum TradeMode", in: "App/Router.swift"))
        XCTAssertTrue(mode.contains(#"case .swap: tr(LocalizedStringResource("tradeMode.swap", defaultValue: "Swap", comment: "The Trade tab's switch to its spot-swap screen: the screen's name, a noun [tight]"))"#))
        XCTAssertTrue(try DocsLinksTests.appSource("Swap/SwapView.swift")
            .contains(#"confirmTitle: LocalizedStringResource("Swap", comment: "Button: make the swap the review shows (a verb)")"#), "the review's button")
    }

    /// A key is one translation wherever it stands, so a key used in several places carries one comment, the same at
    /// every place that writes one, and it names each use; a use with another meaning gets a key of its own.
    func testASharedKeyHasOneCommentForEveryUse() throws {
        let shared: [(key: String, names: [String])] = [("Swap", ["(a verb)"])]
        let app = try FormattedTextIsolationTests.appSources().map(\.text).joined(separator: "\n")
        for (key, names) in shared {
            let site = try NSRegularExpression(pattern: #"(?:LocalizedStringResource|Text)\(""# + NSRegularExpression.escapedPattern(for: key) + #"", comment: "((?:[^"\\]|\\.)*)""#)
            let comments = Set(site.matches(in: app, range: NSRange(app.startIndex..., in: app)).compactMap { Range($0.range(at: 1), in: app).map { String(app[$0]) } })
            XCTAssertEqual(comments.count, 1, "\(key): one comment for every use: \(comments.sorted())")
            for comment in comments {
                for name in names { XCTAssertTrue(comment.contains(name), "\(key): the comment names \(name): \(comment)") }
            }
        }
    }

    // MARK: Dates and durations

    /// Every date and duration written as a `String` is in the app's language (`L10n.locale`), in the system's own units;
    /// English reads as before.
    func testDatesAndDurationsFollowTheAppLanguage() throws {
        for (path, text) in try Self.sources() {
            for line in text.components(separatedBy: "\n") where line.contains(".formatted(") {
                XCTAssertTrue(line.contains("L10n.locale"), "\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
            for line in text.components(separatedBy: "\n") where line.contains("String(format:") {
                XCTAssertFalse(PerpsWalletStringsTests.literals(in: line).contains { PerpsWalletStringsTests.isWords($0.text) },
                               "\(path): words in a format string: \(line.trimmingCharacters(in: .whitespaces))")
            }
            XCTAssertFalse(text.contains("ListFormatter.localizedString("), "\(path): a list in the device's language")
        }
        let center = try Self.source("Notifications/NotificationCenterView.swift")
        XCTAssertTrue(center.contains(#"tr("Today")"#) && center.contains(#"tr("Yesterday")"#))
        XCTAssertTrue(center.contains("day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))"))
        let settings = try Self.source("Profile/Settings.swift")
        XCTAssertTrue(settings.contains("Duration.seconds(Int(length)).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))"))
        XCTAssertTrue(settings.contains(#"Text("Unlocked · \(clock) left")"#))
        XCTAssertFalse(String(TradeStringsTests.uncommented(Array(settings))).contains(#""1 hour""#), "no English-only length")
        XCTAssertTrue(try Self.source("Onboarding/OnboardingView.swift").contains("list.locale = L10n.locale"))

        // English is unchanged: the session lengths read as the code wrote them before.
        let en = Locale(identifier: "en_US")
        let lengths = Mera.SessionLength.choices.map { Duration.seconds(Int($0)).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(en)) }
        XCTAssertEqual(lengths, ["5 minutes", "15 minutes", "1 hour"])
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!).locale(en)), "Sep 21, 2026")
        let list = ListFormatter()
        list.locale = en
        XCTAssertEqual(list.string(from: ["1 MON", "2 USDC", "3 AUSD"]), "1 MON, 2 USDC, and 3 AUSD")
    }

    // MARK: Errors

    /// `describe(_:)` tells a cancelled request and a lost connection by the error's type and code (`FailureKind`), never
    /// by matching its English text, and says them in the app's language.
    func testDescribeKnowsFailuresByType() throws {
        let describe = Self.squeezed(try Self.body(of: "func describe(_ error: Error) -> String", in: "Design/Components.swift"))
        XCTAssertTrue(describe.contains("switch FailureKind.of(error) {"))
        XCTAssertTrue(describe.contains(#"case .cancelled: return tr("Cancelled.")"#))
        XCTAssertTrue(describe.contains(#"case .offline: return tr("No connection. Check your network and try again.")"#))
        XCTAssertTrue(describe.contains("case .other: return error.localizedDescription"))
        // An error's own description comes first, as before: English reads as it did (an RPC call's lost connection still
        // says iOS's own sentence, through `NetworkError`), and only an error without one is told by its type and code.
        let own = try XCTUnwrap(describe.range(of: "(error as? LocalizedError)?.errorDescription"))
        let kind = try XCTUnwrap(describe.range(of: "switch FailureKind.of(error)"))
        XCTAssertLessThan(own.lowerBound, kind.lowerBound)
        for (path, text) in try Self.sources() {
            XCTAssertFalse(text.contains("localizedCaseInsensitiveContains(\"cancel"), path)
            XCTAssertFalse(text.contains("localizedCaseInsensitiveContains(\"network"), path)
            XCTAssertFalse(text.contains("localizedDescription.contains("), "\(path): an error matched by its text")
        }
    }

    /// The server's own English words the app matches stay English, whatever the app's language, and each is still what
    /// the function sends: the email binding's code and its word for a stale token, delete-account's answers. The word
    /// typed to delete an account is DELETE in every language.
    func testServerMatchersStayEnglish() throws {
        let onboarding = try Self.source("Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains(#"guard Self.serverField(text, "error") == "email_already_bound", "#))
        XCTAssertTrue(onboarding.contains(#"catch SupabaseError.http(401, let text) where Self.serverField(text, "error")?.contains("expired") == true { throw EmailAuthError.verificationExpired }"#))
        XCTAssertTrue(onboarding.contains("// not localized: the function's own English word for a stale token"))
        let deletion = try Self.source("Profile/AccountDeletion.swift")
        XCTAssertTrue(deletion.contains(#"catch SupabaseError.http(401, let body) where body.contains("invalid Privy access token") { // not localized"#))
        XCTAssertTrue(deletion.contains(#"catch SupabaseError.http(409, let body) where serverError(body) == "no email binding" { // not localized"#))
        XCTAssertEqual(deletion.components(separatedBy: #"body.contains("PRIVY_APP_SECRET") { // not localized"#).count - 1, 2)
        XCTAssertTrue(deletion.contains(#"confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" } // not localized"#))
        XCTAssertTrue(deletion.contains(#"comment: "Keep DELETE in English and in capitals: it is the word the user must type""#))

        let rebind = try EdgeFunctionErrorTests.function("email-rebind")
        XCTAssertTrue(rebind.contains(#"error: "email_already_bound""#))
        XCTAssertTrue(rebind.contains(#"{ error: "this verification expired — request a new code" }, 401"#))
        let delete = try EdgeFunctionErrorTests.function("delete-account")
        XCTAssertTrue(delete.contains(#"error: "no email binding""#))
        XCTAssertTrue(delete.contains(#"{ error: "invalid Privy access token" }, 401"#))
        XCTAssertTrue(delete.contains(#""PRIVY_APP_SECRET is not configured""#))

        // A mail to support: its subject and the device details are for the support team; the body is the user's.
        let help = try Self.source("Support/GetHelpView.swift")
        XCTAssertTrue(help.contains(#"mail(subject: "DyorHQ support")"#))
        XCTAssertTrue(help.contains(#"mail(subject: "DyorHQ bug report", body: tr("What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n"))"#))
    }

    // MARK: Update screen and the Google button

    /// The owner's update message is written in English: the Update screen shows it only while the app is in English, and
    /// the app's own text otherwise.
    func testTheUpdateScreenShowsTheServerMessageOnlyInEnglish() throws {
        let gate = Self.squeezed(try Self.source("App/UpdateGate.swift"))
        XCTAssertTrue(gate.contains("if let message = minimum.ownerMessage(in: language.resolved) { Text(verbatim: message) } else { Text(\"This version of DyorHQ is no longer supported."))
        XCTAssertFalse(gate.contains("minimum.message"), "the row's text is shown only through ownerMessage(in:) (MinimumBuildTests)")
        XCTAssertTrue(gate.contains("@Environment(LanguageStore.self) private var language"))
    }

    /// "Continue with Google" is drawn in the bundled Google Sans subset only when the subset has every letter of the label
    /// in the app's language (`GoogleButtonFont`); the label is resolved once and drawn as it is.
    func testTheGoogleButtonFallsBackToTheSystemFont() throws {
        let button = Self.squeezed(try Self.source("Onboarding/OnboardingView.swift"))
        XCTAssertTrue(button.contains(#"let label = tr(LocalizedStringResource("Continue with Google", comment: "#))
        XCTAssertTrue(button.contains(#"Text(verbatim: label) .font(GoogleButtonFont.usesGoogleSans(label, language: language.resolved) ? Font.custom("GoogleSans-Medium", size: 17, relativeTo: .body) : Font.body.weight(.medium))"#))
        XCTAssertEqual(button.components(separatedBy: ".custom(\"GoogleSans-Medium\"").count - 1, 1, "Google Sans only behind the check")
    }
}
