import BigInt
import Foundation

public struct RPCError: Error, LocalizedError, Equatable, Sendable {
    public let code: Int
    public let message: String
    /// Revert data (`0x…`) when the node includes it, so callers can decode custom errors.
    public let data: String?

    public init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }
}

public enum NetworkError: Error, LocalizedError {
    case badStatus(Int)
    case malformedResponse
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "The server answered with status \(code)."
        case .malformedResponse: return "The server sent a response the app could not read."
        case .transport(let error): return error.localizedDescription
        }
    }
}

/// Ethereum JSON-RPC over HTTPS with request batching. One instance per endpoint.
public actor RPCClient {
    public let url: URL
    private let session: URLSession
    private var nextId = 1

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    // MARK: Raw calls

    public func call(_ method: String, _ params: [JSON] = []) async throws -> JSON {
        let results = try await batch([(method, params)])
        return try results[0].get()
    }

    /// Sends several requests in one HTTP round trip. Results keep the request order.
    public func batch(_ calls: [(method: String, params: [JSON])]) async throws -> [Result<JSON, RPCError>] {
        guard !calls.isEmpty else { return [] }
        var payload: [JSON] = []
        let firstId = nextId
        for (i, call) in calls.enumerated() {
            payload.append(.object(["jsonrpc": .string("2.0"), "id": .number(Double(firstId + i)), "method": .string(call.method), "params": .array(call.params)]))
        }
        nextId += calls.count

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(calls.count == 1 ? payload[0] : .array(payload))
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NetworkError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.badStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(JSON.self, from: data)
        let responses = calls.count == 1 ? [decoded] : (decoded.array ?? [])
        guard responses.count == calls.count else { throw NetworkError.malformedResponse }

        var byId: [Int: JSON] = [:]
        for r in responses { if let id = r["id"].number { byId[Int(id)] = r } }
        return (0..<calls.count).map { i in
            guard let r = byId[firstId + i] else { return .failure(RPCError(code: -1, message: "Missing response")) }
            let error = r["error"]
            if !error.isNull {
                return .failure(RPCError(code: Int(error["code"].number ?? -1), message: error["message"].string ?? "RPC error", data: error["data"].string))
            }
            return .success(r["result"])
        }
    }

    // MARK: Typed helpers

    public func chainId() async throws -> Int {
        Int(try quantity(await call("eth_chainId")))
    }

    public func blockNumber() async throws -> UInt64 {
        UInt64(try quantity(await call("eth_blockNumber")))
    }

    public func balance(of address: Address, block: BlockTag = .latest) async throws -> BigUInt {
        try quantity(await call("eth_getBalance", [.string(address.hex), block.json]))
    }

    public func code(at address: Address) async throws -> Data {
        try bytes(await call("eth_getCode", [.string(address.hex), BlockTag.latest.json]))
    }

    public func transactionCount(of address: Address, block: BlockTag = .pending) async throws -> UInt64 {
        UInt64(try quantity(await call("eth_getTransactionCount", [.string(address.hex), block.json])))
    }

    public func gasPrice() async throws -> BigUInt {
        try quantity(await call("eth_gasPrice"))
    }

    public func ethCall(_ tx: CallRequest, block: BlockTag = .latest) async throws -> Data {
        try bytes(await call("eth_call", [tx.json, block.json]))
    }

    /// Several `eth_call`s in one HTTP request, each with its own block tag (multicall cannot span blocks).
    public func ethCalls(_ calls: [(CallRequest, BlockTag)]) async throws -> [Result<Data, RPCError>] {
        try await batch(calls.map { ("eth_call", [$0.0.json, $0.1.json]) }).map { result in
            result.flatMap { json in
                if let data = try? bytes(json) { return .success(data) }
                return .failure(RPCError(code: -1, message: "Malformed call result"))
            }
        }
    }

    public func estimateGas(_ tx: CallRequest) async throws -> BigUInt {
        try quantity(await call("eth_estimateGas", [tx.json]))
    }

    public func sendRawTransaction(_ signed: Data) async throws -> Data {
        try bytes(await call("eth_sendRawTransaction", [.string(signed.hexString)]))
    }

    public func transactionReceipt(_ hash: Data) async throws -> TransactionReceipt? {
        let json = try await call("eth_getTransactionReceipt", [.string(hash.hexString)])
        if json.isNull { return nil }
        guard let status = json["status"].string, let block = json["blockNumber"].string, let gasUsed = json["gasUsed"].string else { throw NetworkError.malformedResponse }
        return TransactionReceipt(hash: hash, success: status == "0x1", blockNumber: UInt64(BigUInt(hexQuantity: block) ?? 0), gasUsed: BigUInt(hexQuantity: gasUsed) ?? 0)
    }

    /// Polls until the transaction is mined. Monad blocks every ~0.4 s, so the interval is short.
    public func waitForReceipt(_ hash: Data, timeout: TimeInterval = 90) async throws -> TransactionReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let receipt = try await transactionReceipt(hash) { return receipt }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TransactionError.timedOut(hash)
    }

    // MARK: Parsing

    private func quantity(_ json: JSON) throws -> BigUInt {
        guard let s = json.string, let value = BigUInt(hexQuantity: s) else { throw NetworkError.malformedResponse }
        return value
    }

    private func bytes(_ json: JSON) throws -> Data {
        guard let s = json.string, let data = Data(hex: s) else { throw NetworkError.malformedResponse }
        return data
    }
}

public enum BlockTag: Sendable, Equatable {
    case latest
    case pending
    case number(UInt64)

    var json: JSON {
        switch self {
        case .latest: return .string("latest")
        case .pending: return .string("pending")
        case .number(let n): return .string(BigUInt(n).hexQuantity)
        }
    }
}

/// The parameters of `eth_call` / `eth_estimateGas` / a transaction to sign.
public struct CallRequest: Sendable, Equatable {
    public var from: Address?
    public var to: Address
    public var data: Data
    public var value: BigUInt

    public init(from: Address? = nil, to: Address, data: Data = Data(), value: BigUInt = 0) {
        self.from = from
        self.to = to
        self.data = data
        self.value = value
    }

    var json: JSON {
        var o: [String: JSON] = ["to": .string(to.hex), "data": .string(data.hexString)]
        if let from { o["from"] = .string(from.hex) }
        if value > 0 { o["value"] = .string(value.hexQuantity) }
        return .object(o)
    }
}

public struct TransactionReceipt: Sendable, Equatable {
    public let hash: Data
    public let success: Bool
    public let blockNumber: UInt64
    public let gasUsed: BigUInt
}

public enum TransactionError: Error, LocalizedError {
    case timedOut(Data)
    case reverted(Data)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "The transaction was sent but has not been confirmed yet."
        case .reverted: return "The transaction was mined but reverted."
        case .rejected(let reason): return reason
        }
    }
}
