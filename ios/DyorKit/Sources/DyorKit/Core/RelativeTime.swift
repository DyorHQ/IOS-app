import Foundation

/// A short age or wait in the app's language: one whole unit, the largest that fits, written with iOS's own narrow
/// units (`Duration.UnitsFormatStyle(width: .narrow)` in `L10n.locale`). English reads "45s", "3m", "2h" and "5d", as the
/// app always wrote it; French "3min" and "5j", Spanish "3 min", Chinese "3分钟", Korean "3분". The coin cards, the
/// trade and activity rows (as "%@ ago") and the bridge's time estimate use it. Numbers stay whole: nothing rounds up.
public enum RelativeTime {
    /// How long ago `unix` (seconds since 1970) was at `now`: seconds under a minute, then minutes, hours and days, each
    /// rounded down. Empty when there is no time (0 or less); a time in the future reads as 0 seconds.
    public static func short(_ unix: Int, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        guard unix > 0 else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        if seconds < 60 { return narrow(seconds, .seconds, locale: locale) }
        if seconds < 3600 { return narrow(seconds / 60 * 60, .minutes, locale: locale) }
        if seconds < 86400 { return narrow(seconds / 3600 * 3600, .hours, locale: locale) }
        return narrow(seconds / 86400 * 86400, .days, locale: locale)
    }

    /// A wait of `seconds`, in whole seconds ("30s", "600s"): the bridge's estimate, as it has always been shown.
    public static func seconds(_ seconds: Int, locale: Locale = L10n.locale) -> String {
        narrow(max(0, seconds), .seconds, locale: locale)
    }

    /// `seconds`, an exact number of `unit`s, in that unit alone.
    private static func narrow(_ seconds: Int, _ unit: Duration.UnitsFormatStyle.Unit, locale: Locale) -> String {
        var style = Duration.UnitsFormatStyle(allowedUnits: [unit], width: .narrow)
        style.locale = locale
        return Duration.seconds(Int64(seconds)).formatted(style)
    }
}
