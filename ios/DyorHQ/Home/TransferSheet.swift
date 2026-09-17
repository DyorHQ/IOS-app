import BigInt
import DyorKit
import SwiftUI

/// Moves collateral between Spot (the wallet) and Perps (the Perpl account). Spot → Perps takes AUSD from the
/// wallet; when the wallet is short of AUSD but holds MON, the missing amount is bought with MON at the best venue
/// in the same run, then deposited. Perps → Spot withdraws AUSD from Perpl back into the wallet.
struct TransferSheet: View {
    enum Direction: String, CaseIterable, Identifiable {
        case toPerps, toSpot
        var id: String { rawValue }
        var label: String { self == .toPerps ? "Spot → Perps" : "Perps → Spot" }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var direction: Direction = .toPerps
    @State private var amountText = ""
    @State private var walletAUSD: BigUInt = 0
    @State private var walletMON: BigUInt = 0
    @State private var monUSD: Double?
    @State private var account: PerpAccount?
    @State private var loaded = false
    @State private var quote: VenueQuote?
    @State private var quoteMON: BigUInt = 0
    @State private var quoting = false
    @State private var quoteError: String?
    @State private var showConfirm = false

    private var raw: BigUInt { Amount.parse(amountText, decimals: 6) ?? 0 }
    private var perpsAvailable: BigUInt { account.map { $0.balance - min($0.balance, $0.locked) } ?? 0 }
    /// AUSD the wallet lacks for a Spot → Perps transfer, to be bought with MON.
    private var shortfall: BigUInt { direction == .toPerps && raw > walletAUSD ? raw - walletAUSD : 0 }
    private var needsSwap: Bool { shortfall > 0 }
    private var isCreating: Bool { direction == .toPerps && account == nil }

    private var problem: String? {
        guard raw > 0, loaded else { return nil }
        switch direction {
        case .toPerps:
            if isCreating, raw < Perpl.minimumDeposit { return "The first deposit opens your Perpl account and must be at least 10 AUSD." }
            if needsSwap {
                guard let monUSD, monUSD > 0 else { return "MON has no price right now; deposit AUSD you already hold." }
                if walletMON == 0 { return "Not enough AUSD, and no MON to convert." }
                if let quoteError { return quoteError }
                if let quote, quote.minOut < shortfall { return "MON on hand does not cover the difference at today's price." }
            }
            return nil
        case .toSpot:
            if raw > perpsAvailable { return "More than the balance free on Perpl." }
            return nil
        }
    }

