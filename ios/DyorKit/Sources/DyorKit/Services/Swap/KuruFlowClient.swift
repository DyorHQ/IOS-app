import BigInt
import Foundation

/// Kuru Flow: Kuru's smart aggregator over Monad's order books and pools. The API returns the expected output, a
/// minimum after slippage, and a ready transaction against the KuruFlowEntrypoint. Auth is a per-address JWT
/// (1 request/second), cached per wallet and refreshed a minute before it expires.
actor KuruFlowClient {
    private struct Credential {
        let token: String
        let expiresAt: TimeInterval
    }

    private let session: URLSession
    private var credentials: [Address: Credential] = [:]

    init(session: URLSession) { self.session = session }

    func quote(_ req: SwapRequest) async throws -> VenueQuote? {
        let user = req.account
        let body = try JSONEncoder().encode(JSON.object([
            "userAddress": .string(user.checksummed),
            "tokenIn": .string(req.tokenIn.isNative ? Address.zero.hex : req.tokenIn.address.checksummed),
            "tokenOut": .string(req.tokenOut.isNative ? Address.zero.hex : req.tokenOut.address.checksummed),
            "amount": .string(String(req.amountIn)),
            "slippageTolerance": .number(Double(min(10_000, max(1, req.slippageBps)))),
        ]))
        let (data, status) = try await post(body, user: user, retry: true)
        if status == 429 { throw SwapError.venue("Kuru Flow rate limit reached. Retrying on the next refresh.") }
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .object([:])
        guard (200..<300).contains(status) else {
            throw SwapError.venue(Self.text(json["message"]) ?? Self.text(json["error"]) ?? "Kuru Flow returned \(status).")
        }
        let transaction = json["transaction"]
        guard json["status"].string == "success", transaction.object != nil, let amountOut = Self.quantity(json["output"]) else {
            throw SwapError.venue(Self.text(json["message"]) ?? "Kuru Flow could not route this trade.")
        }
        if amountOut == 0 { return nil }
        let minOut = Self.quantity(json["minOut"]) ?? SwapMath.minAfterSlippage(amountOut, bps: req.slippageBps)
        guard let to = transaction["to"].string.flatMap({ Address($0) }) else { throw SwapError.venue("Kuru Flow returned an invalid transaction.") }
        // The calldata may come without the 0x prefix.
        var calldataHex = transaction["calldata"].string ?? ""
        if !calldataHex.hasPrefix("0x") { calldataHex = "0x" + calldataHex }
        guard let calldata = Data(hex: calldataHex) else { throw SwapError.venue("Kuru Flow returned an invalid transaction.") }
        let tx = TransactionRequest(to: to, data: calldata, value: Self.quantity(transaction["value"]) ?? 0)
        let inToken = req.tokenIn
        let amountIn = req.amountIn

        return VenueQuote(venue: .kuru, amountOut: amountOut, minOut: minOut, route: "Aggregated across Kuru order books and Monad pools", gasEstimate: nil, priceImpactBps: nil) { account in
            guard account == user else { throw SwapError.differentWallet }
            var steps: [TransactionStep] = []
            if !inToken.isNative { steps.append(.approve(token: inToken.address, spender: to, amount: amountIn, label: "Approve \(inToken.symbol) for Kuru Flow")) }
            steps.append(.call(tx, label: "Swap on Kuru Flow"))
            return steps
        }
    }

    // MARK: HTTP

    /// POSTs the quote with a bearer token; a 401 is retried once with a fresh token.
    private func post(_ body: Data, user: Address, retry: Bool) async throws -> (Data, Int) {
        let token = try await jwt(for: user)
        var request = URLRequest(url: Kuru.api.appending(path: "api/quote"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        request.timeoutInterval = 20
        let (data, status) = try await send(request)
        if status == 401, retry {
            credentials[user] = nil
            return try await post(body, user: user, retry: false)
        }
        return (data, status)
    }

    private func jwt(for address: Address) async throws -> String {
        let now = Date().timeIntervalSince1970
        if let cached = credentials[address], cached.expiresAt - 60 > now { return cached.token }
        var request = URLRequest(url: Kuru.api.appending(path: "api/generate-token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSON.object(["user_address": .string(address.checksummed)]))
        request.timeoutInterval = 20
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { throw SwapError.venue("Kuru Flow token request failed (\(status)).") }
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard let token = Self.text(json["token"]) else { throw SwapError.venue("Kuru Flow did not return an access token.") }
        let expiresAt = json["expires_at"].number ?? json["expires_at"].string.flatMap(Double.init) ?? (now + 3600)
        credentials[address] = Credential(token: token, expiresAt: expiresAt)
        return token
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NetworkError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw NetworkError.malformedResponse }
        return (data, http.statusCode)
    }

    // MARK: Parsing

    /// A non-empty string, or nil (the web app treats empty strings as absent).
    private static func text(_ json: JSON) -> String? {
        guard let s = json.string, !s.isEmpty else { return nil }
        return s
    }

    /// Kuru sends amounts as decimal strings, but hex strings and JSON numbers are accepted as JavaScript's `BigInt` would.
    private static func quantity(_ json: JSON) -> BigUInt? {
        if let s = json.string {
            if s.hasPrefix("0x") || s.hasPrefix("0X") { return BigUInt(hexQuantity: s) }
            return BigUInt(s.trimmingCharacters(in: .whitespaces), radix: 10)
        }
        if let n = json.number, n >= 0, n.rounded() == n, n < 1.8e19 { return BigUInt(UInt64(n)) }
        return nil
    }
}
