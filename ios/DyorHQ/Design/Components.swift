import BigInt
import DyorKit
import SwiftUI

// Small, reusable pieces that keep every screen on the same system: SF Symbols, text styles, semantic colors.

/// A token or market logo: remote image with a monogram fallback, always circular, with a faint ring that suits the
/// appearance (`Color.logoRing`), and never colour-inverted by Smart Invert.
struct TokenLogo: View {
    let symbol: String
    let url: URL?
    var size: CGFloat = 36
    /// Whether a logo shipped for `symbol` may stand for this token: false for a token that merely carries a curated
    /// symbol (a "USDC" sent to the wallet), which must never wear the real one's logo.
    var bundled = true

    var body: some View {
        Group {
            // Curated tokens ship a rasterized logo (the token list only publishes SVGs, which the app cannot
            // draw): a transparent disc that fills the square (TokenLogoAssetTests). Anything else tries the remote
            // image (capped and downsampled, RemoteImage): a neutral disc for a moment while it loads, then the
            // monogram until it comes; the monogram at once when there is no image or it failed lately
            // (RemoteImageWait).
            if bundled, let shipped = UIImage(named: "logo-\(symbol)") {
                Image(uiImage: shipped).resizable().scaledToFit()
            } else {
                RemoteImage(url: url, pointSize: size, contentMode: .fit, grace: RemoteImageWait.grace) { loading in
                    if loading { Color.clear } else { monogram }
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.logoRing, lineWidth: 0.5))
        .accessibilityIgnoresInvertColors()
        .accessibilityHidden(true)
    }

    // A token with no image gets a filled monogram in a colour derived from its symbol, so it reads as a real
    // avatar (and each token keeps a consistent, distinct colour across launches) rather than a grey placeholder.
    private var monogram: some View {
        let seed = symbol.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(seed % 360) / 360
        let tint = Color(hue: hue, saturation: 0.5, brightness: 0.62)
        return ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // One line, shrunk rather than wrapped: two emoji at 0.4 of the disc would otherwise break onto two lines.
            Text(symbol.prefix(2).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)
        }
    }
}

/// Marks a token or NFT that reached the wallet without the user choosing it in DyorHQ: anyone can send any token
/// or NFT to any wallet, so its name and symbol prove nothing (security audit 2026-09-26, IOST-12).
struct UnverifiedBadge: View {
    var body: some View {
        Text("Unverified")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.attention)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.attention.opacity(0.14), in: Capsule())
    }
}

/// A circular profile avatar: the uploaded image when there is one, otherwise the wallet's initials on a neutral
/// fill. Used in the Profile header and the DyorHQ Social screens.
struct Avatar: View {
    let url: URL?
    var initials: String = ""
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url {
                RemoteImage(url: url, pointSize: size) { loading in
                    if loading { ZStack { Color(.tertiarySystemFill); ProgressView().controlSize(.small) } } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
        .accessibilityIgnoresInvertColors()
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(.secondary)
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }
}

extension UIImage {
    /// Downscales to fit `maxDimension` and returns JPEG bytes — a small, square-ish avatar rather than a
    /// multi-megabyte camera image.
    func avatarJPEG(maxDimension: CGFloat = 512, quality: CGFloat = 0.85) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

/// Signed percentage in the semantic color, with a text sign so color is never the only cue.
struct ChangeText: View {
    let value: Double?
    var style: Font = .subheadline

    var body: some View {
        if let raw = value {
            let value = abs(raw) < 0.005 ? 0 : raw
            Text(NumberStyle.percent(value))
                .font(style.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(value < 0 ? Color.negative : value > 0 ? Color.positive : Color.secondary)
        } else {
            Text("—").font(style).foregroundStyle(.tertiary)
        }
    }
}

/// A capsule with the change, for rows that show a price and its movement side by side.
struct ChangeBadge: View {
    let value: Double?

    var body: some View {
        if let raw = value {
            let value = abs(raw) < 0.005 ? 0 : raw
            Text(NumberStyle.percent(value))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((value < 0 ? Color.negative : value > 0 ? Color.positive : Color.secondary).opacity(0.14), in: Capsule())
                .foregroundStyle(value < 0 ? Color.negative : value > 0 ? Color.positive : Color.secondary)
        }
    }
}

struct USDText: View {
    let value: Double?
    var font: Font = .body

    var body: some View {
        if let value {
            Text(value, format: .currency(code: "USD").precision(.fractionLength(value.magnitude < 1 && value != 0 ? 4 : 2)))
                .font(font)
                .monospacedDigit()
        } else {
            Text("—").font(font).foregroundStyle(.tertiary)
        }
    }
}

/// Token amount with its symbol, e.g. "12.5 MON".
struct AmountText: View {
    let amount: BigUInt
    let token: Token
    var compact = false
    var font: Font = .body

    var body: some View {
        Text("\(NumberStyle.units(amount, decimals: token.decimals, compact: compact)) \(token.symbol)")
            .font(font)
            .monospacedDigit()
    }
}

/// Decimal entry for token amounts. Keeps the raw string so typing feels native; the parsed value is derived.
struct AmountField: View {
    let title: String
    @Binding var text: String
    let token: Token?
    var onMax: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .font(.title2.weight(.medium))
                .monospacedDigit()
                .textFieldStyle(.plain)
            if let token {
                Text(token.symbol)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let onMax {
                Button("Max", action: onMax)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
    }
}

/// Copyable address row.
struct AddressRow: View {
    let title: String
    let address: Address

