import DyorKit
import SwiftUI

/// The launchpad: a discovery board of coins — graduated pools, coins still climbing their bonding curve, and coins in
/// refund mode or migrating — as an image-forward two-column grid, plus the flow to launch a new one. Modeled on the
/// Ponsfamily launchpad, rebuilt in DyorHQ's serif / monochrome system with the Monad-purple accent. The board lists the
/// live launchpad's coins and a retired one's only once graduated (`Launch.listsOnBoard`); a retired launchpad's
/// sell-only coins show only to their holders, under "Your Sell-Only Coins".
struct LaunchpadView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = LaunchpadModel()
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var query = ""
    @State private var sort: LaunchSort = .newest
    /// The pages over the board: a launch's, or the loader of one opened by reference.
    @State private var path: [LaunchPage] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            // The retired launchpads' coins list only once graduated (they trade on Swap). One still on its curve is
            // sell-only (owner decision 2026-09-28) and hidden from the board (2026-09-29): its holders reach its page
            // from "Your Sell-Only Coins", Home, the Portfolio and Swap.
            board
            .navigationTitle(tr("Launch"))
            .navigationDestination(for: LaunchPage.self) { page in
                switch page {
                case .launch(let launch): LaunchDetailView(launch: launch)
                case .reference(let reference): LaunchReferenceView(reference: reference)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showProfile = true } label: { Label("My Launchpad", systemImage: "person.crop.circle") }
                        .disabled(session.address == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showCreate = true } label: { Label("New Launch", systemImage: "plus.circle.fill") }
                        .disabled(!env.config.launchpad.isDeployed || !session.canSign)
                }
            }
            .searchable(text: $query, prompt: tr("Search coins"))
            // A pull reads what is on chain now: the list and prices the screens share are read again first.
            .refreshable {
                env.invalidateChainReads()
                await model.load(env: env, account: session.address)
            }
            // Restarts with the wallet: whether it may launch is part of what the create screen is given.
            .task(id: session.address) { await model.poll(env: env, account: session.address) }
            // Another account can take over in place (a Privy session adopted over a watch-only one, say) without the
            // tabs being rebuilt: the pages over the board were the previous account's, so they go.
            .onChange(of: session.address) { _, _ in path = [] }
            .overlay { if firstLoad { ProgressView().controlSize(.large) } }
            .sheet(isPresented: $showCreate) { CreateLaunchView(protocolInfo: model.protocolInfo) { Task { await model.load(env: env, account: session.address) } } }
            .sheet(isPresented: $showProfile) { LaunchpadProfileView() }
            .onChange(of: router.pendingLaunch) { _, launch in
                guard let launch else { return }
                open(.launch(launch))
                router.pendingLaunch = nil
            }
            .onChange(of: router.pendingLaunchReference) { _, reference in
                guard let reference else { return }
                open(.reference(reference))
                router.pendingLaunchReference = nil
            }
            // The tab is built lazily: a page sent before it first appears opens then, over the board.
            .onAppear {
                // The board saved for the wallet is in the first frame the tab draws, never a spinner under what it has
                // (`LaunchpadModel.showSaved`): read here, before that frame, rather than in the poll's task, which starts
                // after it. Never animated: nothing of the board moves as it comes in.
                withTransaction(\.disablesAnimations, true) { model.showSaved(env: env, account: session.address) }
                if let launch = router.pendingLaunch { path = [.launch(launch)]; router.pendingLaunch = nil }
                if let reference = router.pendingLaunchReference { path = [.reference(reference)]; router.pendingLaunchReference = nil }
            }
        }
    }

    /// A card's page: the launch as read, or, while its section shows what was saved when the board was last read
    /// (`saved`: the board's coins while `LaunchpadModel.savedAt` is set, the wallet's sell-only coins while
    /// `heldSellOnlySavedAt` is), the coin's reference, so its page reads it now: a launch page shows the launch it is
    /// given as current — its price, its phase, which trades are open.
    private func page(for launch: Launch, saved: Bool) -> LaunchPage {
        saved ? .reference(LaunchReference(token: launch.token, factory: launch.factory)) : .launch(launch)
    }

    /// The board's coins show what was saved when it was last read (`LaunchpadModel.savedAt`).
    private var boardSaved: Bool { model.savedAt != nil }

    /// The wallet's sell-only coins show what was saved when the board was last read (`LaunchpadModel.heldSellOnlySavedAt`):
    /// the balances behind them may be unread when every launch has been read again.
    private var sellOnlySaved: Bool { model.heldSellOnlySavedAt != nil || model.savedAt != nil }

    /// Pushes `page`, unless its coin's page is already on top: a launch read elsewhere (Home's copy differs in every live
    /// field) or a reference to the same coin is the same page, never a second one over it.
    private func open(_ page: LaunchPage) {
        if path.last?.token != page.token { path.append(page) }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if !env.config.launchpad.isDeployed {
                    Label("New launches open soon.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // A launchpad whose launches couldn't be read says so, with Retry; its last good coins stay listed.
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: error)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await model.load(env: env, account: session.address) } }.font(.footnote.weight(.semibold))
                    }
                }
                // The board saved when it was last read, shown while it is read again: said to be, never taken for this read.
                if let savedAt = model.savedAt { SavedLine(date: savedAt, reading: model.loading) }
                if graduated.isEmpty, climbing.isEmpty, refundAndMigrating.isEmpty, sellOnly.isEmpty, !firstLoad {
                    // A search that found nothing says so: a coin the board doesn't list (a retired launchpad's sell-only
                    // coin) is reached from Home, the Portfolio or Swap, not found here. Only the first load hides this:
                    // a poll leaves it on screen. A board with nothing read shows the error above, never "no coins".
                    if searching { ContentUnavailableView.search(text: query).padding(.top, 40) } else if model.error == nil { emptyState }
                } else {
                    if !graduated.isEmpty { section(title: "Graduated", count: graduated.count, subtitle: "Cleared the graduation threshold", coins: graduated, saved: boardSaved) }
                    exploreSection
                    // Every phase has its section (`LaunchPhase.boardSection`), among the coins the board lists: the live
                    // launchpad's in refund mode or migrating.
                    if !refundAndMigrating.isEmpty {
                        section(title: "Refund & Migrating", count: refundAndMigrating.count,
                                subtitle: "In refund mode, holders sell back into the curve; a migrating coin trades once it graduates", coins: refundAndMigrating, saved: boardSaved)
                    }
                    // Only the signed-in wallet's own: the retired launchpads' coins it still holds, which the board
                    // doesn't list, so the Launch tab is never a dead end for their holders. Saved with the board, and
                    // kept when the balances can't be read again, it says when it was read once the board's line
                    // has gone.
                    if !sellOnly.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.savedAt == nil, let heldAt = model.heldSellOnlySavedAt { SavedLine(date: heldAt, reading: model.loading) }
                            section(title: "Your Sell-Only Coins", count: sellOnly.count,
                                    subtitle: LaunchBoard.sellOnlySubtitle(sellOnly), coins: sellOnly, saved: sellOnlySaved)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Nothing here is animated by a saved line: an animation keyed to one animates whatever changes with it — the
            // launches a read brought, the tab's first layout, a `Paragraph`'s words — and drew the Moments board garbled
            // on its first opening (build 23 speed work). A line comes and goes with the board it labels.
        }
        .background(Color(.systemGroupedBackground))
    }

    /// A section of `coins`, each opening its page (`page(for:saved:)`): `saved`, they show what was saved when the board
    /// was last read.
    private func section(title: LocalizedStringKey, count: Int, subtitle: LocalizedStringKey, coins: [Launch], saved: Bool) -> some View {
        section(title: title, count: count, subtitle: Text(subtitle), coins: coins, saved: saved)
    }

    /// A section whose subtitle is built at run time (`LaunchBoard.sellOnlySubtitle`), shown as it is.
    @_disfavoredOverload
    private func section<S: StringProtocol>(title: LocalizedStringKey, count: Int, subtitle: S, coins: [Launch], saved: Bool) -> some View {
        section(title: title, count: count, subtitle: Text(verbatim: String(subtitle)), coins: coins, saved: saved)
    }

    private func section(title: LocalizedStringKey, count: Int, subtitle: Text, coins: [Launch], saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, count: count, subtitle: subtitle)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(coins) { launch in
                    NavigationLink(value: page(for: launch, saved: saved)) { LaunchCard(launch: launch) }
                        .buttonStyle(.plain)
                        .onAppear { prefetch(after: launch, in: coins) }
                }
            }
        }
    }

    @ViewBuilder private var exploreSection: some View {
        if climbing.isEmpty {
            // Nothing on the live curve yet: an invitation, not a gap (only while the launchpad is live, and not for a
            // search that found nothing, or for a first load).
            if env.config.launchpad.isDeployed, !searching, !firstLoad {
                exploreEmptyCard
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Explore", count: climbing.count, subtitle: "Coins still climbing toward graduation")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LaunchSort.allCases) { option in
                            let selected = sort == option
                            Button { if sort != option { Haptics.selection(); sort = option } } label: {
                                Text(option.title)
                                    .font(.footnote.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? Color.brand : Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    let coins = climbing
                    ForEach(coins) { launch in
                        NavigationLink(value: page(for: launch, saved: boardSaved)) { LaunchCard(launch: launch) }
                            .buttonStyle(.plain)
                            .onAppear { prefetch(after: launch, in: coins) }
                    }
                }
            }
        }
    }

    private var exploreEmptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Explore", count: nil, subtitle: "Coins still climbing toward graduation")
            VStack(spacing: 12) {
                Image(systemName: "flame").font(.title2).foregroundStyle(Color.brand)
                Paragraph("No coins on the curve yet: launch the first one.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).disabled(!session.canSign)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20).padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        }
    }

    /// Warms the artwork of the cards after `launch` in its section, as sorted and searched (`BoardPrefetch`).
    private func prefetch(after launch: Launch, in coins: [Launch]) {
        for next in BoardPrefetch.following(launch.id, in: coins) { LaunchArtwork.prefetch(logo: next.logo) }
    }

    /// A section's title with its count (none for an empty section), and what it lists.
    private func sectionHeader(_ title: LocalizedStringKey, count: Int?, subtitle: LocalizedStringKey) -> some View {
        sectionHeader(title, count: count, subtitle: Text(subtitle))
    }

    private func sectionHeader(_ title: LocalizedStringKey, count: Int?, subtitle: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                if let count {
                    Text(verbatim: "\(count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.brand.opacity(0.14), in: Capsule()).foregroundStyle(Color.brand)
                }
            }
            subtitle.font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "flame").font(.largeTitle).foregroundStyle(Color.brand)
            Text(env.config.launchpad.isDeployed ? "No Launches Yet" : "New Launches Open Soon").font(.headline)
            Text(env.config.launchpad.isDeployed ? "Be the first to launch a coin on DyorHQ." : "Launches appear here once the new DyorHQ launchpad contracts are live on Monad.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if env.config.launchpad.isDeployed {
                Button { Haptics.tap(); showCreate = true } label: { Text("Launch a Coin").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!session.canSign)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    /// The coins the board lists (`Launch.listsOnBoard`), searched: every public section is taken from these, so a
    /// hidden coin is never listed, counted or found by search.
    private var matching: [Launch] { searched(model.launches.filter(\.listsOnBoard)) }

    /// The wallet's own sell-only coins (`LaunchpadModel.heldSellOnly`), searched too.
    private var sellOnly: [Launch] { searched(model.heldSellOnly) }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The board has no coin to show and no read has answered yet (nor a save been shown), or one is under way: the
    /// spinner shows over the board, and nothing says "empty" or "not found" (`BoardFirstRead`) — in the frames before the
    /// first read's task starts too. Every later poll keeps what is on screen.
    private var firstLoad: Bool { BoardFirstRead.isLoading(empty: model.launches.isEmpty, answered: model.listed, reading: model.loading) }

    private func searched(_ launches: [Launch]) -> [Launch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return launches }
        return launches.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.symbol.localizedCaseInsensitiveContains(q) }
    }

    private var graduated: [Launch] {
        matching.filter { $0.phase.boardSection == .graduated }.sorted { $0.launchedAt > $1.launchedAt }
    }

    private var climbing: [Launch] {
        let live = matching.filter { $0.phase.boardSection == .climbing }
        switch sort {
        case .newest: return live.sorted { $0.launchedAt > $1.launchedAt }
        case .marketCap: return LaunchpadMath.byMarketCap(live, pairUSD: model.pairUSD)
        case .progress: return live.sorted { $0.progressBps > $1.progressBps }
        }
    }

    /// Coins in refund mode (holders sell back into the curve) or migrating (nothing trades until they graduate), newest
    /// first. The board lists none of a retired launchpad's: those are sell-only.
    private var refundAndMigrating: [Launch] {
        matching.filter { $0.phase.boardSection == .refundAndMigrating }.sorted { $0.launchedAt > $1.launchedAt }
    }
}

