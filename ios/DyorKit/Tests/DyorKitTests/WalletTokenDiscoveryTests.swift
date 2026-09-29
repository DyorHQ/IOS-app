import BigInt
import XCTest
@testable import DyorKit

/// What the wallet's transfer history says it holds (`WalletTokenDiscovery`): ERC-20 tokens only. An NFT collection's
/// `Transfer` shares the ERC-20 signature and its `balanceOf` counts editions, so it is told apart by its log (four
/// topics) and, for a collection already stored as a token, by ERC-165. Contract reads come from `MomentsChainStub`.
final class WalletTokenDiscoveryTests: XCTestCase {
    private let chain = DiscoveryChain()
    private var wallet: Address { chain.wallet }
    private var coin: Address { chain.coin }
    private var collection: Address { chain.collection }
    private var yesToAll: Address { chain.yesToAll }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func discovery() -> WalletTokenDiscovery {
        WalletTokenDiscovery(logsRPC: MomentsChainStub.rpc(), multicall: Multicall(rpc: MomentsChainStub.rpc()))
    }

    private func transfer(_ contract: Address, nft: Bool, block: UInt64) -> Log {
        let topics = [ABI.eventTopic("Transfer(address,address,uint256)"), chain.sender.data.leftPadded(to: 32), wallet.data.leftPadded(to: 32)]
        // ERC-721 indexes the token id and carries no data; ERC-20 carries the amount as data.
        return Log(address: contract, topics: nft ? topics + [BigUInt(7).word] : topics, data: nft ? Data() : BigUInt(5).word,
                   blockNumber: block, transactionHash: Data(repeating: UInt8(block), count: 32), logIndex: 0)
    }

