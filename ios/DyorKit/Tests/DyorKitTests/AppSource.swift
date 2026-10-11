import Foundation
import XCTest

/// The repository's files as text, for the tests that check the app's wiring by reading its sources (the app has no
/// test target of its own), and for those that read the package's sources, the backend's or a script. One place for
/// where each file is, and for the one skip rule: a test of the app's files is skipped when this checkout has only the
/// package.
enum AppSource {
    /// The repository's root folder: this file is ios/DyorKit/Tests/DyorKitTests/AppSource.swift.
    static let root: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // AppSource.swift → DyorKitTests → Tests → DyorKit → ios
        return root
    }()

    /// ios: the app, the package and the project.
    static let iosFolder = root.appendingPathComponent("ios")

    /// ios/DyorHQ: the app's sources and resources.
    static let appFolder = iosFolder.appendingPathComponent("DyorHQ")

    /// ios/DyorKit/Sources/DyorKit: the package's sources.
    static let kitFolder = iosFolder.appendingPathComponent("DyorKit/Sources/DyorKit")

    /// A skip when this checkout has only the package (no ios/DyorHQ).
    static func requireApp() throws {
        guard FileManager.default.fileExists(atPath: appFolder.path) else {
            throw XCTSkip("ios/DyorHQ is not in this checkout")
        }
    }

    /// The app's file at `path` under ios/DyorHQ, or a skip when this checkout has only the package.
    static func app(_ path: String) throws -> String {
        try requireApp()
        return try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    /// The package's source file at `path` under ios/DyorKit/Sources/DyorKit.
    static func kit(_ path: String) throws -> String {
        try String(contentsOf: kitFolder.appendingPathComponent(path), encoding: .utf8)
    }

    /// The file at `path` under the repository's root.
    static func repo(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file of the app, by its path under ios/DyorHQ, in the order of those paths; a new file is read too.
    /// A skip when this checkout has only the package.
    static func allAppFiles() throws -> [(path: String, text: String)] {
        try requireApp()
        // The enumerator names each file by its real path, symlinks resolved (a folder under /tmp comes back under
        // /private/tmp), which #filePath need not be: both sides are resolved the same way before one is cut from the other.
        let folder = appFolder.resolvingSymlinksInPath().path
        let files = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { file in
            (path: String(file.resolvingSymlinksInPath().path.dropFirst(folder.count + 1)), text: try String(contentsOf: file, encoding: .utf8))
        }.sorted { $0.path < $1.path }
    }

    /// `text` with every run of whitespace, line breaks included, as one space: a check pins the code, not its
    /// indentation or where its lines break.
    static func squeezed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The one app file that declares the top-level type `name`, by its path under ios/DyorHQ, with its text: the file
    /// with a line that starts (after any attributes and modifiers) `struct`, `class`, `enum`, `actor` or `protocol`
    /// and the name, or, when no file declares the type itself, the one with its `extension`. A check of one type's code
    /// finds the type here, so moving it to a file of its own needs no change to the check. Fails unless exactly one
    /// file declares it.
    static func declaration(of name: String) throws -> (file: String, text: String) {
        let lead = #"^(?:@\w+(?:\([^)\n]*\))? )*(?:(?:public|internal|fileprivate|private|final|nonisolated|indirect) )*"#
        let named = " " + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        let type = try NSRegularExpression(pattern: lead + "(?:struct|class|enum|actor|protocol)" + named, options: .anchorsMatchLines)
        let extensionOfIt = try NSRegularExpression(pattern: lead + "extension" + named, options: .anchorsMatchLines)
        let files = try allAppFiles()
        func declaring(_ regex: NSRegularExpression) -> [(path: String, text: String)] {
            files.filter { regex.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
        }
        var found = declaring(type)
        if found.isEmpty { found = declaring(extensionOfIt) }
        let file = try XCTUnwrap(found.count == 1 ? found.first : nil, "\(name): declared in \(found.map(\.path)), not in one app file")
        return (file: file.path, text: file.text)
    }
}