/// A page over the Launch tab's board: a launch's own, or that of a launch opened by reference
/// (`Router.openLaunch(_: LaunchReference)`), which reads it first. One typed path holds both, pushed by value: a stack
/// bound to a typed path pushes its own element type and nothing else.
enum LaunchPage: Hashable {
    case launch(Launch)
    case reference(LaunchReference)

    /// The coin whose page it is, however it was opened: one page per coin on the stack.
    var token: Address {
        switch self {
        case .launch(let launch): return launch.token
        case .reference(let reference): return reference.token
        }
    }
}

enum LaunchSort: String, CaseIterable, Identifiable {
    case newest, marketCap, progress
    var id: Self { self }
    var title: String {
        switch self {
        case .newest: return tr(LocalizedStringResource("Newest", comment: "Sort chip: the newest coins first [tight]"))
        case .marketCap: return tr(LocalizedStringResource("Market Cap", comment: "Sort chip: the largest market cap first [tight]"))
        case .progress: return tr(LocalizedStringResource("Near Graduation", comment: "Sort chip: the coins closest to graduating first [tight]"))
        }
    }
}

/// One coin in the discovery grid: an image-forward card with its badge, name, market cap and — while on the curve —
/// its progress toward graduation.
struct LaunchCard: View {
    let launch: Launch

