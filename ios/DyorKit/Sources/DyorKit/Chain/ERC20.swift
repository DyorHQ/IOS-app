import BigInt
import Foundation

/// ERC-20 calldata builders and reads.
public enum ERC20 {
    public static func balanceOf(_ token: Address, _ owner: Address) throws -> ContractCall {
        try ContractCall(to: token, "balanceOf(address)", [.address(owner)], returns: "uint256")
    }

    public static func allowance(_ token: Address, owner: Address, spender: Address) throws -> ContractCall {
        try ContractCall(to: token, "allowance(address,address)", [.address(owner), .address(spender)], returns: "uint256")
    }

    public static func symbol(_ token: Address) throws -> ContractCall { try ContractCall(to: token, "symbol()", returns: "string") }
    public static func name(_ token: Address) throws -> ContractCall { try ContractCall(to: token, "name()", returns: "string") }
    public static func decimals(_ token: Address) throws -> ContractCall { try ContractCall(to: token, "decimals()", returns: "uint8") }

    public static func approveCalldata(spender: Address, amount: BigUInt) throws -> Data {
        try ABI.encodeCall("approve(address,uint256)", [.address(spender), .uint(amount)])
    }

    public static func transferCalldata(to: Address, amount: BigUInt) throws -> Data {
        try ABI.encodeCall("transfer(address,uint256)", [.address(to), .uint(amount)])
    }

    /// Reads symbol, name and decimals so any Monad token can be added by address. Only a readable `symbol()` is
    /// required — `name()` falls back to the symbol and `decimals()` to 18 — so a token that merely omits an optional
    /// field (or returns a non-standard value) is still surfaced instead of being dropped.
    public static func metadata(_ token: Address, multicall: Multicall) async throws -> Token? {
        let results = try await multicall.read([try symbol(token), try name(token), try decimals(token)])
        guard case .success(let s) = results[0], let symbol = s.first.flatMap(\.stringOrNil), !symbol.isEmpty else { return nil }
        var name = symbol
        if case .success(let n) = results[1], let value = n.first.flatMap(\.stringOrNil), !value.isEmpty { name = value }
        var decimals = 18
        if case .success(let d) = results[2], let value = d.first.flatMap(\.uintOrNil), value <= 36 { decimals = Int(value) }
        return Token(address: token, symbol: symbol, name: name, decimals: decimals)
    }

    /// Resolves symbol/name/decimals for many tokens at once, batching the reads through the multicall (50 tokens =
    /// 150 reads per round trip). Drops only tokens with no readable symbol; name/decimals fall back like `metadata`.
    public static func metadataBatch(_ addresses: [Address], multicall: Multicall) async -> [Token] {
        await metadataReport(addresses, multicall: multicall).tokens
    }

    /// `metadataBatch`, saying which tokens weren't read at all (`unread`): those whose read got no answer (the connection,
    /// or a throttle that outlasted the client's retries), so nothing is known of them. Tokens are read 50 a read, so no one
    /// token can keep the others from being read: a read the node refuses as a whole (one token's return bomb makes the
    /// aggregate run out of gas) and a token whose symbol can't be read in its read (it has none, it reverts, or a token
    /// before it starved it of gas, which Multicall3 reports as a failed call) are read again, each token on its own, a
    /// few at a time. A token whose symbol still can't be read on its own is dropped, as `metadata` drops it: never unread.
    public static func metadataReport(_ addresses: [Address], multicall: Multicall) async -> (tokens: [Token], unread: [Address]) {
        var found: [Address: Token] = [:]
        var unread = Set<Address>()
        var alone: [Address] = []
        var index = 0
        while index < addresses.count {
            let batch = Array(addresses[index ..< min(index + 50, addresses.count)])
            index += batch.count
            switch await captured({ try await multicall.read(try batch.flatMap { try [symbol($0), name($0), decimals($0)] }) }) {
            case .success(let results):
                for (offset, address) in batch.enumerated() {
                    if let token = token(address, results.dropFirst(offset * 3).prefix(3)) { found[address] = token } else { alone.append(address) }
                }
            case .failure(let error):
                if isCallError(error) { alone += batch } else { unread.formUnion(batch) }
            }
        }
        for start in stride(from: 0, to: alone.count, by: 5) {
            await withTaskGroup(of: (address: Address, outcome: Result<[Result<[ABIValue], Error>], Error>).self) { tasks in
                for address in alone[start ..< min(start + 5, alone.count)] {
                    tasks.addTask { (address, await captured { try await multicall.read([try symbol(address), try name(address), try decimals(address)]) }) }
                }
                for await (address, outcome) in tasks {
                    switch outcome {
                    case .success(let results): found[address] = token(address, results[...])
                    case .failure(let error): if !isCallError(error) { unread.insert(address) }
                    }
                }
            }
        }
        return (addresses.compactMap { found[$0] }, addresses.filter(unread.contains))
    }

