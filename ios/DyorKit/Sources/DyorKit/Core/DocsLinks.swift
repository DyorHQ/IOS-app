import Foundation

/// The DyorHQ docs (GitBook, dyorhq.gitbook.io/docs), one case per page the app links to: the Help Center (the home), the
/// Learn rows of Get Help, and the "Learn more" links under a screen's own explanation. Each path is the page's published
/// GitBook path, checked live: GitBook's canonical paths differ from the docs repository's file paths, so a path is never
/// built from a file name, and none redirects. `DocsLinksTests` pins the table to the published pages, and with
/// DYOR_LIVE_DOCS=1 asks each one for a 200 without following a redirect.
public enum DocsLinks: String, CaseIterable, Sendable {
    /// The docs home: the Help Center.
    case home = ""
    case quickstart = "getting-started/quickstart"
    case selfCustodyAndSecurity = "platform/self-custody-and-security"
    case slippageAndPriceImpact = "spot-trading/slippage-and-price-impact"
    case depositAndWithdraw = "perpetuals/deposit-and-withdraw"
    case oneClickTrading = "perpetuals/one-click-trading"
    case launchACoin = "launchpad/launch-a-coin"
    case launchpadGraduation = "launchpad/graduation"
    case launchpadFeesAndRewards = "launchpad/fees-and-rewards"
    case publishAMoment = "moments/publish-a-moment"
    case collectAMoment = "moments/collect-a-moment"
    case momentsGraduationAndVesting = "moments/graduation-and-vesting"
    case momentsEarningsAndFees = "moments/earnings-and-fees"
    case bridge = "wallet-and-account/bridge"
    case notificationsAndPriceAlerts = "wallet-and-account/notifications-and-price-alerts"
    case exportSignOutDelete = "wallet-and-account/export-sign-out-delete"
    case riskDisclosures = "resources/risk-disclosures"

    /// Where the docs live. The home is this URL itself, with no trailing slash.
    public static let base = "https://dyorhq.gitbook.io/docs"

    /// The page's published URL.
    public var url: URL {
        URL(string: rawValue.isEmpty ? Self.base : "\(Self.base)/\(rawValue)")!
    }

    /// The page's topic, for a link's accessibility label ("Learn more about …").
    public var topic: String {
        switch self {
        case .home: return "DyorHQ"
        case .quickstart: return "getting started"
        case .selfCustodyAndSecurity: return "self-custody and security"
        case .slippageAndPriceImpact: return "slippage and price impact"
        case .depositAndWithdraw: return "depositing and withdrawing collateral"
        case .oneClickTrading: return "one-click trading"
        case .launchACoin: return "launching a coin"
        case .launchpadGraduation: return "graduation"
        case .launchpadFeesAndRewards: return "launchpad fees and rewards"
        case .publishAMoment: return "publishing a Moment"
        case .collectAMoment: return "collecting a Moment"
        case .momentsGraduationAndVesting: return "Moment graduation and vesting"
        case .momentsEarningsAndFees: return "Moment earnings and fees"
        case .bridge: return "bridging"
        case .notificationsAndPriceAlerts: return "notifications and price alerts"
        case .exportSignOutDelete: return "exporting, signing out and deleting"
        case .riskDisclosures: return "the risks"
        }
    }
}
