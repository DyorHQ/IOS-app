import XCTest
@testable import DyorKit

/// The Moments tab reads its list beside the policy, never behind it (`MomentsService.board`): a policy that can't be
/// read leaves Publish off with its reason, and the Moments still show. The link base stays strict (it is hashed into
/// `termsHash()` and compared with DyorHQ's).
final class MomentsBoardTests: XCTestCase {
    private static let stack = TextMomentsChain.stack

    func testAPolicyThatCantBeReadLeavesTheFeed() async throws {
        let stack = Self.stack
        MomentsChainStub.install { to, data in
            if to == stack.addresses.factory, data.prefix(4) == ABI.selector(MomentsABI.Factory.externalBaseURI) {
                return ChainTextTests.stringReturn(Data("https://dyorhq.fun/moments/c4/".utf8) + Data([0xff]))
            }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let board = try await service.board()
        XCTAssertEqual(board.moments.map(\.id), [3, 2, 1], "the Moments show")
        XCTAssertThrowsError(try board.policy.get()) { XCTAssertEqual($0 as? ABIError, .invalidUTF8, "the link base is still read strictly") }
        XCTAssertNotNil(board.policyUnread, "Publish says why it is off")
    }

    func testAReadablePolicyComesWithTheFeed() async throws {
        let stack = Self.stack
        MomentsChainStub.install { stack.answer($0, $1) }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let board = try await service.board()
        XCTAssertEqual(board.moments.count, 3)
        XCTAssertEqual(try board.policy.get()?.externalBaseURI, MomentsAddresses.expectedExternalBaseURI)
        XCTAssertNil(board.policyUnread)
    }

    func testTheFeedStillThrowsWhenItsMomentsCantBeRead() async throws {
        let stack = Self.stack
        MomentsChainStub.install({ stack.answer($0, $1) }, breaking: [stack.addresses.collect])
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        do {
            let board = try await service.board()
            XCTFail("the feed answered \(board.moments.map(\.id))")
        } catch {}
    }

    /// The tab wires it in: one board read, never the policy and the list awaited together, and the header says why
    /// Publish is off.
    func testTheMomentsTabLoadsItsListWithoutThePolicy() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Moments/MomentsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let board = try await env.moments.board(limit: 60)"))
        XCTAssertTrue(source.contains("policyUnread = board.policyUnread"))
        XCTAssertTrue(source.contains("if let unread = model.policyUnread {"))
        XCTAssertFalse(source.contains("try await (policyTask, listTask)"), "the list never waits on the policy")
    }
}
