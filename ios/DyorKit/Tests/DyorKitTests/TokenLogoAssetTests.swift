import CoreGraphics
import DyorKit
import Foundation
import ImageIO
import XCTest

/// The coin logos the app ships (ios/DyorHQ/Resources/TokenLogos). `TokenLogo` clips each file to a circle over the
/// card's colour, so a file must be the coin alone: square, transparent outside the disc, the disc centred and filling
/// the canvas. Seventeen of them were once drawn small in the top-left corner of an opaque white square, which showed
/// as a white crescent beside every logo on a dark card. `scripts/dev/normalize-token-logos.py` makes a file that
/// passes.
final class TokenLogoAssetTests: XCTestCase {
    /// Every symbol `TokenLogo` finds a shipped logo for: each curated token with a logo (aBIL has none on purpose), and
    /// the Perps markets that have one.
    static let expectedSymbols = Set(Token.core.filter { $0.logoURL != nil }.map(\.symbol))
        .union(["BTC", "ETH", "SOL", "ZEC", "HYPE", "MON"])

    /// The logo folder, or a skip when this checkout has only the package.
    static func logoFolder() throws -> URL {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return app.appendingPathComponent("Resources/TokenLogos")
    }

    /// The folder's file names as stored. A device looks a logo up by exact case, while this Mac's disk ignores case, so
    /// only the listing can tell `logo-USDe.png` from `logo-USDE.png`.
    static func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: logoFolder().path).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testEveryLogoTheAppLooksUpShipsInExactCase() throws {
        let names = try Self.fileNames()
        for symbol in Self.expectedSymbols.sorted() {
            XCTAssertTrue(names.contains("logo-\(symbol).png"), "logo-\(symbol).png is missing (exact case)")
        }
        // Nothing else: a logo for a symbol no curated token carries would dress any token with that symbol, and a
        // stray image would ship in the app.
        let extra = Set(names).subtracting(Self.expectedSymbols.map { "logo-\($0).png" })
        XCTAssertTrue(extra.isEmpty, "not a logo the app looks up: \(extra.sorted())")
    }

    /// Transparent outside the disc: no plate of any colour. The 2 px allowance is the disc's anti-aliased edge.
    func testNothingIsDrawnOutsideTheDisc() throws {
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            XCTAssertEqual(logo.width, logo.height, "\(name) is not square")
            XCTAssertGreaterThanOrEqual(logo.width, 128, "\(name) is smaller than 128 px")
            let radius = Double(logo.width) / 2
            var outside = 0
            for y in 0..<logo.height {
                for x in 0..<logo.width where logo.alpha(x, y) > 0 {
                    let distance = ((Double(x) + 0.5 - radius) * (Double(x) + 0.5 - radius)
                        + (Double(y) + 0.5 - radius) * (Double(y) + 0.5 - radius)).squareRoot()
                    if distance > radius + 2 { outside += 1 }
                }
            }
            XCTAssertEqual(outside, 0, "\(name) draws \(outside) pixels outside its disc")
        }
    }

    /// The coin fills the square, centred: its visible part (at least half covered) spans at least 97% of each side and
    /// sits within 1% of the middle, so it lines up with the circle `TokenLogo` clips to. On an opaque corner the coin is
    /// what differs from the corner's colour, so a coin drawn small on a plate is measured too.
    func testTheCoinIsCentredAndFillsTheSquare() throws {
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            let plate = logo.alpha(0, 0) == 255 ? logo.pixel(0, 0) : nil
            var minX = logo.width, minY = logo.height, maxX = -1, maxY = -1
            for y in 0..<logo.height {
                for x in 0..<logo.width where logo.alpha(x, y) >= 128 && plate.map({ logo.difference(x, y, $0) > 24 }) ?? true {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let side = Double(logo.width)
            XCTAssertGreaterThanOrEqual(maxX, 0, "\(name) is blank")
            guard maxX >= 0 else { continue }
            XCTAssertGreaterThanOrEqual(Double(maxX - minX + 1) / side, 0.97, "\(name) is narrower than its canvas")
            XCTAssertGreaterThanOrEqual(Double(maxY - minY + 1) / side, 0.97, "\(name) is shorter than its canvas")
            XCTAssertLessThanOrEqual(abs(Double(minX + maxX + 1) / 2 - side / 2), side * 0.01, "\(name) is off-centre across")
            XCTAssertLessThanOrEqual(abs(Double(minY + maxY + 1) / 2 - side / 2), side * 0.01, "\(name) is off-centre down")
        }
    }

    /// No coin sits on a white disc. A plate already cut to a circle, with the coin drawn smaller inside it, passes both
    /// checks above, yet shows as a white ring round the coin on a dark card. So the outer tenth of the disc must be the
    /// coin's own edge: at most half of it near-white. The shipped coins' edges are at most 17% near-white (WBTC); each
    /// plated file had at least 66%.
    func testNoCoinSitsOnAWhiteDisc() throws {
        for name in try Self.fileNames() where name.hasPrefix("logo-") {
            let logo = try Bitmap(Self.logoFolder().appendingPathComponent(name))
            let radius = Double(logo.width) / 2
            var edge = 0, white = 0
            for y in 0..<logo.height {
                for x in 0..<logo.width where logo.alpha(x, y) >= 200 {
                    let distance = ((Double(x) + 0.5 - radius) * (Double(x) + 0.5 - radius)
                        + (Double(y) + 0.5 - radius) * (Double(y) + 0.5 - radius)).squareRoot()
                    guard distance >= radius * 0.9, distance <= radius - 2 else { continue }
                    edge += 1
                    if logo.isNearWhite(x, y) { white += 1 }
                }
            }
            XCTAssertGreaterThan(edge, 0, "\(name) has no edge")
            XCTAssertLessThanOrEqual(Double(white) / Double(max(edge, 1)), 0.5, "\(name) sits on a white disc")
        }
    }
}

/// A PNG's pixels (premultiplied RGBA), decoded with ImageIO the way UIKit reads the file. An image with no alpha reads
/// as opaque.
private struct Bitmap {
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init(_ url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.lastPathComponent)
        let (width, height) = (image.width, image.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, url.lastPathComponent)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * width + x) * 4 + 3] }

    func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }

    /// Whether a pixel is white or nearly so (every channel at least 230 once its alpha is divided out): a plate's
    /// colour, never a coin's own pale tint such as ezETH's lime or mUSD's blue.
    func isNearWhite(_ x: Int, _ y: Int) -> Bool {
        let value = pixel(x, y)
        guard value[3] > 0 else { return false }
        return value[0..<3].allSatisfy { Int($0) * 255 >= 230 * Int(value[3]) }
    }

    /// How far a pixel's colour is from `other`: the sum of the channel differences.
    func difference(_ x: Int, _ y: Int, _ other: [UInt8]) -> Int {
        zip(pixel(x, y), other).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }
}
