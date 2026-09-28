import XCTest
@testable import DyorKit

/// The app's links into the DyorHQ docs (`DocsLinks`) go only to pages GitBook has published, at their canonical paths:
/// GitBook's paths differ from the docs repository's file paths, and a page that redirects or isn't published yet
/// (resources/faq, resources/past-cohorts-and-retired-launchpads, resources/security-and-responsible-disclosure) is never
/// linked. With DYOR_LIVE_DOCS=1, every link is asked for a 200 without following a redirect.
final class DocsLinksTests: XCTestCase {
    /// Every page published on 2026-09-28, each answering 200 at this exact URL.
    static let published: [String] = [
        "https://dyorhq.gitbook.io/docs",
        "https://dyorhq.gitbook.io/docs/getting-started/quickstart",
        "https://dyorhq.gitbook.io/docs/getting-started/create-your-account",
        "https://dyorhq.gitbook.io/docs/getting-started/fund-your-wallet",
        "https://dyorhq.gitbook.io/docs/getting-started/supported-network-and-assets",
        "https://dyorhq.gitbook.io/docs/platform/app-tour",
        "https://dyorhq.gitbook.io/docs/platform/self-custody-and-security",
        "https://dyorhq.gitbook.io/docs/platform/integrations-and-fees",
        "https://dyorhq.gitbook.io/docs/spot-trading/swap",
        "https://dyorhq.gitbook.io/docs/spot-trading/slippage-and-price-impact",
        "https://dyorhq.gitbook.io/docs/spot-trading/adding-tokens",
        "https://dyorhq.gitbook.io/docs/perpetuals/overview",
        "https://dyorhq.gitbook.io/docs/perpetuals/deposit-and-withdraw",
        "https://dyorhq.gitbook.io/docs/perpetuals/one-click-trading",
        "https://dyorhq.gitbook.io/docs/perpetuals/placing-orders",
        "https://dyorhq.gitbook.io/docs/perpetuals/managing-positions",
        "https://dyorhq.gitbook.io/docs/launchpad/overview",
        "https://dyorhq.gitbook.io/docs/launchpad/launch-a-coin",
        "https://dyorhq.gitbook.io/docs/launchpad/trading-on-the-curve",
        "https://dyorhq.gitbook.io/docs/launchpad/graduation",
        "https://dyorhq.gitbook.io/docs/launchpad/fees-and-rewards",
        "https://dyorhq.gitbook.io/docs/launchpad/my-launchpad",
        "https://dyorhq.gitbook.io/docs/moments/overview",
        "https://dyorhq.gitbook.io/docs/moments/publish-a-moment",
        "https://dyorhq.gitbook.io/docs/moments/collect-a-moment",
        "https://dyorhq.gitbook.io/docs/moments/graduation-and-vesting",
        "https://dyorhq.gitbook.io/docs/moments/earnings-and-fees",
        "https://dyorhq.gitbook.io/docs/moments/my-moments",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/home-and-portfolio",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/send-receive-transfer",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/bridge",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/notifications-and-price-alerts",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/profile-and-settings",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/dyorhq-social",
        "https://dyorhq.gitbook.io/docs/wallet-and-account/export-sign-out-delete",
        "https://dyorhq.gitbook.io/docs/resources/contracts-and-addresses",
        "https://dyorhq.gitbook.io/docs/resources/risk-disclosures",
        "https://dyorhq.gitbook.io/docs/resources/glossary",
        "https://dyorhq.gitbook.io/docs/resources/official-links",
    ]

    /// Written in the docs but not published yet: never linked.
    static let unpublished = ["resources/faq", "resources/past-cohorts-and-retired-launchpads", "resources/security-and-responsible-disclosure"]

    func testEveryLinkIsAPublishedDocsPage() {
        XCTAssertEqual(Self.published.count, 39)
        XCTAssertEqual(Set(Self.published).count, Self.published.count, "no page twice")
        for page in DocsLinks.allCases {
            let url = page.url.absoluteString
            XCTAssertTrue(url.hasPrefix("https://dyorhq.gitbook.io/docs"), url)
            XCTAssertTrue(Self.published.contains(url), "\(page): \(url) is not a published page")
            XCTAssertFalse(url.hasSuffix("/"), "\(url): GitBook redirects a trailing slash")
            XCTAssertNil(page.url.query, url)
            XCTAssertNil(page.url.fragment, url)
            XCTAssertFalse(Self.unpublished.contains { url.hasSuffix($0) }, url)
            XCTAssertFalse(page.topic.isEmpty, url)
        }
        XCTAssertEqual(Set(DocsLinks.allCases.map(\.url)).count, DocsLinks.allCases.count, "one case per page")
        XCTAssertEqual(DocsLinks.base, "https://dyorhq.gitbook.io/docs")
    }

