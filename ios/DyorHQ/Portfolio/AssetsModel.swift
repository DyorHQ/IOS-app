import BigInt
import DyorKit
import SwiftUI

/// Everything the wallet holds on Monad — every ERC-20 with a balance and every NFT — discovered from the wallet's
/// own transfer history rather than a curated list, so assets received anywhere on the chain show up here.
@Observable
@MainActor
final class AssetsModel {
    /// A held token, valued (`HeldToken`): the Send sheet lists the same ones (`WalletTokens`), in its own order.
    typealias TokenAsset = HeldToken

    private(set) var tokens: [TokenAsset] = []
    /// Tokens the wallet was sent rather than chose in the app — found in its history — shown as Unverified (IOST-12).
    private(set) var unverified: Set<Address> = []
    private(set) var nfts: [NFTAsset] = []
    /// Moments by their NFT contract, so a Moment edition opens its own page instead of a generic link.
    private(set) var momentsByNFT: [Address: MomentInfo] = [:]
    /// Retired-cohort Moments by their coin: such a coin opens its claim-only page, never a swap (a trade on a retired
    /// pool pays the retired fee wallet). Entries are only ever added — a failed read keeps the ones already known —
    /// and a coin in `MomentsAddresses.retiredMainnetCoins` gets no swap even before its Moment has been read.
    private(set) var retiredByCoin: [Address: MomentInfo] = [:]
    /// Retired-cohort Moments by their NFT contract, so a past-cohort edition opens its claim-only page.
    private(set) var retiredByNFT: [Address: MomentInfo] = [:]
    /// Held coins still on a launchpad's bonding curve, the live launchpad's or a retired one's, with their launches
    /// (`LaunchpadService.curveHoldings`): no Swap venue routes a curve, so such a coin's row opens its Launch page, where
    /// its curve trades (Buy and Sell on the live launchpad, Sell only on a retired one), as Home's token page does. A
    /// coin whose launch couldn't be read opens its page by reference, which reads it. Known before the token list
    /// shows, so such a coin never gets a Swap row; a failed check keeps the coins already known, and the rest open Swap,
    /// whose "no venue" state checks again and points to the Launch page.
    private(set) var curve: CurveHoldings = .none
    /// Prices couldn't all be read (`WalletTokens.Ranked.pricesFailed`): some tokens are unpriced, so the holdings total
    /// would be a part passed off as the whole. It isn't shown, and the card says why.
    private(set) var pricesFailed = false
    /// The curated tokens held that no pool prices (`WalletTokens.Ranked.unpriced`): they simply have no price, so the
    /// total is of the priced assets, and the card names what it leaves out.
    private(set) var unpriced: [Token] = []
    /// False when part of the wallet couldn't be read (`WalletTokens.Read.complete`: its history, read fail-fast, or a
    /// balance): a token it holds may be missing, which the card says, with Retry, rather than pass the list off as
    /// everything the wallet holds.
    private(set) var complete = true
    /// No balance could be read at all (`WalletTokens.read` threw): the list is empty for that, not because the wallet
    /// holds nothing.
    private(set) var balancesUnread = false
    private(set) var loading = false
    private(set) var loadedFor: Address?

    /// The priced assets' dollar value: a token with no price adds nothing.
    var totalValue: Double { tokens.compactMap(\.value).reduce(0, +) }
    /// The holdings total is shown: every price that exists was read, and something is priced.
    var showsTotal: Bool { !pricesFailed && totalValue > 0 }

    /// What part of the read failed, in words, as the Send sheet says it: nil when all of it was read. Nothing about
    /// prices when there is nothing to value.
    var readGap: String? {
        if balancesUnread { return tr("Your balances couldn't be read. Check your connection and try again.") }
        switch (complete, pricesFailed) {
        case (true, false): return nil
        case (true, true): return tokens.isEmpty ? nil : tr("Some prices couldn't be read, so values are missing and no total is shown.")
        case (false, _) where tokens.isEmpty: return tr("No tokens found, but part of your wallet couldn't be read, so some may be missing.")
        case (false, false): return tr("Part of your wallet couldn't be read, so a token may be missing from the list and the total.")
        case (false, true): return tr("Some prices and part of your wallet couldn't be read, so values and tokens may be missing, and no total is shown.")
        }
    }

