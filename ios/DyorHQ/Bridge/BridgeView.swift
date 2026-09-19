import DyorKit
import SwiftUI

/// Cross-chain Bridge (Home "Bridge"). Moves the user's own funds between their address on any EVM chain and Monad,
/// both directions, via Aurora Intents — the app quotes, signs the source-chain deposit, and tracks settlement. One
/// side is always Monad, so the picker only ever chooses the other chain.
struct BridgeView: View {
    @State private var model: BridgeModel
    @Environment(\.dismiss) private var dismiss
    @State private var showChainPicker = false
    @State private var pickingFromToken = false
    @State private var pickingToToken = false

    init(env: AppEnvironment) { _model = State(initialValue: BridgeModel(env: env)) }

    var body: some View {
        NavigationStack {
            Group {
                if !model.isConfigured {
                    ContentUnavailableView("Bridge unavailable", systemImage: "arrow.left.arrow.right.circle",
                                           description: Text("Cross-chain bridging isn't configured in this build yet."))
                } else {
                    form
                }
            }
            .navigationTitle("Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { await model.load() }
        .sheet(isPresented: $showChainPicker) { chainPicker }
        .sheet(isPresented: $pickingFromToken) { tokenPicker(for: model.fromChain, isFrom: true) }
        .sheet(isPresented: $pickingToToken) { tokenPicker(for: model.toChain, isFrom: false) }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error = model.loadError { InlineError(message: error) }

                ZStack {
                    VStack(spacing: 8) {
                        fromCard
                        toCard
                    }
                    flipButton
                }

                quoteSummary
                statusCard
                Spacer(minLength: 8)
                PrimaryButton(title: primaryTitle, isBusy: model.isBusy, isDisabled: !primaryEnabled) {
                    Task { await runPrimary() }
                }
                .disabled(!primaryEnabled)
                Text("Powered by Aurora Intents · cross-chain settlement handled for you.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: From / To

    private var fromCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("From").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let bal = model.fromBalanceText {
                    Button { model.useMax() } label: { Text("Balance: \(bal)").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else if model.loadingBalances {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(spacing: 8) {
                chainChip(model.fromChain, tappable: !model.fromChain.isMonad)
                tokenChip(model.fromToken) { pickingFromToken = true }
                Spacer()
                TextField("0", text: Binding(get: { model.amountText }, set: { model.amountText = $0; model.amountChanged() }))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.title3.weight(.semibold)).monospacedDigit().frame(minWidth: 80)
            }
            if model.insufficient {
                Text("More than your \(model.fromChain.name) balance.").font(.caption2).foregroundStyle(Color.negative)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var toCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                chainChip(model.toChain, tappable: !model.toChain.isMonad)
                tokenChip(model.toToken) { pickingToToken = true }
                Spacer()
                if model.quoting { ProgressView().controlSize(.small) }
                else if let out = model.quote?.amountOutFormatted {
                    Text("≈ \(out)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var flipButton: some View {
        Button { withAnimation(.snappy) { model.flipDirection() } } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.bold)).foregroundStyle(Color.onStatus)
                .frame(width: 34, height: 34).background(Color.brand, in: Circle())
                .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 3))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }

    private func chainChip(_ chain: EVMChain, tappable: Bool) -> some View {
        Button { if tappable { showChainPicker = true } } label: {
            HStack(spacing: 4) {
                Text(chain.name).font(.subheadline.weight(.medium))
                if tappable { Image(systemName: "chevron.down").font(.caption2) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain).disabled(!tappable || model.isBusy)
    }

    private func tokenChip(_ token: AuroraToken?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(token?.symbol ?? "Token").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain).disabled(model.isBusy)
    }

    // MARK: Quote + status

    @ViewBuilder private var quoteSummary: some View {
        if let error = model.quoteError {
            Text(error).font(.caption).foregroundStyle(Color.attention).frame(maxWidth: .infinity, alignment: .leading)
        } else if let quote = model.quote {
            VStack(spacing: 6) {
                DetailRow("You send", "\(model.amountText) \(model.fromToken?.symbol ?? "")")
                DetailRow("You receive", model.expectedOut ?? "—", tint: .positive)
                if let secs = quote.timeEstimate, secs > 0 { DetailRow("Estimated time", "≈ \(Int(secs))s") }
                DetailRow("Route", "\(model.fromChain.name) → \(model.toChain.name)")
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .signing, .submitting, .bridging:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(statusText).font(.subheadline)
                Spacer()
            }
            .padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .done(let out):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrived on \(model.toChain.name)").font(.subheadline.weight(.semibold))
                    if !out.isEmpty { Text("Received \(out)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(12).background(Color.positive.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .failed(let message):
            InlineError(message: message)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .signing: return "Sending on \(model.fromChain.name)…"
        case .submitting: return "Notifying the bridge…"
        case .bridging(let s): return s.label
        default: return ""
        }
    }

    private var primaryTitle: String {
        switch model.phase {
        case .done: return "Bridge again"
        case .failed: return "Try again"
        case .signing, .submitting, .bridging: return "Bridging…"
        default: return model.intoMonad ? "Bridge to Monad" : "Bridge to \(model.toChain.name)"
        }
    }

    /// The primary button is a "start over" once a deposit has been signed (poll-path `.done`/`.failed`), never a
    /// second `execute()` — so a real deposit can't be double-sent.
    private var primaryEnabled: Bool {
        switch model.phase {
        case .idle: return model.canBridge
        case .done, .failed: return true
        default: return false
        }
    }

    private func runPrimary() async {
        switch model.phase {
        case .done, .failed: model.reset()
        default: await model.execute()
        }
    }

    // MARK: Pickers

    private var chainPicker: some View {
        NavigationStack {
            List(model.selectableChains) { chain in
                Button { model.selectOtherChain(chain); showChainPicker = false } label: {
                    HStack {
                        Text(chain.name)
                        Spacer()
                        if chain == model.otherChain { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(model.intoMonad ? "Bridge from" : "Bridge to")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func tokenPicker(for chain: EVMChain, isFrom: Bool) -> some View {
        NavigationStack {
            List(model.tokens(on: chain)) { token in
                Button {
                    if isFrom { model.setFromToken(token) } else { model.setToToken(token) }
                    pickingFromToken = false; pickingToToken = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(token.symbol).fontWeight(.medium)
                            Text(chain.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let selected = isFrom ? model.fromToken : model.toToken
                        if token == selected { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("\(chain.name) token")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
