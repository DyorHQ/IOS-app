import DyorKit
import Foundation

/// Signs with a wallet the user imported into DyorHQ — their own secp256k1 key, held on this device. Transactions
/// are signed locally and broadcast by the app's own RPC client, exactly like the Privy path; the difference is
/// only where the key lives. The raw key never leaves the device.
struct LocalWallet: Wallet, PerplEnrollmentSigner {
    let account: Secp256k1Account

    var address: Address { account.address }

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        try account.sign(transaction)
    }

    func signMessage(_ message: Data) async throws -> Data {
        try account.signMessage(message)
    }

    func signPerplEnrollment(_ validated: PerplEnrollment.Validated) async throws -> String {
        try account.sign(hash32: validated.digest).hexString
    }
}

/// A wallet that can sign Perpl's API-key enrollment, whose EIP-712 digest it signs directly with its secp256k1 key.
/// Both the Privy embedded wallet and an imported local wallet provide it, so authenticated Perpl trading works with
/// either. It takes a payload `PerplEnrollment.validate` accepted, never a digest: only `validate` can make one, so no
/// API in the app hands a wallet an arbitrary 32-byte digest to sign.
protocol PerplEnrollmentSigner: Wallet {
    func signPerplEnrollment(_ validated: PerplEnrollment.Validated) async throws -> String
}

extension PrivyWallet: PerplEnrollmentSigner {}
