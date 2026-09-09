import BigInt
import XCTest
@testable import DyorKit

/// Vectors in Fixtures/vectors.json were produced with viem and real `eth_call`s against Monad mainnet
/// (see the generator in the web repository's session notes), so encode/decode is checked against the
/// reference implementation and against live contract output, not against itself.
final class CoreTests: XCTestCase {
    private static let vectors: JSON = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }()

    private var v: JSON { Self.vectors }

    // MARK: Keccak

    func testKeccakVectors() {
        XCTAssertEqual(Keccak.hash256("").hexString, "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(Keccak.hash256("abc").hexString, "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        // Longer than one rate block (136 bytes) exercises multi-block absorption.
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(Keccak.hash256(long).count, 32)
        XCTAssertNotEqual(Keccak.hash256(long), Keccak.hash256(String(repeating: "a", count: 201)))
    }

    func testSelectors() {
        for (signature, expected) in v["selectors"].object! {
            XCTAssertEqual(ABI.selector(signature).hexString, expected.string!, signature)
        }
    }

    // MARK: Addresses and hex

    func testAddressChecksum() {
        let address = Address("0x34b6552d57a35a1d042ccae1951bd1c370112a6f")!
        XCTAssertEqual(address.checksummed, v["checksum"].string!)
        XCTAssertEqual(address.short, "0x34B6…2a6F")
        XCTAssertNil(Address("0x1234"))
        XCTAssertEqual(Address(" 0x34B6552d57a35a1D042CcAe1951BD1C370112a6F "), address)
    }

    func testHexQuantities() {
        XCTAssertEqual(BigUInt(hexQuantity: "0x0"), 0)
        XCTAssertEqual(BigUInt(hexQuantity: "0x8f"), 143)
        XCTAssertEqual(BigUInt(143).hexQuantity, "0x8f")
        XCTAssertEqual(Data(hex: "0xabc")!.hexString, "0x0abc")
        XCTAssertNil(Data(hex: "0xzz"))
    }

    // MARK: ABI encoding against viem

    func testEncodeExecOrders() throws {
        let desc: ABIValue = .tuple([
            .uint(BigUInt(1_725_800_000_000)), .uint(10), .uint(0), .uint(0), .uint(12345), .uint(500), .uint(0),
            .bool(false), .bool(false), .bool(true), .uint(0), .uint(500), .uint(0), .uint(0), .uint(300),
        ])
        let signature = "execOrders((uint256,uint256,uint8,uint256,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,uint256,uint256,uint256)[],bool)"
        let data = try ABI.encodeCall(signature, [.array([desc]), .bool(true)])
        XCTAssertEqual(data.hexString, v["encoded"]["execOrders"].string!)
    }

    func testEncodeSimpleCalls() throws {
        let usdc = Monad.usdc
        XCTAssertEqual(try ABI.encodeCall("getAccountByAddr(address)", [.address(usdc)]).hexString, v["encoded"]["getAccountByAddr"].string!)
        XCTAssertEqual(try ERC20.transferCalldata(to: usdc, amount: 1_000_000).hexString, v["encoded"]["erc20Transfer"].string!)
    }

    func testEncodeMixedDynamicParameters() throws {
        let values: [ABIValue] = [
            .string("hello dyor"),
            .array([.uint(1), .uint(2), .uint(3)]),
            .bytes(Data(hex: "0xdeadbeef")!),
            .int(-5),
            .bytes(Data(repeating: 0xab, count: 32)),
            .array([.tuple([.address(Monad.usdc), .bool(true)]), .tuple([.address(Perpl.exchange), .bool(false)])]),
        ]
        let types = try ABIType.parseList("string,uint256[],bytes,int256,bytes32,(address,bool)[]")
        let encoded = try ABI.encode(values, types)
        XCTAssertEqual(encoded.hexString, v["encoded"]["mixed"].string!)
        // Round trip.
        let decoded = try ABI.decode(encoded, types)
        XCTAssertEqual(decoded, values)
    }

    func testEncodeAggregate3() throws {
        let calls: ABIValue = .array([
            .tuple([.address(Monad.usdc), .bool(true), .bytes(Data(hex: "0x95d89b41")!)]),
            .tuple([.address(Monad.usdc), .bool(true), .bytes(Data(hex: "0x313ce567")!)]),
            .tuple([.address(Perpl.exchange), .bool(true), .bytes(Data(hex: "0x00")!)]),
        ])
        XCTAssertEqual(try ABI.encodeCall("aggregate3((address,bool,bytes)[])", [calls]).hexString, v["encoded"]["aggregate3"].string!)
    }

    func testPoolIdHash() throws {
        let encoded = try ABI.encode([.address(.zero), .address(Monad.usdc), .uint(500), .int(10), .address(.zero)], "address,address,uint24,int24,address")
        XCTAssertEqual(Keccak.hash256(encoded).hexString, v["poolId"].string!)
    }

    func testTypeParser() throws {
        XCTAssertEqual(try ABIType.parse("(uint256,(address,bool)[])[]").canonical, "(uint256,(address,bool)[])[]")
        XCTAssertEqual(try ABIType.parse("bytes32[4]").canonical, "bytes32[4]")
        XCTAssertFalse(try ABIType.parse("(uint256,address)").isDynamic)
        XCTAssertTrue(try ABIType.parse("(uint256,string)").isDynamic)
        XCTAssertThrowsError(try ABIType.parse("uint7"))
        XCTAssertThrowsError(try ABIType.parse("(uint256"))
    }

    // MARK: Decoding real Monad contract output

    func testDecodePerpetualInfo() throws {
        let raw = Data(hex: v["chain"]["getPerpetualInfo1"].string!)!
        let types = try ABIType.parseList("(string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool)")
        let info = try ABI.decode(raw, types)[0]
        XCTAssertEqual(info[1].string, "BTC")
        XCTAssertGreaterThan(info[11].uint, 0, "mark price")
        XCTAssertLessThanOrEqual(info[2].uint, 18, "price decimals")
        XCTAssertEqual(info[4].bytes.count, 32)
        // fundingRatePct100k is a signed int16; it must decode without trapping whatever its sign.
        _ = info[20].int
    }

    func testDecodeMarginFractions() throws {
        let raw = Data(hex: v["chain"]["getMarginFractions10"].string!)!
        let values = try ABI.decode(raw, "uint256,uint256,uint256,uint256,uint256,uint256")
        XCTAssertEqual(values.count, 6)
        XCTAssertGreaterThan(values[0].uint, 0)
    }

    func testUnknownPerplAccountRevertsWithCustomError() throws {
        // getAccountByAddr reverts with AccountNotFound(address) for addresses that never deposited.
        let data = v["chain"]["getAccountByAddrRevert"].string!
        XCTAssertTrue(data.hasPrefix("0x03a0e277"))
        let payload = Data(hex: data)!
        XCTAssertEqual(try ABI.decode(payload.dropFirst(4), "address")[0].address, Monad.usdc)
    }

    func testDecodeOrderIdIndex() throws {
        let raw = Data(hex: v["chain"]["getOrderIdIndex10"].string!)!
        let values = try ABI.decode(raw, "uint256,uint256[],uint256")
        XCTAssertEqual(values[1].elements.count, values[1].elements.count) // decodes without error
    }

    func testDecodeErc20Metadata() throws {
        XCTAssertEqual(try ABI.decode(Data(hex: v["chain"]["usdcSymbol"].string!)!, "string")[0].string, "USDC")
        XCTAssertEqual(try ABI.decode(Data(hex: v["chain"]["usdcDecimals"].string!)!, "uint8")[0].uint, 6)
    }

    func testDecodeAggregate3Result() throws {
        XCTAssertGreaterThan(v["chain"]["multicall3CodeLength"].number!, 0, "Multicall3 is deployed on Monad")
        let raw = Data(hex: v["chain"]["aggregate3Result"].string!)!
        let items = try ABI.decode(raw, [.array(.tuple([.bool, .bytes]))])[0].elements
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0][0].bool)
        XCTAssertEqual(try ABI.decode(items[0][1].bytes, "string")[0].string, "USDC")
        XCTAssertEqual(try ABI.decode(items[1][1].bytes, "uint8")[0].uint, 6)
        XCTAssertFalse(items[2][0].bool, "a bogus selector against the exchange fails inside aggregate3")
    }

    // MARK: Amounts and formatting

    func testAmountParsing() {
        XCTAssertEqual(Amount.parse("1", decimals: 18), BigUInt(10).power(18))
        XCTAssertEqual(Amount.parse("1,234.5", decimals: 6), 1_234_500_000)
        XCTAssertEqual(Amount.parse(".5", decimals: 2), 50)
        XCTAssertEqual(Amount.parse("0.1234567", decimals: 6), 123_456, "extra digits are truncated, not rounded")
        XCTAssertNil(Amount.parse("1e5", decimals: 6))
        XCTAssertNil(Amount.parse("", decimals: 6))
        XCTAssertNil(Amount.parse("1.2.3", decimals: 6))
        XCTAssertEqual(Amount.exact(1_234_500_000, decimals: 6), "1234.5")
        XCTAssertEqual(Amount.exact(1, decimals: 6), "0.000001")
        XCTAssertEqual(Amount.exact(0, decimals: 18), "0")
        XCTAssertEqual(Amount.raw(1.5, decimals: 6), 1_500_000)
        XCTAssertEqual(Amount.units(BigInt(-1_500_000), decimals: 6), -1.5)
    }

    func testNumberStyle() {
        XCTAssertEqual(NumberStyle.number(0), "0")
        XCTAssertEqual(NumberStyle.number(1234.5678), "1,234.57")
        XCTAssertEqual(NumberStyle.number(1_234_567, compact: true), "1.23M")
        XCTAssertEqual(NumberStyle.number(2.5), "2.5")
        XCTAssertEqual(NumberStyle.number(0.00012), "0.00012")
        XCTAssertEqual(NumberStyle.number(0.000000042), "0.0₇42")
        XCTAssertEqual(NumberStyle.number(-3), "−3")
        XCTAssertEqual(NumberStyle.percent(1.234), "+1.23%")
        XCTAssertEqual(NumberStyle.percent(-0.5), "−0.50%")
        XCTAssertEqual(NumberStyle.basisPoints(30), "0.3%")
    }
}
