import XCTest
@testable import DyorKit

/// The app's local notifications (build 17, N1): what a perp order's notice says, and the delegate installed at launch.
final class LocalNotificationTests: XCTestCase {
    /// The app's sources, or a skip when this checkout has no app.
    private func appSource(_ path: String) throws -> String {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file of the app, by path relative to `ios/DyorHQ`.
    private func appSources() throws -> [(path: String, text: String)] {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() }
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { file in
            (String(file.path.dropFirst(app.path.count + 1)), try String(contentsOf: file, encoding: .utf8))
        }
    }

    /// `text` with every run of whitespace as one space: the checks pin the code, not its indentation.
    private func squeeze(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text of the function that starts at `signature` in `text`, up to its closing brace at the indentation it
    /// opened at.
    private func function(_ signature: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), signature)
        let line = text[..<start.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(line.prefix { $0 == " " })
        let end = try XCTUnwrap(text.range(of: "\n" + indent + "}\n", range: start.upperBound..<text.endIndex), signature)
        return String(text[start.lowerBound..<end.upperBound])
    }

    // MARK: - Perp order notices

    /// Perpl acknowledging a market order is not a fill: it says "Order submitted". A limit order says "Order placed".
    /// Only a position read says "Order filled".
    func testAnAcknowledgedOrderIsNeverFilled() {
        XCTAssertEqual(PerpOrderNotice(acknowledged: .market), .submitted)
        XCTAssertEqual(PerpOrderNotice(acknowledged: .market).title, "Order submitted")
        XCTAssertEqual(PerpOrderNotice(acknowledged: .limit), .placed)
        XCTAssertEqual(PerpOrderNotice(acknowledged: .limit).title, "Order placed")
        XCTAssertEqual(PerpOrderNotice.filled.title, "Order filled")
        for kind in [OrderKind.market, .limit] {
            XCTAssertNotEqual(PerpOrderNotice(acknowledged: kind), .filled, "\(kind)")
        }
    }

    /// The app posts the notice from the order's kind at acknowledgement and `.filled` only from `detectFills`, and the
    /// old `filled:` flag (which made a market order say "Order filled" at acknowledgement) is gone.
    func testTheAppPostsTheNoticeByKind() throws {
        let notifications = try appSource("Wallet/Notifications.swift")
        XCTAssertTrue(notifications.contains("static func perpOrder(_ notice: PerpOrderNotice, side: String, market: String) {"))
        XCTAssertTrue(notifications.contains("post(kind: .perp, title: notice.title,"))
        XCTAssertFalse(notifications.contains("\"Order filled\""), "the titles live in PerpOrderNotice")

        let trade = try appSource("Perps/PerpTradeView.swift")
        XCTAssertTrue(trade.contains("Notifications.perpOrder(PerpOrderNotice(acknowledged: input.kind), side:"))
        let fills = try appSource("Perps/PerpsView.swift")
        let detect = try function("private func detectFills(", in: fills)
        XCTAssertTrue(detect.contains("Notifications.perpOrder(.filled, side:"), "the fill notice comes from detectFills")

        for (path, text) in try appSources() {
            XCTAssertFalse(text.contains("filled: input.kind == .market"), path)
            XCTAssertFalse(text.contains("filled: true"), path)
            let calls = text.components(separatedBy: "Notifications.perpOrder(").dropFirst()
            for call in calls {
                let notice = call.prefix { $0 != "," }
                XCTAssertTrue(notice == "PerpOrderNotice(acknowledged: input.kind)" || (notice == ".filled" && path == "Perps/PerpsView.swift"),
                              "\(path): perpOrder(\(notice), …)")
            }
        }
    }

    // MARK: - The delegate, at launch

    /// The notification delegate is installed in the app delegate's `didFinishLaunching`, before iOS hands over the tap
    /// that launched the app, and nowhere else: not in RootView's `.task`, which runs too late for a cold start.
    /// Banners keep showing while the app is open.
    func testTheDelegateIsSetAtLaunch() throws {
        let app = try appSource("App/DyorHQApp.swift")
        let delegate = try XCTUnwrap(app.range(of: "final class AppDelegate: NSObject, UIApplicationDelegate {"))
        let launch = try function("func application(_ application: UIApplication,\n                     didFinishLaunchingWithOptions", in: String(app[delegate.upperBound...]))
        XCTAssertTrue(launch.contains("Notifications.configure()"))
        XCTAssertTrue(launch.contains("return true"))

        let root = try appSource("App/RootView.swift")
        XCTAssertFalse(root.contains("Notifications.configure()"))
        XCTAssertTrue(squeeze(root).contains(".task { session.start(); settings.appearance.apply() }"))

        let notifications = try appSource("Wallet/Notifications.swift")
        let configure = squeeze(try function("static func configure() {", in: notifications))
        XCTAssertTrue(configure.contains("if center.delegate !== NotificationForegroundDelegate.shared { center.delegate = NotificationForegroundDelegate.shared }"),
                      "set once; a second call changes nothing")
        let willPresent = try function("func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent", in: notifications)
        XCTAssertTrue(willPresent.contains("completionHandler([.banner, .list, .sound])"))

        for (path, text) in try appSources() {
            XCTAssertEqual(text.components(separatedBy: "Notifications.configure()").count - 1, path == "App/DyorHQApp.swift" ? 1 : 0, path)
            let delegates = text.components(separatedBy: "delegate = NotificationForegroundDelegate.shared").count - 1
            XCTAssertEqual(delegates, path == "Wallet/Notifications.swift" ? 1 : 0, path)
        }
    }
}
