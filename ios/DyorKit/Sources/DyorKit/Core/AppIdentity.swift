import Foundation

/// How DyorHQ names itself: to the servers it calls, and in the device log.
public enum AppIdentity {
    /// The `User-Agent` of the HTTP requests DyorHQ makes to its own and its partners' servers.
    // not localized: a protocol header
    public static let userAgent = "DyorHQ/1.0 (iOS)"
    /// The subsystem of every `Logger` DyorHQ writes to the device log (Console.app); each has a category of its own.
    // not localized: a log subsystem
    public static let logSubsystem = "fun.dyorhq.app"
}
