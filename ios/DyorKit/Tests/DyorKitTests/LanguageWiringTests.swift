import Foundation
import XCTest
@testable import DyorKit

/// The app's wiring of its language (build 18, L1), read from the app's sources and project: the catalogs agree with
/// the project, and no source resolves text with a locale argument.
final class LanguageWiringTests: XCTestCase {
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

    private static func between(_ text: String, _ start: String, _ end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start).upperBound
        let to = try XCTUnwrap(text.range(of: end, range: from..<text.endIndex), end).lowerBound
        return String(text[from..<to])
    }

    /// The catalogs and the project: English is the development language everywhere, the bundle lists only the languages
    /// that ship (and no catalog carries another), the permission strings in the InfoPlist catalog are the Info.plist's
    /// own, and the app's name is never translated.
    func testTheCatalogsAndTheProjectAgree() throws {
        let ios = try Self.ios()
        let project = try Self.source("project.yml")
        XCTAssertTrue(project.contains("\n  developmentLanguage: en\n"))
        XCTAssertTrue(project.contains("\n    LOCALIZATION_PREFERS_STRING_CATALOGS: YES\n"))
        XCTAssertTrue(project.contains("\n    SWIFT_EMIT_LOC_STRINGS: YES\n"))
        let package = Self.squeezed(try Self.source("DyorKit/Package.swift"))
        XCTAssertTrue(package.contains("defaultLocalization: \"en\","))
        XCTAssertTrue(package.contains("], resources: [.process(\"Resources\")]),"))

        let info = try XCTUnwrap(NSDictionary(contentsOf: ios.appendingPathComponent("DyorHQ/Info.plist")) as? [String: Any])
        let shipped = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(shipped, ["en"], "English only until a translation is complete")
        XCTAssertTrue(project.contains("        CFBundleLocalizations: [\(shipped.joined(separator: ", "))]\n"), "Info.plist regenerated from project.yml")

        func catalog(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: ios.appendingPathComponent(path))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], path)
            XCTAssertEqual(json["sourceLanguage"] as? String, "en", path)
            return try XCTUnwrap(json["strings"] as? [String: Any], path)
        }
        let catalogs = ["DyorHQ/Resources/Localizable.xcstrings", "DyorHQ/Resources/InfoPlist.xcstrings",
                        "DyorKit/Sources/DyorKit/Resources/Localizable.xcstrings"]
        for path in catalogs {
            for (key, entry) in try catalog(path) {
                let languages = ((entry as? [String: Any])?["localizations"] as? [String: Any])?.keys.map { $0 } ?? []
                for language in languages { XCTAssertTrue(shipped.contains(language), "\(path): \(key) has \(language), which doesn't ship") }
            }
        }

        let plist = try catalog("DyorHQ/Resources/InfoPlist.xcstrings")
        for key in ["NSFaceIDUsageDescription", "NSPhotoLibraryUsageDescription", "CFBundleDisplayName", "CFBundleName"] {
            let entry = try XCTUnwrap(plist[key] as? [String: Any], key)
            let english = (((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertEqual(english, info[key] as? String, "\(key): the catalog's English is the Info.plist's, byte for byte")
        }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            XCTAssertEqual((plist[key] as? [String: Any])?["shouldTranslate"] as? Bool, false, "\(key): DyorHQ is never translated")
        }
    }

    /// `String(localized:…, locale:)` never selects a language (its locale only formats the arguments), so no source uses
    /// it: text goes through `tr()` or `L10n.tr`.
    func testNoSourceResolvesTextWithALocaleArgument() throws {
        let ios = try Self.ios()
        var checked = 0
        for folder in ["DyorHQ", "DyorKit/Sources"] {
            let files = FileManager.default.enumerator(at: ios.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" {
                checked += 1
                for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") where line.contains("String(localized:") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    XCTAssertFalse(line.contains("locale:"), "\(file.lastPathComponent): \(line)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }
}
