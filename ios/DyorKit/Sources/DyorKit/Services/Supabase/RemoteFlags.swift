import Foundation

/// Switches the owner can flip from the backend, without a new build: the optional `flags` object of the public,
/// read-only `app_config` row 'ios' (`{"min_build": 16, "flags": {"dyorVenuePrices": false}}`), read with the minimum
/// build (`SupabaseClient.iosAppConfig`, by the app's `UpdateGate`). All four are kill switches (`dyorVenuePrices`,
/// `dyorBadges`, `perpsLiveOutcome`, `perpsApiActions`): each is on unless the row says JSON `false` for it. A row
/// without `flags`, a switch left out, and a value that isn't JSON true or false (a string, a number, null, an object)
/// all leave it on. So shipping writes nothing to production, and a typo in the row can't turn a feature off.
public struct RemoteFlags: Equatable, Sendable {
    /// DyorHQ coins priced on their own curve or pool (`PriceService.setUsesDyorVenues`). Off, they are priced like any
    /// other token, as build 16 priced them.
    public let dyorVenuePrices: Bool
    /// The DyorHQ Launch and DyorHQ Moment labels (`TokenBadge`). Off, a DyorHQ coin shows as build 16 showed it: no
    /// DyorHQ label, and one sent to the wallet Unverified.
    public let dyorBadges: Bool
    /// The one-click order sheet shows Perpl's real outcome (filled, resting, not filled…) instead of ending at the
    /// gateway's acknowledgement. Off (JSON `false`): today's acknowledgement sheet (`placeLegacy`), and Close / Add
    /// Margin / Cancel Order go on-chain. Requests already sent keep the mode of their tap.
    public let perpsLiveOutcome: Bool
    /// Close / Add Margin / Cancel Order go over the trading connection when one-click is live. Off (JSON `false`): they
    /// go on-chain; the order sheet is unaffected. Requests already sent keep the mode of their tap.
    public let perpsApiActions: Bool

    /// Every switch on: what the app uses until the row is read (or its last values read are restored), and for a row
    /// that says nothing.
    public static let on = RemoteFlags()

    public init(dyorVenuePrices: Bool = true, dyorBadges: Bool = true, perpsLiveOutcome: Bool = true, perpsApiActions: Bool = true) {
        self.dyorVenuePrices = dyorVenuePrices
        self.dyorBadges = dyorBadges
        self.perpsLiveOutcome = perpsLiveOutcome
        self.perpsApiActions = perpsApiActions
    }

    /// The switches in PostgREST's answer to `app_config?key=eq.ios&select=value` (`[{"value": {...}}]`). Anything that
    /// isn't that answer, or a `flags` that isn't an object, is `.on`.
    public static func parse(_ data: Data) -> RemoteFlags {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 1,
              let value = rows[0]["value"] as? [String: Any], let flags = value["flags"] as? [String: Any] else { return .on }
        return RemoteFlags(dyorVenuePrices: flag(flags["dyorVenuePrices"]), dyorBadges: flag(flags["dyorBadges"]),
                           perpsLiveOutcome: flag(flags["perpsLiveOutcome"]), perpsApiActions: flag(flags["perpsApiActions"]))
    }

    /// A kill switch's value: false only for JSON `false`; on for everything else.
    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }
}
