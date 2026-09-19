import BigInt
import Foundation

/// Reads the wallet's token balances on other EVM chains, so the Bridge can show "you have X USDC on Base". The same
/// `0x…` address is used on every chain; a native asset uses `eth_getBalance`, an ERC-20 uses `balanceOf` batched
/// through that chain's multicall. Per-chain failures are swallowed (a dead public RPC returns nothing, never blocks).
public struct MultiChainBalances: Sendable {
    public init() {}

    /// Balances (raw, smallest units) keyed by Aurora `assetId`, for the given tokens on one chain.
    public func balances(owner: Address, chain: EVMChain, tokens: [AuroraToken]) async -> [String: BigUInt] {
        let rpc = RPCClient(url: chain.rpcURL)
        var out: [String: BigUInt] = [:]

        let native = tokens.filter { $0.isNative }
        if !native.isEmpty, let bal = try? await rpc.balance(of: owner) {
            for token in native { out[token.assetId] = bal }
        }

        let erc20 = tokens.filter { !$0.isNative }
        if !erc20.isEmpty {
            let pairs: [(AuroraToken, ContractCall)] = erc20.compactMap { token in
                guard let address = Address(token.contractAddress ?? ""), let call = try? ERC20.balanceOf(address, owner) else { return nil }
                return (token, call)
            }
            if let results = try? await Multicall(rpc: rpc).read(pairs.map(\.1)) {
                for (pair, result) in zip(pairs, results) {
                    if case .success(let values) = result, let value = values.first?.uint { out[pair.0.assetId] = value }
                }
            }
        }
        return out
    }
}
