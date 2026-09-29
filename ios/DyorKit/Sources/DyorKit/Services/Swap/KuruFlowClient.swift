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
        // A retired Moment coin never reaches the API: its calldata comes back ready-made, so refuse before asking.
        try SwapEngine.ensureTradable([req.tokenIn.address, req.tokenOut.address])
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
        guard let to = transaction["to"].string.flatMap({ Address($0) }) else { throw SwapError.venue("Kuru Flow returned an invalid transaction.") }
        // The calldata may come without the 0x prefix.
        var calldataHex = transaction["calldata"].string ?? ""
        if !calldataHex.hasPrefix("0x") { calldataHex = "0x" + calldataHex }
        guard let calldata = Data(hex: calldataHex) else { throw SwapError.venue("Kuru Flow returned an invalid transaction.") }
        // Never approve or call a contract the API chose: the only acceptable target is Kuru Flow's entrypoint (verified
        // live — native and ERC-20 routes both go through it), and the value must be exactly the input for a native
        // swap and zero otherwise. A compromised or spoofed API could otherwise point the approval at a drainer.
        let value = Self.quantity(transaction["value"]) ?? 0
        guard to == Kuru.entrypoint, value == (req.tokenIn.isNative ? req.amountIn : 0) else {
            throw SwapError.venue("Kuru Flow returned an unexpected transaction, so it was blocked for your safety.")
        }
        // Kuru chooses the route, so an ordinary pair could still hop through a retired cohort's coin or pool.
        try SwapEngine.ensureNoRetired(in: calldata)
        // Nor trust what the API says the calldata does: decode it (`KuruFlowSwap`) for every account, not only a passkey
        // account's session. It must pay this account, trade exactly the requested amount of the requested tokens, and
        // enforce at least the minimum the requested slippage allows on the quoted output — the one the sheet shows. A
        // spoofed API that inflated `output` to win the best-price race then only builds a swap that reverts.
        // The app never asks for an integrator or referral fee either, so a fee tuple with any basis points is a skim the
        // API slipped in (`KuruFlowSwap.takesNoFee`, the web's `kuruFeeAllowed`; IOST-7).
        let slippage = min(10_000, max(1, req.slippageBps)) // as sent
        guard let swap = KuruFlowSwap(calldata: calldata), (swap.recipient ?? user) == user,
              swap.tokenIn == (req.tokenIn.isNative ? Address.zero : req.tokenIn.address),
              swap.tokenOut == (req.tokenOut.isNative ? Address.zero : req.tokenOut.address),
              swap.amountIn == req.amountIn, swap.minAmountOut >= SwapMath.minAfterSlippage(amountOut, bps: slippage), swap.takesNoFee else {
            throw SwapError.venue("Kuru Flow returned an unexpected transaction, so it was blocked for your safety.")
        }
        let minOut = swap.minAmountOut
        let tx = TransactionRequest(to: to, data: calldata, value: value)
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

/// A swap call on the KuruFlowEntrypoint, decoded from the ready-made calldata the Flow API returns, so the wallet can
/// check what it signs rather than trusting the API (MERA-PLAN §3). Kuru publishes no ABI and the contract is not
/// source-verified; this layout was read from its bytecode (2026-09-25) and matches live mainnet swaps:
///
///     0xce1e7030  (address tokenOut, uint256 minAmountOut, address tokenIn, uint256 amountIn,
///                  (address feeRecipient, uint256 feeBps, address referrer, uint256 referrerFeeBps, bool feeOnOutput),
///                  bytes route)                                   → output paid to msg.sender
///     0x31343b21  the same arguments, then (address recipient)    → output paid to `recipient`
///
/// Native MON is the zero address on either side. The entrypoint pulls `amountIn` of `tokenIn` from the caller (or
/// takes it as `msg.value`), runs `route` through its router, takes any fees, and reverts unless what is left for the
/// recipient is at least `minAmountOut` — so the minimum holds net of fees, whichever side they come from. Decoded the
/// same way as the web app's `decodeKuruFlowSwap` (app/lib/swap/kuru.ts).
public struct KuruFlowSwap: Sendable, Equatable {
    /// The selectors, as found in the contract's dispatcher (no public signature text exists for them).
    public static let payCaller = Data([0xce, 0x1e, 0x70, 0x30])
    public static let payRecipient = Data([0x31, 0x34, 0x3b, 0x21])

