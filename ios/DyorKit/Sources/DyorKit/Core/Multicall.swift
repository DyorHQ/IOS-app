import BigInt
import Foundation

/// One contract read inside a multicall: the target, the calldata, and how to interpret the return data.
public struct ContractCall: Sendable {
    public let to: Address
    public let data: Data
    public let returnTypes: [ABIType]

    public init(to: Address, data: Data, returns: [ABIType]) {
        self.to = to
        self.data = data
        returnTypes = returns
    }

    /// `ContractCall(to: token, "balanceOf(address)", [.address(owner)], returns: "uint256")`
    public init(to: Address, _ signature: String, _ args: [ABIValue] = [], returns: String) throws {
        self.to = to
        data = try ABI.encodeCall(signature, args)
        returnTypes = try ABIType.parseList(returns)
    }
}

/// Multicall3 `aggregate3`, deployed at the canonical address on Monad mainnet. Batches many reads into one
/// `eth_call` at a single block, which is what keeps market screens to one round trip.
public struct Multicall: Sendable {
    public static let address = Address(literal: "0xcA11bde05977b3631167028862bE2a173976CA11")
    private static let signature = "aggregate3((address,bool,bytes)[])"
    private static let returns: [ABIType] = [.array(.tuple([.bool, .bytes]))]

    public let rpc: RPCClient

    public init(rpc: RPCClient) { self.rpc = rpc }

    /// Runs every call; failed calls come back as `.failure` so one bad read never hides the others.
    public func read(_ calls: [ContractCall], block: BlockTag = .latest) async throws -> [Result<[ABIValue], Error>] {
        guard !calls.isEmpty else { return [] }
        let args: ABIValue = .array(calls.map { .tuple([.address($0.to), .bool(true), .bytes($0.data)]) })
        let data = try ABI.encodeCall(Self.signature, [args])
        let raw = try await rpc.ethCall(CallRequest(to: Self.address, data: data), block: block)
        let decoded = try ABI.decode(raw, Self.returns)[0].elements
        guard decoded.count == calls.count else { throw NetworkError.malformedResponse }
        return zip(calls, decoded).map { call, item in
            guard item[0].bool else { return .failure(RPCError(code: -32000, message: "Call reverted", data: item[1].bytes.hexString)) }
            do { return .success(try ABI.decode(item[1].bytes, call.returnTypes)) } catch { return .failure(error) }
        }
    }

    /// Like `read`, but throws if any call failed.
    public func readAll(_ calls: [ContractCall], block: BlockTag = .latest) async throws -> [[ABIValue]] {
        try await read(calls, block: block).map { try $0.get() }
    }
}
