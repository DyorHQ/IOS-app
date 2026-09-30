import BigInt
import CoreText
import XCTest
@testable import DyorKit

/// A creator's text can't rearrange the app's text around it. The Launch ticket's balance line puts the coin's symbol
/// before the pair balance ("Balance: 1.2K PEPE · 10.5 MON"): a symbol carrying U+202E (right-to-left override) used to
/// show that as "… PEPE NOM 5.01 ·". Laid out with CoreText, the line reads in its own order. Uses service calls only, so
/// the same file shows what earlier builds answered.
final class ChainTextBidiTests: XCTestCase {
    /// `text` in the order CoreText draws it, left to right, on one line.
    static func visual(_ text: String) -> String {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        let units = Array(text.utf16)
        var drawn: [(x: CGFloat, index: Int)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (index, position) in zip(indices, positions) { drawn.append((position.x, index)) }
        }
        return drawn.sorted { $0.x < $1.x }.map { String(utf16CodeUnits: [units[$0.index]], count: 1) }.joined()
    }

    func testTheLayoutCheckSeesAnOverride() {
        let line = "Balance: 1.2K PEPE\u{202E} · 10.5 MON"
        XCTAssertNotEqual(Self.visual(line), "Balance: 1.2K PEPE · 10.5 MON", "an override reverses what follows it")
        XCTAssertEqual(Self.visual("Balance: 1.2K PEPE · 10.5 MON"), "Balance: 1.2K PEPE · 10.5 MON")
    }

    func testALaunchSymbolCantReorderTheTicketsBalanceLine() async throws {
        let token = Address(literal: "0x0000000000000000000000000000000000a1b100")
        let curve = Address(literal: "0x0000000000000000000000000000000000a1b1c0")
        let live = V2Fixture.launchpad
        MomentsChainStub.install { to, data in
            let selector = data.prefix(4)
            func is_(_ s: String) -> Bool { selector == ABI.selector(s) }
            func enc(_ v: [ABIValue], _ t: String) -> Data { try! ABI.encode(v, t) }
            typealias F = LaunchpadABI.Factory
            if to == live.factory {
                if is_(F.launchCount) { return enc([.uint(1)], "uint256") }
                if is_(F.getLaunches) { return enc([.array([.address(token)])], "address[]") }
                if is_(F.getLaunchedToken) {
                    let fields: [ABIValue] = [.address(token), .address(curve), .address(.zero), .address(.zero), .address(.zero), .uint(BigUInt(10).power(21)), .uint(0), .uint(100),
                                              .int(60), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(true)]
                    return enc([.tuple(fields)], LaunchpadABI.launchedTokenReturns(legacy: false))
                }
                return nil
            }
            if LaunchpadAddresses.retiredStacks.contains(where: { $0.factory == to }) { return is_(F.launchCount) ? enc([.uint(0)], "uint256") : nil }
            if to == token {
                if is_(LaunchpadABI.Token.name) { return enc([.string("Pepe\u{2067}")], "string") }
                if is_(LaunchpadABI.Token.symbol) { return enc([.string("PEPE\u{202E}")], "string") }
                if is_(LaunchpadABI.Token.getTokenInfo) {
                    return enc([.address(.zero), .string(""), .string("\u{202E}gm"), .tuple(Array(repeating: .string(""), count: 5))], "address,string,string,(string,string,string,string,string)")
                }
                if is_(LaunchpadABI.Token.totalSupply) { return enc([.uint(BigUInt(10).power(27))], "uint256") }
            }
            if to == curve {
                if is_(LaunchpadABI.Curve.completed) || is_(LaunchpadABI.Curve.rescued) { return enc([.bool(false)], "bool") }
                return enc([.uint(1)], "uint256")
            }
            return nil
        }
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: live)
        let listed = try await service.launches()
        let launch = try XCTUnwrap(listed.first)
        let balance = "Balance: 1.2K \(launch.symbol) · 10.5 MON"
        XCTAssertEqual(Self.visual(balance), "Balance: 1.2K PEPE · 10.5 MON", "the line reads in its own order")
        let title = "Buy \(launch.name) for 10.5 MON"
        XCTAssertEqual(Self.visual(title), "Buy Pepe for 10.5 MON")
        XCTAssertEqual(launch.description, "gm")
    }
}