    /// One token from its symbol, name and decimals reads, in that order: nil when the symbol isn't a readable string. The
    /// name falls back to the symbol and the decimals to 18, as `metadata` has them.
    private static func token(_ address: Address, _ reads: ArraySlice<Result<[ABIValue], Error>>) -> Token? {
        let reads = Array(reads)
        guard reads.count == 3, case .success(let s) = reads[0], let symbol = s.first.flatMap(\.stringOrNil), !symbol.isEmpty else { return nil }
        var name = symbol
        if case .success(let n) = reads[1], let value = n.first.flatMap(\.stringOrNil), !value.isEmpty { name = value }
        var decimals = 18
        if case .success(let d) = reads[2], let value = d.first.flatMap(\.uintOrNil), value <= 36 { decimals = Int(value) }
        return Token(address: address, symbol: symbol, name: name, decimals: decimals)
    }

    /// Balances, and which couldn't be read (`balanceReport`).
    public struct BalanceReport: Sendable, Equatable {
        public var balances: [Address: BigUInt] = [:]
        /// Tokens whose read failed as a whole — the node or the connection didn't answer it — so nothing is known of them.
        public var unread: Set<Address> = []
        /// Tokens whose own `balanceOf` failed, read on its own: the contract refuses it (it reverts, burns its gas, or
        /// answers what isn't a balance).
        public var failed: Set<Address> = []

        public init(balances: [Address: BigUInt] = [:], unread: Set<Address> = [], failed: Set<Address> = []) {
            self.balances = balances
            self.unread = unread
            self.failed = failed
        }
    }

    /// Native and ERC-20 balances read so that no one token can keep the others from being read: native MON on its own
    /// (`eth_getBalance`), the curated tokens in a read of their own, every other token in reads of at most `batch`, all
    /// at once (`balanceReport(ofTokens:)`). What couldn't be read is said (`BalanceReport.unread`, `.failed`), never
    /// taken for zero.
    public static func balanceReport(of tokens: [Token], owner: Address, rpc: RPCClient, multicall: Multicall, batch: Int = 50) async -> BalanceReport {
        var seen = Set<Address>()
        let unique = tokens.filter { seen.insert($0.address).inserted }
        let erc20s = unique.filter { !$0.isNative }
        let curated = erc20s.filter { Token.core($0.address) != nil }.map(\.address)
        let others = erc20s.filter { Token.core($0.address) == nil }.map(\.address)
        let readsNative = unique.contains(where: \.isNative)
        async let native: Result<BigUInt, Error>? = readsNative ? await captured { try await rpc.balance(of: owner) } : nil
        async let curatedRead = balanceReport(ofTokens: curated, owner: owner, multicall: multicall, batch: max(1, curated.count))
        async let othersRead = balanceReport(ofTokens: others, owner: owner, multicall: multicall, batch: batch)
        var report = await curatedRead
        let rest = await othersRead
        report.balances.merge(rest.balances) { first, _ in first }
        report.unread.formUnion(rest.unread)
        report.failed.formUnion(rest.failed)
        switch await native {
        case .success(let balance)?: report.balances[Monad.native] = balance
        case .failure?: report.unread.insert(Monad.native)
        case nil: break
        }
        return report
    }