    private var ready: Bool { raw > 0 && loaded && problem == nil && (!needsSwap || quote != nil) && !quoting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $direction) { ForEach(Direction.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    AmountField(title: "0", text: $amountText, token: .ausd) {
                        Haptics.selection()
                        amountText = Amount.exact(direction == .toPerps ? walletAUSD : perpsAvailable, decimals: 6)
                    }
                } header: {
                    Text(direction == .toPerps ? (isCreating ? "Open your Perpl account" : "Deposit to Perps") : "Withdraw to Spot")
                } footer: {
                    if let problem { Text(problem) }
                    else if direction == .toPerps, needsSwap, let quote {
                        Text("Uses \(NumberStyle.units(walletAUSD, decimals: 6)) AUSD from your wallet and swaps ≈ \(NumberStyle.units(quoteMON, decimals: 18, compact: true)) MON → AUSD on \(quote.venue.displayName) for the rest.")
                    } else if direction == .toPerps, needsSwap, quoting { Text("Pricing the MON → AUSD swap…") }
                    else if direction == .toPerps { Text("In wallet: \(NumberStyle.units(walletAUSD, decimals: 6)) AUSD · \(NumberStyle.units(walletMON, decimals: 18, compact: true)) MON") }
                    else { Text("Free on Perpl: \(NumberStyle.units(perpsAvailable, decimals: 6)) AUSD") }
                }
            }
            .navigationTitle("Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { showConfirm = true }.disabled(!ready) }
            }
            .task { await load() }
            .task(id: "\(direction.rawValue)-\(amountText)") { await requote() }
            .sheet(isPresented: $showConfirm) {
                ConfirmationSheet(title: direction == .toPerps ? (isCreating ? "Create Trading Account" : "Deposit to Perps") : "Withdraw to Spot",
                                  confirmTitle: direction == .toPerps ? "Transfer" : "Withdraw",
                                  build: { try await plan() },
                                  onDone: { dismiss() },
                                  onCompleted: { hash in
                                      ActivityLog.record(ActivityRecord(kind: .send, title: direction == .toPerps ? "Transferred to Perps" : "Withdrawn to Spot", subtitle: "\(NumberStyle.units(raw, decimals: 6)) AUSD", hash: hash, section: "perps", usd: Amount.units(raw, decimals: 6)), owner: session.address)
                                  }) {
                    DetailRow("Amount", "\(NumberStyle.units(raw, decimals: 6)) AUSD")
                    if direction == .toPerps, needsSwap, let quote {
                        DetailRow("Swap first", "≈ \(NumberStyle.units(quoteMON, decimals: 18, compact: true)) MON → \(NumberStyle.units(quote.amountOut, decimals: 6)) AUSD on \(quote.venue.displayName)")
                    }
                    DetailRow(direction == .toPerps ? "To" : "From", "Perpl Exchange")
                    if isCreating { DetailRow("Account", "Opens a new trading account") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        guard let address = session.address else { return }
        async let collateral = env.perpl.collateral(of: address)
        async let perpAccount = env.perpl.account(address)
        async let balances = ERC20.balances(of: [.mon], owner: address, rpc: env.rpc, multicall: env.multicall)
        async let price = env.prices.prices(for: [.mon])
        walletAUSD = (try? await collateral.wallet) ?? 0
        account = try? await perpAccount
        walletMON = (try? await balances)?[Monad.native] ?? 0
        monUSD = (try? await price)?[Monad.native]?.usd
        loaded = true
    }

    /// Prices the MON needed for the shortfall (plus 1% headroom) at the best venue, so the deposit is covered by
    /// the quote's guaranteed minimum.
    private func requote() async {
        quote = nil; quoteError = nil; quoteMON = 0
        guard direction == .toPerps, needsSwap, let address = session.address, let monUSD, monUSD > 0 else { return }
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        quoting = true
        defer { quoting = false }
        let shortfallUSD = Amount.units(shortfall, decimals: 6)
        var monNeeded = Amount.raw(shortfallUSD / monUSD * 1.01, decimals: 18)
        for _ in 0..<2 {
            guard monNeeded <= walletMON else { quoteError = "Not enough MON to cover the difference."; return }
            let request = SwapRequest(tokenIn: .mon, tokenOut: .ausd, amountIn: monNeeded, slippageBps: settings.slippageBps, account: address)
            let outcome = await env.swap.quotes(for: request)
            if Task.isCancelled { return }
            guard let best = outcome.best else { quoteError = outcome.errors.values.first ?? "No venue can price MON → AUSD right now."; return }
            if best.minOut >= shortfall { quote = best; quoteMON = monNeeded; return }
            // Undershot (price moved or impact): scale the MON up by the ratio and try once more.
            monNeeded = monNeeded * shortfall / max(best.minOut, 1) * 102 / 100
        }
        quoteError = "The MON → AUSD price moved; try again."
    }

    private func plan() async throws -> [TransactionStep] {
        guard let address = session.address else { return [] }
        switch direction {
        case .toSpot:
            return env.perpl.withdrawPlan(amountCNS: raw)
        case .toPerps:
            var steps: [TransactionStep] = []
            if needsSwap, let quote { steps += try await quote.build(address) }
            steps += env.perpl.depositPlan(amountCNS: raw, hasAccount: account != nil)
            return steps
        }
    }
}
