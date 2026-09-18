import AuthenticationServices
import CryptoKit
import DyorKit
import Foundation
import UIKit

/// One passkey ceremony with the WebAuthn PRF extension, the way Mera's `createPasskeyWithPrfOutput` and
/// `getPasskeyPrfOutput` run it: a discoverable, user-verified platform passkey bound to the relying party, evaluated
/// with two 32-byte salts in the same prompt. The outputs are the only secrets the account layer ever sees, and they
/// live in memory for the duration of a session — nothing is written to disk.
@MainActor
final class PasskeyCeremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Result: Sendable {
        let credentialID: Data
        /// PRF output for the first salt (Mera's account namespace).
        let account: Data
        /// PRF output for the second salt (DyorHQ's utility namespace), when the authenticator evaluated it.
        let utility: Data?
    }

    enum Failure: LocalizedError {
        case prfUnavailable, cancelled, noCredential, failed(String)
        var errorDescription: String? {
            switch self {
            case .prfUnavailable: return "This passkey provider did not return the PRF secret. Passkeys in iCloud Keychain on iOS 18 or later are supported."
            case .cancelled: return "Cancelled."
            case .noCredential: return "No passkey for DyorHQ was found on this device or in iCloud Keychain."
            case .failed(let why): return why
            }
        }
    }

    private var continuation: CheckedContinuation<Result, Error>?

    /// Creates a passkey for `rpId` and evaluates the PRF in the same ceremony (iOS 18+). Falls back to an immediate
    /// assertion when the authenticator registers without evaluating.
    func create(rpId: String, userName: String, salts: (Data, Data)) async throws -> Result {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let userID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let request = provider.createCredentialRegistrationRequest(challenge: Self.challenge(), name: userName, userID: userID)
        request.userVerificationPreference = .required
        request.prf = .inputValues(.saltInput1(salts.0, saltInput2: salts.1))
        let result = try await perform(request)
        if result.account.isEmpty {
            return try await assert(rpId: rpId, salts: salts, credentialID: result.credentialID)
        }
        return result
    }

    /// Signs in with an existing passkey (any discoverable one for `rpId`, or the given credential) and returns the
    /// same PRF outputs the creation ceremony did.
    func assert(rpId: String, salts: (Data, Data), credentialID: Data? = nil) async throws -> Result {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: Self.challenge())
        request.userVerificationPreference = .required
        request.prf = .inputValues(.saltInput1(salts.0, saltInput2: salts.1))
        if let credentialID { request.allowedCredentials = [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialID)] }
        let result = try await perform(request)
        guard !result.account.isEmpty else { throw Failure.prfUnavailable }
        return result
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> Result {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private static func challenge() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    private static func bytes(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

    // MARK: ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let continuation = self.continuation
        self.continuation = nil
        switch authorization.credential {
        case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            let first = Self.bytes(registration.prf?.first) ?? Data()
            continuation?.resume(returning: Result(credentialID: registration.credentialID, account: first, utility: Self.bytes(registration.prf?.second)))
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            let first = Self.bytes(assertion.prf?.first) ?? Data()
            continuation?.resume(returning: Result(credentialID: assertion.credentialID, account: first, utility: Self.bytes(assertion.prf?.second)))
        default:
            continuation?.resume(throwing: Failure.failed("Unexpected credential type."))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let continuation = self.continuation
        self.continuation = nil
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled: continuation?.resume(throwing: Failure.cancelled)
            case .failed where authError.localizedDescription.localizedCaseInsensitiveContains("credential"): continuation?.resume(throwing: Failure.noCredential)
            default: continuation?.resume(throwing: Failure.failed(authError.localizedDescription))
            }
        } else {
            continuation?.resume(throwing: Failure.failed(error.localizedDescription))
        }
    }

    // MARK: ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}
