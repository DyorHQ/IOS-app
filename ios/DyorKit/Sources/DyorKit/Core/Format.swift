import BigInt
import Foundation

/// Conversions between raw token units and human numbers, plus the trading-style number formatting the app uses
/// wherever SwiftUI's own formatters are not the right tool (dust prices, compact balances).
public enum Amount {
    /// `BigUInt` raw units to a floating value; precise enough for display, never for math that goes on-chain.
    public static func units(_ value: BigUInt, decimals: Int) -> Double {
        guard decimals > 0 else { return Double(value) }
        return Double(value) / pow(10, Double(decimals))
    }

    public static func units(_ value: BigInt, decimals: Int) -> Double {
        let magnitude = units(value.magnitude, decimals: decimals)
        return value.sign == .minus ? -magnitude : magnitude
    }

    /// Exact conversion of a floating amount to raw units (rounds half away from zero at the last digit).
    public static func raw(_ value: Double, decimals: Int) -> BigUInt {
        guard value.isFinite, value > 0 else { return 0 }
        let text = String(format: "%.\(decimals)f", value)
        return parse(text, decimals: decimals) ?? 0
    }

    /// Parses user input like "1,234.5" into raw units. Returns nil for anything that is not a plain decimal.
    public static func parse(_ input: String, decimals: Int) -> BigUInt? {
        let cleaned = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, cleaned != ".", cleaned.allSatisfy({ $0.isNumber || $0 == "." }), cleaned.filter({ $0 == "." }).count <= 1 else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? ""
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        if fraction.count > decimals { fraction = String(fraction.prefix(decimals)) }
        fraction += String(repeating: "0", count: decimals - fraction.count)
        let digits = (whole.isEmpty ? "0" : whole) + fraction
        return BigUInt(digits, radix: 10)
    }

    /// Exact decimal string of raw units, trimmed of trailing zeros ("1.5", "0.000001", "1200").
    public static func exact(_ value: BigUInt, decimals: Int) -> String {
        let digits = String(value)
        if decimals == 0 { return digits }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[split...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = String(padded[..<split])
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }
}

public enum NumberStyle {
    private static let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")

    /// Balances and prices: compact suffixes for large values (1.2M), trailing zeros trimmed, and
    /// leading-zero notation (0.0₆42) for dust prices so tiny tokens stay readable.
    public static func number(_ value: Double, compact: Bool = false, maximumFractionDigits: Int? = nil) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        let sign = value < 0 ? "−" : ""
        if magnitude == 0 { return "0" }
        if compact, magnitude >= 1_000 {
            let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
            for (divisor, suffix) in units where magnitude >= divisor {
                return sign + trim(String(format: "%.2f", magnitude / divisor)) + suffix
            }
        }
        if magnitude >= 1_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = maximumFractionDigits ?? 2
            return sign + (formatter.string(from: NSNumber(value: magnitude)) ?? String(magnitude))
        }
        if magnitude >= 1 { return sign + trim(String(format: "%.\(maximumFractionDigits ?? 4)f", magnitude)) }
        if magnitude >= 1e-4 { return sign + trim(String(format: "%.6f", magnitude)) }
        // 0.000000042 → 0.0₇42
        let text = String(format: "%.20f", magnitude)
        guard let dot = text.firstIndex(of: ".") else { return sign + String(magnitude) }
        let fraction = text[text.index(after: dot)...]
        let zeros = fraction.prefix { $0 == "0" }.count
        var significant = String(fraction.dropFirst(zeros).prefix(4))
        while significant.count > 1, significant.hasSuffix("0") { significant.removeLast() }
        return "\(sign)0.0\(String(zeros).map { subscripts[Int(String($0))!] }.map(String.init).joined())\(significant)"
    }

    public static func units(_ value: BigUInt, decimals: Int, compact: Bool = false, maximumFractionDigits: Int? = nil) -> String {
        number(Amount.units(value, decimals: decimals), compact: compact, maximumFractionDigits: maximumFractionDigits)
    }

    public static func percent(_ value: Double, fractionDigits: Int = 2, signed: Bool = true) -> String {
        guard value.isFinite else { return "—" }
        let body = String(format: "%.\(fractionDigits)f%%", abs(value))
        if !signed { return body }
        return (value < 0 ? "−" : value > 0 ? "+" : "") + body
    }

    public static func basisPoints(_ bps: Int) -> String {
        trim(String(format: "%.2f", Double(bps) / 100)) + "%"
    }

    private static func trim(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
