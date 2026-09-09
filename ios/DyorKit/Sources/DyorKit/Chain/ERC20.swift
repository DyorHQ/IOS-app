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

    /// Reads symbol, name and decimals so any Monad token can be added by address.
    public static func metadata(_ token: Address, multicall: Multicall) async throws -> Token? {
        let results = try await multicall.read([try symbol(token), try name(token), try decimals(token)])
        guard case .success(let s) = results[0], case .success(let n) = results[1], case .success(let d) = results[2] else { return nil }
        return Token(address: token, symbol: s[0].string, name: n[0].string, decimals: Int(d[0].uint))
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
