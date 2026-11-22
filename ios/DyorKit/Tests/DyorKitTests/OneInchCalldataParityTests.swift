import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// The app's 1inch swap decoder (`OneInchSwap`) against the shared parity fixture, written by
/// scripts/research/xstocks/make-parity-fixture.mjs from viem's encoding and read by the research tool's own decoder
/// too (tests/xstocks-research.test.mjs): every case decodes here exactly when it decodes there, to the same values, and
/// is refused for the same reason. The research tool checks 1inch's real answers with that decoder, so what it calls
/// signable is what the app signs.
final class OneInchCalldataParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let calldata: String
            let decodes: Bool
            let problem: String?
            let executor: String?
            let srcToken: String?
            let dstToken: String?
            let srcReceiver: String?
            let dstReceiver: String?
            let amount: String?
            let minReturn: String?
            let flags: String?
            let executorData: String?
        }
        let account: String
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "oneinch-swap-parity", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEveryCaseReadsAsTheResearchToolReadsIt() throws {
        let fixture = try fixture()
        let account = try XCTUnwrap(Address(fixture.account))
        // Both outcomes are covered, whatever cases the fixture gains.
        XCTAssertTrue(fixture.cases.contains { $0.decodes } && fixture.cases.contains { !$0.decodes })
        for item in fixture.cases {
            let data = try XCTUnwrap(Data(hex: item.calldata), item.name)
            let swap = OneInchSwap(calldata: data)
            XCTAssertEqual(swap != nil, item.decodes, item.name)
            guard let swap else { continue }
            XCTAssertEqual(swap.executor, Address(try XCTUnwrap(item.executor)), item.name)
            XCTAssertEqual(swap.srcToken, Address(try XCTUnwrap(item.srcToken)), item.name)
            XCTAssertEqual(swap.dstToken, Address(try XCTUnwrap(item.dstToken)), item.name)
            XCTAssertEqual(swap.srcReceiver, Address(try XCTUnwrap(item.srcReceiver)), item.name)
            XCTAssertEqual(swap.dstReceiver, Address(try XCTUnwrap(item.dstReceiver)), item.name)
            XCTAssertEqual(swap.executorData, Data(hex: try XCTUnwrap(item.executorData)), item.name)
            XCTAssertEqual(swap.amount, BigUInt(try XCTUnwrap(item.amount)), item.name)
            XCTAssertEqual(swap.minReturn, BigUInt(try XCTUnwrap(item.minReturn)), item.name)
            XCTAssertEqual(swap.flags, BigUInt(try XCTUnwrap(item.flags)), item.name)
            let problem: String? = switch swap.problem(account: account, value: 0) {
            case .recipient: "recipient"
            case .flags: "flags"
            case .value: "value"
            case nil: nil
            }
            XCTAssertEqual(problem, item.problem, item.name)
        }
    }

    /// The app's own encoding of the canonical buy (`OneInchSwap.calldata`) is byte for byte viem's.
    func testTheAppsEncodingIsViems() throws {
        let canonical = try XCTUnwrap(try fixture().cases.first { $0.name == "canonical buy" })
        let address = { (hex: String) in Address(literal: hex) }
        let built = try OneInchSwap.calldata(executor: address("0x00000000000000000000000000000000000e0001"),
                                             srcToken: address("0x00000000000000000000000000000000000a0002"),
                                             dstToken: address("0x00000000000000000000000000000000000a0001"),
                                             srcReceiver: address("0x00000000000000000000000000000000000b0001"),
                                             dstReceiver: address("0x00000000000000000000000000000000000c0001"),
                                             amount: 50_000_000, minReturn: BigUInt(165_000_000_000_000_000),
                                             executorData: Data([0x12, 0x34, 0xab, 0xcd]))
        XCTAssertEqual(built.hexString, canonical.calldata.lowercased())
    }
}
