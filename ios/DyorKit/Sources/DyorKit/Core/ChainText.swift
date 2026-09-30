import Foundation

public extension ChainText {
    /// Creator text as the app shows it (a launch's name, symbol and description, a Moment's name, symbol and place),
    /// with the characters `WalletHoldings.visible` drops for being invisible or changing direction removed: format
    /// characters (general category Cf: the direction embeddings, overrides and isolates, the direction marks,
    /// zero-width spaces and joiners, the byte-order mark, the soft hyphen), default-ignorable code points and the rest
    /// of `Address.cleanedInput`'s invisible set, and control characters. A creator's symbol can then never reverse or
    /// hide the app's text around it: "PEPE" and U+202E before "· 10.5 MON" showed "NOM 5.01 ·". A line break (CR LF as
    /// one) is a space, or stays a line break in `multiline` text (a description); a tab is a space. A joiner, variation
    /// selector or tag right after an emoji stays, so emoji sequences (a family, a flag, a red heart) still draw as one:
    /// none of them changes direction.
    ///
    /// Single-line text (a name, a symbol, a place) with a right-to-left letter in it (`isRightToLeft`) comes back inside
    /// U+2068 FIRST STRONG ISOLATE … U+2069 POP DIRECTIONAL ISOLATE: its own letters still read right to left, and the
    /// numbers and words the app puts around it keep their order. Without the isolate, the symbol "אבג" drew the ticket's
    /// "Balance: 1.2K אבג · 10.5 MON" as "Balance: 1.2K 10.5 · גבא MON". A description (`multiline`) is never wrapped: it
    /// is shown on its own, as a paragraph that takes its direction from its first letter, which an isolate would hide.
    /// Nor is text with no right-to-left letter, so every ASCII name and symbol comes back exactly as cleaned, character
    /// for character: comparisons with curated symbols ("USDC"), `WalletHoldings.isPlain` and look-ups by symbol are
    /// unaffected. A letter disc takes its letters with `leading`, which skips the isolate.
    ///
    /// For showing only: a Moment's link slug, and anything hashed or compared, reads the chain's text as it is.
    static func shown(_ text: String, multiline: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        var afterEmoji = false
        var previous: UInt32 = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            defer { previous = value }
            if lineBreaks.contains(value) {
                afterEmoji = false
                if value == 0x0A, previous == 0x0D { continue }
                out.append(multiline ? "\n" : " ")
                continue
            }
            if value == 0x09 {
                afterEmoji = false
                out.append(" ")
                continue
            }
            if afterEmoji, value == 0x200D || value == 0xFE0E || value == 0xFE0F || (0xE0020...0xE007F).contains(value) {
                out.append(scalar)
                continue
            }
            let properties = scalar.properties
            switch properties.generalCategory {
            case .format, .control: continue
            default: break
            }
            if properties.isDefaultIgnorableCodePoint || Address.isInvisible(scalar) { continue }
            out.append(scalar)
            afterEmoji = properties.isEmoji
        }
        guard !multiline, out.contains(where: isRightToLeft) else { return String(out) }
        return "\u{2068}" + String(out) + "\u{2069}"
    }

    /// The first `count` characters of `text` that draw, for a letter disc (a coin with no logo): a character made only of
    /// format characters (general category Cf), such as the isolate `shown` puts around right-to-left text, is skipped,
    /// so the symbol "אבג" shows "אב", not one letter. Text without such characters gives exactly `text.prefix(count)`.
    static func leading(_ text: String, _ count: Int) -> String {
        String(text.lazy.filter { !$0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format } }.prefix(max(0, count)))
    }

    /// Whether `scalar` lies where Unicode's code points default to a strong right-to-left direction (bidi class R or AL
    /// in DerivedBidiClass, assigned or not): Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and their
    /// extensions (U+0590–U+08FF), the Hebrew and Arabic presentation forms (U+FB1D–U+FDFF, U+FE70–U+FEFE; U+FEFF, the
    /// byte-order mark, is removed anyway), and the right-to-left scripts of the supplementary planes (U+10800–U+10FFF,
    /// U+1E800–U+1EFFF). Swift exposes no bidi class, so these ranges stand in for it. The few code points in them that
    /// aren't letters (Arabic digits, marks) only mean that text with them is isolated too, which changes nothing.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFE, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    /// LF, VT, FF, CR, NEL, and the line and paragraph separators.
    private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
}
