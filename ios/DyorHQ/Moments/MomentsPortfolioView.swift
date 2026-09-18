import BigInt
import DyorKit
import SwiftUI

/// My Moments: every Moment the wallet has a stake in — editions collected, coins promised, claimable now, still
/// vesting, claimed — with one Claim All for everything vested.
struct MomentsPortfolioView: View {
    let moments: [MomentInfo]
    let onOpen: (MomentInfo) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var portfolio: MomentPortfolio?
    @State private var error: String?
    @State private var showClaimAll = false

    var body: some View {
        NavigationStack {
            List {
                if let portfolio {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            tile("Pending", portfolio.pending, "promised, not graduated yet")
                            tile("Claimable now", portfolio.claimable, "vested and unclaimed", tint: portfolio.claimable > 0 ? .brand : .primary)
                            tile("Still vesting", portfolio.vesting, "unlocks at the monthly cliffs")
                            tile("Claimed", portfolio.claimed, "already in your wallet")
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
                        ContentUnavailableView("No Moments Yet", systemImage: "camera.aperture", description: Text("Collect a Moment and it shows up here with its editions and coins."))
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
            }
            .listStyle(.insetGrouped)
            .navigationTitle("My Moments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showClaimAll) {
                ConfirmationSheet(title: "Claim All", confirmTitle: "Claim All", build: { await env.moments.claimAllPlan(momentIds: portfolio?.claimableIds ?? []) }, onDone: { Task { await load() } },
                                  onCompleted: { hash in ActivityLog.record(ActivityRecord(kind: .moment, title: "Claimed vested coins", subtitle: "\(portfolio?.claimableIds.count ?? 0) Moments", hash: hash), owner: session.address) }) {
                    ForEach(portfolio?.rows.filter { $0.moment.graduated && $0.claimable > 0 } ?? []) { row in
                        DetailRow("$\(row.moment.symbol)", MomentsFormat.coins(row.claimable))
                    }
                }
            }
        }
    }

    private func tile(_ title: String, _ coins: BigUInt, _ subtitle: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MomentsFormat.coins(coins)).font(.headline).monospacedDigit().foregroundStyle(tint)
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() async {
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
            MomentArtwork(provenance: row.moment.provenance, symbol: row.moment.symbol)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.moment.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("$\(row.moment.symbol)").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(row.nftBalance) \(row.nftBalance == 1 ? "edition" : "editions") · promised \(MomentsFormat.coins(row.entitlement)) · claimed \(MomentsFormat.coins(row.claimed)) · in wallet \(MomentsFormat.coins(row.coinBalance))\(row.isCreator ? " · creator" : "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.moment.graduated ? MomentsFormat.coins(row.claimable) : MomentsFormat.coins(row.entitlement)).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(row.moment.graduated ? "claimable" : row.moment.state == .expired ? "expired" : "pending").font(.caption2).foregroundStyle(row.moment.graduated && row.claimable > 0 ? Color.brand : .secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
