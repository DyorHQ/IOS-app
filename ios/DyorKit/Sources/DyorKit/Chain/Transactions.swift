import BigInt
import Foundation

/// A transaction the app wants to send, before nonce, gas and fees are filled in.
public struct TransactionRequest: Sendable, Equatable {
    public var to: Address
    public var data: Data
    public var value: BigUInt

    public init(to: Address, data: Data = Data(), value: BigUInt = 0) {
        self.to = to
        self.data = data
        self.value = value
    }
}

/// Everything a signer needs for an EIP-1559 transaction on Monad.
public struct PreparedTransaction: Sendable, Equatable {
    public let from: Address
    public let to: Address
    public let data: Data
    public let value: BigUInt
    public let nonce: UInt64
    public let gasLimit: BigUInt
    public let maxFeePerGas: BigUInt
    public let maxPriorityFeePerGas: BigUInt
    public let chainId: Int
}

/// The app's one signing abstraction. Privy's embedded wallet and any future passkey wallet both fit behind it,
/// so screens never know which is in use.
public protocol Wallet: Sendable {
    var address: Address { get }
    /// Signs and returns the raw RLP-encoded transaction (`0x02…`), ready for `eth_sendRawTransaction`.
    func sign(_ transaction: PreparedTransaction) async throws -> Data
    /// EIP-191 personal message signature.
    func signMessage(_ message: Data) async throws -> Data
}

public struct TransactionStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approve(token: Address, spender: Address, amount: BigUInt)
        /// A Permit2 allowance of `amount` for `spender` that expires `lifetime` seconds after the step is sent. The
        /// expiration is set when the step runs, not when the plan is built, so a sheet left open never sends one that
        /// is already stale; skipped when the existing allowance covers `amount` for at least another minute.
        case permit2Approve(token: Address, spender: Address, amount: BigUInt, lifetime: Int)
        case call
    }
    public let kind: Kind
    public let request: TransactionRequest?
    public let label: String

    public static func approve(token: Address, spender: Address, amount: BigUInt, label: String) -> TransactionStep {
        TransactionStep(kind: .approve(token: token, spender: spender, amount: amount), request: nil, label: label)
    }

    public static func permit2Approve(token: Address, spender: Address, amount: BigUInt, lifetime: Int, label: String) -> TransactionStep {
        TransactionStep(kind: .permit2Approve(token: token, spender: spender, amount: amount, lifetime: lifetime), request: nil, label: label)
    }

    /// The transaction this step sends when it runs at `now` (an approval becomes its `approve` call). Nil for a call
    /// step without a request. For previews: at run time an approval the allowance already covers is skipped.
    public func request(at now: Date = Date()) throws -> TransactionRequest? {
        switch kind {
        case .approve(let token, let spender, let amount):
            return TransactionRequest(to: token, data: try ERC20.approveCalldata(spender: spender, amount: amount))
        case .permit2Approve(let token, let spender, let amount, let lifetime):
            let expiration = BigUInt(Int(now.timeIntervalSince1970) + lifetime)
            return TransactionRequest(to: Uniswap.permit2, data: try SwapCalldata.permit2Approve(token: token, spender: spender, amount: amount, expiration: expiration))
        case .call:
            return request
        }
    }

    public static func call(_ request: TransactionRequest, label: String) -> TransactionStep {
        TransactionStep(kind: .call, request: request, label: label)
    }
}

public enum TransactionEvent: Sendable, Equatable {
    case preparing(String)
    case sent(String, Data)
    case confirmed(String, Data)
}

/// Prepares, simulates, signs, broadcasts and confirms transactions. Monad charges for the gas *limit*, so the
/// limit is the estimate plus a small margin rather than a generous round number.
public struct TransactionSender: Sendable {
    public let rpc: RPCClient
    public let multicall: Multicall
    /// The EVM chain this sender signs for. Defaults to Monad so every existing caller is unchanged; the Bridge
    /// builds a sender per source chain (Ethereum, Base, …) with that chain's id and RPC so the same wallet key
    /// signs a valid transaction there.
    public let chainId: Int
    /// How long the Monad reserve-balance waits poll and give up (MERA-PLAN §5). Tests shorten them.
    var timing = Timing()

    struct Timing: Sendable {
        /// Between `eth_blockNumber` reads while a MON-sending step waits out the 3-block spacing (blocks are ~0.4 s).
        var blockPoll: Duration = .milliseconds(150)
        /// The spacing wait gives up and sends anyway after this: a node whose head stalls (or a local fork that only
        /// mines on demand) must never hang a plan.
        var spacingTimeout: Duration = .seconds(5)
        /// Before resending a transaction Monad refused because the account's funding is still settling.
        var fundingRetry: Duration = .seconds(1)
    }

