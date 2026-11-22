import XCTest
@testable import DyorKit

/// No API in the app signs an arbitrary 32-byte digest. A key signs a raw digest in three places only, each over a
/// payload `PerplEnrollment.validate` accepted (`PerplEnrollment.Validated`, which only `validate` can make): an imported
/// wallet's and Privy's `signPerplEnrollment`, and a passkey session's own Perpl enrollment. Everything else a key signs
/// is a transaction or an EIP-191 message, hashed by `Secp256k1Account` itself. Read from the sources: a new raw-digest
/// call site anywhere fails here until it is reviewed.
final class DigestSigningPinTests: XCTestCase {
    /// The lines of `text` that are code, not comments.
    private func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private func sites(of needle: String, in files: [(path: String, text: String)]) -> [String] {
        files.flatMap { file in codeLines(file.text).filter { $0.contains(needle) }.map { "\(file.path): \($0.trimmingCharacters(in: .whitespaces))" } }
    }

    private func kitFiles() throws -> [(path: String, text: String)] {
        let root = AppSource.kitFolder
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map {
            (path: String($0.path.dropFirst(root.path.count + 1)), text: try String(contentsOf: $0, encoding: .utf8))
        }.sorted { $0.path < $1.path }
    }

    func testRawDigestSigningIsPerplEnrollmentOnly() throws {
        let kit = try kitFiles()
        XCTAssertEqual(sites(of: "sign(hash32:", in: kit), [
            "Chain/Secp256k1Account.swift: public func sign(hash32: Data) throws -> Data {",
            "Chain/Secp256k1Account.swift: return try sign(hash32: digest)",
            "Services/Mera/MeraSigningSession.swift: let signature = try account(now()).sign(hash32: payload.validated.digest)",
        ])
        XCTAssertEqual(sites(of: "secp256k1Sign", in: kit), [])
        // The kit's one digest signature sits inside the session's Perpl enrollment.
        let session = try AppSource.kit("Services/Mera/MeraSigningSession.swift")
        let enrollment = try XCTUnwrap(session.range(of: "public func enrollPerpl("))
        let signing = try XCTUnwrap(session.range(of: "sign(hash32: payload.validated.digest)"))
        XCTAssertLessThan(enrollment.lowerBound, signing.lowerBound)
        XCTAssertNil(session[enrollment.upperBound..<signing.lowerBound].range(of: "public func "), "no other function in between")

        let app = try AppSource.allAppFiles()
        XCTAssertEqual(sites(of: "sign(hash32:", in: app), ["Wallet/LocalWallet.swift: try account.sign(hash32: validated.digest).hexString"])
        XCTAssertEqual(sites(of: "secp256k1Sign", in: app),
                       ["Wallet/PrivyWallet.swift: let signature = try await provider.request(.secp256k1Sign(hash: validated.digest.hexString))"])
        for (path, text) in app + kit {
            XCTAssertFalse(text.contains("signDigest"), path)
            XCTAssertFalse(text.contains("DigestSigner"), path)
        }
        let local = AppSource.squeezed(try AppSource.app("Wallet/LocalWallet.swift"))
        XCTAssertTrue(local.contains("func signPerplEnrollment(_ validated: PerplEnrollment.Validated) async throws -> String { try account.sign(hash32: validated.digest).hexString }"))
        XCTAssertTrue(local.contains("protocol PerplEnrollmentSigner: Wallet { func signPerplEnrollment(_ validated: PerplEnrollment.Validated) async throws -> String }"))
        let privy = AppSource.squeezed(try AppSource.app("Wallet/PrivyWallet.swift"))
        XCTAssertTrue(privy.contains("func signPerplEnrollment(_ validated: PerplEnrollment.Validated) async throws -> String { let signature = try await provider.request(.secp256k1Sign(hash: validated.digest.hexString))"))
        let trading = try AppSource.app("Wallet/PerplTrading.swift")
        XCTAssertTrue(trading.contains("let walletSignature = try await signer.signPerplEnrollment(payload.validated)"))
        // Only `validate` makes a `Validated`.
        let validation = try AppSource.kit("Services/Perpl/PerplEnrollment.swift")
        XCTAssertTrue(validation.contains("fileprivate init(typedData: EIP712.TypedData, digest: Data) {"))
        XCTAssertEqual(validation.components(separatedBy: "Validated(").count - 1, 1, "built once, in validate")
    }
}
