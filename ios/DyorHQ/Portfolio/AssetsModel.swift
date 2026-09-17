import BigInt
import DyorKit
import SwiftUI

/// Everything the wallet holds on Monad — every ERC-20 with a balance and every NFT — discovered from the wallet's
/// own transfer history rather than a curated list, so assets received anywhere on the chain show up here.
@Observable
@MainActor
final class AssetsModel {
    struct TokenAsset: Identifiable, Hashable {
        let token: Token
        let balance: BigUInt
        let usd: Double?
        var id: Address { token.address }
        var value: Double? { usd.map { Amount.units(balance, decimals: token.decimals) * $0 } }
    }

    private(set) var tokens: [TokenAsset] = []
    private(set) var nfts: [NFTAsset] = []
    /// Moments by their NFT contract, so a Moment edition opens its own page instead of a generic link.
    private(set) var momentsByNFT: [Address: MomentInfo] = [:]
    private(set) var loading = false
    private(set) var loadedFor: Address?

    var totalValue: Double { tokens.compactMap(\.value).reduce(0, +) }

    func load(env: AppEnvironment, address: Address?, force: Bool) async {
        guard let address else { tokens = []; nfts = []; loadedFor = nil; return }
        if !force, loadedFor == address { return }
        loading = true
        defer { loading = false }

        async let nftTask = env.nftDiscovery.heldNFTs(wallet: address)
        async let momentsTask = env.moments.moments(limit: 200)

        var universe = KnownTokenStore.universe(owner: address)
        let known = Set(universe.map(\.address))
        universe += await env.walletDiscovery.heldTokens(wallet: address, known: known, wholeHistory: true)
        let balances = (try? await ERC20.balances(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)) ?? [:]
        let held = universe.filter { (balances[$0.address] ?? 0) > 0 }
        let prices = (try? await env.prices.prices(for: held)) ?? [:]
        tokens = held.map { TokenAsset(token: $0, balance: balances[$0.address] ?? 0, usd: prices[$0.address]?.usd) }
            .sorted { ($0.value ?? 0, Amount.units($0.balance, decimals: $0.token.decimals)) > ($1.value ?? 0, Amount.units($1.balance, decimals: $1.token.decimals)) }

        let moments = (try? await momentsTask) ?? []
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
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showAllTokens = false
    @State private var kind: Kind = .assets

    private enum Kind: String, CaseIterable, Identifiable {
        case assets, nfts
        var id: String { rawValue }
        var label: String { self == .assets ? "Assets" : "NFTs" }
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("My Holdings").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                else if kind == .assets, model.totalValue > 0 { Text(model.totalValue, format: .currency(code: "USD").precision(.fractionLength(0...2))).font(.subheadline.weight(.semibold)).monospacedDigit() }
                else if kind == .nfts, !model.nfts.isEmpty { Text("\(model.nfts.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary) }
            }

            Picker("Holdings", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind == .assets, model.tokens.isEmpty {
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
                        Button { router.openSwap(tokenIn: asset.token, tokenOut: asset.token.symbol == "USDC" ? .mon : .usdc); dismiss() } label: {
                            HStack(spacing: 12) {
                                TokenLogo(symbol: asset.token.symbol, url: asset.token.logoURL, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.token.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text(asset.token.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(NumberStyle.units(asset.balance, decimals: asset.token.decimals, compact: true)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary)
                                    if let value = asset.value { Text(value, format: .currency(code: "USD").precision(.fractionLength(0...2))).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                        Button { open(nft) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    Color(.tertiarySystemFill)
                                    if let url = nft.imageURL {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image { image.resizable().scaledToFill() }
                                            else if phase.error != nil { Image(systemName: "photo").foregroundStyle(.secondary) }
                                            else { ProgressView().controlSize(.small) }
                                        }
                                    } else {
                                        Image(systemName: "seal").foregroundStyle(.secondary)
                                    }
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(nft.name).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Text(model.momentsByNFT[nft.contract] != nil ? "Moment · OpenSea" : "OpenSea").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(nft.name), \(nft.collection)")
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
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
