import Foundation
import LocalAuthentication
import XCTest
@testable import DyorKit

/// App Lock's and the passkey's prompt (`BiometricGate` in the app's Theme.swift): its kind (`BiometricPromptKind`) names
/// it and picks its icon, so the icon never depends on text that is translated, and the reason iOS shows is written in
/// the code and resolved in the app's language.
final class BiometricPromptKindTests: XCTestCase {
    private static func source(_ path: String) throws -> String {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard FileManager.default.fileExists(atPath: ios.appendingPathComponent("DyorHQ").path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return try String(contentsOf: ios.appendingPathComponent(path), encoding: .utf8)
    }

    /// The prompt's kind decides both its name and its icon; Apple's names are never translated.
    func testPromptKind() {
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .faceID), .faceID)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .touchID), .touchID)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .opticID), .opticID)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: true, biometry: .none), .passcode)
        XCTAssertEqual(BiometricPromptKind(biometricsAvailable: false, biometry: .faceID), .passcode, "no enrolled biometrics: the passcode")
        XCTAssertEqual(BiometricPromptKind.allCases.map(\.symbol), ["faceid", "touchid", "opticid", "lock"])
        XCTAssertEqual([BiometricPromptKind.faceID, .touchID, .opticID].map(\.name), ["Face ID", "Touch ID", "Optic ID"])
        XCTAssertEqual(BiometricPromptKind.passcode.name, "Passcode")
    }

    /// App Lock's and the passkey's prompt icon comes from the kind, never from the (translated) name; the reason iOS
    /// shows is written in the code and resolved in the app's language.
    func testTheGateIconNeverDependsOnTranslatedText() throws {
        let theme = try Self.source("DyorHQ/Design/Theme.swift")
        let from = try XCTUnwrap(theme.range(of: "enum BiometricGate {")).upperBound
        let to = try XCTUnwrap(theme.range(of: "final class BiometricPrompt")).lowerBound
        let gate = String(theme[from..<to])
        XCTAssertTrue(gate.contains("typealias PromptKind = BiometricPromptKind"))
        XCTAssertTrue(gate.contains("static var promptName: String { promptKind.name }"))
        XCTAssertTrue(gate.contains("static var promptSymbol: String { promptKind.symbol }"))
        XCTAssertFalse(gate.contains("switch promptName"))
        XCTAssertFalse(gate.contains("case \"Face ID\""))
        XCTAssertTrue(gate.contains("static func authenticate(reason: LocalizedStringResource) async -> Bool"))
        XCTAssertTrue(gate.contains("let text = tr(reason)"))
        XCTAssertTrue(gate.contains("localizedReason: text"))
        XCTAssertTrue(gate.contains("return kind == .passcode ? tr(\"Biometrics\") : kind.name"))
    }
}
