import BigInt
import DyorKit
import SwiftUI

/// One Moment: its media and provenance, where it is on the way to graduation, the collect ticket, the wallet's
/// own editions / coins / claims, the creator's proceeds and fees, the pool once it exists, and every fixed fact
/// about it. Everything reads straight from the contracts; every write is a confirmation sheet.
struct MomentDetailView: View {
    @State var info: MomentInfo
    var onChanged: () -> Void = {}
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var clock = Clock()
    @State private var detail: MomentDetail?
    @State private var account: MomentAccountView?
    @State private var quote: CollectQuote?
    @State private var quoteReason: String?
    @State private var quantity = 1
    @State private var nftHolders: (holders: Int, topHolder: Address?, topCount: Int)?
    @State private var holderStats: MomentHolderStats?
    @State private var loadError: String?
    @State private var action: MomentAction?
    @Environment(\.openURL) private var openURL

    private enum MomentAction: Identifiable {
        case collect, claim, creatorProceeds, creatorFees, platformProceeds, platformFees, treasuryProceeds, retry, expire, buyback
        var id: Int { hashValue }
    }

    private var m: Moment { info.moment }
    private var now: Int { clock.now }
    private var isCreator: Bool { session.address != nil && session.address == m.creator }
    private var canCollect: Bool { info.isCollecting(at: now) }

