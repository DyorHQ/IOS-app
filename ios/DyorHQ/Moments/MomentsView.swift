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
    @State private var path: [MomentInfo] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    enum MomentFilter: String, CaseIterable, Identifiable {
        case all, collecting, graduated
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
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
                    ContentUnavailableView("Moments Not Live Yet", systemImage: "camera.aperture", description: Text("Moments appear here once the contracts are deployed on Monad."))
                } else {
                    board
                }
            }
            .navigationTitle("Moments")
            .navigationDestination(for: MomentInfo.self) { info in MomentDetailView(info: info, onChanged: { Task { await model.load(env: env) } }) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showPortfolio = true } label: { Label("My Moments", systemImage: "person.crop.rectangle.stack") }
                        .disabled(!env.config.moments.isDeployed || session.address == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showCreate = true } label: { Label("Publish", systemImage: "plus") }
                        .disabled(!env.config.moments.isDeployed || model.policy?.publishingPaused == true)
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
                path = [pending]
                router.pendingMoment = nil
            }
            .onAppear {
                if let pending = router.pendingMoment {
                    path = [pending]
                    router.pendingMoment = nil
                }
            }
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let error = model.error { InlineError(message: error) }
                Picker("Filter", selection: $filter) {
                    ForEach(MomentFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    emptyState
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
            Text("COLLECT A MOMENT").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text("Every collect funds the coin.").font(.system(.title, design: .serif).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let policy = model.policy {
                Text("Collect an edition in USDC and you are owed the coin at one price. Once the reserve reaches \(MomentsFormat.usdc(policy.threshold)) the coin graduates into a locked Uniswap pool and vesting starts.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if policy.publishingPaused {
                    Label("Publishing is paused by governance; collecting continues.", systemImage: "pause.circle").font(.caption).foregroundStyle(Color.attention)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.largeTitle).foregroundStyle(Color.brand)
            Text(filter == .all ? "No Moments yet" : "Nothing here yet").font(.headline)
            Text(filter == .all ? "Be the first: publish a moment with its photo, place and date." : "Change the filter to see other Moments.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if filter == .all, session.canSign {
                Button("Publish a Moment") { Haptics.tap(); showCreate = true }.buttonStyle(.borderedProminent).foregroundStyle(.white).padding(.top, 4)
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
            async let policyTask = env.moments.policy()
            async let listTask = env.moments.moments(limit: 60)
            let (policy, list) = try await (policyTask, listTask)
            self.policy = policy
            moments = list
            error = nil
        } catch {
            if moments.isEmpty { self.error = describe(error) }
        }
    }
}