    func load(env: AppEnvironment, address: Address?, force: Bool) async {
        guard let address else { tokens = []; nfts = []; complete = true; balancesUnread = false; loadedFor = nil; return }
        if !force, loadedFor == address { return }
        loading = true
        defer { loading = false }

        async let nftTask = env.nftDiscovery.heldNFTs(wallet: address)
        async let momentsTask = env.moments.moments(limit: 200)
        async let retiredTask = PastMomentsModel.allMoments(env: env)

        // The token part is the Send sheet's too (`WalletTokens`). Balances that couldn't be read list nothing, as before,
        // and the card says so, as it says when only part of the wallet couldn't be read.
        let read = try? await WalletTokens.read(env: env, address: address)
        var ranked: [TokenAsset] = []
        var found: CurveHoldings?
        var failed = false
        var unpricedHeld: [Token] = []
        // The Portfolio keeps the order it has always had; the Send sheet ranks the same tokens its own way. The coins on a
        // curve come from the same read that valued them: the launchpads are asked once.
        if let read {
            let result = await WalletTokens.ranked(read, env: env, by: WalletHoldings.portfolioPrecedes)
            ranked = result.tokens
            found = result.curve
            failed = result.pricesFailed
            unpricedHeld = result.unpriced
        }
        // As the list marks them: the DyorHQ coins the wallet launched or collected are its own, not Unverified.
        unverified = read == nil ? KnownTokenStore.unverified(owner: address) : Set(ranked.filter(\.unverified).map(\.id))
        // Known before the token list shows, so a retired Moment coin or a coin on a curve is never offered a swap in between.
        // A retired cohort that couldn't be read keeps the Moments already known, and the card says part of the wallet
        // couldn't be read.
        let retired = await retiredTask
        for info in retired.moments {
            retiredByCoin[info.moment.coin] = info
            retiredByNFT[info.moment.nft] = info
        }
        if let found { curve = found }
        pricesFailed = failed
        unpriced = unpricedHeld
        complete = (read?.complete ?? false) && retired.complete
        balancesUnread = read == nil
        tokens = ranked

        let moments = (try? await momentsTask) ?? []
        // Their coins, proven by their cohorts, for the coins' pictures and labels.
        await env.dyorCoins.ingest(moments + retired.moments)
        momentsByNFT = Dictionary(moments.map { ($0.moment.nft, $0) }, uniquingKeysWith: { first, _ in first })
        nfts = await nftTask
        loadedFor = address
    }
}

/// My Holdings on the Portfolio: everything the wallet owns on Monad, as one toggle — Assets (every ERC-20 with a
/// balance, valued) or NFTs (every ERC-721, from its metadata). A Moment edition opens its Moment; any other NFT
/// opens on OpenSea.
struct AssetsCard: View {
    let model: AssetsModel
    /// Reads the holdings again, after a read that failed in part.
    let retry: () -> Void
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showAllTokens = false
    @State private var kind: Kind = .assets

