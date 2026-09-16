import BigInt
import DyorKit
import SwiftUI

// Small, reusable pieces that keep every screen on the same system: SF Symbols, text styles, semantic colors.

/// A token or market logo: remote image with a monogram fallback, always circular.
struct TokenLogo: View {
    let symbol: String
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        Group {
            // Curated tokens ship a rasterized logo (the token list only publishes SVGs, which AsyncImage cannot
            // draw); anything else tries the remote image and falls back to a monogram.
            if let bundled = UIImage(named: "logo-\(symbol)") {
                Image(uiImage: bundled).resizable().scaledToFit()
            } else {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        monogram
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(Circle())
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
            Text(symbol.prefix(2).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
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
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if phase.error != nil { placeholder }
                    else { ZStack { Color(.tertiarySystemFill); ProgressView().controlSize(.small) } }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
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
        Button {
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
            .foregroundStyle(foreground)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isDisabled || isBusy)
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

    init(_ label: String, _ value: String, tint: Color = .primary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().foregroundStyle(tint).multilineTextAlignment(.trailing)
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
                case .sent(let label, _):
                    Label("\(label) sent", systemImage: "paperplane").foregroundStyle(.secondary)
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
