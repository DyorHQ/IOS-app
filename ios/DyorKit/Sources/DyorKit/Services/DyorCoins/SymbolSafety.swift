import Foundation

/// Which coin symbols show as what they are, and which names and symbols a coin made in DyorHQ may not take.
///
/// A symbol is display-safe when nothing in it can make it read as another: plain printable ASCII (as MON's and every
/// curated token's is), or Chinese, Japanese or Korean letters with ASCII digits. Everything else is not: control,
/// format, direction-changing and zero-width characters, combining marks, full-width Latin, and letters from any other
/// script — Cyrillic and Greek hold letters drawn exactly like Latin ones — as well as a mix of Latin and CJK letters.
/// A DyorHQ coin whose symbol isn't display-safe is labelled Unverified, never "DyorHQ Launch" (`TokenBadge`), and the
/// create forms refuse such a symbol, any name or symbol that reads as a curated token's, and a name with hidden
/// characters or Latin letters mixed with Cyrillic or Greek ones (`createRefusal`), so a coin made in the app never
/// carries a warning. One made directly on the contracts still can.
public enum SymbolSafety {
    /// Whether `symbol` shows as what it is (see above). False for empty text or spaces alone.
    public static func isDisplaySafe(_ symbol: String) -> Bool {
        guard symbol.unicodeScalars.contains(where: { $0.value != 0x20 }) else { return false }
        if WalletHoldings.isPlain(symbol) { return true }
        var letters = 0
        for scalar in symbol.unicodeScalars {
            if ("0"..."9").contains(scalar) { continue }
            guard isEastAsianLetter(scalar) else { return false }
            letters += 1
        }
        return letters > 0
    }

    /// A letter of the Han (Chinese), Hangul (Korean), Hiragana or Katakana (Japanese) scripts, precomposed: the blocks
    /// below, and only their letters (`Lo`, or `Lm` such as 々 and the long-vowel mark ー), never an invisible filler
    /// (U+3164 and its kin are letters by category). Radicals, compatibility ideographs, conjoining and half-width jamo,
    /// half-width kana and the combining sound marks are left out: none is needed to write a name, and each is another way
    /// to draw the same text.
    static func isEastAsianLetter(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard properties.generalCategory == .otherLetter || properties.generalCategory == .modifierLetter, !properties.isDefaultIgnorableCodePoint else { return false }
        return eastAsianLetters.contains { $0.contains(scalar.value) }
    }

    private static let eastAsianLetters: [ClosedRange<UInt32>] = [
        // Han: the iteration marks 々 and 〆, CJK Unified Ideographs and Extension A, then Extensions B–I.
        0x3005...0x3006, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF, 0x2A700...0x2EE5F, 0x30000...0x323AF,
        // Hangul syllables and compatibility jamo.
        0xAC00...0xD7A3, 0x3131...0x318E,
        // Hiragana, its iteration marks; Katakana, the long-vowel and iteration marks, the small phonetic extensions.
        0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF,
    ]

    // MARK: Create guard

    /// Why a create form refuses a coin's name or symbol.
    public enum CreateRefusal: Hashable, Sendable {
        /// The symbol reads as a curated token's (`WalletHoldings.imitated(by:)`): "USDC", "USDС" with a Cyrillic С, "WM0N".
        case symbolImitates(Token)
        /// The name reads as a curated token's name or symbol: "Monad", "Wrapped MON", "USDC".
        case nameImitates(Token)
        /// The symbol isn't display-safe (`isDisplaySafe`).
        case symbolNotDisplaySafe
        /// The name holds a character that doesn't show as itself (`hasHiddenCharacters`).
        case nameHasHiddenCharacters
        /// The name mixes Latin letters with Cyrillic or Greek ones (`mixesLookAlikeAlphabets`).
        case nameMixesAlphabets