    /// The fee tuple `(feeRecipient, feeBps, referrer, referrerFeeBps, feeOnOutput)`.
    public struct Fee: Sendable, Equatable {
        public let recipient: Address
        public let bps: BigUInt
        public let referrer: Address
        public let referrerBps: BigUInt
        public let onOutput: Bool

        public init(recipient: Address, bps: BigUInt, referrer: Address, referrerBps: BigUInt, onOutput: Bool) {
            self.recipient = recipient
            self.bps = bps
            self.referrer = referrer
            self.referrerBps = referrerBps
            self.onOutput = onOutput
        }
    }

    public let tokenOut: Address
    public let minAmountOut: BigUInt
    public let tokenIn: Address
    public let amountIn: BigUInt
    public let fee: Fee
    /// Who receives the output: nil for the variant that pays `msg.sender`, i.e. the account that signs the call.
    public let recipient: Address?

    /// Whether the fee tuple is one the wallet signs, as the web's `kuruFeeAllowed` rules (IOST-7): no basis points on
    /// either side. The app never asks Kuru for an integrator or referral fee (the quote request carries no referrer
    /// fields), so any is a skim a spoofed or compromised API slipped in; the entrypoint enforces the minimum net of fees,
    /// so it could take at most the slippage tolerance, but it is refused outright. The recipient and referrer addresses
    /// are not pinned: at zero basis points they receive nothing.
    public var takesNoFee: Bool { fee.bps == 0 && fee.referrerBps == 0 }

    /// Nil for any other selector, a short or malformed payload, an address word with dirty high bytes (which the
    /// contract would reject anyway), or a fee flag that is not a clean bool.
    public init?(calldata: Data) {
        let data = Data(calldata)
        guard data.count >= 4 else { return nil }
        let selector = data.prefix(4)
        let explicitRecipient: Bool
        if selector == Self.payCaller { explicitRecipient = false } else if selector == Self.payRecipient { explicitRecipient = true } else { return nil }
        let args = ABIWords(data.dropFirst(4))
        // Ten head words (four scalars, the five-word fee tuple, the route's offset), plus the recipient.
        guard args.count >= (explicitRecipient ? 11 : 10), let tokenOut = args.address(0), let minOut = args.uint(1),
              let tokenIn = args.address(2), let amountIn = args.uint(3),
              let feeRecipient = args.address(4), let feeBps = args.uint(5), let referrer = args.address(6), let referrerBps = args.uint(7),
              let onOutput = args.uint(8), onOutput <= 1 else { return nil }
        self.tokenOut = tokenOut
        minAmountOut = minOut
        self.tokenIn = tokenIn
        self.amountIn = amountIn
        fee = Fee(recipient: feeRecipient, bps: feeBps, referrer: referrer, referrerBps: referrerBps, onOutput: onOutput == 1)
        if explicitRecipient {
            guard let recipient = args.address(10) else { return nil }
            self.recipient = recipient
        } else {
            recipient = nil
        }
    }
}

/// Reads a calldata payload (the arguments after the selector) as 32-byte ABI words, rejecting what a strict decoder
/// would: a word past the end, or an address word whose high 12 bytes aren't zero.
struct ABIWords {
    let data: Data

    init(_ data: Data) { self.data = Data(data) }

    var count: Int { data.count / 32 }

    func word(_ index: Int) -> Data? {
        guard index >= 0, (index + 1) * 32 <= data.count else { return nil }
        return data.subdata(in: index * 32..<(index + 1) * 32)
    }

    func uint(_ index: Int) -> BigUInt? { word(index).map { BigUInt($0) } }

    func address(_ index: Int) -> Address? {
        guard let word = word(index), word.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
        return Address(data: Data(word.suffix(20)))
    }
}