    public init(rpc: RPCClient, chainId: Int = Monad.chainId) {
        self.rpc = rpc
        multicall = Multicall(rpc: rpc)
        self.chainId = chainId
    }

    public func prepare(_ request: TransactionRequest, from wallet: Wallet) async throws -> PreparedTransaction {
        let call = CallRequest(from: wallet.address, to: request.to, data: request.data, value: request.value)
        // Simulate first so a revert surfaces as a readable error before the wallet is asked to sign.
        do {
            _ = try await rpc.ethCall(call)
        } catch let error as RPCError {
            throw TransactionError.rejected(RevertReason.describe(error))
        }
        async let nonce = rpc.transactionCount(of: wallet.address)
        async let estimate = rpc.estimateGas(call)
        async let fees = feeParameters()
        let gasLimit = Self.gasLimit(estimate: try await estimate)
        let (maxFee, tip) = try await fees
        return PreparedTransaction(from: wallet.address, to: request.to, data: request.data, value: request.value, nonce: try await nonce, gasLimit: gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip, chainId: chainId)
    }

    /// The node's estimate plus 20%: the limit every prepared transaction carries.
    static func gasLimit(estimate: BigUInt) -> BigUInt { estimate * 120 / 100 }

    /// The gas limit `prepare` would set for `request` sent from `from`, or nil when the node can't estimate it (a
    /// revert, an unreachable RPC). For sizing a "Max" before the transaction exists.
    public func gasLimit(for request: TransactionRequest, from: Address) async -> BigUInt? {
        guard let estimate = try? await rpc.estimateGas(CallRequest(from: from, to: request.to, data: request.data, value: request.value)) else { return nil }
        return Self.gasLimit(estimate: estimate)
    }

    /// What a transaction of `gasLimit` may be charged up front on this chain today: `gasLimit × (2 × base + tip)`,
    /// the max fee `prepare` sets, with `NetworkFeeReserve`'s headroom. The chain's fallback when the RPC can't answer.
    public func feeReserve(gasLimit: BigUInt) async -> BigUInt {
        guard let fees = try? await feeParameters() else { return NetworkFeeReserve.fallback(chainId: chainId) }
        return NetworkFeeReserve.amount(gasLimit: gasLimit, maxFeePerGas: fees.maxFee, chainId: chainId)
    }

    /// The most of a native `balance` a "Max" can send and still pay the network fee (MERA-PLAN §5). The gas limit is
    /// estimated from `request` when there is one to estimate (a route on screen, a transfer to a known address), and
    /// is `budget` otherwise. Zero when the fee takes the whole balance.
    public func maxValue(balance: BigUInt, like request: TransactionRequest?, from: Address?, budget: BigUInt) async -> BigUInt {
        var limit = budget
        if let request, let from, let estimate = await gasLimit(for: request, from: from) { limit = estimate }
        return NetworkFeeReserve.spendable(balance: balance, reserve: await feeReserve(gasLimit: limit))
    }

    /// EIP-1559 fees: the node's suggested tip, with a max fee of twice the base fee plus that tip so the transaction
    /// still lands if the base fee doubles. Monad charges gas limit × min(maxFee, base + tip); tipping the whole gas
    /// price (the old rule) roughly doubled every fee there. Falls back to the gas price when a node can't answer.
    func feeParameters() async throws -> (maxFee: BigUInt, tip: BigUInt) {
        async let baseFee = rpc.latestBaseFee()
        async let suggestedTip = rpc.maxPriorityFeePerGas()
        let base = (try? await baseFee) ?? nil
        let tip = try? await suggestedTip
        if let base, let tip { return (base * 2 + tip, tip) }
        let price = try await rpc.gasPrice()
        return (price * 2, price)
    }

    public func send(_ request: TransactionRequest, from wallet: Wallet) async throws -> Data {
        let prepared = try await prepare(request, from: wallet)
        let signed = try await wallet.sign(prepared)
        return try await broadcast(signed, prepared)
    }

