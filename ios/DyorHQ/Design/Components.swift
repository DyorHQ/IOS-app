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

    private var monogram: some View {
        Text(symbol.prefix(2).uppercased())
            .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
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
    var isBusy = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small).tint(Color(.systemBackground)) }
                else if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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
                        Link("View", destination: Monad.explorerTransaction(hash)).font(.footnote)
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

/// Text that reads a raw error the way a person would.
func describe(_ error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
    let text = error.localizedDescription
    if text.localizedCaseInsensitiveContains("cancel") { return "Cancelled." }
    if text.localizedCaseInsensitiveContains("network") || text.localizedCaseInsensitiveContains("offline") { return "No connection. Check your network and try again." }
    return text
}
