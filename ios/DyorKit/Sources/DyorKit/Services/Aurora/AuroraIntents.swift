import Foundation

/// Aurora Intents (NEAR Intents) Swap API — the cross-chain bridge behind the Home "Bridge" button. The app requests
/// a quote, sends the origin-chain deposit itself (same wallet, any EVM chain), reports the tx, then polls status.
/// The API key is a URL path segment on every call (no header); the integrator fee is configured on the key in
/// Aurora Studio. Docs: https://docs.intents.aurora.dev/api-reference/swap-api-reference.
public struct AuroraIntents: Sendable {
    public let base: URL
    public let apiKey: String
    /// Optional NEAR account to receive the integrator fee, sent as `appFees` on each quote. When nil the key's own
    /// Studio fee configuration applies instead.
    public let feeRecipient: String?
    public let feeBps: Int
    private let session: URLSession

    public init(apiKey: String,
                feeRecipient: String? = nil,
                feeBps: Int = 10,
                base: URL = URL(string: "https://intents-api.aurora.dev/api")!,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.feeRecipient = feeRecipient
        self.feeBps = feeBps
        self.base = base
        self.session = session
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: Endpoints

    /// Every supported token across every chain, each with its `blockchain`, `assetId`, `decimals` and (for ERC-20s)
    /// `contractAddress`. Public — any key value returns the global list.
    public func tokens() async throws -> [AuroraToken] {
        struct Wrap: Decodable { let tokens: [AuroraToken] }
        return try await get("tokens", as: Wrap.self).tokens
    }

    /// A quote for `amount` (smallest units of `originAsset`) into `destinationAsset`, delivered to `recipient` on the
    /// destination chain, refunded to `refundTo` on the origin chain. Returns the origin-chain deposit address to fund.
    public func quote(amount: String,
                      originAsset: String,
                      destinationAsset: String,
                      recipient: String,
                      refundTo: String,
                      slippageBps: Int) async throws -> AuroraQuote {
        let body = AuroraQuoteRequest(
            dry: false, swapType: "EXACT_INPUT", depositType: "ORIGIN_CHAIN",
            amount: amount, originAsset: originAsset, destinationAsset: destinationAsset,
            slippageTolerance: slippageBps, refundTo: refundTo, refundType: "ORIGIN_CHAIN",
            recipient: recipient, recipientType: "DESTINATION_CHAIN", referral: "dyorhq",
            appFees: feeRecipient.map { [AuroraAppFee(recipient: $0, fee: feeBps)] }
        )
        return try await post("quote", body: body, as: AuroraQuoteResponse.self).quote
    }

    /// Tells Aurora the deposit was sent, so it starts settling without waiting to observe the tx itself.
    @discardableResult
    public func submitDeposit(txHash: String, depositAddress: String, memo: String? = nil) async throws -> AuroraSwapState {
        try await post("deposit/submit", body: AuroraSubmitRequest(txHash: txHash, depositAddress: depositAddress, memo: memo), as: AuroraSwapState.self)
    }

    /// The current settlement status for a deposit address (from `PENDING_DEPOSIT` through `SUCCESS` / `REFUNDED`).
    public func status(depositAddress: String, depositMemo: String? = nil) async throws -> AuroraSwapState {
        var items = [URLQueryItem(name: "depositAddress", value: depositAddress)]
        if let depositMemo { items.append(URLQueryItem(name: "depositMemo", value: depositMemo)) }
        return try await get("status", query: items, as: AuroraSwapState.self)
    }

    // MARK: Transport

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent(path).appendingPathComponent(apiKey), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        var req = URLRequest(url: url(path, query: query))
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await run(req)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, as: T.Type) async throws -> T {
        var req = URLRequest(url: url(path))
        req.timeoutInterval = 20
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await run(req)
    }

    private func run<T: Decodable>(_ request: URLRequest) async throws -> T {
        guard isConfigured else { throw AuroraError.notConfigured }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuroraError.transport("No response") }
        guard (200..<300).contains(http.statusCode) else {
            // Surface only Aurora's decoded `message` — never the raw body, whose error shape can echo the request
            // path (which carries the API key).
            let message = (try? JSONDecoder().decode(AuroraErrorBody.self, from: data))?.message
            throw AuroraError.api(status: http.statusCode, message: message ?? "Aurora request failed (\(http.statusCode)).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AuroraError.decoding(error.localizedDescription) }
    }
}

public enum AuroraError: LocalizedError {
    case notConfigured
    case api(status: Int, message: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Bridge isn't configured yet — the Aurora API key is missing."
        case .api(_, let message): return message
        case .transport(let m): return m
        case .decoding(let m): return "Couldn't read Aurora's response: \(m)"
        }
    }
}