    /// Monad's consensus checks a sender's balance as of a few blocks back, so a transaction from an account funded
    /// less than 3 blocks ago is refused with "Signer had insufficient balance" although the funds are visible. The
    /// same signed bytes are sent once more after ~1 s (no second signature, so no second Face ID). If the node still
    /// refuses, the message says what is true: the funds are still settling, or the balance doesn't cover the value
    /// plus the fee.
    func broadcast(_ signed: Data, _ transaction: PreparedTransaction) async throws -> Data {
        guard chainId == Monad.chainId else { return try await rpc.sendRawTransaction(signed) }
        do {
            return try await rpc.sendRawTransaction(signed)
        } catch let error as RPCError where Self.isFundingInFlight(error) {
            try await Task.sleep(for: timing.fundingRetry)
            do {
                return try await rpc.sendRawTransaction(signed)
            } catch let error as RPCError where Self.isFundingInFlight(error) {
                throw TransactionError.rejected(await fundingRefusal(transaction))
            }
        }
    }

    /// Monad's refusal for a balance its consensus can't see yet. Other chains say "insufficient funds", which is a
    /// real shortfall and stays one.
    static func isFundingInFlight(_ error: RPCError) -> Bool {
        error.message.localizedCaseInsensitiveContains("insufficient balance")
    }

    static let fundsArriving = "Your funds are still arriving. Try again in a moment."

    /// "Still arriving" when the latest balance covers the value and the most the fee can be; otherwise the account is
    /// really short, and saying the funds are on their way would be false.
    private func fundingRefusal(_ transaction: PreparedTransaction) async -> String {
        guard let balance = try? await rpc.balance(of: transaction.from) else { return Self.fundsArriving }
        let cost = transaction.value + transaction.gasLimit * transaction.maxFeePerGas
        return balance >= cost ? Self.fundsArriving : "Not enough MON to pay for gas."
    }

    /// Monad's reserve balance: while an account holds under 10 MON plus what a transaction sends, that transaction
    /// reverts unless it is the sender's first in 3 blocks.
    public static let monadReserveBalance = BigUInt(10).power(19)
    static let reserveSpacingBlocks: UInt64 = 3

    /// Before a step that sends MON on Monad, when the account is under the reserve (10 MON + the value): waits until
    /// the head is 3 blocks past the block that confirmed this run's previous step (MERA-PLAN §5). The at-risk plan is
    /// an ERC-20-pair launch with a creator buy (approve, then `launchAndBuy` with its 5 MON fee). A first step, a step
    /// without value, a well-funded account and every other chain go straight on. A balance that can't be read counts
    /// as under the reserve; a head that doesn't move gives up after `timing.spacingTimeout` and sends anyway.
    func waitForReserveSpacing(value: BigUInt, after previousBlock: UInt64?, from address: Address) async throws {
        guard chainId == Monad.chainId, value > 0, let previousBlock else { return }
        if let balance = try? await rpc.balance(of: address), balance >= Self.monadReserveBalance + value { return }
        let target = previousBlock + Self.reserveSpacingBlocks
        let deadline = ContinuousClock.now + timing.spacingTimeout
        while ContinuousClock.now < deadline {
            if let head = try? await rpc.blockNumber(), head >= target { return }
            try await Task.sleep(for: timing.blockPoll)
        }
    }

    /// Runs a plan step by step. Approvals are skipped when the allowance already covers the amount.
    public func run(_ steps: [TransactionStep], from wallet: Wallet, onEvent: @Sendable @escaping (TransactionEvent) -> Void) async throws -> Data {
        var last: Data?
        // The block that confirmed this run's previous step, for Monad's reserve spacing.
        var previousBlock: UInt64?
        for step in steps {
            onEvent(.preparing(step.label))
            let request: TransactionRequest
            switch step.kind {
            case .approve(let token, let spender, let amount):
                let allowance = try await multicall.readAll([try ERC20.allowance(token, owner: wallet.address, spender: spender)])[0][0].uint
                if allowance >= amount { continue }
                request = TransactionRequest(to: token, data: try ERC20.approveCalldata(spender: spender, amount: amount))
            case .permit2Approve(let token, let spender, let amount, _):
                let allowance = try await multicall.readAll([try SwapCalldata.permit2Allowance(owner: wallet.address, token: token, spender: spender)])[0]
                if allowance[0].uint >= amount, allowance[1].uint > BigUInt(Int(Date().timeIntervalSince1970) + 60) { continue }
                guard let r = try step.request(at: Date()) else { continue }
                request = r
            case .call:
                guard let r = step.request else { continue }
                request = r
            }
            try await waitForReserveSpacing(value: request.value, after: previousBlock, from: wallet.address)
            let hash = try await send(request, from: wallet)
            onEvent(.sent(step.label, hash))
            let receipt = try await rpc.waitForReceipt(hash)
            guard receipt.success else { throw TransactionError.reverted(hash) }
            onEvent(.confirmed(step.label, hash))
            last = hash
            previousBlock = receipt.blockNumber
        }
        guard let hash = last else { throw TransactionError.rejected("Nothing to send.") }
        return hash
    }
}

