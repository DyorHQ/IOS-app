import DyorKit
import SwiftUI

// The Launch tab's model (`LaunchpadModel`): the board's launches, the factory's terms, each pair asset's price and
// the wallet's sell-only coins.

@Observable
@MainActor
final class LaunchpadModel {
    private(set) var launches: [Launch] = []
    private(set) var protocolInfo: ProtocolInfo?
    /// Each pair asset's USD price, by pair token (MON under the zero address; USDC and AUSD $1), read the way
    /// `LaunchpadProfileModel` reads them: the Market Cap sort compares coins in dollars across pair assets. A pair with
    /// no price is left out, and a failed read keeps the last prices.
    private(set) var pairUSD: [Address: Double] = [:]
    /// The retired launchpads' sell-only coins the signed-in wallet holds, which the board doesn't list: its "Your
    /// Sell-Only Coins" (`LaunchBoard.heldSellOnly`). Cleared on an account change; a read that failed, of a factory
    /// or a balance, keeps it (a held coin never drops from the section unsaid).
    private(set) var heldSellOnly: [Launch] = []
    /// When `heldSellOnly` was read, while it is what was saved for the wallet when the board was last read in full
    /// (`restoreSaved`); nil once a read of the wallet's sell-only coins landed in this session. Apart from `savedAt`: the
    /// launches can all be read again while the balances behind this section aren't, and until they are, the section says
    /// when it was read and its coins open by reference, so their pages read them now.
    private(set) var heldSellOnlySavedAt: Date?
    /// The account the board's per-account reads belong to: `heldSellOnly`, and the terms (`protocolInfo`, which say
    /// whether it may launch). Both are cleared when it changes, and a read made for another account is dropped.
    private var loadedFor: Address?
    private(set) var loading = false
    private(set) var error: String?
    /// When the board on screen was read, while it shows what was saved for the wallet when last read in full
    /// (`restoreSaved`); nil once a read of every launchpad landed. The board says it ("Updated 3 min ago").
    private(set) var savedAt: Date?
    /// A read of the launchpads has answered in this session — every one, some or none of them (`error` says which) — or
    /// the board saved for the wallet is shown: until then an empty board is loading (`BoardFirstRead`), never "No
    /// Launches Yet".
    private(set) var listed = false

    /// What the board saves for a wallet once read in full (`SavedScreens.Screen.launchBoard`): the launches, each pair
    /// asset's price, and the wallet's sell-only coins.
    struct Saved: Codable, Sendable {
        let launches: [Launch]
        let pairUSD: [Address: Double]
        let heldSellOnly: [Launch]
    }

    func poll(env: AppEnvironment, account: Address?) async {
        while !Task.isCancelled {
            await load(env: env, account: account)
            try? await Task.sleep(for: .seconds(20))
        }
    }

    /// Takes in `account` before the board's first frame (`LaunchpadView`'s `onAppear`) and at the start of every load:
    /// another account's sell-only coins and its terms go, and a board with nothing on it yet shows what was saved for
    /// this one when it was last read in full — a small file on the device, read on the spot — said to be
    /// (`restoreSaved`). So the tab opens on the coins it last showed rather than on a spinner until its first read's
    /// task starts.
    func showSaved(env: AppEnvironment, account: Address?) {
        // Another account: none of the previous one's coins may stay on screen, even when a read below fails, nor
        // its terms (`protocolInfo` carries whether that account may launch), which a failed read would otherwise keep.
        if account != loadedFor {
            heldSellOnly = []
            heldSellOnlySavedAt = nil
            protocolInfo = nil
            loadedFor = account
        }
        // A board with nothing on it yet shows what was saved for this account when last read, said to be (`restoreSaved`).
        restoreSaved(env: env, account: account)
    }