private struct AuroraErrorBody: Decodable { let message: String? }

// MARK: - Models

/// A token Aurora can bridge. `assetId` is Aurora's canonical id (`nep245:v2_1.omni.hot.tg:<evmChainId>_<suffix>`);
/// `contractAddress` is the ERC-20 address on `blockchain`, absent for the chain's native asset.
public struct AuroraToken: Decodable, Sendable, Hashable, Identifiable {
    public let assetId: String
    public let decimals: Int
    public let blockchain: String
    public let symbol: String
    public let contractAddress: String?
    public let price: Double?
    public var id: String { assetId }
    public var isNative: Bool { contractAddress == nil }
}

struct AuroraAppFee: Encodable, Sendable { let recipient: String; let fee: Int }

struct AuroraQuoteRequest: Encodable, Sendable {
    let dry: Bool
    let swapType: String
    let depositType: String
    let amount: String
    let originAsset: String
    let destinationAsset: String
    let slippageTolerance: Int
    let refundTo: String
    let refundType: String
    let recipient: String
    let recipientType: String
    let referral: String?
    let appFees: [AuroraAppFee]?
}

struct AuroraSubmitRequest: Encodable, Sendable {
    let txHash: String
    let depositAddress: String
    let memo: String?
}

struct AuroraQuoteResponse: Decodable, Sendable { let quote: AuroraQuote }

/// The actionable part of a quote: where to send on the origin chain, and the amounts.
public struct AuroraQuote: Decodable, Sendable {
    public let depositAddress: String?
    public let depositMemo: String?
    public let amountIn: String
    public let amountInFormatted: String?
    public let amountInUsd: String?
    public let amountOut: String
    public let amountOutFormatted: String?
    public let amountOutUsd: String?
    public let minAmountOut: String?
    public let refundFee: String?
    public let withdrawFee: String?
    public let deadline: String?
    public let timeEstimate: Double?
}

public enum AuroraSwapStatus: String, Decodable, Sendable {
    case knownDepositTx = "KNOWN_DEPOSIT_TX"
    case pendingDeposit = "PENDING_DEPOSIT"
    case incompleteDeposit = "INCOMPLETE_DEPOSIT"
    case processing = "PROCESSING"
    case success = "SUCCESS"
    case refunded = "REFUNDED"
    case failed = "FAILED"
}

public struct AuroraSwapState: Decodable, Sendable {
    public let status: AuroraSwapStatus
    public let updatedAt: String?
    public let swapDetails: AuroraSwapDetails?

    private enum CodingKeys: String, CodingKey { case status, updatedAt, swapDetails }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(AuroraSwapStatus.self, forKey: .status)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        // `swapDetails` is secondary (formatted amount, refund reason). The poll only needs `status` to advance, so a
        // decode failure or schema drift in `swapDetails` must NEVER stall settlement tracking — swallow it to nil.
        swapDetails = try? c.decodeIfPresent(AuroraSwapDetails.self, forKey: .swapDetails)
    }
}

/// A settlement transaction reference from Aurora (`{hash, explorerUrl}`).
public struct AuroraTxRef: Decodable, Sendable, Hashable {
    public let hash: String
    public let explorerUrl: String?
}

public struct AuroraSwapDetails: Decodable, Sendable {
    public let amountOutFormatted: String?
    public let amountOutUsd: String?
    /// Origin / destination settlement txs. These are arrays of OBJECTS in Aurora's schema — decoding them as
    /// `[String]` (as an earlier version did) threw a typeMismatch the moment the deposit tx was recorded, which
    /// silently stalled the status poll at "Confirming your deposit…". Keep them as `AuroraTxRef`.
    public let originChainTxHashes: [AuroraTxRef]?
    public let destinationChainTxHashes: [AuroraTxRef]?
    public let refundedAmountFormatted: String?
    public let refundReason: String?
}