    private var isGraduated: Bool { launch.phase == .graduated }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // A fixed square sized to the cell width, with the artwork cropped to fill it. Defining the square
                // with a Color spacer (instead of `.aspectRatio(.fill)` on the image, which reports a size larger than
                // its frame) keeps every card's height — and its tap area — bounded, so a wide or tall image can no
                // longer overflow its cell and spill onto the filter chips above (which was hijacking their taps).
                Color(.tertiarySystemFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { LaunchArtwork(symbol: launch.symbol, logo: launch.logo) }
                    .clipped()
                badge
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(launch.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(launch.symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Market cap").font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: launch.marketCapInPair.map { "\(NumberStyle.number($0, compact: true)) \(launch.pair.symbol)" } ?? "—")
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        // A retired launchpad's graduated coin (QT) is an ordinary pool coin: no caption.
                        if launch.isSellOnly { Text("Retired launchpad").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        Text(verbatim: RelativeTime.short(launch.launchedAt)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if launch.phase == .bonding {
                    progress
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) // tap area is exactly the card, never its neighbours
    }

    @ViewBuilder private var badge: some View {
        if launch.isSellOnly {
            // Only under Your Sell-Only Coins: the public board lists none. A stuck or migrating one is badged with what
            // it waits for: nothing trades until it graduates.
            Text(launch.sellOnlyBadge)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
        } else if isGraduated {
            Label("Graduated", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.positive)
        } else if launch.phase.boardSection == .refundAndMigrating {
            Text(launch.phase.title)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
        } else if launch.progressBps >= 8000 {
            Text(verbatim: "\(launch.progressBps / 100)%")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(Color.brand)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                    Capsule().fill(Color.brand).frame(width: geo.size.width * min(1, Double(launch.progressBps) / 10_000), height: 5)
                }
            }
            .frame(height: 5)
            Text("\(launch.progressBps / 100)% to graduation").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A coin's artwork: its uploaded image, or a monogram on a tinted ground when it has none. The logo is whatever string
/// the coin's launcher wrote on-chain, so it is loaded only from DyorHQ's bucket or through the fixed IPFS gateways
/// (`ImageSourcePolicy`), never a host the launcher chose, through the capped loader (RemoteImage).
struct LaunchArtwork: View {
    let symbol: String
    let logo: String
    /// How wide the artwork is drawn, in points: the thumbnail is decoded for this size.
    var pointSize: CGFloat = LaunchArtwork.cardPointSize

    /// The size a board's card draws it at (`LaunchCard`), and what its next rows are warmed at (`prefetch`).
    static let cardPointSize: CGFloat = 240

    /// Warms the picture a board's card for `logo` will ask for — the same sources, size bucket and caps as `body` at
    /// `cardPointSize` — ahead of the board's scroll (`BoardPrefetch`, `ImagePipeline.prefetch`).
    @MainActor static func prefetch(logo: String) {
        let bucket = ImageSizeBucket.bucket(points: cardPointSize)
        RemoteImageLoader.shared.prefetch(ImageSourcePolicy.app.creatorSources(logo).map { RemoteImageSource(url: $0) }, bucket: bucket,
                                          caps: RemoteMedia.caps(forThumbnail: bucket))
    }

    var body: some View {
        Group {
            let sources = ImageSourcePolicy.app.creatorSources(logo).map { RemoteImageSource(url: $0) }
            if !sources.isEmpty {
                RemoteImage(sources: sources, pointSize: pointSize) { loading in
                    if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .accessibilityIgnoresInvertColors()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.brand.opacity(0.30), Color.brand.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Sized to the frame: a fixed 40 pt shows only "…" in the 34–44 pt rows. Cards and headers keep 40. The letters
            // skip the isolate around right-to-left text (`ChainText.leading`).
            GeometryReader { frame in
                Text(ChainText.leading(symbol, 2).uppercased())
                    .font(.system(size: min(40, frame.size.width * 0.4), weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