    private enum Kind: String, CaseIterable, Identifiable {
        case assets, nfts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .assets: return tr(LocalizedStringResource("Assets", comment: "A tab: in My Holdings the tokens held, on Perps the trading account's balance [tight]"))
            case .nfts: return tr(LocalizedStringResource("NFTs", comment: "My Holdings tab: the NFTs held [tight]"))
            }
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("My Holdings").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                else if kind == .assets, model.showsTotal { Text(PriceFormat.usdValue(model.totalValue)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                else if kind == .nfts, !model.nfts.isEmpty { Text(verbatim: "\(model.nfts.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary) }
            }

            Picker("Holdings", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind == .assets, !model.loading, let gap = model.readGap {
                // A read that failed in part is said, with Retry, never passed off as all the wallet holds.
                VStack(alignment: .leading, spacing: 8) {
                    Text(gap).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry", systemImage: "arrow.clockwise", action: retry).font(.footnote.weight(.medium))
                }
            }
            if kind == .assets, model.showsTotal, !model.unpriced.isEmpty, !model.loading {
                // A token no pool prices is no failure: the total is of the rest, and says what it leaves out.
                Paragraph("Doesn't include \(WalletHoldings.symbolList(model.unpriced)): no price found.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if kind == .assets, model.tokens.isEmpty, model.loading || model.readGap == nil {
                Text(model.loading ? "Reading the wallet…" : "No tokens in this wallet yet.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            }
            if kind == .nfts, model.nfts.isEmpty {
                Text(model.loading ? "Reading the wallet…" : "No NFTs in this wallet yet.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            }

            if kind == .assets, !model.tokens.isEmpty {
                let shown = showAllTokens ? model.tokens : Array(model.tokens.prefix(6))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, asset in
                        let route = model.curve.route(asset.token.address)
                        if let retired = model.retiredByCoin[asset.token.address] {
                            // A retired cohort's coin is never offered a swap: it opens its claim-only page.
                            NavigationLink(value: PastMomentRoute(info: retired)) { tokenRow(asset) }
                                .buttonStyle(.plain)
                        } else if MomentsAddresses.isRetiredCoin(asset.token.address) {
                            // Its cohort could not be read yet: still no swap, just the row.
                            tokenRow(asset, note: "Past cohort · trading closed")
                        } else if route.isOnCurve {
                            // Never Swap: no venue routes a coin still on a launchpad's curve, live or retired. It trades
                            // on its curve, from its Launch page, where Home sends it too; by reference when unread.
                            Button {
                                router.openLaunchPage(for: route)
                                dismiss()
                            } label: {
                                tokenRow(asset, note: route.rowNote, unverified: model.unverified.contains(asset.token.address))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { router.openSwap(tokenIn: asset.token, tokenOut: asset.token.symbol == "USDC" ? .mon : .usdc); dismiss() } label: { tokenRow(asset, unverified: model.unverified.contains(asset.token.address)) }
                                .buttonStyle(.plain)
                        }
                        if index < shown.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
                if model.tokens.count > shown.count {
                    Button("Show all \(model.tokens.count)") { showAllTokens = true }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }

            if kind == .nfts, !model.nfts.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.nfts) { nft in
                        if let retired = model.retiredByNFT[nft.contract] {
                            // A past-cohort edition opens its claim-only page, here in the Portfolio.
                            NavigationLink(value: PastMomentRoute(info: retired)) { nftTile(nft, caption: "Past cohort Moment") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: "\(nft.name), \(nft.collection)"))
                        } else if model.momentsByNFT[nft.contract] != nil {
                            Button { open(nft) } label: { nftTile(nft, caption: "Moment · OpenSea") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: "\(nft.name), \(nft.collection)"))
                        } else {
                            // Any other collection was sent to the wallet, not chosen here: its name and art prove nothing.
                            Button { open(nft) } label: { nftTile(nft, caption: "OpenSea", unverified: true) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(nft.name), \(nft.collection), unverified")
                        }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func nftTile(_ nft: NFTAsset, caption: LocalizedStringKey, unverified: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let moment = model.momentsByNFT[nft.contract] ?? model.retiredByNFT[nft.contract] {
                        // A Moment's art comes through the Moment's own checked sources, not the NFT's metadata.
                        MomentArtwork(provenance: moment.provenance, symbol: moment.symbol, creator: moment.moment.creator)
                    } else if let url = nft.imageURL {
                        RemoteImage(url: url, pointSize: 120) { loading in
                            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }
                        .accessibilityIgnoresInvertColors() // art, left as it is under Smart Invert
                    } else {
                        Image(systemName: "seal").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(nft.name).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 4) {
                if unverified { UnverifiedBadge() }
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func tokenRow(_ asset: AssetsModel.TokenAsset, note: LocalizedStringKey, unverified: Bool = false) -> some View {
        tokenRow(asset, note: Text(note), unverified: unverified)
    }

    /// A row whose note is worded at run time (a curve route's `rowNote`), shown as it is: the token's name when there is
    /// none.
    @_disfavoredOverload
    private func tokenRow(_ asset: AssetsModel.TokenAsset, note: String? = nil, unverified: Bool = false) -> some View {
        tokenRow(asset, note: note.map { Text(verbatim: $0) }, unverified: unverified)
    }

    private func tokenRow(_ asset: AssetsModel.TokenAsset, note: Text?, unverified: Bool) -> some View {
        HStack(spacing: 12) {
            TokenLogo(token: asset.token, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(asset.token.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    TokenBadgeView(token: asset.token, receivedUnasked: unverified)
                }
                (note ?? Text(verbatim: asset.token.displayName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(NumberStyle.units(asset.balance, decimals: asset.token.decimals, compact: true)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary)
                if let value = asset.value { Text(PriceFormat.usdValue(value)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func open(_ nft: NFTAsset) {
        Haptics.tap()
        if let moment = model.momentsByNFT[nft.contract] {
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                router.openMoment(moment)
            }
        } else {
            openURL(nft.openSeaURL)
        }
    }
}
