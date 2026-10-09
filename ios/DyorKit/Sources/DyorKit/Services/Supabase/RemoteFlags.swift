import Foundation

/// Switches the owner can flip from the backend, without a new build: the optional `flags` object of the public,
/// read-only `app_config` row 'ios' (`{"min_build": 16, "flags": {"dyorVenuePrices": false}}`), read with the minimum
/// build (`SupabaseClient.iosAppConfig`, by the app's `UpdateGate`). The kill switches (`dyorVenuePrices`, `dyorBadges`)
/// are on unless the row says `false` for them: a row without `flags`, a switch left out, and a value that isn't JSON
/// true or false (a string, a number, null, an object) all leave them on. So shipping writes nothing to production, and
/// a typo in the row can't turn a feature off. The one opt-in switch (`perpsLiveOutcome`) is the other way round: it is
/// on only when the row says JSON `true`, because it waits for the owner's evidence rather than protecting a shipped
/// feature.
public struct RemoteFlags: Equatable, Sendable {
    /// DyorHQ coins priced on their own curve or pool (`PriceService.setUsesDyorVenues`). Off, they are priced like any
    /// other token, as build 16 priced them.
    public let dyorVenuePrices: Bool
    /// The DyorHQ Launch and DyorHQ Moment labels (`TokenBadge`). Off, a DyorHQ coin shows as build 16 showed it: no
    /// DyorHQ label, and one sent to the wallet Unverified.
    public let dyorBadges: Bool
    /// The one-click order sheet waits for Perpl's real outcome (filled, resting, not filled…) instead of ending at the
    /// gateway's acknowledgement. Opt-in: off for a missing row, a missing key, a string, a number or null; on only for
    /// JSON `true`, which the owner sets once the stream census shows the shapes the outcome reading relies on.
    public let perpsLiveOutcome: Bool

    /// The kill switches on, the opt-in switch off: what the app uses until the row is read, and for a row that says
    /// nothing.
    public static let on = RemoteFlags()

    public init(dyorVenuePrices: Bool = true, dyorBadges: Bool = true, perpsLiveOutcome: Bool = false) {
        self.dyorVenuePrices = dyorVenuePrices
        self.dyorBadges = dyorBadges
        self.perpsLiveOutcome = perpsLiveOutcome
    }

    /// The switches in PostgREST's answer to `app_config?key=eq.ios&select=value` (`[{"value": {...}}]`). Anything that
    /// isn't that answer, or a `flags` that isn't an object, is `.on`.
    public static func parse(_ data: Data) -> RemoteFlags {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 1,
              let value = rows[0]["value"] as? [String: Any], let flags = value["flags"] as? [String: Any] else { return .on }
        return RemoteFlags(dyorVenuePrices: flag(flags["dyorVenuePrices"]), dyorBadges: flag(flags["dyorBadges"]),
                           perpsLiveOutcome: optIn(flags["perpsLiveOutcome"]))
    }

    /// A kill switch's value: false only for JSON `false`; on for everything else.
    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }

    /// An opt-in switch's value: true only for JSON `true`; off for everything else.
    private static func optIn(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}