    var body: some View {
        LabeledContent(title) {
            Text(address.short)
                .speechSpellsOutCharacters()
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = address.checksummed }
            Link(destination: Monad.explorerAddress(address)) { Label("View on Monadscan", systemImage: "safari") }
        }
    }
}

/// Inline error under a form, in sentence case with a symbol.
struct InlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.attention)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Error: \(message)")
    }
}

/// "Learn more": one page of the DyorHQ docs (`DocsLinks`), opened in Safari like the Terms and Privacy links. It goes
/// only under an explanation the screen already gives (a section footer or a line of help text), once per explanation,
/// in the surrounding text style.
struct LearnMoreLink: View {
    let page: DocsLinks

    init(_ page: DocsLinks) { self.page = page }

    var body: some View {
        Link("Learn more", destination: page.url)
            .foregroundStyle(.tint)
            .accessibilityLabel("Learn more about \(page.topic)")
            .accessibilityHint("Opens the DyorHQ docs in Safari.")
    }
}

/// Full-width primary action at the bottom of a screen.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    /// A custom symbol from the asset catalog, used when no `systemImage` fits (e.g. the balance scale).
    var image: String?
    var isBusy = false
    var isDisabled = false
    /// Label/spinner color on the prominent fill. Defaults to white, which reads on the brand purple in both themes.
    /// When the caller tints the button with a status color (`.positive`/`.negative`), pass `.onStatus` instead — the
    /// dark-mode status hues are light mint/rose where white fails WCAG contrast.
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        let unavailable = isDisabled && !isBusy
        let button = Button {
            Haptics.commit()
            action()
        } label: {
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small).tint(foreground) }
                else if let systemImage { Image(systemName: systemImage) }
                else if let image { Image(image) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(unavailable ? Color(.secondaryLabel) : foreground)
        }
        if unavailable {
            // iOS draws a disabled prominent button as a near-clear fill with faded text, which all but vanishes on a
            // light background. This keeps the button's size and shape with a solid neutral fill and readable text,
            // and it stays disabled for touch and VoiceOver.
            button.buttonStyle(UnavailablePrimaryButtonStyle()).disabled(true)
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)
        }
    }
}

/// `PrimaryButton` while it can't be used: the height and shape of a `.large` `.borderedProminent` button (a capsule
/// from iOS 26, a rounded rectangle before), on a solid gray that reads in light and dark.
private struct UnavailablePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 15) // measured against the enabled button: both 62 pt at the default text size
            .background(Color(.systemGray5), in: shape)
    }

    private var shape: AnyShape {
        if #available(iOS 26, *) { AnyShape(Capsule()) } else { AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
    }
}

/// A block of label/value pairs, like a receipt.
struct DetailRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) { content }
            .font(.subheadline)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var tint: Color = .primary
    /// VoiceOver reads the value character by character: an address, a hash (AI-13).
    var spellsOut = false

    init(_ label: String, _ value: String, tint: Color = .primary, spellsOut: Bool = false) {
        self.label = label
        self.value = value
        self.tint = tint
        self.spellsOut = spellsOut
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).speechSpellsOutCharacters(spellsOut).monospacedDigit().foregroundStyle(tint).multilineTextAlignment(.trailing)
        }
    }
}

/// Progress of a transaction plan, shown in confirmation sheets.
struct TransactionProgress: View {
    let events: [TransactionEvent]
    /// When set, the confirmed row's "View" opens this callback with the tx hash instead of the block explorer.
    var onView: ((Data) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                switch event {
                case .preparing(let label):
                    Label(label, systemImage: "circle.dotted").foregroundStyle(.secondary)
                case .sent(let label, let hash):
                    HStack {
                        Label("\(label) sent", systemImage: "paperplane").foregroundStyle(.secondary)
                        Spacer()
                        // Until it confirms, the explorer is the only way to see whether a sent step landed — which the
                        // user must check before trying again after an error.
                        if !events.contains(.confirmed(label, hash)) {
                            Link("View", destination: Monad.explorerTransaction(hash)).font(.footnote)
                        }
                    }
                case .confirmed(let label, let hash):
                    HStack {
                        Label("\(label) confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive)
                        Spacer()
                        if let onView {
                            Button("View") { onView(hash) }.font(.footnote)
                        } else {
                            Link("View", destination: Monad.explorerTransaction(hash)).font(.footnote)
                        }
                    }
                }
            }
        }
        .font(.subheadline)
        .symbolRenderingMode(.hierarchical)
    }
}

extension View {
    /// Standard treatment for a screen that is still loading its first data.
    @ViewBuilder
    func loadingOverlay(_ isLoading: Bool) -> some View {
        overlay {
            if isLoading {
                ProgressView().controlSize(.large)
            }
        }
    }
}

/// Resigns the first responder, dismissing the keyboard. The decimal pad has no return key, so screens that use it
/// pair this with a "Done" key-accessory button and interactive scroll-to-dismiss — otherwise the keyboard hides
/// the tab bar with no way back.
@MainActor func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// A "Done" button above the keyboard that dismisses it — the standard escape hatch for decimal-pad fields.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Haptics.selection(); dismissKeyboard() }.fontWeight(.semibold)
            }
        }
    }
}

/// Text that reads a raw error the way a person would.
func describe(_ error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
    let text = error.localizedDescription
    if text.localizedCaseInsensitiveContains("cancel") { return "Cancelled." }
    if text.localizedCaseInsensitiveContains("network") || text.localizedCaseInsensitiveContains("offline") { return "No connection. Check your network and try again." }
    return text
}
