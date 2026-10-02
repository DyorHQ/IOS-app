import DyorKit
import SwiftUI

/// The Moments board: every Moment as an image-forward card — collecting ones with their progress to graduation,
/// graduated ones with their coin price — plus the flow to publish one and the wallet's own editions and coins.
struct MomentsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = MomentsModel()
    @State private var clock = Clock()
    @State private var filter: MomentFilter = .all
    @State private var showCreate = false
    @State private var showPortfolio = false
    /// Moments pushed by value (the board, publish, the portfolio) and, from a link, by (factory, id) to load first.
    @State private var path = NavigationPath()

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    enum MomentFilter: String, CaseIterable, Identifiable {
        case all, collecting, graduated
        var id: String { rawValue }
        /// The segment's name, written out (never the raw value) so it is translated.
        var label: Text {
            switch self {
            case .all: return Text("All", comment: "[tight] Moments filter: every Moment")
            case .collecting: return Text("Collecting", comment: "[tight] Moments filter: Moments still open to collect")
            case .graduated: return Text("Graduated", comment: "[tight] Moments filter: Moments whose coin graduated")
            }
        }
    }

    private var shown: [MomentInfo] {
        switch filter {
        case .all: return model.moments
        case .collecting: return model.moments.filter { $0.isCollecting(at: clock.now) }
        case .graduated: return model.moments.filter(\.graduated)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !env.config.moments.isDeployed {
                    // The live (v2) cohort is pending. Past-cohort Moments stay reachable through My Moments and links.
                    ContentUnavailableView("Moments Not Live Yet", systemImage: "camera.aperture",
                                           description: Text("New Moments appear here once the new DyorHQ Moments contracts are live on Monad. Moments from earlier cohorts are in My Moments."))
                } else {
                    board
                }
            }
            .navigationTitle("Moments")
            .navigationDestination(for: MomentInfo.self) { info in MomentDetailView(info: info, onChanged: { Task { await model.load(env: env) } }) }
            .navigationDestination(for: MomentLink.self) { link in MomentLinkView(link: link, onChanged: { Task { await model.load(env: env) } }) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showPortfolio = true } label: { Label("My Moments", systemImage: "person.crop.rectangle.stack") }
                        .disabled(session.address == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only on terms the app can bind a publish to (`MomentPolicy.canPublish`): neither pause, the c4 link
                    // base, and an on-chain terms hash that matches the terms read with it.
                    Button { Haptics.tap(); showCreate = true } label: { Label("Publish", systemImage: "plus") }
                        .disabled(!env.config.moments.isDeployed || model.policy?.canPublish != true)
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateMomentView(policy: model.policy) { info in
                    Task { await model.load(env: env) }
                    if let info { path.append(info) }
                }
            }
            .sheet(isPresented: $showPortfolio) { MomentsPortfolioView(moments: model.moments) { info in showPortfolio = false; path.append(info) } }
            .refreshable { await model.load(env: env) }
            .task { await model.poll(env: env) }
            .task { await clock.run() }
            .onChange(of: router.pendingMoment) { _, pending in
                guard let pending else { return }
                path = NavigationPath([pending])
                router.pendingMoment = nil
            }
            .onChange(of: router.pendingMomentLink) { _, link in
                guard let link else { return }
                path = NavigationPath([link])
                router.pendingMomentLink = nil
            }
            .onAppear {
                // The tab is lazy: a request made before it was first shown is waiting here.
                if let pending = router.pendingMoment {
                    path = NavigationPath([pending])
                    router.pendingMoment = nil
                }
                if let link = router.pendingMomentLink {
                    path = NavigationPath([link])
                    router.pendingMomentLink = nil
                }
            }
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // A read that failed says so, with Retry; the Moments last read stay listed (as on the Launch board).
                if let error = model.error {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: error)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await model.load(env: env) } }.font(.footnote.weight(.semibold))
                    }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(MomentFilter.allCases) { $0.label.tag($0) }
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    // Never "No Moments yet" for a feed that couldn't be read.
                    if model.error == nil || !model.moments.isEmpty { emptyState }
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(shown) { info in
                            NavigationLink(value: info) { MomentCard(info: info, now: clock.now) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .scrollIndicators(.hidden)
        .overlay { if model.moments.isEmpty, model.loading { ProgressView().controlSize(.large) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOMENTS", comment: "Eyebrow over the Moments board, in capitals").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text("Make your favorite moments last forever.").font(.system(.title, design: .serif).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text("Publish a photo or video as an NFT on Monad. Share it with everyone and earn every time it's collected.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let unread = model.policyUnread {
                // The terms couldn't be read: Publish is off (no policy to bind a publish to), the Moments still show.
                Label(unread, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(Color.attention)
            } else if let policy = model.policy {
                if let block = policy.publishBlock {
                    // Why Publish is off: a pause (governance's or the guardian's), a link base that isn't DyorHQ's, or terms
                    // the app can't bind a publish to.
                    Label(block.message, systemImage: block == .publishingPaused || block == .guardianPaused ? "pause.circle" : "exclamationmark.octagon")
                        .font(.caption).foregroundStyle(Color.attention)
                } else if let pending = policy.pending, !pending.hasLapsed(at: Date(timeIntervalSince1970: TimeInterval(clock.now))) {
                    // MO-4: a queued policy can't change a Moment silently. If it's applied before a publish confirms, the
                    // publish is refused and the creator reviews the new terms; Publish a Moment shows what would change.
                    Label("New terms for new Moments are queued. If they take effect before your publish confirms, nothing is published and you review them again.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.attention)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.largeTitle).foregroundStyle(Color.brand)
            Text(filter == .all ? "No Moments yet" : "Nothing here yet").font(.headline)
            Text(filter == .all ? "Be the first: publish a photo or video and make it last forever." : "Change the filter to see other Moments.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if filter == .all, session.canSign, model.policy?.canPublish == true {
                Button("Publish a Moment") { Haptics.tap(); showCreate = true }.buttonStyle(.borderedProminent).foregroundStyle(.white).padding(.top, 4)
            } else if filter != .all {
                Button("Show All Moments") { Haptics.selection(); filter = .all }.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

@Observable
@MainActor
final class MomentsModel {
    private(set) var moments: [MomentInfo] = []
    private(set) var policy: MomentPolicy?
    /// Why Publish is unavailable when the last policy read failed (`MomentsBoard.policyUnread`).
    private(set) var policyUnread: String?
    private(set) var loading = false
    private(set) var error: String?

    func poll(env: AppEnvironment) async {
        while !Task.isCancelled {
            await load(env: env)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    func load(env: AppEnvironment) async {
        guard env.config.moments.isDeployed else { return }
        loading = true
        defer { loading = false }
        do {
            // The list never waits on the policy: a policy that can't be read leaves Publish off, with its reason.
            let board = try await env.moments.board(limit: 60)
            moments = board.moments
            policy = try? board.policy.get()
            policyUnread = board.policyUnread
            error = nil
        } catch {
            // Every failed read says so, the first or a refresh: the Moments last read stay, never a feed frozen unsaid. A
            // read cut short because the tab went off screen isn't one: the feed reloads when it's back.
            guard !Task.isCancelled else { return }
            self.error = describe(error)
        }
    }
}
