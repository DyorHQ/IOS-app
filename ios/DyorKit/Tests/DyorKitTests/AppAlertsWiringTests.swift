import XCTest
@testable import DyorKit

/// The app's wiring of the alerts while it is open (build 17, N2; the rules are `AppAlertsTests`): the "Perps Margin
/// Warnings" switch and App Lock's fresh-install default (R4).
final class AppAlertsWiringTests: XCTestCase {
    private func app(_ path: String) throws -> String {
        try DocsLinksTests.appSource(path).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text of the function that starts at `signature`, up to its closing brace at the indentation it opened at.
    private func function(_ signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let line = text[..<start.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(line.prefix { $0 == " " })
        let end = try XCTUnwrap(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex), signature)
        return String(text[start.lowerBound..<end.upperBound]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The switch: "Perps Margin Warnings", on by default, next to the others, mirrored to the backend with them.
    func testTheMarginSwitch() throws {
        let settings = try app("Profile/Settings.swift")
        XCTAssertTrue(settings.contains("Toggle(\"Swaps & Fills\", isOn: $settings.notifyFills) Toggle(\"Perps Margin Warnings\", isOn: $settings.notifyMargin) Toggle(\"Price Alerts\", isOn: $settings.notifyPriceAlerts)"))
        let theme = try app("Design/Theme.swift")
        XCTAssertTrue(theme.contains("var notifyMargin: Bool { didSet { store(notifyMargin, \"settings.notifyMargin\") } }"))
        XCTAssertTrue(theme.contains("notifyMargin = defaults.object(forKey: \"settings.notifyMargin\") as? Bool ?? true"))
        XCTAssertTrue(theme.contains("\"notifyMargin\": notifyMargin,"))
        XCTAssertTrue(theme.contains("if let v = restored.notifyMargin { notifyMargin = v }"))
        XCTAssertEqual(BackendRestore.settings(from: ["notifyMargin": false], appearances: []).notifyMargin, false)
        XCTAssertNil(BackendRestore.settings(from: ["notifyMargin": 1], appearances: []).notifyMargin, "a number is not a boolean")
        XCTAssertNil(BackendRestore.settings(from: [:], appearances: []).notifyMargin)
    }

    /// R4: a fresh install must start with App Lock ON, which `AppSettings.appLockDefault` decides from whether any key
    /// with an earlier run's prefix exists. The new switch's key has the "settings." prefix (like "settings.notifyFills"),
    /// so it must never be written before that decision: `init` only reads it, and only its `didSet` writes it (Swift runs
    /// no `didSet` during `init`), through `store`. N2's other files write no key with such a prefix at all.
    func testTheNewKeyCantTurnAppLockOff() throws {
        let raw = try DocsLinksTests.appSource("Design/Theme.swift")
        let earlierRun = try XCTUnwrap(raw.range(of: "let earlierRun = [")).upperBound
        let quotesAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
        let prefixes = raw[earlierRun...].prefix { $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: quotesAndSpace) }
        XCTAssertTrue(prefixes.contains("settings.") && prefixes.contains("perp.") && prefixes.contains("priceAlerts."), "\(prefixes)")

        // In `init`, every key is read; the only write is App Lock's own decision, after which `store` may write.
        let initBody = try function("init(defaults: UserDefaults = .standard) {", in: raw)
        XCTAssertFalse(initBody.contains("defaults.set("), "init writes nothing")
        XCTAssertFalse(initBody.contains("store("), "init writes nothing")
        XCTAssertTrue(initBody.contains("requireBiometrics = defaults.object(forKey: \"settings.biometrics\") as? Bool ?? Self.appLockDefault(defaults)"))
        XCTAssertTrue(initBody.contains("notifyMargin = defaults.object(forKey: \"settings.notifyMargin\") as? Bool ?? true"))
        // The key is written in one place: its didSet.
        XCTAssertEqual(raw.components(separatedBy: "\"settings.notifyMargin\"").count - 1, 2, "read in init, written in didSet")
        for (path, text) in try AppSwiftSources.all() where path != "Design/Theme.swift" {
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
        for file in ["Services/Perpl/PerpRisk.swift", "Services/Notifications/AppAlerts.swift"] {
            var kit = URL(fileURLWithPath: #filePath)
            for _ in 0..<3 { kit.deleteLastPathComponent() }
            let text = try String(contentsOf: kit.appendingPathComponent("Sources/DyorKit").appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("UserDefaults"), file)
            XCTAssertEqual(prefixed(text), [], file)
        }
    }
}

/// Every Swift file of the app, by path relative to `ios/DyorHQ`.
enum AppSwiftSources {
    static func all() throws -> [(path: String, text: String)] {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() }
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { file in
            (String(file.path.dropFirst(app.path.count + 1)), try String(contentsOf: file, encoding: .utf8))
        }
    }
}