    /// `account` is the signed-in wallet: whether it may launch (`canLaunch`) comes with the factory's terms. A launchpad
    /// whose launches couldn't be read keeps its last good coins on the board, and the board shows the error with Retry
    /// (`LaunchListing.keeping`): never a board with that launchpad's coins silently gone.
    func load(env: AppEnvironment, account: Address?) async {
        // Runs while the live stack is pending too: the retired stacks' launches are still read (and `protocolInfo` is nil).
        loading = true
        defer { loading = false }
        // Already done before the board's first frame (`showSaved`), unless the account changed since.
        showSaved(env: env, account: account)
        // Saved only while this device's data isn't erased meanwhile (`SavedScreens.epoch`).
        let epoch = env.savedScreens.epoch
        async let info = env.launchpad.protocolInfo(extraPairTokens: Token.launchpadPairAssets, account: account)
        let listing = await env.launchpad.launchListing(limit: 60)
        launches = listing.keeping(launches)
        let readAt = Date()
        // Every launchpad read now: nothing saved is left on the board. One that couldn't be read keeps its saved coins,
        // still said to be saved.
        if listing.complete { savedAt = nil }
        // A read cut short because the tab went off screen isn't a failure to show: the board reloads when it's back.
        guard !Task.isCancelled else { return }
        do {
            // Nil for a launchpad not deployed yet. Taken only for the account it was read for: it says whether that
            // account may launch.
            let read = try await info
            if account == loadedFor { protocolInfo = read }
        } catch {
            // A failed read keeps the last good terms, so the Create form open over the board keeps its pairs and fee
            // (`launchPlan` reads the fee, the terms hash and the blocker again before anything is signed).
        }
        error = listing.firstError.map(describe)
        if !listed { listed = true }
        let held = await Self.heldSellOnly(env: env, account: account, listing: listing)
        if let held, !Task.isCancelled, account == loadedFor {
            heldSellOnly = held
            heldSellOnlySavedAt = nil
        }
        let prices = await Self.pairPrices(env: env, launches: launches)
        if let prices { pairUSD = prices }
        // Saved for the next opening once every part was read: the launches of every launchpad, the wallet's sell-only
        // coins and the prices.
        if listing.complete, held != nil, prices != nil, !Task.isCancelled, account == loadedFor {
            env.savedScreens.save(Saved(launches: launches, pairUSD: pairUSD, heldSellOnly: heldSellOnly), .launchBoard, wallet: account, savedAt: readAt, epoch: epoch)
        }
    }

    /// The board saved for `account` when last read in full (`SavedScreens`), while the board has nothing on it (nothing read
    /// in this session, or no read answered yet): shown at once, said to be (`savedAt`), until a read of every launchpad
    /// replaces it.
    private func restoreSaved(env: AppEnvironment, account: Address?) {
        guard launches.isEmpty, let saved = env.savedScreens.load(Saved.self, .launchBoard, wallet: account) else { return }
        launches = saved.value.launches
        pairUSD = saved.value.pairUSD
        heldSellOnly = saved.value.heldSellOnly
        heldSellOnlySavedAt = saved.savedAt
        savedAt = saved.savedAt
        listed = true
    }

    /// The sell-only coins among a listing's launches that `account` holds, in one balanceOf multicall; none without an
    /// account or such a coin, and nil when a balance couldn't be read.
    private static func heldSellOnly(env: AppEnvironment, account: Address?, listing: LaunchListing) async -> [Launch]? {
        // A factory that couldn't be read left its coins out of the listing: nothing can be decided from the rest, or a
        // held coin of a retired stack that failed would drop from the section.
        guard listing.complete else { return nil }
        let sellOnly = listing.launches.filter { !$0.listsOnBoard }
        guard let account, !sellOnly.isEmpty else { return [] }
        let tokens = sellOnly.map { Token(address: $0.token, symbol: $0.symbol, name: $0.name, decimals: 18, isLaunchpad: true) }
        guard let balances = try? await ERC20.balances(of: tokens, owner: account, rpc: env.rpc, multicall: env.multicall) else { return nil }
        return LaunchBoard.heldSellOnly(sellOnly, balances: balances)
    }

    private static func pairPrices(env: AppEnvironment, launches: [Launch]) async -> [Address: Double]? {
        var tokens: [Address: Token] = [:]
        for launch in launches where tokens[launch.pairToken] == nil {
            tokens[launch.pairToken] = Token(address: launch.pairToken, symbol: launch.pair.symbol, name: launch.pair.symbol, decimals: launch.pair.decimals)
        }
        guard !tokens.isEmpty, let prices = try? await env.prices.prices(for: Array(tokens.values)) else { return nil }
        return prices.compactMapValues { $0.usd > 0 ? $0.usd : nil }
    }
}
