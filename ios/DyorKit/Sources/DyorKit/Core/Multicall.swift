import BigInt
import Foundation

/// One contract read inside a multicall: the target, the calldata, and how to interpret the return data.
public struct ContractCall: Sendable {
    public let to: Address
    public let data: Data
    public let returnTypes: [ABIType]
    /// How its `string` returns decode (`ABI.StringDecoding`): lossy unless the exact bytes matter.
    public let strings: ABI.StringDecoding

    public init(to: Address, data: Data, returns: [ABIType], strings: ABI.StringDecoding = .lossy) {
        self.to = to
        self.data = data
        returnTypes = returns
        self.strings = strings
    }

    /// `ContractCall(to: token, "balanceOf(address)", [.address(owner)], returns: "uint256")`
    public init(to: Address, _ signature: String, _ args: [ABIValue] = [], returns: String, strings: ABI.StringDecoding = .lossy) throws {
        self.to = to
        data = try ABI.encodeCall(signature, args)
        returnTypes = try ABIType.parseList(returns)
        self.strings = strings
    }

    /// A read whose signature, arguments and return types are fixed in source: one that fails to encode traps, naming
    /// `context` and the signature, as `ABI.fixedCalldata` does.
    static func fixed(to: Address, _ signature: String, _ args: [ABIValue], returns: String, strings: ABI.StringDecoding = .lossy,
                      context: String) -> ContractCall {
        do { return try ContractCall(to: to, signature, args, returns: returns, strings: strings) } catch { preconditionFailure("\(context) call \(signature) failed to encode: \(error)") }
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

    /// Multicall3's own `getBlockNumber()`, as a call: added to a `read`, it says the block every other call in it was
    /// answered at — one aggregate runs at a single block.
    public static let blockNumber = ContractCall(to: address, data: ABI.selector("getBlockNumber()"), returns: [.uint(256)])

    /// The block a `blockNumber` call answered; nil when it failed.
    public static func block(_ result: Result<[ABIValue], Error>) -> UInt64? {
        guard case .success(let values) = result, case .uint(let number)? = values.first else { return nil }
        return UInt64(exactly: number)
    }

    /// Runs every call; failed calls come back as `.failure` so one bad read never hides the others: a call that failed
    /// (it reverted or ran out of gas) as an `RPCError` carrying what it returned, and one whose return data isn't of its
    /// `returnTypes` as the decoding's error.
    public func read(_ calls: [ContractCall], block: BlockTag = .latest) async throws -> [Result<[ABIValue], Error>] {
        guard !calls.isEmpty else { return [] }
        let data = try Self.calldata(calls)
        let raw = try await rpc.ethCall(CallRequest(to: Self.address, data: data), block: block)
        return try Self.results(raw, for: calls)
    }

    /// Like `read`, but throws if any call failed.
    public func readAll(_ calls: [ContractCall], block: BlockTag = .latest) async throws -> [[ABIValue]] {
        try await read(calls, block: block).map { try $0.get() }
    }

    /// Several `read`s, each its calls at its own block, sent as one batched JSON-RPC request (a chart's samples): one
    /// answer per request, in order, a request the node couldn't serve (a block it no longer holds) as its failure.
    public func read(_ requests: [(calls: [ContractCall], block: UInt64)]) async throws -> [Result<[Result<[ABIValue], Error>], Error>] {
        guard !requests.isEmpty else { return [] }
        let encoded = try requests.map { request -> (CallRequest, BlockTag) in
            (CallRequest(to: Self.address, data: try Self.calldata(request.calls)), .number(request.block))
        }
        let answers = try await rpc.ethCalls(encoded)
        guard answers.count == requests.count else { throw NetworkError.malformedResponse }
        return zip(requests, answers).map { request, answer in
            Result { try Self.results(try answer.get(), for: request.calls) }
        }
    }

    /// `aggregate3` calldata for `calls`, each allowed to fail on its own.
    private static func calldata(_ calls: [ContractCall]) throws -> Data {
        let args: ABIValue = .array(calls.map { .tuple([.address($0.to), .bool(true), .bytes($0.data)]) })
        return try ABI.encodeCall(Self.signature, [args])
    }

    /// `aggregate3`'s answer `raw` as one result per call of `calls`, in order (`read`); throws when it isn't one answer
    /// per call.
    private static func results(_ raw: Data, for calls: [ContractCall]) throws -> [Result<[ABIValue], Error>] {
        let decoded = try ABI.decode(raw, Self.returns)[0].elements
        guard decoded.count == calls.count else { throw NetworkError.malformedResponse }
        return zip(calls, decoded).map { call, item in
            // not localized: an RPC message, matched like a node's ("revert", `ERC20.isCallError`)
            guard item[0].bool else { return .failure(RPCError(code: -32000, message: "Call reverted", data: item[1].bytes.hexString)) }
            do { return .success(try ABI.decode(item[1].bytes, call.returnTypes, strings: call.strings)) } catch { return .failure(error) }
        }
    }
}