    func testOnlyERC20TransfersAreTakenForTokens() async {
        MomentsChainStub.install(chain.answer, logs: [transfer(coin, nft: false, block: 10), transfer(collection, nft: true, block: 20)])
        let found = await discovery().heldTokens(wallet: wallet, wholeHistory: true)
        XCTAssertEqual(found.map(\.address), [coin], "the collection's edition transfer is not a token transfer")
        XCTAssertEqual(found.first?.symbol, "CN")
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == collection }, "the collection is never read as a token")
        XCTAssertTrue(WalletTokenDiscovery.isERC20Transfer(transfer(coin, nft: false, block: 1)))
        XCTAssertFalse(WalletTokenDiscovery.isERC20Transfer(transfer(collection, nft: true, block: 1)))
    }

    func testACollectionStoredAsATokenIsFoundByERC165() async {
        MomentsChainStub.install(chain.answer)
        let tokens = [Token.mon, Token.usdc, Token(address: coin, symbol: "CN", name: "Coin", decimals: 18),
                      Token(address: collection, symbol: "EDN", name: "Editions", decimals: 18), Token(address: yesToAll, symbol: "ANY", name: "Any", decimals: 18)]
        let collections = await discovery().collections(among: tokens)
        XCTAssertEqual(collections, [collection], "the ERC-721 collection only: a token that doesn't answer stays, and so does one answering yes to everything")
        let asked = Set(MomentsChainStub.calls().map(\.to))
        XCTAssertEqual(asked, [coin, collection, yesToAll], "MON and the curated tokens are never asked")
        let none = await discovery().collections(among: [Token.mon, Token.usdc])
        XCTAssertTrue(none.isEmpty)
    }

    /// A scan tells "nothing there" from "couldn't read it": a refused history, chain head or balance read leaves it
    /// incomplete, so a list can say a token may be missing instead of showing what it found as everything.
    func testAScanSaysWhenItCouldNotReadEverything() async {
        let found = Token(address: coin, symbol: "CN", name: "Coin", decimals: 18)
        MomentsChainStub.install(chain.answer, logs: [transfer(coin, nft: false, block: 10)])
        let full = await discovery().scan(wallet: wallet, wholeHistory: true)
        XCTAssertEqual(full, WalletTokenDiscovery.Scan(tokens: [found], complete: true))

        MomentsChainStub.install(chain.answer)
        let nothing = await discovery().scan(wallet: wallet, wholeHistory: true)
        XCTAssertEqual(nothing, WalletTokenDiscovery.Scan(tokens: [], complete: true), "an empty history, read in full")

        MomentsChainStub.install(chain.answer, logs: [transfer(coin, nft: false, block: 10)], refusing: ["eth_getLogs"])
        let noHistory = await discovery().scan(wallet: wallet, wholeHistory: true)
        XCTAssertEqual(noHistory, WalletTokenDiscovery.Scan(tokens: [], complete: false), "the history refused: nothing found, and not complete")
        let listed = await discovery().heldTokens(wallet: wallet, wholeHistory: true)
        XCTAssertTrue(listed.isEmpty, "heldTokens still lists what it found")

        MomentsChainStub.install(chain.answer, logs: [transfer(coin, nft: false, block: 10)], refusing: ["eth_getBlockByNumber"])
        let noHead = await discovery().scan(wallet: wallet, wholeHistory: true)
        XCTAssertEqual(noHead, WalletTokenDiscovery.Scan(tokens: [], complete: false))

        MomentsChainStub.install(chain.answer, logs: [transfer(coin, nft: false, block: 10)], refusing: ["eth_call"])
        let noBalances = await discovery().scan(wallet: wallet, wholeHistory: true)
        XCTAssertEqual(noBalances, WalletTokenDiscovery.Scan(tokens: [], complete: false), "the token was seen, its balance couldn't be read")
    }

    /// The app's one read of the wallet's tokens (`WalletTokens`, behind the Portfolio's Assets and the Send list) leaves
    /// collections out and carries whether the scan was complete; the Send list says when it wasn't, with Retry.
    func testTheWalletsTokenListLeavesCollectionsOutAndSaysWhenItIsIncomplete() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let source = try String(contentsOf: app.appendingPathComponent("Wallet/WalletTokens.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let collections = await env.walletDiscovery.collections(among: held)"))
        XCTAssertTrue(source.contains("tokens: held.filter { !collections.contains($0.address) }"))
        XCTAssertTrue(source.contains("let scan = await env.walletDiscovery.scan(wallet: address, known: known, wholeHistory: true)"))
        XCTAssertTrue(source.contains("complete: scan.complete)"))
        let profile = try String(contentsOf: app.appendingPathComponent("Profile/ProfileView.swift"), encoding: .utf8)
        XCTAssertTrue(profile.contains("assets = .loaded(ranked.tokens, complete: read.complete, pricesFailed: ranked.pricesFailed)"))
        XCTAssertTrue(profile.contains("if let gap = Self.readGap(complete: complete, pricesFailed: pricesFailed) { readNotice(gap) }"))
        XCTAssertTrue(profile.contains("readNotice(\"No tokens found, but part of your wallet's history couldn't be read"), "an incomplete empty read is never \"nothing to send\"")
    }

    func testAFailedCheckKeepsEveryToken() async {
        // Every call reverts, as a node that can't serve the read: nothing is taken for a collection.
        MomentsChainStub.install { _, _ in nil }
        let collections = await discovery().collections(among: [Token(address: collection, symbol: "EDN", name: "Editions", decimals: 18)])
        XCTAssertTrue(collections.isEmpty)
    }
}

/// The contracts `WalletTokenDiscoveryTests` reads, answered from memory.
private struct DiscoveryChain: Sendable {
    let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    let sender = Address(literal: "0x9999999999999999999999999999999999999999")
    /// An ERC-20 the wallet was sent.
    let coin = Address(literal: "0x00000000000000000000000000000000000c0001")
    /// An ERC-721 collection the wallet was sent an edition of (a Moment edition, say).
    let collection = Address(literal: "0x00000000000000000000000000000000000c0002")
    /// A contract that answers true to every `supportsInterface`, the invalid id included.
    let yesToAll = Address(literal: "0x00000000000000000000000000000000000c0003")

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        guard [coin, collection, yesToAll].contains(to) else { return nil }
        if is_("balanceOf(address)") { return encode([.uint(to == collection ? 1 : 5)], "uint256") }
        if is_("symbol()") { return encode([.string(to == collection ? "EDN" : "CN")], "string") }
        if is_("name()") { return encode([.string(to == collection ? "Editions" : "Coin")], "string") }
        if is_("decimals()") { return to == collection ? nil : encode([.uint(18)], "uint8") }
        if is_("supportsInterface(bytes4)") {
            let id = Data(data.dropFirst(4).prefix(4))
            if to == yesToAll { return encode([.bool(true)], "bool") }
            if to == collection { return encode([.bool(id == WalletTokenDiscovery.erc721Interface || id == Data([0x01, 0xff, 0xc9, 0xa7]))], "bool") }
        }
        return nil
    }
}