    var body: some View {
        List {
            headerSection
            if !info.graduated, info.state != .expired { progressSection }
            statsSection
            if canCollect { collectSection }
            if info.isRetriable { pendingSection }
            if info.state == .expired { expiredSection } else if info.isExpirable(at: now) { expirableSection }
            if let account, account.nftBalance > 0 || account.entitlement > 0 || account.coinBalance > 0 || account.claimable > 0 { positionSection(account) }
            if isCreator { creatorSection }
            if let account, account.platformProceeds > 0 || account.platformFees > 0 || account.treasuryProceeds > 0 { beneficiarySection(account) }
            if info.graduated, let pool = info.pool { poolSection(pool) }
            holdersSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(info.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: OpenSea.collection(contract: m.nft), subject: Text(info.name),
                          message: Text("\(info.name) — a Moment on Monad, kept forever. Collect it on DyorHQ, \(SupportLinks.tagline).")) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .refreshable { await load() }
        .task { await clock.run() }
        .task { await load() }
        .task(id: "\(quantity)-\(info.ledger.reserve)-\(info.state.rawValue)") { await refreshQuote() }
        .sheet(item: $action) { which in sheet(for: which) }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                MomentArtwork(provenance: info.provenance, symbol: info.symbol)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(info.name).font(.title2.weight(.semibold)).lineLimit(2)
                        Text("$\(info.symbol)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    MomentStateBadge(info: info, now: now)
                    HStack(spacing: 6) {
                        if !info.provenance.place.isEmpty { Label(info.provenance.place, systemImage: "mappin.and.ellipse").lineLimit(1) }
                        if info.provenance.date > 0 { Label(MomentsFormat.day(info.provenance.date), systemImage: "calendar") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if let loadError { InlineError(message: loadError) }
            }
            .padding(.vertical, 4)
        }
    }

    private var progressSection: some View {
        Section {
            Gauge(value: min(1, Double(info.progressBps) / 10_000)) {
                Text("Graduation")
            } currentValueLabel: {
                Text("\(info.progressBps / 100)%")
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.brand)
            LabeledContent("Reserve", value: "\(MomentsFormat.usdc(info.ledger.reserve)) of \(MomentsFormat.usdc(m.threshold))")
            if info.state == .collecting, now < m.deadline {
                LabeledContent("Still needed", value: "\(MomentsFormat.usdc(info.reserveRemaining)) · about \(info.collectsToGraduate) \(info.collectsToGraduate == 1 ? "collect" : "collects")")
                LabeledContent("Window closes", value: MomentsFormat.date(m.deadline))
            }
        } footer: {
            Text("\(NumberStyle.basisPoints(m.reserveBps)) of every collect builds the reserve; at the threshold the coin graduates into a locked Uniswap pool.")
        }
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                if info.graduated, let pool = info.pool {
                    stat("Coin price", MomentsFormat.coinPrice(pool.usdcPerCoin))
                    Divider().frame(height: 34)
                    stat("FDV", pool.fdvUSD.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                    Divider().frame(height: 34)
                    stat("Since open", pool.changeSinceOpen.map { NumberStyle.percent($0) } ?? "—")
                } else {
                    stat("Per edition", MomentsFormat.usdc(m.price))
                    Divider().frame(height: 34)
                    stat("Editions", "\(info.editions)")
                    Divider().frame(height: 34)
                    stat("Collects", "\(info.ledger.collects)")
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var collectSection: some View {
        Section {
            Stepper(value: $quantity, in: 1...MomentsConstants.maxBatch) {
                HStack {
                    Text("Editions")
                    Spacer()
                    Text("\(quantity)").monospacedDigit().fontWeight(.semibold)
                }
            }
            if let quote {
                LabeledContent("You pay") { Text(MomentsFormat.usdc(quote.gross)).monospacedDigit().fontWeight(.semibold) }
                LabeledContent("You get") { Text("\(quote.editions) \(quote.editions == 1 ? "edition" : "editions") · \(MomentsFormat.coins(quote.entitlement)) $\(info.symbol)").monospacedDigit().multilineTextAlignment(.trailing) }
                if quote.terminal {
                    Label("This collect completes the Moment: it takes only what the reserve still needs (\(MomentsFormat.usdc(quote.gross)) for \(quote.editions) \(quote.editions == 1 ? "edition" : "editions")) and graduates the coin in the same transaction.", systemImage: "sparkles")
                        .font(.footnote).foregroundStyle(Color.brand)
                }
            } else if let quoteReason {
                Text(quoteReason).font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Quoting…").font(.footnote).foregroundStyle(.secondary) }
            }
            if let account {
                LabeledContent("Your USDC") { Text(MomentsFormat.usdc(account.usdcBalance)).monospacedDigit().foregroundStyle(insufficient ? Color.attention : .secondary) }
            }
            if session.canSign {
                Button {
                    Haptics.tap()
                    action = .collect
                } label: {
                    Label(quote?.terminal == true ? "Collect and Graduate" : "Collect \(quantity) \(quantity == 1 ? "Edition" : "Editions")", systemImage: "camera.aperture")
                        .fontWeight(.semibold)
                }
                .disabled(quote == nil || insufficient)
            } else {
                Text(session.address == nil ? "Sign in to collect." : "You are watching this address. Sign in to collect.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Collect")
        } footer: {
            Text("Paid in USDC: \(NumberStyle.basisPoints(m.reserveBps)) reserve, \(NumberStyle.basisPoints(m.creatorBps)) creator, \(NumberStyle.basisPoints(m.platformBps)) DyorHQ. Your NFT appears on OpenSea as soon as it settles.")
        }
    }

    private var insufficient: Bool {
        guard let quote, let account else { return false }
        return account.usdcBalance < quote.gross
    }

    private var pendingSection: some View {
        Section {
            Text("Graduation has not completed yet; anyone can retry it.")
                .font(.footnote).foregroundStyle(.secondary)
            if info.ledger.stuckSince > 0 { LabeledContent("First failure", value: MomentsFormat.date(info.ledger.stuckSince)) }
            Button("Retry Graduation", systemImage: "arrow.clockwise") { Haptics.tap(); action = .retry }.disabled(!session.canSign)
        } header: {
            Text("Graduation Pending")
        }
    }

    private var expiredSection: some View {
        Section {
            LabeledContent("Ended", value: MomentsFormat.date(info.ledger.endedAt))
            Text("The window closed before the threshold; the reserve was wound down. Editions stay with their collectors.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Expired")
        }
    }

    private var expirableSection: some View {
        Section {
            Text(info.state == .collecting
                 ? "The collect window closed with the reserve short of the threshold. Anyone can wind it down: \(NumberStyle.basisPoints(m.expiryCreatorBps)) of the reserve to the creator, the rest to the treasury."
                 : "Graduation has been failing for more than a week past the deadline. Anyone can wind the Moment down now.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Expire Moment", systemImage: "xmark.circle") { Haptics.tap(); action = .expire }.disabled(!session.canSign)
        } header: {
            Text("Window Closed")
        }
    }

    private func positionSection(_ account: MomentAccountView) -> some View {
        Section {
            if account.nftBalance > 0 {
                LabeledContent("Editions", value: account.nftIds.isEmpty ? "\(account.nftBalance)" : account.nftIds.prefix(6).map { "#\($0)" }.joined(separator: ", ") + (account.nftIds.count > 6 ? " +\(account.nftIds.count - 6)" : ""))
                ForEach(account.nftIds.prefix(3), id: \.self) { id in
                    Link(destination: OpenSea.item(contract: m.nft, tokenId: id)) { Label("View #\(id) on OpenSea", systemImage: "sailboat") }
                }
            }
            if account.entitlement > 0 { LabeledContent("Coins owed", value: "\(MomentsFormat.coins(account.entitlement)) $\(info.symbol)") }
            if info.graduated {
                LabeledContent("Claimable now") { Text("\(MomentsFormat.coins(account.claimable)) $\(info.symbol)").monospacedDigit().fontWeight(account.claimable > 0 ? .semibold : .regular).foregroundStyle(account.claimable > 0 ? Color.brand : .primary) }
                LabeledContent("Claimed", value: "\(MomentsFormat.coins(account.claimed)) $\(info.symbol)")
                LabeledContent("Vested", value: "\(MomentsMath.collectorVestedBps(graduatedAt: info.pool?.graduatedAt ?? 0, now: now) / 100)%")
                if account.claimable > 0 {
                    Button("Claim \(MomentsFormat.coins(account.claimable)) $\(info.symbol)", systemImage: "arrow.down.circle") { Haptics.tap(); action = .claim }.disabled(!session.canSign)
                }
            }
            if account.coinBalance > 0 {
                LabeledContent("In wallet", value: "\(MomentsFormat.coins(account.coinBalance)) $\(info.symbol)")
                if let pool = info.pool { LabeledContent("Value") { USDText(value: MomentsMath.coins(account.coinBalance) * pool.usdcPerCoin) } }
            }
        } header: {
            Text("Your Position")
        } footer: {
            if !info.graduated, info.state != .expired { Text("Coins are minted to you as they vest once the Moment graduates.") }
        }
    }

    private var creatorSection: some View {
        Section {
            LabeledContent("Proceeds to withdraw") { Text(MomentsFormat.usdc(account?.creatorProceeds ?? 0)).monospacedDigit().fontWeight((account?.creatorProceeds ?? 0) > 0 ? .semibold : .regular) }
            if (account?.creatorProceeds ?? 0) > 0 {
                Button("Withdraw Proceeds", systemImage: "banknote") { Haptics.tap(); action = .creatorProceeds }.disabled(!session.canSign)
            }
            if info.graduated {
                LabeledContent("Pool fees to withdraw") { Text(MomentsFormat.usdc(account?.creatorFees ?? 0)).monospacedDigit().fontWeight((account?.creatorFees ?? 0) > 0 ? .semibold : .regular) }
                if (account?.creatorFees ?? 0) > 0 {
                    Button("Withdraw Pool Fees", systemImage: "banknote") { Haptics.tap(); action = .creatorFees }.disabled(!session.canSign)
                }
                if let account {
                    LabeledContent("Allocation claimable") { Text("\(MomentsFormat.coins(account.claimableCreator)) $\(info.symbol)").monospacedDigit() }
                    LabeledContent("Allocation vested", value: "\(MomentsMath.creatorVestedBps(graduatedAt: info.pool?.graduatedAt ?? 0, now: now) / 100)%")
                }
            }
        } header: {
            Text("You Created This")
        } footer: {
            Text("\(NumberStyle.basisPoints(m.creatorBps)) of every collect, plus \(NumberStyle.basisPoints(MomentsConstants.hookCreatorShareBps)) of the pool's 1% fee after graduation, accrue here for you.")
        }
    }

    private func beneficiarySection(_ account: MomentAccountView) -> some View {
        Section("Protocol Beneficiary") {
            if account.platformProceeds > 0 {
                LabeledContent("Platform proceeds", value: MomentsFormat.usdc(account.platformProceeds))
                Button("Withdraw Platform Proceeds") { Haptics.tap(); action = .platformProceeds }.disabled(!session.canSign)
            }
            if account.platformFees > 0 {
                LabeledContent("Platform pool fees", value: MomentsFormat.usdc(account.platformFees))
                Button("Withdraw Platform Fees") { Haptics.tap(); action = .platformFees }.disabled(!session.canSign)
            }
            if account.treasuryProceeds > 0 {
                LabeledContent("Treasury share", value: MomentsFormat.usdc(account.treasuryProceeds))
                Button("Withdraw Treasury Share") { Haptics.tap(); action = .treasuryProceeds }.disabled(!session.canSign)
            }
        }
    }

    private func poolSection(_ pool: MomentPool) -> some View {
        Section {
            LabeledContent("Coin price", value: MomentsFormat.coinPrice(pool.usdcPerCoin))
            LabeledContent("Opened at", value: MomentsFormat.coinPrice(MomentsMath.usdcPerCoin(sqrtPriceX96: pool.openingSqrtPriceX96, usdcIs0: pool.usdcIs0)))
            LabeledContent("Graduated", value: MomentsFormat.date(pool.graduatedAt))
            LabeledContent("Seeded with", value: "\(MomentsFormat.usdc(pool.reserveSeed)) + \(MomentsFormat.coins(pool.poolCoins)) $\(info.symbol)")
            LabeledContent("Position", value: "Full range · locked forever")
            LabeledContent("Fees accrued", value: "creator \(MomentsFormat.usdc(pool.creatorFees)) · DyorHQ \(MomentsFormat.usdc(pool.platformFees)) · buyback \(MomentsFormat.usdc(pool.buybackFees))")
            LabeledContent("Buyback budget", value: MomentsFormat.usdc(pool.buybackBudget))
            if pool.buybackReady(at: now) {
                Button("Run Buyback", systemImage: "arrow.triangle.2.circlepath") { Haptics.tap(); action = .buyback }.disabled(!session.canSign)
            } else if pool.lastBuyback > 0 {
                LabeledContent("Last buyback", value: MomentsFormat.date(pool.lastBuyback))
            }
            Button {
                Haptics.tap()
                router.openSwap(tokenIn: .usdc, tokenOut: info.coinToken)
            } label: {
                Label("Trade $\(info.symbol)", systemImage: "arrow.left.arrow.right").fontWeight(.semibold)
            }
        } header: {
            Text("Pool")
        } footer: {
            Text("Liquidity locked forever in Uniswap v4. Every trade pays 1.5%: pool, creator, DyorHQ and buybacks.")
        }
    }

    private var holdersSection: some View {
        Section("Holders") {
            LabeledContent("Edition holders", value: nftHolders.map { "\($0.holders)" } ?? "—")
            if let top = nftHolders?.topHolder, let count = nftHolders?.topCount, count > 0 {
                LabeledContent("Largest", value: "\(top.short) · \(count) \(count == 1 ? "edition" : "editions")")
            }
            if info.graduated {
                LabeledContent("Coin holders", value: holderStats.map { "\($0.holders)" } ?? "—")
                if let stats = holderStats, stats.holders > 0 {
                    LabeledContent("Top wallet", value: "\(stats.topHolder?.short ?? "—") · \(NumberStyle.basisPoints(stats.topHolderBps)) of circulating")
                    LabeledContent("In the pool", value: NumberStyle.basisPoints(stats.poolBps))
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            AddressRow(title: "Creator", address: m.creator)
            LabeledContent("Published", value: MomentsFormat.date(m.publishedAt))
            LabeledContent("Collect window", value: "until \(MomentsFormat.date(m.deadline))")
            LabeledContent("Split", value: "\(NumberStyle.basisPoints(m.reserveBps)) reserve · \(NumberStyle.basisPoints(m.creatorBps)) creator · \(NumberStyle.basisPoints(m.platformBps)) DyorHQ")
            LabeledContent("Creator allocation", value: NumberStyle.basisPoints(m.creatorAllocBps))
            LabeledContent("NFT royalty", value: NumberStyle.basisPoints(m.royaltyBps))
            LabeledContent("Supply", value: "\(MomentsFormat.coins(MomentsConstants.supply)) $\(info.symbol)")
            if let detail {
                LabeledContent("Owed to collectors", value: "\(MomentsFormat.coins(detail.supply.entitlements)) · \(detail.supply.collects) collects")
                LabeledContent("Minted so far", value: MomentsFormat.coins(detail.coinTotalSupply))
            }
            if !info.provenance.mediaHash.isEmpty, info.provenance.mediaHash.contains(where: { $0 != 0 }) {
                LabeledContent("Media hash") { Text(info.provenance.mediaHash.hexString.prefix(18) + "…").font(.footnote.monospaced()).foregroundStyle(.secondary) }
            }
            Link(destination: OpenSea.collection(contract: m.nft)) { Label("View on OpenSea", systemImage: "sailboat") }
            if let url = info.provenance.animationURL { Link(destination: url) { Label("Open video", systemImage: "play.rectangle") } }
            else if let url = info.provenance.mediaURL { Link(destination: url) { Label("Open media", systemImage: "photo") } }
            AddressRow(title: "Coin", address: m.coin)
            AddressRow(title: "NFT", address: m.nft)
        } header: {
            Text("About this Moment")
        } footer: {
            Text("Fixed at publish; nothing about a live Moment can be changed.")
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheet(for which: MomentAction) -> some View {
        switch which {
        case .collect:
            ConfirmationSheet(
                title: "Collect \(info.symbol)", confirmTitle: quote?.terminal == true ? "Collect and Graduate" : "Collect",
                build: {
                    guard let signer = session.wallet as? MomentsPermitSigner else { throw MomentsService.MomentsError.signerRequired }
                    return try await env.moments.collectPlan(momentId: m.id, quantity: quantity, price: m.price, signer: signer, symbol: info.symbol)
                },
                onDone: { finished() },
                onCompleted: { hash in
                    ActivityLog.record(ActivityRecord(kind: .moment, title: "Collected \(info.name)", subtitle: "\(quantity) \(quantity == 1 ? "edition" : "editions") · \(MomentsFormat.usdc(quote?.gross ?? m.price * BigUInt(quantity)))", hash: hash, usd: MomentsMath.usdc(quote?.gross ?? m.price * BigUInt(quantity))), owner: session.address)
                },
                // The settled sheet's View control opens the newest edition on OpenSea, where the NFT now lives.
                onView: { _ in openURL(OpenSea.item(contract: m.nft, tokenId: BigUInt((detail?.supply.collects ?? 0) + quantity))) }
            ) {
                DetailRow("Moment", "\(info.name) ($\(info.symbol))")
                DetailRow("Editions", "\(quantity)")
                DetailRow("You pay", MomentsFormat.usdc(quote?.gross ?? m.price * BigUInt(quantity)))
                DetailRow("Coins owed", "\(MomentsFormat.coins(quote?.entitlement ?? 0)) $\(info.symbol)")
                DetailRow("Your NFT", "On OpenSea once it settles")
                if quote?.terminal == true { DetailRow("Graduates", "Yes, in this transaction", tint: .brand) }
            }
        case .claim:
            ConfirmationSheet(title: "Claim \(info.symbol)", confirmTitle: "Claim", build: { await env.moments.claimPlan(momentId: m.id, symbol: info.symbol) }, onDone: { finished() },
                              onCompleted: { hash in ActivityLog.record(ActivityRecord(kind: .moment, title: "Claimed $\(info.symbol)", subtitle: "\(MomentsFormat.coins(account?.claimable ?? 0)) vested coins", hash: hash), owner: session.address) }) {
                DetailRow("Claimable", "\(MomentsFormat.coins(account?.claimable ?? 0)) $\(info.symbol)")
            }
        case .creatorProceeds:
            ConfirmationSheet(title: "Withdraw Proceeds", confirmTitle: "Withdraw", build: { await env.moments.withdrawCreatorProceedsPlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Proceeds", MomentsFormat.usdc(account?.creatorProceeds ?? 0))
            }
        case .creatorFees:
            ConfirmationSheet(title: "Withdraw Pool Fees", confirmTitle: "Withdraw", build: { await env.moments.withdrawCreatorFeesPlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Pool fees", MomentsFormat.usdc(account?.creatorFees ?? 0))
            }
        case .platformProceeds:
            ConfirmationSheet(title: "Withdraw Platform Proceeds", confirmTitle: "Withdraw", build: { await env.moments.withdrawPlatformProceedsPlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Proceeds", MomentsFormat.usdc(account?.platformProceeds ?? 0))
            }
        case .platformFees:
            ConfirmationSheet(title: "Withdraw Platform Fees", confirmTitle: "Withdraw", build: { await env.moments.withdrawPlatformFeesPlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Pool fees", MomentsFormat.usdc(account?.platformFees ?? 0))
            }
        case .treasuryProceeds:
            ConfirmationSheet(title: "Withdraw Treasury Share", confirmTitle: "Withdraw", build: { await env.moments.withdrawTreasuryProceedsPlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Treasury share", MomentsFormat.usdc(account?.treasuryProceeds ?? 0))
            }
        case .retry:
            ConfirmationSheet(title: "Retry Graduation", confirmTitle: "Retry", build: { await env.moments.retryGraduationPlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Reserve", MomentsFormat.usdc(info.ledger.reserve))
                DetailRow("Pool", "\(MomentsFormat.usdc(info.ledger.reserve)) + coins, locked")
            }
        case .expire:
            ConfirmationSheet(title: "Expire Moment", confirmTitle: "Expire", build: { await env.moments.expirePlan(momentId: m.id) }, onDone: { finished() }) {
                DetailRow("Reserve", MomentsFormat.usdc(info.ledger.reserve))
                DetailRow("To creator", NumberStyle.basisPoints(m.expiryCreatorBps))
                DetailRow("To treasury", NumberStyle.basisPoints(MomentsConstants.bps - m.expiryCreatorBps))
            }
        case .buyback:
            ConfirmationSheet(title: "Run Buyback", confirmTitle: "Run", build: { await env.moments.buybackPlan(momentId: m.id, minCoinOut: 0) }, onDone: { finished() }) {
                DetailRow("Budget", MomentsFormat.usdc(info.pool?.buybackBudget ?? 0))
                DetailRow("Spends", "half on coins, half paired as liquidity")
                DetailRow("Impact cap", "1%")
            }
        }
    }

    private func finished() {
        Task {
            await load()
            onChanged()
        }
    }

    // MARK: Loading

    private func load() async {
        do {
            if let fresh = try await env.moments.info(id: m.id) { info = fresh }
            async let detailTask = env.moments.moment(id: m.id)
            async let holdersTask = env.moments.nftHolders(nft: m.nft, editions: info.editions)
            async let accountTask = loadAccount()
            let (detail, holders, account) = try await (detailTask, holdersTask, accountTask)
            self.detail = detail
            nftHolders = holders
            self.account = account
            loadError = nil
            if info.graduated {
                holderStats = await env.moments.holderStats(coin: m.coin, publishedAt: m.publishedAt)
            }
        } catch {
            loadError = describe(error)
        }
    }

    private func loadAccount() async throws -> MomentAccountView? {
        guard let address = session.address else { return nil }
        return try await env.moments.accountView(info, account: address)
    }

    private func refreshQuote() async {
        guard canCollect else { quote = nil; quoteReason = nil; return }
        do {
            quote = try await env.moments.quote(id: m.id, quantity: quantity)
            quoteReason = nil
        } catch {
            quote = nil
            quoteReason = describe(error)
        }
    }
}