    /// ERC-20 balances of `tokens`, in reads of at most `batch` tokens, all at once. A read the node refuses as a whole
    /// (one token's return bomb makes the aggregate run out of gas) and a token whose call fails inside a read (starved
    /// of gas by a token before it) are read again, each token on its own, so only the token at fault is left out; a
    /// read that got no answer at all (the connection) is not retried here.
    public static func balanceReport(ofTokens tokens: [Address], owner: Address, multicall: Multicall, batch: Int = 50) async -> BalanceReport {
        guard !tokens.isEmpty else { return BalanceReport() }
        let size = max(1, batch)
        let groups = stride(from: 0, to: tokens.count, by: size).map { Array(tokens[$0 ..< min($0 + size, tokens.count)]) }
        var report = BalanceReport()
        var retry: [Address] = []
        await withTaskGroup(of: (group: [Address], outcome: Result<[Result<[ABIValue], Error>], Error>).self) { tasks in
            for group in groups {
                tasks.addTask { (group, await captured { try await multicall.read(try group.map { try balanceOf($0, owner) }) }) }
            }
            for await (group, outcome) in tasks {
                switch outcome {
                case .success(let results):
                    for (token, result) in zip(group, results) {
                        if case .success(let values) = result, let balance = values.first?.uintOrNil { report.balances[token] = balance } else { retry.append(token) }
                    }
                case .failure(let error):
                    // The node answered with an error about the call itself: a token in it may be at fault. Anything
                    // else (no answer, or throttling that outlasted the client's retries) would fail again token by token.
                    if isCallError(error) { if group.count > 1 { retry += group } else { report.failed.formUnion(group) } } else { report.unread.formUnion(group) }
                }
            }
        }
        guard !retry.isEmpty else { return report }
        await withTaskGroup(of: (token: Address, outcome: Result<[Result<[ABIValue], Error>], Error>).self) { tasks in
            for token in retry {
                tasks.addTask { (token, await captured { try await multicall.read([try balanceOf(token, owner)]) }) }
            }
            for await (token, outcome) in tasks {
                switch outcome {
                case .success(let results):
                    if case .success(let values)? = results.first, let balance = values.first?.uintOrNil { report.balances[token] = balance } else { report.failed.insert(token) }
                case .failure(let error):
                    if isCallError(error) { report.failed.insert(token) } else { report.unread.insert(token) }
                }
            }
        }
        return report
    }

    /// The node's answer that the call itself fails — it reverts or runs out of gas — as opposed to a request that
    /// failed (no answer, throttling, a node that can't serve it).
    static func isCallError(_ error: Error) -> Bool {
        guard let error = error as? RPCError, !RPCClient.isRateLimited(error) else { return false }
        let message = error.message.lowercased()
        return error.code == 3 || message.contains("revert") || message.contains("out of gas") || message.contains("gas required exceeds")
            || message.contains("invalid opcode")
    }

    /// `body`'s outcome as a value.
    static func captured<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Native and ERC-20 balances for a list of tokens, keyed by address. Missing entries mean the read failed.
    public static func balances(of tokens: [Token], owner: Address, rpc: RPCClient, multicall: Multicall) async throws -> [Address: BigUInt] {
        let erc20s = tokens.filter { !$0.isNative }
        async let native = tokens.contains { $0.isNative } ? rpc.balance(of: owner) : BigUInt(0)
        async let results = multicall.read(try erc20s.map { try balanceOf($0.address, owner) })
        var out: [Address: BigUInt] = [:]
        if tokens.contains(where: { $0.isNative }) { out[Monad.native] = try await native }
        for (token, result) in zip(erc20s, try await results) {
            if case .success(let values) = result { out[token.address] = values[0].uint }
        }
        return out
    }
}
