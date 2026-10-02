import BigInt
import DyorKit
import SwiftUI

/// My Moments: every Moment the wallet has a stake in — editions collected, coins promised, claimable now, still
/// vesting, claimed — with one Claim All for everything vested. Moments of the retired cohorts follow as Past Cohorts:
/// outside the totals and Claim All, each opens its own claim-only page.
struct MomentsPortfolioView: View {
    let moments: [MomentInfo]
    let onOpen: (MomentInfo) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var portfolio: MomentPortfolio?
    @State private var error: String?
    @State private var showClaimAll = false
    @State private var past = PastMomentsModel()

    var body: some View {
        NavigationStack {
            List {
                if let portfolio {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            tile(Text("Pending", comment: "[tight] My Moments tile: coins promised, not graduated yet"), portfolio.pending,
                                 Text("promised, not graduated yet", comment: "[tight] My Moments tile, under the amount"))
                            tile(Text("Claimable now", comment: "[tight] My Moments tile: vested coins to claim"), portfolio.claimable,
                                 Text("vested and unclaimed", comment: "[tight] My Moments tile, under the amount"), tint: portfolio.claimable > 0 ? .brand : .primary)
                            tile(Text("Still vesting", comment: "[tight] My Moments tile: coins not vested yet"), portfolio.vesting,
                                 Text("unlocks at the monthly cliffs", comment: "[tight] My Moments tile, under the amount"))
                            tile(Text("Claimed", comment: "[tight] My Moments tile: coins already claimed"), portfolio.claimed,
                                 Text("already in your wallet", comment: "[tight] My Moments tile, under the amount"))
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        if portfolio.claimable > 0 {
                            Button("Claim All", systemImage: "arrow.down.circle.fill") { Haptics.tap(); showClaimAll = true }
                                .fontWeight(.semibold)
                                .disabled(!session.canSign)
                        }
                    } footer: {
                        Text("Coins across every Moment. Vesting unlocks at the monthly cliffs.")
                    }
                    if portfolio.rows.isEmpty {
                        if past.positions.isEmpty {
                            ContentUnavailableView {
                                Label("No Moments Yet", systemImage: "camera.aperture")
                            } description: {
                                Text("Collect a Moment and it shows up here with its editions and coins.")
                            } actions: {
                                Button("Browse Moments") { Haptics.tap(); dismiss() }
                            }
                        }
                    } else {
                        Section("Your Moments") {
                            ForEach(portfolio.rows) { row in
                                Button { Haptics.tap(); onOpen(row.moment) } label: { PortfolioRowView(row: row) }.buttonStyle(.plain)
                            }
                        }
                    }
                } else if let error {
                    InlineError(message: error)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your Moments…").foregroundStyle(.secondary) }
                }
                if !past.positions.isEmpty || past.error != nil || past.incomplete != nil {
                    Section {
                        if let error = past.error { InlineError(message: "Couldn't read every past cohort (pull to refresh): \(error)") }
                        if let incomplete = past.incomplete { InlineError(message: incomplete) }
                        ForEach(past.positions) { position in
                            Button { Haptics.tap(); onOpen(position.info) } label: { PastMomentRow(position: position) }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("Past Cohorts")
                    } footer: {
                        Text("Earlier DyorHQ Moments contracts. Collecting is closed; claim your vested coins and, as a creator, withdraw your own proceeds.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("My Moments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showClaimAll) {
                ConfirmationSheet(title: "Claim All", confirmTitle: "Claim All", build: { await env.moments.claimAllPlan(momentIds: portfolio?.claimableIds ?? []) }, onDone: { Task { await load() } },
                                  // Recorded in the language in use; `section` is an identifier, never translated.
                                  onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed vested coins"), subtitle: tr("across \(portfolio?.claimableIds.count ?? 0) Moments"), hash: hash, section: "moments"), owner: session.address) },
                                  intent: .momentsClaim) {
                    ForEach(portfolio?.rows.filter { $0.moment.graduated && $0.claimable > 0 } ?? []) { row in
                        DetailRow(Text(verbatim: "$\(row.moment.symbol)"), Text(verbatim: MomentsFormat.coins(row.claimable)))
                    }
                }
            }
        }
    }

    /// `title` and `subtitle` are `Text`s so their keys carry a translator's note: both are tight.
    private func tile(_ title: Text, _ coins: BigUInt, _ subtitle: Text, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(MomentsFormat.coins(coins)).font(.headline).monospacedDigit().foregroundStyle(tint)
            subtitle.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() async {
        async let live: () = loadLive()
        async let pastLoad: () = past.load(env: env, address: session.address, force: true)
        _ = await (live, pastLoad)
    }

    private func loadLive() async {
        guard let address = session.address else { portfolio = .empty; return }
        do {
            portfolio = try await env.moments.portfolio(account: address, moments: moments.isEmpty ? (try await env.moments.moments(limit: 200)) : moments)
            error = nil
        } catch {
            self.error = describe(error)
        }
    }
}

private struct PortfolioRowView: View {
    let row: MomentPortfolioRow

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: row.moment.provenance, symbol: row.moment.symbol, creator: row.moment.moment.creator)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.moment.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(row.moment.symbol)").font(.caption).foregroundStyle(.secondary)
                }
                summary.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.moment.graduated ? MomentsFormat.coins(row.claimable) : MomentsFormat.coins(row.entitlement)).font(.subheadline.weight(.semibold)).monospacedDigit()
                status.font(.caption2).foregroundStyle(row.moment.graduated && row.claimable > 0 ? Color.brand : .secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The row's editions and coins, one sentence (with "· creator" for its creator).
    private var summary: Text {
        let promised = MomentsFormat.coins(row.entitlement), claimed = MomentsFormat.coins(row.claimed), held = MomentsFormat.coins(row.coinBalance)
        return row.isCreator
            ? Text("\(row.nftBalance) editions · promised \(promised) · claimed \(claimed) · in wallet \(held) · creator")
            : Text("\(row.nftBalance) editions · promised \(promised) · claimed \(claimed) · in wallet \(held)")
    }

    /// What the amount on the right is.
    private var status: Text {
        if row.moment.graduated { return Text("claimable", comment: "[tight] My Moments row, under an amount of coins: they can be claimed now") }
        if row.moment.state == .expired { return Text("expired", comment: "[tight] My Moments row, under an amount of coins: the Moment expired") }
        return Text("pending", comment: "[tight] My Moments row, under an amount of coins: promised, the Moment has not graduated")
    }
}