        /// What the form says under the field.
        public var message: String {
            switch self {
            case .symbolImitates(let token): return "This symbol looks like \(token.symbol), a token DyorHQ already lists. Choose another symbol."
            case .nameImitates(let token): return "This name looks like \(token.symbol), a token DyorHQ already lists. Choose another name."
            case .symbolNotDisplaySafe: return "Use Latin letters, or Chinese, Japanese or Korean letters, with digits. Other alphabets and hidden characters aren't allowed."
            case .nameHasHiddenCharacters: return "This name has hidden or direction-changing characters. Remove them."
            case .nameMixesAlphabets: return "This name mixes Latin letters with Cyrillic or Greek letters that look like them. Use one alphabet."
            }
        }

        /// Whether it is about the symbol field (else the name field).
        public var isAboutSymbol: Bool {
            switch self {
            case .symbolImitates, .symbolNotDisplaySafe: return true
            case .nameImitates, .nameHasHiddenCharacters, .nameMixesAlphabets: return false
            }
        }
    }

    /// Why a new launch or Moment may not take `name` and `symbol`, or nil when it may: a symbol that reads as a curated
    /// token's, then a name that does, then a symbol that isn't display-safe, then a name with hidden characters, then a
    /// name mixing look-alike alphabets. An empty field is the form's own check, not a refusal here.
    public static func createRefusal(name: String, symbol: String) -> CreateRefusal? {
        if let token = WalletHoldings.imitated(by: probe(symbol: symbol, name: "")) { return .symbolImitates(token) }
        if let token = WalletHoldings.imitated(by: probe(symbol: "", name: name)) { return .nameImitates(token) }
        if !symbol.isEmpty, !isDisplaySafe(symbol) { return .symbolNotDisplaySafe }
        if hasHiddenCharacters(name) { return .nameHasHiddenCharacters }
        if mixesLookAlikeAlphabets(name) { return .nameMixesAlphabets }
        return nil
    }

    /// Whether `name` holds a character that doesn't show as itself: a control, format or direction-changing character,
    /// a zero-width or other invisible one (`Address.isInvisible`, default-ignorable code points), a line or paragraph
    /// separator, a private-use or unassigned code point. The joiner, variation selectors and tags inside an emoji
    /// sequence ("👨‍👩‍👧", "❤️", a flag) belong to the emoji, and accents to their letters ("Café", "Niño"): neither is hidden.
    public static func hasHiddenCharacters(_ name: String) -> Bool {
        for character in name {
            let scalars = character.unicodeScalars
            let emoji = scalars.count > 1 && (scalars.first?.properties.isEmoji ?? false)
            for scalar in scalars {
                if emoji, scalar.value == 0x200D || scalar.value == 0xFE0E || scalar.value == 0xFE0F || (0xE0020...0xE007F).contains(scalar.value) { continue }
                let properties = scalar.properties
                switch properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
                default: break
                }
                if properties.isDefaultIgnorableCodePoint || Address.isInvisible(scalar) { return true }
            }
        }
        return false
    }

    /// Whether `name` has Latin letters and Cyrillic or Greek ones, many of which are drawn exactly alike ("Dоge" with a
    /// Cyrillic о). A name in one of those alphabets alone, or in any other, is fine.
    public static func mixesLookAlikeAlphabets(_ name: String) -> Bool {
        var latin = false
        var lookAlike = false
        for scalar in name.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            // Basic Latin, Latin-1 and Extended-A/B, Latin Extended Additional, full-width Latin.
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A: latin = true
            // Greek and Coptic, Greek Extended, Cyrillic and its supplement and extensions.
            case 0x370...0x3FF, 0x1F00...0x1FFF, 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: lookAlike = true
            default: break
            }
        }
        return latin && lookAlike
    }

    /// A token that is neither MON nor curated, carrying the text to check, for `WalletHoldings.imitated(by:)`.
    private static func probe(symbol: String, name: String) -> Token {
        Token(address: Address(literal: "0x000000000000000000000000000000000000dEaD"), symbol: symbol, name: name, decimals: 18)
    }
}