/// Turns node revert payloads into sentences people can act on.
public enum RevertReason {
    public static func describe(_ error: RPCError) -> String {
        if let data = error.data, let bytes = Data(hex: data), bytes.count >= 4 {
            let selector = bytes.prefix(4).hexString
            if selector == "0x08c379a0", let message = try? ABI.decode(bytes.dropFirst(4), "string")[0].string { // Error(string)
                return message
            }
            if let named = knownErrors[selector] { return named }
        }
        let message = error.message
        if message.localizedCaseInsensitiveContains("insufficient funds") { return "Not enough MON to pay for gas." }
        // "execution reverted: custom error 0xabcdef12: 0000…" — keep the selector and the payload's words as
        // numbers (usually amounts or limits), drop the wall of hex.
        if let range = message.range(of: #"custom error (0x[0-9a-fA-F]{8})"#, options: .regularExpression) {
            let selector = String(message[range]).replacingOccurrences(of: "custom error ", with: "")
            var args = ""
            let payload = error.data.flatMap { Data(hex: $0) }?.dropFirst(4) ?? Data()
            if !payload.isEmpty, payload.count % 32 == 0, payload.count <= 32 * 6 {
                let words = stride(from: payload.startIndex, to: payload.endIndex, by: 32).map { BigUInt(payload[$0..<$0 + 32]) }
                args = " with " + words.map { $0.bitWidth > 128 ? "0x" + String($0, radix: 16).prefix(10) + "…" : String($0) }.joined(separator: ", ")
            }
            return "The contract rejected the transaction (custom error \(selector)\(args))."
        }
        return message.isEmpty ? "The transaction would fail." : message
    }

    /// Custom error selectors worth naming. Extend as contracts are added.
    static let knownErrors: [String: String] = [
        ABI.selector("InsufficientGasForGraduation()").hexString: "This buy would graduate the token and needs more gas. Try again.",
    ]
}

/// EIP-1559 transaction encoding (type 2) for wallets that sign a hash rather than a JSON request.
public enum RLP {
    public static func encode(_ item: RLPItem) -> Data {
        switch item {
        case .bytes(let data):
            if data.count == 1, data[data.startIndex] < 0x80 { return data }
            return length(data.count, offset: 0x80) + data
        case .list(let items):
            let body = items.map(encode).reduce(Data(), +)
            return length(body.count, offset: 0xC0) + body
        }
    }

    private static func length(_ n: Int, offset: UInt8) -> Data {
        if n < 56 { return Data([offset + UInt8(n)]) }
        let bytes = BigUInt(n).serialize()
        return Data([offset + 55 + UInt8(bytes.count)]) + bytes
    }

    public static func quantity(_ value: BigUInt) -> RLPItem { .bytes(value == 0 ? Data() : value.serialize()) }

    /// The bytes to sign for an EIP-1559 transaction: `0x02 || rlp([chainId, nonce, priority, maxFee, gas, to, value, data, accessList])`.
    public static func unsignedPayload(_ tx: PreparedTransaction) -> Data {
        Data([0x02]) + encode(.list([
            quantity(BigUInt(tx.chainId)), quantity(BigUInt(tx.nonce)), quantity(tx.maxPriorityFeePerGas), quantity(tx.maxFeePerGas),
            quantity(tx.gasLimit), .bytes(tx.to.data), quantity(tx.value), .bytes(tx.data), .list([]),
        ]))
    }

    /// The raw transaction once `v` (0/1), `r` and `s` are known.
    public static func signedTransaction(_ tx: PreparedTransaction, v: UInt8, r: BigUInt, s: BigUInt) -> Data {
        Data([0x02]) + encode(.list([
            quantity(BigUInt(tx.chainId)), quantity(BigUInt(tx.nonce)), quantity(tx.maxPriorityFeePerGas), quantity(tx.maxFeePerGas),
            quantity(tx.gasLimit), .bytes(tx.to.data), quantity(tx.value), .bytes(tx.data), .list([]),
            quantity(BigUInt(v)), quantity(r), quantity(s),
        ]))
    }
}

public indirect enum RLPItem: Sendable, Equatable {
    case bytes(Data)
    case list([RLPItem])
}
