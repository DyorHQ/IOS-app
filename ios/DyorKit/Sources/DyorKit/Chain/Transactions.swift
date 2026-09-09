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
    public enum Kind: Sendable, Equatable { case approve(token: Address, spender: Address, amount: BigUInt), call }
    public let kind: Kind
    public let request: TransactionRequest?
    public let label: String

    public static func approve(token: Address, spender: Address, amount: BigUInt, label: String) -> TransactionStep {
        TransactionStep(kind: .approve(token: token, spender: spender, amount: amount), request: nil, label: label)
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

    public init(rpc: RPCClient) {
        self.rpc = rpc
        multicall = Multicall(rpc: rpc)
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
        async let gasPrice = rpc.gasPrice()
        let gasLimit = try await estimate * 120 / 100
        let fee = try await gasPrice
        return PreparedTransaction(from: wallet.address, to: request.to, data: request.data, value: request.value, nonce: try await nonce, gasLimit: gasLimit, maxFeePerGas: fee * 2, maxPriorityFeePerGas: fee, chainId: Monad.chainId)
    }

    public func send(_ request: TransactionRequest, from wallet: Wallet) async throws -> Data {
        let prepared = try await prepare(request, from: wallet)
        let signed = try await wallet.sign(prepared)
        return try await rpc.sendRawTransaction(signed)
    }

    /// Runs a plan step by step. Approvals are skipped when the allowance already covers the amount.
    public func run(_ steps: [TransactionStep], from wallet: Wallet, onEvent: @Sendable @escaping (TransactionEvent) -> Void) async throws -> Data {
        var last: Data?
        for step in steps {
            onEvent(.preparing(step.label))
            let request: TransactionRequest
            switch step.kind {
            case .approve(let token, let spender, let amount):
                let allowance = try await multicall.readAll([try ERC20.allowance(token, owner: wallet.address, spender: spender)])[0][0].uint
                if allowance >= amount { continue }
                request = TransactionRequest(to: token, data: try ERC20.approveCalldata(spender: spender, amount: amount))
            case .call:
                guard let r = step.request else { continue }
                request = r
            }
            let hash = try await send(request, from: wallet)
            onEvent(.sent(step.label, hash))
            let receipt = try await rpc.waitForReceipt(hash)
            guard receipt.success else { throw TransactionError.reverted(hash) }
            onEvent(.confirmed(step.label, hash))
            last = hash
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
