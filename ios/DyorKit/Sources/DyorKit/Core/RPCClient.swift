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

/// Ethereum JSON-RPC over HTTPS with request batching and endpoint failover. `urls` are tried in order when an
/// endpoint fails at the transport level or answers HTTP 429 / 5xx, and calls an endpoint throttles inside an HTTP 200
/// are re-sent to the next endpoint, so one throttled or down public endpoint never takes the app offline. After a
/// failover the answering endpoint is preferred for 30 s, then the primary is tried again. Batches are split into
/// requests of at most `maxBatch` calls.
public actor RPCClient {
    /// The primary endpoint — shown in Settings and handed to Privy's embedded wallet.
    public let url: URL
    public let urls: [URL]
    private let session: URLSession
    private let maxBatch: Int
    private var nextId = 1
    private var preferred = 0
    private var preferredSince = Date.distantPast
    private static let stickiness: TimeInterval = 30

    public init(url: URL, session: URLSession = .shared, maxBatch: Int = 100) {
        self.url = url
        self.urls = [url]
        self.session = session
        self.maxBatch = max(1, maxBatch)
    }

    /// Several interchangeable endpoints for the same chain, in preference order.
    public init(urls: [URL], session: URLSession = .shared, maxBatch: Int = 100) {
        precondition(!urls.isEmpty, "RPCClient needs at least one endpoint")
        self.url = urls[0]
        self.urls = urls
        self.session = session
        self.maxBatch = max(1, maxBatch)
    }

    // MARK: Raw calls

    public func call(_ method: String, _ params: [JSON] = []) async throws -> JSON {
        let results = try await batch([(method, params)])
        return try results[0].get()
    }

    /// Sends several requests, `maxBatch` per HTTP round trip. Results keep the request order.
    public func batch(_ calls: [(method: String, params: [JSON])]) async throws -> [Result<JSON, RPCError>] {
        guard !calls.isEmpty else { return [] }
        guard calls.count > maxBatch else { return try await batchChunk(calls) }
        var results: [Result<JSON, RPCError>] = []
        results.reserveCapacity(calls.count)
        var start = 0
        while start < calls.count {
            let end = min(start + maxBatch, calls.count)
            results += try await batchChunk(Array(calls[start..<end]))
            start = end
        }
        return results
    }

    /// Whether an HTTP status means "this endpoint, not this request" — worth retrying on the next endpoint.
    static func shouldFailOver(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

    /// POSTs `body` to the preferred endpoint, failing over to the next on a transport error or a 429 / 5xx answer.
    /// When every endpoint is throttling at once (a burst, measured on the live public endpoints) it backs off and tries
    /// again in bounded rounds; when every endpoint is simply unreachable (offline) it fails at once instead. Any other
    /// status is the answer about this request: no other endpoint is asked, and its body is returned with it (`exchange`).
    private func post(_ body: Data) async throws -> (data: Data, status: Int) {
        if preferred != 0, Date().timeIntervalSince(preferredSince) > Self.stickiness { preferred = 0 }
        var failure: Error = NetworkError.malformedResponse
        for round in 0...Self.throttleRetries {
            if round > 0 { try await Task.sleep(for: .milliseconds(400 * round)) }
            var throttled = false
            for attempt in 0..<urls.count {
                let index = (preferred + attempt) % urls.count
                var request = URLRequest(url: urls[index])
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.httpBody = body
                request.timeoutInterval = 30
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    // A cancelled task must stop here, not go on to hit the next endpoint.
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw NetworkError.transport(error) }
                    failure = NetworkError.transport(error)
                    continue
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    failure = NetworkError.badStatus(http.statusCode)
                    if Self.shouldFailOver(status: http.statusCode) { throttled = true; continue }
                    return (data, http.statusCode)
                }
                if index != preferred { preferred = index; preferredSince = Date() }
                return (data, 200)
            }
            if !throttled { break } // nothing answered at all (offline / unreachable): waiting won't help
        }
        throw failure
    }

    /// Whether a per-call error is the endpoint throttling us rather than an answer about the call itself. Public
    /// endpoints report throttling inside an HTTP 200: QuickNode's rpc.monad.xyz counts batch items (≤ 50/s) and fails
    /// the overflow items with "50/second request limit reached"; others use code -32005 / 429 or "rate limit" text.
    /// Deliberately narrow: execution reverts, gas and nonce errors never match.
    static func isRateLimited(_ error: RPCError) -> Bool {
        if error.code == 429 || error.code == -32005 { return true }
        let message = error.message.lowercased()
        return message.contains("request limit") || message.contains("rate limit") || message.contains("too many requests")
            || message.contains("per second") || message.contains("throughput")
    }

    /// One batch, plus bounded retries of just the calls the endpoint throttled: each retry goes to the next endpoint
    /// (the public endpoints limit differently — items vs. requests — so the other one usually has room), with a short
    /// backoff from the second retry on. A throttled call is never executed, so re-sending it is always safe.
    private func batchChunk(_ calls: [(method: String, params: [JSON])]) async throws -> [Result<JSON, RPCError>] {
        var results = try await exchange(calls)
        var throttled = results.indices.filter { if case .failure(let e) = results[$0] { return Self.isRateLimited(e) }; return false }
        var round = 0
        while !throttled.isEmpty, round < Self.throttleRetries {
            round += 1
            if urls.count > 1 { preferred = (preferred + 1) % urls.count; preferredSince = Date() }
            if round > 1 { try await Task.sleep(for: .milliseconds(350 * (round - 1))) }
            let retried = try await exchange(throttled.map { calls[$0] })
            for (k, i) in throttled.enumerated() { results[i] = retried[k] }
            throttled = throttled.filter { if case .failure(let e) = results[$0] { return Self.isRateLimited(e) }; return false }
        }
        return results
    }

    private static let throttleRetries = 4

    /// Whether `body` answers every call of a request with ids `ids` with a JSON-RPC error: one error object for a single
    /// call, an array of them for a batch.
    static func isErrorAnswer(_ body: JSON, ids: Range<Int>, single: Bool) -> Bool {
        let responses = single ? [body] : (body.array ?? [])
        guard responses.count == ids.count else { return false }
        let answered = responses.compactMap { response -> Int? in
            guard response["error"]["code"].number != nil || response["error"]["message"].string != nil else { return nil }
            return response["id"].number.flatMap { Int(exactly: $0) }
        }
        return Set(answered) == Set(ids) && answered.count == ids.count
    }

    /// Sends `calls` as one JSON-RPC request (with endpoint failover) and maps the answers back to request order.
    private func exchange(_ calls: [(method: String, params: [JSON])]) async throws -> [Result<JSON, RPCError>] {
        var payload: [JSON] = []
        let firstId = nextId
        for (i, call) in calls.enumerated() {
            payload.append(.object(["jsonrpc": .string("2.0"), "id": .number(Double(firstId + i)), "method": .string(call.method), "params": .array(call.params)]))
        }
        nextId += calls.count

        let (data, status) = try await post(try JSONEncoder().encode(calls.count == 1 ? payload[0] : .array(payload)))
        let decoded: JSON
        if (200..<300).contains(status) {
            decoded = try JSONDecoder().decode(JSON.self, from: data)
        } else {
            // A request error whose body is the JSON-RPC error of every call in it is that error, as an HTTP 200 would carry
            // it: rpc1 refuses a single-object `eth_getLogs` over its log cap as HTTP 400 (the same call in a one-item
            // array: HTTP 200), and rpc.monad.xyz and rpc4 a range over theirs as HTTP 413, each naming what it can answer
            // in the error (`RPCClient.refusesSize`). Any other body is the status.
            guard (400..<500).contains(status), let body = try? JSONDecoder().decode(JSON.self, from: data),
                  Self.isErrorAnswer(body, ids: firstId..<(firstId + calls.count), single: calls.count == 1)
            else { throw NetworkError.badStatus(status) }
            decoded = body
        }
        let responses = calls.count == 1 ? [decoded] : (decoded.array ?? [])
        guard responses.count == calls.count else { throw NetworkError.malformedResponse }

        var byId: [Int: JSON] = [:]
        // `Int(exactly:)`: a hostile or broken RPC can send any JSON number as an id; a non-integer one matches nothing.
        for r in responses { if let id = r["id"].number, let key = Int(exactly: id) { byId[key] = r } }
        return (0..<calls.count).map { i in
            guard let r = byId[firstId + i] else { return .failure(RPCError(code: -1, message: "Missing response")) }
            let error = r["error"]
            if !error.isNull {
                return .failure(RPCError(code: error["code"].number.flatMap { Int(exactly: $0) } ?? -1, message: error["message"].string ?? "RPC error", data: error["data"].string))
            }
            return .success(r["result"])
        }
    }

    // MARK: Typed helpers

    // Quantities from the RPC are converted with `init(exactly:)`: an out-of-range answer is a malformed response, not a
    // crash.
    public func chainId() async throws -> Int {
        let raw = try quantity(await call("eth_chainId"))
        guard let id = Int(exactly: raw) else { throw NetworkError.malformedResponse }
        return id
    }

    public func blockNumber() async throws -> UInt64 {
        let raw = try quantity(await call("eth_blockNumber"))
        guard let number = UInt64(exactly: raw) else { throw NetworkError.malformedResponse }
        return number
    }

    public func balance(of address: Address, block: BlockTag = .latest) async throws -> BigUInt {
        try quantity(await call("eth_getBalance", [.string(address.hex), block.json]))
    }

    public func code(at address: Address) async throws -> Data {
        try bytes(await call("eth_getCode", [.string(address.hex), BlockTag.latest.json]))
    }

    public func transactionCount(of address: Address, block: BlockTag = .pending) async throws -> UInt64 {
        let raw = try quantity(await call("eth_getTransactionCount", [.string(address.hex), block.json]))
        guard let count = UInt64(exactly: raw) else { throw NetworkError.malformedResponse }
        return count
    }

    public func gasPrice() async throws -> BigUInt {
        try quantity(await call("eth_gasPrice"))
    }

    /// The node's suggested EIP-1559 tip.
    public func maxPriorityFeePerGas() async throws -> BigUInt {
        try quantity(await call("eth_maxPriorityFeePerGas"))
    }

    /// The latest block's base fee, or nil on a chain without EIP-1559.
    public func latestBaseFee() async throws -> BigUInt? {
        let json = try await call("eth_getBlockByNumber", [BlockTag.latest.json, .bool(false)])
        guard let hex = json["baseFeePerGas"].string else { return nil }
        return BigUInt(hexQuantity: hex)
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

    /// Submits a signed transaction and returns its hash. The hash is keccak-256 of the signed bytes, computed here
    /// rather than taken from the node's answer, so what the app follows is always the transaction it signed. When the
    /// network says it already has this exact transaction — a failover resend after the first endpoint accepted it but
    /// its answer was lost — that is success, not an error. "Nonce too low" is success only if this very transaction is
    /// known; otherwise another transaction used the nonce and the error stands.
    public func sendRawTransaction(_ signed: Data) async throws -> Data {
        let hash = Keccak.hash256(signed)
        do {
            guard try bytes(await call("eth_sendRawTransaction", [.string(signed.hexString)])).count == 32 else { throw NetworkError.malformedResponse }
            return hash
        } catch let error as RPCError {
            let message = error.message.lowercased()
            if message.contains("already known") || message.contains("known transaction") || message.contains("already imported") { return hash }
            if message.contains("nonce too low"), let known = try? await call("eth_getTransactionByHash", [.string(hash.hexString)]), !known.isNull { return hash }
            throw error
        }
    }

    /// Whether the network has this transaction: mined (a receipt) or waiting (`eth_getTransactionByHash`). Nil when
    /// neither read got an answer, which says nothing either way.
    public func knowsTransaction(_ hash: Data) async -> Bool? {
        var answered = false
        do {
            if try await transactionReceipt(hash) != nil { return true }
            answered = true
        } catch {}
        do {
            let pending = try await call("eth_getTransactionByHash", [.string(hash.hexString)])
            if !pending.isNull { return true }
            answered = true
        } catch {}
        return answered ? false : nil
    }

    public func transactionReceipt(_ hash: Data) async throws -> TransactionReceipt? {
        let json = try await call("eth_getTransactionReceipt", [.string(hash.hexString)])
        if json.isNull { return nil }
        guard let status = json["status"].string, let block = json["blockNumber"].string, let gasUsed = json["gasUsed"].string else { throw NetworkError.malformedResponse }
        return TransactionReceipt(hash: hash, success: status == "0x1", blockNumber: UInt64(exactly: BigUInt(hexQuantity: block) ?? 0) ?? 0, gasUsed: BigUInt(hexQuantity: gasUsed) ?? 0)
    }

    /// Polls until the transaction is mined. Monad blocks every ~0.4 s, so the interval is short. The budget is a number
    /// of polls (180 × 500 ms, about 90 s of running), not a wall-clock deadline: a run the system suspended (the phone
    /// locked mid-plan) resumes with the polls it had left instead of finding its deadline gone and reporting a mined
    /// transaction as unconfirmed. One last read always follows the final wait.
    public func waitForReceipt(_ hash: Data, polls: Int = 180, interval: Duration = .milliseconds(500)) async throws -> TransactionReceipt {
        for _ in 0..<max(1, polls) {
            if let receipt = try await pollReceipt(hash) { return receipt }
            try await Task.sleep(for: interval)
        }
        if let receipt = try await pollReceipt(hash) { return receipt }
        throw TransactionError.timedOut(hash)
    }

    /// One receipt read, nil while the transaction is pending. A failed read (a dropped connection on resume, every
    /// endpoint throttled, a malformed answer) says nothing about a transaction that is already broadcast, so it is
    /// also nil — never a failure the user would answer by sending it again. Only cancellation throws.
    private func pollReceipt(_ hash: Data) async throws -> TransactionReceipt? {
        do {
            return try await transactionReceipt(hash)
        } catch let error as CancellationError {
            throw error
        } catch {
            try Task.checkCancellation()
            return nil
        }
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
    /// Signed and handed to the network, but no endpoint's answer arrived to say it was taken: it may be live. Follow
    /// this hash; never sign a replacement for it.
    case possiblySent(Data)

    /// Sent — or possibly sent — with no confirmation seen.
    public static let unconfirmed = "Sent — confirmation not seen yet. Check it before trying again."

    public var errorDescription: String? {
        switch self {
        case .timedOut, .possiblySent: return Self.unconfirmed
        case .reverted: return "The transaction was mined but reverted."
        case .rejected(let reason): return reason
        }
    }

    /// The transaction this error is about, when it has one.
    public var hash: Data? {
        switch self {
        case .timedOut(let hash), .reverted(let hash), .possiblySent(let hash): return hash
        case .rejected: return nil
        }
    }
}
