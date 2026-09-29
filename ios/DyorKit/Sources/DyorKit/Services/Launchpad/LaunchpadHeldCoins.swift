import Foundation

public extension LaunchpadService {
    /// The launches of those of `tokens` a known launchpad recorded — the live one once deployed, then each retired one
    /// (`stacks`) — in any phase, by coin, each from the first factory whose record names a curve (`firstRecord`, as
    /// `knownCurve` reads it). What values a held launch coin the way Home does: `Launch.price` is its curve's price, or
    /// its pool's once graduated. MON and the curated tokens are never asked. One aggregate asks every factory for every
    /// coin's record, then each factory's coins are read as launches in one read per factory. Throws when the aggregate
    /// fails; a factory whose launches can't be read leaves its coins out.
    func recordedLaunches(_ tokens: [Token]) async throws -> [Address: Launch] {
        var seen = Set<Address>()
        let coins = tokens.filter { SwapEngine.mayBeLaunchCoin($0) && seen.insert($0.address).inserted }.map(\.address)
        let stacks = stacks.filter(\.isDeployed)
        guard !coins.isEmpty, !stacks.isEmpty else { return [:] }
        let calls = coins.flatMap { coin in
            stacks.map { LaunchpadABI.call($0.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(coin)], returns: LaunchpadABI.launchedTokenReturns(legacy: $0.generation.legacyRecord)) }
        }
        let results = try await multicall.read(calls)
        guard results.count == calls.count else { throw LaunchpadError.unexpectedResponse("launchpad records") }
        var byFactory: [Address: [LaunchpadABI.LaunchRecord]] = [:]
        for (i, coin) in coins.enumerated() {
            let answers = Array(results[i * stacks.count ..< (i + 1) * stacks.count])
            if let hit = Self.firstRecord(stacks: stacks, records: answers), hit.record.token == coin {
                byFactory[hit.stack.factory, default: []].append(hit.record)
            }
        }
        var launches: [Address: Launch] = [:]
        await withTaskGroup(of: [Launch].self) { group in
            for (factory, records) in byFactory {
                group.addTask { (try? await self.hydrate(records, factory: factory)) ?? [] }
            }
            for await list in group { for launch in list { launches[launch.token] = launch } }
        }
        return launches
    }
}