    /// The table itself: each case and the page it opens.
    func testTheTableIsPinned() {
        let expected: [(DocsLinks, String)] = [
            (.home, "https://dyorhq.gitbook.io/docs"),
            (.quickstart, "https://dyorhq.gitbook.io/docs/getting-started/quickstart"),
            (.selfCustodyAndSecurity, "https://dyorhq.gitbook.io/docs/platform/self-custody-and-security"),
            (.slippageAndPriceImpact, "https://dyorhq.gitbook.io/docs/spot-trading/slippage-and-price-impact"),
            (.perpetualsOverview, "https://dyorhq.gitbook.io/docs/perpetuals/overview"),
            (.oneClickTrading, "https://dyorhq.gitbook.io/docs/perpetuals/one-click-trading"),
            (.launchACoin, "https://dyorhq.gitbook.io/docs/launchpad/launch-a-coin"),
            (.launchpadGraduation, "https://dyorhq.gitbook.io/docs/launchpad/graduation"),
            (.launchpadFeesAndRewards, "https://dyorhq.gitbook.io/docs/launchpad/fees-and-rewards"),
            (.publishAMoment, "https://dyorhq.gitbook.io/docs/moments/publish-a-moment"),
            (.collectAMoment, "https://dyorhq.gitbook.io/docs/moments/collect-a-moment"),
            (.momentsGraduationAndVesting, "https://dyorhq.gitbook.io/docs/moments/graduation-and-vesting"),
            (.momentsEarningsAndFees, "https://dyorhq.gitbook.io/docs/moments/earnings-and-fees"),
            (.bridge, "https://dyorhq.gitbook.io/docs/wallet-and-account/bridge"),
            (.notificationsAndPriceAlerts, "https://dyorhq.gitbook.io/docs/wallet-and-account/notifications-and-price-alerts"),
            (.exportSignOutDelete, "https://dyorhq.gitbook.io/docs/wallet-and-account/export-sign-out-delete"),
            (.riskDisclosures, "https://dyorhq.gitbook.io/docs/resources/risk-disclosures"),
        ]
        XCTAssertEqual(DocsLinks.allCases, expected.map(\.0))
        for (page, url) in expected { XCTAssertEqual(page.url.absoluteString, url, "\(page)") }
    }

    // MARK: The app

    /// The app's sources (ios/DyorHQ), or a skip when this checkout has only the package.
    static func appSource(_ path: String) throws -> String {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }

    /// The Help Center is the docs home: Get Help leads with the Learn rows, and Profile's settings list it next to the
    /// Terms of Use and the Privacy Policy. The old dyorhq.fun/support page is gone.
    func testGetHelpAndProfileOpenTheDocs() throws {
        let help = try Self.appSource("Support/GetHelpView.swift")
        XCTAssertTrue(help.contains("static let helpCenter = DocsLinks.home.url"))
        XCTAssertFalse(help.contains("dyorhq.fun/support"))
        let learn = try XCTUnwrap(help.range(of: "group(\"Learn\")"), "Get Help has a Learn group")
        let getHelp = try XCTUnwrap(help.range(of: "group(\"Get Help\")"))
        XCTAssertLessThan(learn.lowerBound, getHelp.lowerBound, "Learn comes first")
        let rows = String(help[learn.upperBound..<getHelp.lowerBound])
        for (title, link) in [("Help Center", "SupportLinks.helpCenter"), ("Getting Started", "DocsLinks.quickstart.url"),
                              ("Risk Disclosures", "DocsLinks.riskDisclosures.url")] {
            XCTAssertTrue(rows.contains("title: \"\(title)\"") && rows.contains("openURL(\(link))"), title)
        }
        // The published Contracts & Addresses page doesn't list the contracts this build calls yet: no row opens it.
        XCTAssertFalse(rows.contains("Contracts"))
        let profile = try Self.appSource("Profile/ProfileView.swift")
        XCTAssertTrue(profile.contains("Link(destination: SupportLinks.helpCenter) { SettingsRow(\"Help Center\""))
        let helpCenter = try XCTUnwrap(profile.range(of: "SettingsRow(\"Help Center\""))
        let terms = try XCTUnwrap(profile.range(of: "SettingsRow(\"Terms of Use\""))
        XCTAssertLessThan(helpCenter.lowerBound, terms.lowerBound)
    }

