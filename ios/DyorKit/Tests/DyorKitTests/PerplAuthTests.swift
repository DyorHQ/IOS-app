import CryptoKit
import XCTest
@testable import DyorKit

final class PerplAuthTests: XCTestCase {
    private func btc() -> PerpMarket {
        PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                   mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                   fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
    }

    // MARK: Encodings

    func testBase64urlNoPadding() {
        XCTAssertEqual(PerplAuth.base64url(Data([0xfb, 0xff, 0xbf])), "-_-_")           // + / → - _
        XCTAssertEqual(PerplAuth.base64url(Data([0x01])), "AQ")                          // no '=' padding
        XCTAssertFalse(PerplAuth.base64url(Data([0x00, 0x00])).contains("="))
    }

    func testRestCanonical() {
        let canonical = PerplAuth.restCanonical(chainId: 143, method: "GET", target: "/v1/trading/fills?count=1", timestamp: "1700000000000", nonce: "abc", body: "")
        // sha256("") = e3b0c442...
        XCTAssertEqual(canonical, "143\nGET\n/v1/trading/fills?count=1\n1700000000000\nabc\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testWsSigninCanonical() {
        XCTAssertEqual(PerplAuth.wsSigninCanonical(chainId: 143, timestamp: "1700000000000", nonce: "xyz"), "143\ntrading-ws-signin\n1700000000000\nxyz")
    }

    func testEd25519SignVerifyAndPublicKey() throws {
        let secret = PerplAuth.newSecret()
        XCTAssertEqual(secret.count, 32)
        let pubHex = try PerplAuth.publicKeyHex(secret: secret)
        XCTAssertTrue(pubHex.hasPrefix("0x"))
        XCTAssertEqual(pubHex.count, 2 + 64)

        let message = Data("perpl".utf8)
        let sigB64 = try PerplAuth.sign(message, secret: secret)
        // Decode base64url back and verify with CryptoKit
        var b64 = sigB64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let sig = Data(base64Encoded: b64)!
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: Data(hex: pubHex)!)
        XCTAssertTrue(pub.isValidSignature(sig, for: message))

        // proof-of-possession over a 32-byte digest verifies too
        let digest = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let pop = try PerplAuth.proofOfPossession(digest: digest, secret: secret)
        XCTAssertTrue(pub.isValidSignature(Data(hex: pop)!, for: digest))
    }

    // MARK: Order frames

    func testMarketEntryFrame() {
        let input = OrderInput(market: btc(), side: .long, kind: .market, size: 0.1, leverage: 10, slippageBps: 50)
        let frame = PerplOrders.entry(input, accountId: 5001, head: 12345678).json(rq: 1024, sn: 1)
        XCTAssertEqual(frame["mt"] as? Int, 22)
        XCTAssertEqual(frame["t"] as? Int, 1)          // OpenLong wire
        XCTAssertEqual(frame["p"] as? Int, 0)          // market
        XCTAssertEqual(frame["s"] as? Int, 10000)      // 0.1 * 10^5
        XCTAssertEqual(frame["ms"] as? Int, 50)
        XCTAssertEqual(frame["fl"] as? Int, 4)         // IOC
        XCTAssertEqual(frame["lv"] as? Int, 1000)      // 10x
        XCTAssertEqual(frame["lb"] as? Int, 12345778)  // head + 100
        XCTAssertNil(frame["tp"])
    }

    func testLimitEntryShortFrame() {
        let input = OrderInput(market: btc(), side: .short, kind: .limit, size: 0.1, price: 95000, leverage: 5)
        let frame = PerplOrders.entry(input, accountId: 5001, head: 100).json(rq: 2, sn: 2)
        XCTAssertEqual(frame["t"] as? Int, 2)          // OpenShort
        XCTAssertEqual(frame["p"] as? Int, 950000)     // 95000 * 10^1
        XCTAssertEqual(frame["fl"] as? Int, 0)         // GTC
        XCTAssertNil(frame["ms"])
        XCTAssertEqual(frame["lv"] as? Int, 500)
    }

    func testTakeProfitAndStopLossLong() {
        let tp = PerplOrders.takeProfit(side: .long, price: 110000, size: 0.1, market: btc(), accountId: 5001, linkedPositionId: 42).json(rq: 3, sn: 3)
        XCTAssertEqual(tp["t"] as? Int, 3)             // CloseLong
        XCTAssertEqual(tp["p"] as? Int, 0)             // market on trigger
        XCTAssertEqual(tp["tp"] as? Int, 1100000)      // 110000 * 10^1
        XCTAssertEqual(tp["tpc"] as? Int, 1)           // GTELast
        XCTAssertEqual(tp["lp"] as? Int, 42)
        XCTAssertEqual(tp["fl"] as? Int, 4)            // IOC
        XCTAssertEqual(tp["lv"] as? Int, 0)
        XCTAssertEqual(tp["lb"] as? Int, 0)            // triggers require lb:0

        let sl = PerplOrders.stopLoss(side: .long, price: 90000, size: 0.1, market: btc(), accountId: 5001, linkedPositionId: 42).json(rq: 4, sn: 4)
        XCTAssertEqual(sl["t"] as? Int, 3)
        XCTAssertEqual(sl["tp"] as? Int, 900000)
        XCTAssertEqual(sl["tpc"] as? Int, 4)           // LTEMark
        XCTAssertEqual(sl["lb"] as? Int, 0)
    }

    func testStopLossShortUsesMarkGte() {
        let sl = PerplOrders.stopLoss(side: .short, price: 100000, size: 0.1, market: btc(), accountId: 5001, linkedPositionId: 7).json(rq: 5, sn: 5)
        XCTAssertEqual(sl["t"] as? Int, 4)             // CloseShort
        XCTAssertEqual(sl["tpc"] as? Int, 3)           // GTEMark
    }

    func testCancelFrame() {
        let cancel = PerplOrders.cancel(perpId: 1, orderId: 778899, accountId: 5001, head: 100).json(rq: 6, sn: 6)
        XCTAssertEqual(cancel["t"] as? Int, 5)         // Cancel
        XCTAssertEqual(cancel["oid"] as? Int, 778899)
        XCTAssertEqual(cancel["s"] as? Int, 0)
        XCTAssertEqual(cancel["lv"] as? Int, 0)
    }
}
