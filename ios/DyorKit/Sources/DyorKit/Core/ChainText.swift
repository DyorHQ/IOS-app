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
        return String(out)
    }

    /// LF, VT, FF, CR, NEL, and the line and paragraph separators.
    private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
}
