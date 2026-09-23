import BigInt
import DyorKit
import SwiftUI

/// A retired-cohort Moment the Portfolio pushes. Moment ids restart at 1 on every factory, so the navigation identity
/// is the (factory, id) key, never the id — a cohort-1 "#2" can never open cohort 3's #2.
struct PastMomentRoute: Hashable {
    let info: MomentInfo
    var key: MomentKey { info.key }

    static func == (a: PastMomentRoute, b: PastMomentRoute) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// The wallet's Moments on the retired cohorts that still hold something for it (coins to claim or vesting, creator
/// proceeds or pool fees, editions or coins), read from each cohort's own contracts.
@Observable
@MainActor
final class PastMomentsModel {
    private(set) var positions: [RetiredMomentPosition] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedFor: Address?
    /// The wallet the latest load is for: a slower load for a wallet signed out since never lands.
    private var requested: Address?

    func load(env: AppEnvironment, address: Address?, force: Bool) async {
        requested = address
        guard let address else { positions = []; error = nil; loadedFor = nil; loading = false; return }
        if !force, loadedFor == address { return }
        if loadedFor != address { positions = [] }
        loading = true
        defer { if requested == address { loading = false } }
        var found: [RetiredMomentPosition] = []
        var failure: String?
        for cohort in env.retiredMoments {
            do {
                found += try await cohort.positions(account: address)
            } catch {
                // Keep what this cohort showed before rather than dropping a claim on a transient read failure.
                failure = describe(error)
                found += positions.filter { $0.key.factory == cohort.factory }
            }
        }
        guard requested == address else { return }
        positions = found
        error = failure
        loadedFor = address
    }

    /// Every Moment of every retired cohort (a cohort that cannot be read is left out, not fatal).
    static func allMoments(env: AppEnvironment) async -> [MomentInfo] {
        var out: [MomentInfo] = []
        for cohort in env.retiredMoments { out += (try? await cohort.moments()) ?? [] }
        return out
    }
}

/// Past cohorts on the Portfolio: shown when the wallet has something on a retired cohort, or when a cohort could not
/// be read (a claim is never hidden behind a failed read). Each row opens the Moment's claim-only page; collecting and
/// trading are closed there.
struct PastCohortsCard: View {
    let model: PastMomentsModel

    var body: some View {
        if !model.positions.isEmpty || model.error != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Past Cohorts").font(.headline)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.mini) }
                }
                Text("Moments from earlier DyorHQ contracts. Collecting is closed; claim your vested coins and, as a creator, withdraw your own proceeds.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.error { InlineError(message: "Couldn't read every past cohort (pull to refresh): \(error)") }
                VStack(spacing: 0) {
                    ForEach(Array(model.positions.enumerated()), id: \.element.id) { index, position in
                        NavigationLink(value: PastMomentRoute(info: position.info)) { PastMomentRow(position: position) }
                            .buttonStyle(.plain)
                        if index < model.positions.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
            }
            .padding(16)
            .cardBackground()
        }
    }
}

/// One retired-cohort Moment the wallet has something in (the Portfolio's Past Cohorts card and My Moments).
struct PastMomentRow: View {
    let position: RetiredMomentPosition

    private var info: MomentInfo { position.info }

    private var summary: String {
        var parts: [String] = []
        if position.row.nftBalance > 0 { parts.append("\(position.row.nftBalance) \(position.row.nftBalance == 1 ? "edition" : "editions")") }
        if position.row.isCreator { parts.append("creator") }
        if info.graduated, position.row.vesting > 0 { parts.append("\(MomentsFormat.coins(position.row.vesting)) vesting") }
        if position.row.coinBalance > 0 { parts.append("\(MomentsFormat.coins(position.row.coinBalance)) in wallet") }
        return parts.isEmpty ? "Collecting closed" : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: info.moment.creator)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("$\(info.symbol)").font(.caption).foregroundStyle(.secondary)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if position.claimable > 0 {
                    Text(MomentsFormat.coins(position.claimable)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Color.brand)
                    Text("claimable").font(.caption2).foregroundStyle(Color.brand)
                } else if position.creatorWithdrawable > 0 {
                    Text(MomentsFormat.usdc(position.creatorWithdrawable)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("to withdraw").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(info.graduated ? "Graduated" : info.state == .expired ? "Expired" : "Closed").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