    /// Each "Learn more" sits on the screen that explains its topic (under a section footer or a line of help text), and
    /// the table holds only pages the app opens: those, plus Get Help's Learn rows. No screen writes a docs URL itself.
    func testEachLearnMoreLinkIsOnTheScreenThatExplainsIt() throws {
        let placements: Set<String> = [
            "oneClickTrading Profile/Settings.swift",               // Perpl Trading: the trading key's footer
            "perpetualsOverview Perps/PerpsView.swift",             // the first deposit, which opens the Perpl account
            "slippageAndPriceImpact Swap/SwapView.swift",           // the slippage sheet's explanation
            "launchACoin Launchpad/LaunchpadView.swift",            // Launch a Coin: the pairing footer
            "launchpadGraduation Launchpad/LaunchpadView.swift",    // the coin page's gauge, or its graduation section
            "launchpadFeesAndRewards Launchpad/LaunchpadView.swift", // the coin page's creator fees
            "publishAMoment Moments/CreateMomentView.swift",        // Publish a Moment: the economics footer
            "collectAMoment Moments/MomentDetailView.swift",        // the collect section
            "momentsGraduationAndVesting Moments/MomentDetailView.swift", // Your Position: vesting and claims
            "momentsEarningsAndFees Moments/MomentDetailView.swift", // You Created This: the creator's earnings
            "bridge Bridge/BridgeView.swift",                       // under "Powered by Aurora Intents"
            "exportSignOutDelete Wallet/WalletExportView.swift",    // Export Wallet: the key warning
            "exportSignOutDelete Profile/AccountDeletion.swift",    // Delete Account: what is deleted
            "notificationsAndPriceAlerts Profile/Settings.swift",   // Notifications: what reaches you, and when
            "selfCustodyAndSecurity Onboarding/OnboardingView.swift", // sign-in: "DyorHQ never holds your keys"
        ]
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() }
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"LearnMoreLink\(\.(\w+)\)"#)
        var found = Set<String>()
        var graduation = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = String(file.path.dropFirst(app.path.count + 1))
            XCTAssertFalse(text.contains("https://dyorhq.gitbook.io"), "\(relative): docs links come from DocsLinks")
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(match.range(at: 1), in: text)!])
                XCTAssertNotNil(DocsLinks.allCases.first { "\($0)" == name }, name)
                found.insert("\(name) \(relative)")
                if name == "launchpadGraduation" { graduation += 1 }
            }
        }
        XCTAssertEqual(found, placements)
        // The coin page shows one of its two graduation links: under the gauge while the curve trades, or under the
        // graduation section once it doesn't.
        XCTAssertEqual(graduation, 2)
        let launchpad = try Self.appSource("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(launchpad.contains("if launch.phase == .bonding, launch.curveSellsOpen { LearnMoreLink(.launchpadGraduation) }"))
        XCTAssertTrue(launchpad.contains("if launch.curveSellsOpen { ticketSection } else { graduatedSection }"))

        let linked = Set(placements.map { String($0.split(separator: " ")[0]) }).union(["home", "quickstart", "riskDisclosures"])
        XCTAssertEqual(linked, Set(DocsLinks.allCases.map { "\($0)" }), "one case per page the app opens, plus the home")
        let component = try Self.appSource("Design/Components.swift")
        XCTAssertTrue(component.contains("Link(\"Learn more\", destination: page.url)"))
    }

    // MARK: Live

    /// Every link answers 200 itself: no redirect is followed (a moved page answers 3xx here), so a link to a path GitBook
    /// only redirects from fails. Off by default: set DYOR_LIVE_DOCS=1.
    func testEveryLinkAnswers200WithoutARedirect() async throws {
        guard ProcessInfo.processInfo.environment["DYOR_LIVE_DOCS"] == "1" else { throw XCTSkip("set DYOR_LIVE_DOCS=1") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for page in DocsLinks.allCases {
            var request = URLRequest(url: page.url)
            request.httpMethod = "GET"
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            XCTAssertEqual(status, 200, "\(page.url.absoluteString) answered \(status.map(String.init) ?? "no HTTP status")"
                           + ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location").map { " → \($0)" } ?? ""))
        }
    }
}

/// Refuses every redirect, so the redirect response itself comes back.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
