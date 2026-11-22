import BigInt
import XCTest
@testable import DyorKit

/// Signer-independent hardening for 1inch, with no venue in the build: the strict `OneInchSwap` decoder (hand-built
/// calldata, then every mutation), the structural guard `TransactionSender.prepare` asks first on every chain (each
/// refused shape refused before any request; the app's ordinary requests untouched), the run's deadline checks on an
/// injected clock (a signed transaction is always broadcast), the expected swap terms, and the router-exact allowance
/// rule. Every address here is a test fixture except the 1inch contracts themselves.
final class OneInchHardeningTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    private let executor = Address(literal: "0x5555555555555555555555555555555555555555")
    /// A test-only stand-in for an xStock: no real token.
    private let stock = Address(literal: "0x7777777777777777777777777777777777777777")
    private let amountIn = BigUInt(25_000_000) // 25 USDC
    private let minReturn = BigUInt(99_000_000_000_000_000) // 0.099 of an 18-decimal token
    private var chain: SimulatedChain { RPCStub.chain! }

    override func setUp() {
        super.setUp()
        RPCStub.reset()
        RPCStub.chain = SimulatedChain()
        RPCStub.baseFee = "0x174876e800" // 100 gwei
        RPCStub.tip = "0x77359400"       // 2 gwei
        chain.balance = BigUInt(10).power(20)
    }

    override func tearDown() {
        RPCStub.reset()
        super.tearDown()
    }

    // MARK: Builders

    private func word(_ value: BigUInt) -> Data { value.word }
    private func word(_ address: Address) -> Data { Data(count: 12) + address.data }

    /// The canonical calldata, built word by word from the ABI rules alone (not by the app's encoder): the selector, the
    /// executor, the seven static words of the description inline, the offset of `data` (9 words in: 0x120), then its
    /// length and its bytes padded to a word.
    private func handBuilt(src: Address = Monad.usdc, dst: Address? = nil, srcReceiver: Address? = nil, dstReceiver: Address? = nil,
                           amount: BigUInt? = nil, minReturn: BigUInt? = nil, flags: BigUInt = 0, data: Data = Data([0xde, 0xad, 0xbe, 0xef])) -> Data {
        var out = Data([0x07, 0xed, 0x23, 0x79])
        out += word(executor)
        out += word(src) + word(dst ?? stock) + word(srcReceiver ?? executor) + word(dstReceiver ?? account)
        out += word(amount ?? amountIn) + word(minReturn ?? self.minReturn) + word(flags)
        out += word(BigUInt(0x120))
        out += word(BigUInt(data.count)) + data + Data(count: (32 - data.count % 32) % 32)
        return out
    }

    private var canonical: Data { handBuilt() }

    private var expected: TransactionStep.ExpectedSwap {
        .init(tokenIn: Monad.usdc, tokenOut: stock, amountIn: amountIn, minReturnFloor: minReturn)
    }

    private func approve(_ token: Address, _ spender: Address, _ amount: BigUInt) -> TransactionRequest {
        TransactionRequest(to: token, data: try! ABI.encodeCall("approve(address,uint256)", [.address(spender), .uint(amount)]))
    }

    private var rpc: RPCClient { RPCClient(url: URL(string: "https://primary.test")!, session: RPCStub.session()) }

    private func sender(chainId: Int = Monad.chainId, clock: ClockBox? = nil) -> TransactionSender {
        var sender = TransactionSender(rpc: rpc, chainId: chainId)
        sender.timing = .init(blockPoll: .milliseconds(1), spacingTimeout: .milliseconds(50), fundingRetry: .milliseconds(1),
                              resendAttempts: 2, resendBackoff: .milliseconds(1), receiptPolls: 5, receiptInterval: .milliseconds(1),
                              receiptFastPolls: 0, receiptFastInterval: .milliseconds(1))
        if let clock { sender.now = { clock.now } }
        return sender
    }

    // MARK: Constants

    /// The router's selector is the generic swap's, computed here from its signature; the contracts read back as they
    /// were written (a typo in a checksummed literal shows here); nothing 1inch is on in this build.
    func testConstants() {
        XCTAssertEqual(ABI.selector(OneInchSwap.signature), OneInchSwap.selector)
        XCTAssertEqual(OneInchSwap.selector.hexString, "0x07ed2379")
        XCTAssertEqual(OneInch.router.checksummed, "0x111111125421cA6dc452d289314280a0f8842A65")
        XCTAssertEqual(OneInch.aqua.checksummed, "0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a")
        XCTAssertEqual(OneInch.swapVMRouter.checksummed, "0x111111338c5091E8440b67B168bAe16a668AC0De")
        XCTAssertEqual(OneInch.refusedContracts, [OneInch.aqua, OneInch.swapVMRouter])
        XCTAssertFalse(OneInch.compiledIn, "no 1inch swap in this build")
        XCTAssertEqual(OneInch.firmWindow, .seconds(20))
        XCTAssertGreaterThan(OneInch.startMargin, OneInch.signMargin)
        XCTAssertEqual(OneInch.stockSlippageCapBps, 100)
        XCTAssertTrue(XStocks.curated.isEmpty, "no unverified xStock address ships")
        XCTAssertTrue(XStocks.knownUncurated.isEmpty)
        XCTAssertFalse(XStocks.isKnown(stock))
        XCTAssertEqual(Venue.oneInch.displayName, "1inch")
        XCTAssertFalse(SwapEngine.quoteVenues.contains(.oneInch), "1inch is in no quote round yet")
    }

    // MARK: Decoder

    func testCanonicalSwapDecodes() throws {
        XCTAssertEqual(canonical, try OneInchSwap.calldata(executor: executor, srcToken: Monad.usdc, dstToken: stock, srcReceiver: executor,
                                                           dstReceiver: account, amount: amountIn, minReturn: minReturn,
                                                           executorData: Data([0xde, 0xad, 0xbe, 0xef])),
                       "the hand-built bytes are the canonical encoding")
        let swap = try XCTUnwrap(OneInchSwap(calldata: canonical))
        XCTAssertEqual(swap.executor, executor)
        XCTAssertEqual(swap.srcToken, Monad.usdc)
        XCTAssertEqual(swap.dstToken, stock)
        XCTAssertEqual(swap.srcReceiver, executor)
        XCTAssertEqual(swap.dstReceiver, account)
        XCTAssertEqual(swap.amount, amountIn)
        XCTAssertEqual(swap.minReturn, minReturn)
        XCTAssertEqual(swap.flags, 0)
        XCTAssertEqual(swap.executorData, Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertNil(swap.problem(account: account, value: 0))
        XCTAssertTrue(swap.matches(expected, account: account, value: 0))
        // A sell (the stock in, USDC out) and empty executor data read the same way.
        XCTAssertNotNil(OneInchSwap(calldata: handBuilt(src: stock, dst: Monad.usdc, data: Data())))
    }

    /// Anything but the one canonical encoding of the generic swap is no swap at all.
    func testEveryShapeButTheCanonicalOneIsUnreadable() {
        let base = canonical
        var cases: [(String, Data)] = [
            ("a trailing byte", base + Data([0x00])),
            ("a trailing word", base + Data(count: 32)),
            ("a 1inch-style suffix", base + Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])),
            ("one byte short", base.dropLast()),
            ("the selector only", OneInchSwap.selector),
            ("nothing", Data()),
            ("unoswap's selector", ABI.selector("unoswap(uint256,uint256,uint256,uint256)") + base.dropFirst(4)),
            ("a fill order's selector", ABI.selector("fillOrder((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes32,bytes32,uint256,uint256)") + base.dropFirst(4)),
            ("the zero source token", handBuilt(src: .zero)),
            ("the native marker in", handBuilt(src: OneInchSwap.nativeMarker)),
            ("the native marker out", handBuilt(dst: OneInchSwap.nativeMarker)),
            ("the zero destination token", handBuilt(dst: .zero)),
            ("the same token both ways", handBuilt(dst: Monad.usdc)),
            ("a zero amount", handBuilt(amount: 0)),
            ("a zero minimum", handBuilt(minReturn: 0)),
            ("oversized", handBuilt(data: Data(count: OneInchSwap.maxCalldataBytes))),
        ]
        // Dirty words: the high bytes of each address word, a moved offset, garbage in the padding after `data`, and a
        // length that runs past it.
        for index in [0, 1, 2, 3, 4] {
            var dirty = base
            dirty[4 + 32 * index] = 0x01
            cases.append(("a dirty address word \(index)", dirty))
        }
        var movedOffset = base
        movedOffset.replaceSubrange(4 + 32 * 8 ..< 4 + 32 * 9, with: word(BigUInt(0x140)))
        cases.append(("a non-canonical offset", movedOffset + Data(count: 32)))
        var dirtyPadding = base
        dirtyPadding[dirtyPadding.count - 1] = 0x01
        cases.append(("dirty padding", dirtyPadding))
        var longerLength = base
        longerLength.replaceSubrange(4 + 32 * 9 ..< 4 + 32 * 10, with: word(BigUInt(33)))
        cases.append(("a length past the data", longerLength))
        for (name, data) in cases {
            XCTAssertNil(OneInchSwap(calldata: data), name)
        }
        XCTAssertEqual(cases.count, 24)
    }

    /// Fields that decode but make a swap one no signer signs, and terms other than the reviewed ones.
    func testFieldMutationsAreRefused() throws {
        func problem(_ data: Data, value: BigUInt = 0) -> OneInchSwap.Problem? { OneInchSwap(calldata: data)?.problem(account: account, value: value) }
        XCTAssertEqual(problem(handBuilt(dstReceiver: stranger)), .recipient)
        XCTAssertEqual(problem(handBuilt(dstReceiver: .zero)), .recipient, "1inch's zero-means-caller is refused too")
        XCTAssertEqual(problem(handBuilt(flags: 1)), .flags)
        XCTAssertEqual(problem(handBuilt(flags: BigUInt(1) << 255)), .flags)
        XCTAssertEqual(problem(canonical, value: 1), .value)
        XCTAssertNil(problem(handBuilt(srcReceiver: stranger)), "the executor's working address is 1inch's to choose")

        func matches(_ data: Data, _ terms: TransactionStep.ExpectedSwap? = nil, value: BigUInt = 0) -> Bool {
            OneInchSwap(calldata: data)?.matches(terms ?? expected, account: account, value: value) ?? false
        }
        XCTAssertTrue(matches(canonical))
        XCTAssertTrue(matches(handBuilt(minReturn: minReturn + 1)), "a better minimum")
        XCTAssertFalse(matches(handBuilt(minReturn: minReturn - 1)), "a minimum under the floor")
        XCTAssertFalse(matches(handBuilt(amount: amountIn + 1)), "more in")
        XCTAssertFalse(matches(handBuilt(amount: amountIn - 1)), "less in: the amount must be exact")
        XCTAssertFalse(matches(handBuilt(src: Monad.usdt0)), "another token in")
        XCTAssertFalse(matches(handBuilt(dst: stranger)), "another token out")
        XCTAssertFalse(matches(handBuilt(dstReceiver: stranger)))
        XCTAssertFalse(matches(handBuilt(flags: 4)))
        XCTAssertFalse(matches(canonical, value: 1))
    }

    // MARK: Guard

    private func refusal(_ request: TransactionRequest, chainId: Int = Monad.chainId, compiledIn: Bool = false) -> ThirdPartyCalldataGuard.Refusal? {
        ThirdPartyCalldataGuard.refusal(request, account: account, chainId: chainId, compiledIn: compiledIn)
    }

    /// Every refused shape: refused on its own, and by `prepare` before a single request leaves the device (no eth_call,
    /// no estimate, no nonce), on Monad and on another chain.
    func testRefusedShapesNeverReachTheNode() async throws {
        let unlimited = TransactionSender.unlimitedAllowance
        let permit2 = { (spender: Address) in
            TransactionRequest(to: Uniswap.permit2, data: try! SwapCalldata.permit2Approve(token: Monad.usdc, spender: spender, amount: 1, expiration: 1))
        }
        var dirtyRouterApproval = approve(Monad.usdc, OneInch.router, unlimited).data
        dirtyRouterApproval[4] = 0xff // the spender word's high bytes: an older token truncates them
        let cases: [(String, TransactionRequest, ThirdPartyCalldataGuard.Refusal)] = [
            ("a call to Aqua", TransactionRequest(to: OneInch.aqua, data: canonical), .refusedContract),
            ("a call to SwapVMRouter", TransactionRequest(to: OneInch.swapVMRouter, data: Data([0x01, 0x02, 0x03, 0x04])), .refusedContract),
            ("MON to Aqua", TransactionRequest(to: OneInch.aqua, value: 1), .refusedContract),
            ("an approval of Aqua", approve(Monad.usdc, OneInch.aqua, 1), .refusedContract),
            ("an approval of SwapVMRouter", approve(stock, OneInch.swapVMRouter, 1), .refusedContract),
            ("increaseAllowance for SwapVMRouter", TransactionRequest(to: Monad.usdc, data: try ABI.encodeCall("increaseAllowance(address,uint256)", [.address(OneInch.swapVMRouter), .uint(1)])), .refusedContract),
            ("a Permit2 approval of Aqua", permit2(OneInch.aqua), .refusedContract),
            ("an unlimited router approval", approve(Monad.usdc, OneInch.router, unlimited), .unlimitedRouterApproval),
            ("a max router approval", approve(Monad.usdc, OneInch.router, BigUInt(2).power(256) - 1), .unlimitedRouterApproval),
            ("an unlimited increaseAllowance for the router", TransactionRequest(to: Monad.usdc, data: try ABI.encodeCall("increaseAllowance(address,uint256)", [.address(OneInch.router), .uint(unlimited)])), .unlimitedRouterApproval),
            ("a dirty spender word naming the router", TransactionRequest(to: Monad.usdc, data: dirtyRouterApproval), .unlimitedRouterApproval),
            ("a router approval with no amount", TransactionRequest(to: Monad.usdc, data: ABI.selector("approve(address,uint256)") + word(OneInch.router)), .unlimitedRouterApproval),
            ("a Permit2 approval of the router", permit2(OneInch.router), .permit2Router),
            ("the canonical swap while 1inch is off", TransactionRequest(to: OneInch.router, data: canonical), .routerCall),
            ("MON to the router", TransactionRequest(to: OneInch.router, value: 1), .routerCall),
            ("an unreadable router call", TransactionRequest(to: OneInch.router, data: canonical + Data([0x00])), .routerCall),
        ]
        for (name, request, expected) in cases {
            XCTAssertEqual(refusal(request), expected, name)
            XCTAssertEqual(refusal(request, chainId: 8453), expected, "\(name) on Base")
            RPCStub.hosts = []
            for chainId in [Monad.chainId, 8453] {
                do {
                    _ = try await sender(chainId: chainId).prepare(request, from: StubWallet())
                    XCTFail("\(name) was prepared on \(chainId)")
                } catch TransactionError.rejected(let message) {
                    XCTAssertEqual(message, expected.message, name)
                }
            }
            XCTAssertEqual(RPCStub.hosts, [], "\(name): not one request")
        }
        for refusal in [ThirdPartyCalldataGuard.Refusal.refusedContract, .unlimitedRouterApproval, .permit2Router, .routerCall] {
            XCTAssertFalse(refusal.message.isEmpty)
        }
    }

    /// With 1inch compiled in, only a canonical swap on Monad that pays the account, sets no flags and carries no MON
    /// passes; the exact and revoking approvals of the router always pass.
    func testRouterCallsPassOnlyAsAReadableSwap() {
        XCTAssertNil(refusal(TransactionRequest(to: OneInch.router, data: canonical), compiledIn: true))
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: canonical), chainId: 1, compiledIn: true), .routerCall, "Monad only")
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: handBuilt(dstReceiver: stranger)), compiledIn: true), .routerCall)
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: handBuilt(dstReceiver: .zero)), compiledIn: true), .routerCall)
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: handBuilt(flags: 1)), compiledIn: true), .routerCall)
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: canonical, value: 1), compiledIn: true), .routerCall)
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: canonical + Data(count: 32)), compiledIn: true), .routerCall)
        XCTAssertEqual(refusal(TransactionRequest(to: OneInch.router, data: Data()), compiledIn: true), .routerCall)
        XCTAssertNil(refusal(approve(Monad.usdc, OneInch.router, amountIn)), "the exact approval")
        XCTAssertNil(refusal(approve(Monad.usdc, OneInch.router, 0)), "revoking it")
        XCTAssertNil(refusal(approve(Monad.usdc, OneInch.router, TransactionSender.unlimitedAllowance - 1)))
    }

    /// The app's own requests are not the guard's business: Kuru, Uniswap (Universal Router, SwapRouter02, the standing
    /// Permit2 approval), Monday, wrapping, a launchpad buy, a Perpl deposit, a Send and an Aurora-style deposit on another
    /// chain all pass it, and `prepare` goes on to simulate them.
    func testOrdinaryRequestsAreUntouched() async throws {
        let route = V3Route(path: [Monad.usdc, Monad.wmon], fees: [500])
        let hop = try XCTUnwrap(V4Hop(key: PoolKey.canonical(Monad.usdc, Monad.native, fee: 500, tickSpacing: 10), from: Monad.usdc))
        let kuruData = KuruFlowSwap.payCaller + (try ABI.encode([.address(Monad.native), .uint(1), .address(Monad.usdc), .uint(amountIn),
                                                                  .tuple([.address(stranger), .uint(0), .address(.zero), .uint(0), .bool(true)]), .bytes(Data([0x02]))],
                                                                 "address,uint256,address,uint256,(address,uint256,address,uint256,bool),bytes"))
        let requests: [(String, TransactionRequest, Int)] = [
            ("a Kuru Flow swap", TransactionRequest(to: Kuru.entrypoint, data: kuruData), Monad.chainId),
            ("a Uniswap v4 swap", try SwapCalldata.universalRouterV4(currencyIn: Monad.usdc, currencyOut: Monad.native, hops: [hop], amountIn: amountIn, minOut: 1, deadline: 1), Monad.chainId),
            ("a Uniswap v3 swap", try SwapCalldata.swapRouter02(route: route, amountIn: amountIn, minOut: 1, account: account, nativeIn: false, nativeOut: false, deadline: 1), Monad.chainId),
            ("a Monday swap", try SwapCalldata.mondaySwap(route: route, amountIn: amountIn, minOut: 1, account: account, nativeIn: false, nativeOut: false, deadline: 1), Monad.chainId),
            ("the old standing Permit2 approval", approve(Monad.usdc, Uniswap.permit2, SwapCalldata.maxUint160), Monad.chainId),
            ("a Permit2 allowance for the Universal Router", TransactionRequest(to: Uniswap.permit2, data: try SwapCalldata.permit2Approve(token: Monad.usdc, spender: Uniswap.universalRouter, amount: amountIn, expiration: 1)), Monad.chainId),
            ("a Kuru approval", approve(Monad.usdc, Kuru.entrypoint, amountIn), Monad.chainId),
            ("wrapping MON", TransactionRequest(to: Monad.wmon, data: ABI.selector("deposit()"), value: 1), Monad.chainId),
            ("a launchpad buy", TransactionRequest(to: stranger, data: try ABI.encodeCall(LaunchpadABI.Curve.buy, [.uint(1), .uint(1), .address(account)]), value: 1), Monad.chainId),
            ("a Perpl deposit", TransactionRequest(to: Perpl.exchange, data: try ABI.encodeCall(PerplExchange.Signature.depositCollateral, [.uint(10_000_000)])), Monad.chainId),
            ("a Send", TransactionRequest(to: Monad.usdc, data: try ERC20.transferCalldata(to: stranger, amount: amountIn)), Monad.chainId),
            ("a MON Send", TransactionRequest(to: stranger, value: 1), Monad.chainId),
            ("an Aurora-style deposit on Base", TransactionRequest(to: stranger, data: try ERC20.transferCalldata(to: executor, amount: amountIn)), 8453),
            ("an Aurora-style native deposit on Ethereum", TransactionRequest(to: executor, value: 1), 1),
        ]
        for (name, request, chainId) in requests {
            XCTAssertNil(ThirdPartyCalldataGuard.refusal(request, account: account, chainId: chainId), name)
            XCTAssertNil(ThirdPartyCalldataGuard.refusal(request, account: account, chainId: chainId, compiledIn: true), name)
            RPCStub.hosts = []
            let prepared = try await sender(chainId: chainId).prepare(request, from: StubWallet())
            XCTAssertEqual(prepared.data, request.data, name)
            XCTAssertFalse(RPCStub.hosts.isEmpty, "\(name) was simulated")
        }
    }

    // MARK: Deadlines

    private func target(_ byte: UInt8) -> TransactionRequest { TransactionRequest(to: stranger, data: Data([byte])) }

    /// Steps without a deadline run exactly as before: the clock is never read.
    func testStepsWithoutADeadlineNeverReadTheClock() async throws {
        let clock = ClockBox()
        _ = try await sender(clock: clock).run([.call(target(1), label: "Approve"), .call(target(2), label: "Swap")], from: StubWallet()) { _ in }
        XCTAssertEqual(clock.reads, 0)
        XCTAssertEqual(chain.sent.count, 2)
    }

    /// Less than the start margin left: nothing is read, prepared or signed.
    func testExpiredBeforeTheStartSendsNothing() async {
        let clock = ClockBox()
        let wallet = ClockWallet(clock: clock)
        let steps: [TransactionStep] = [.call(target(1), label: "Approve"), .call(target(2), label: "Swap", notAfter: clock.start + OneInch.startMargin - .milliseconds(1))]
        await assertExpired(steps, sender: sender(clock: clock), wallet: wallet)
        XCTAssertEqual(RPCStub.hosts, [], "not one request")
        XCTAssertEqual(wallet.signatures, 0)
    }

    /// The approval went out and confirmed; by then the quote ran out: the swap is never prepared, and the error says so.
    func testExpiredAfterTheApprovalNeverPreparesTheSwap() async {
        let clock = ClockBox()
        let wallet = ClockWallet(clock: clock, advanceOnSign: .seconds(30))
        let events = EventLog()
        let steps: [TransactionStep] = [.call(target(1), label: "Approve"), .call(target(2), label: "Swap", notAfter: clock.start + OneInch.firmWindow)]
        await assertExpired(steps, sender: sender(clock: clock), wallet: wallet, events: events)
        XCTAssertEqual(wallet.signatures, 1, "the approval only")
        XCTAssertEqual(chain.sent.count, 1)
        XCTAssertEqual(chain.simulations, 1, "the swap was never simulated")
        XCTAssertTrue(events.all.contains { if case .confirmed("Approve", _) = $0 { return true }; return false })
        XCTAssertFalse(events.all.contains { if case .sent("Swap", _) = $0 { return true }; return false })
    }

    /// Time left at the start and before prepare, but less than the signing margin once the step is prepared: prepared,
    /// never signed.
    func testUnderTheSignMarginIsNotSigned() async {
        let clock = ClockBox()
        let deadline = clock.start + OneInch.firmWindow
        // Reads: before the start, before prepare, before signing (2 s left, under the 3 s margin).
        clock.script = [.zero, .zero, OneInch.firmWindow - .seconds(2)]
        let wallet = ClockWallet(clock: clock)
        await assertExpired([.call(target(2), label: "Swap", notAfter: deadline)], sender: sender(clock: clock), wallet: wallet)
        XCTAssertEqual(chain.simulations, 1, "prepared")
        XCTAssertEqual(wallet.signatures, 0, "never signed")
        XCTAssertEqual(chain.sent.count, 0)
    }

    /// Once signed, the step is broadcast whatever the clock says afterwards, and followed to its receipt.
    func testASignedStepIsAlwaysBroadcast() async throws {
        let clock = ClockBox()
        let wallet = ClockWallet(clock: clock, advanceOnSign: .seconds(60))
        let hash = try await sender(clock: clock).run([.call(target(2), label: "Swap", notAfter: clock.start + OneInch.firmWindow)], from: wallet) { _ in }
        XCTAssertEqual(wallet.signatures, 1)
        XCTAssertEqual(chain.sent.count, 1)
        XCTAssertEqual(hash, Keccak.hash256(Data(hex: chain.sent[0].raw)!))
        XCTAssertEqual(clock.reads, 3, "before the start, before prepare, before signing: never after")
    }

    private func assertExpired(_ steps: [TransactionStep], sender: TransactionSender, wallet: Wallet, events: EventLog = EventLog(),
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await sender.run(steps, from: wallet) { events.append($0) }
            XCTFail("expected quoteExpired", file: file, line: line)
        } catch let error as TransactionError {
            guard case .quoteExpired = error else { return XCTFail("unexpected \(error)", file: file, line: line) }
            XCTAssertNil(error.hash, file: file, line: line)
            XCTAssertEqual(error.errorDescription, "The quote expired before the swap was signed, so the swap wasn't sent. Get a new quote and try again.", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Expected swap terms

    /// A step's call is read again against the terms it was reviewed with, before it is prepared: any difference is
    /// refused without a request. A match goes on to `prepare`, where the guard refuses it while 1inch is off.
    func testExpectedTermsAreCheckedBeforePrepare() async {
        let mismatches: [(String, TransactionRequest)] = [
            ("another contract", TransactionRequest(to: stranger, data: canonical)),
            ("an unreadable call", TransactionRequest(to: OneInch.router, data: canonical + Data([0x00]))),
            ("more in", TransactionRequest(to: OneInch.router, data: handBuilt(amount: amountIn + 1))),
            ("another token out", TransactionRequest(to: OneInch.router, data: handBuilt(dst: stranger))),
            ("a lower minimum", TransactionRequest(to: OneInch.router, data: handBuilt(minReturn: minReturn - 1))),
            ("another recipient", TransactionRequest(to: OneInch.router, data: handBuilt(dstReceiver: stranger))),
            ("MON sent", TransactionRequest(to: OneInch.router, data: canonical, value: 1)),
        ]
        for (name, request) in mismatches {
            RPCStub.hosts = []
            do {
                _ = try await sender().run([.call(request, label: "Swap", expectedSwap: expected)], from: StubWallet()) { _ in }
                XCTFail(name)
            } catch TransactionError.rejected(let message) {
                XCTAssertEqual(message, "This swap no longer matches what you reviewed, so nothing was sent for it.", name)
            } catch {
                XCTFail("\(name): \(error)")
            }
            XCTAssertEqual(RPCStub.hosts, [], name)
        }
        do {
            _ = try await sender().run([.call(TransactionRequest(to: OneInch.router, data: canonical), label: "Swap", expectedSwap: expected)], from: StubWallet()) { _ in }
            XCTFail("1inch is off in this build")
        } catch TransactionError.rejected(let message) {
            XCTAssertEqual(message, ThirdPartyCalldataGuard.Refusal.routerCall.message, "terms matched; the guard refused")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(RPCStub.hosts, [])
    }

    // MARK: Allowances

    /// The router's approval is skipped only at exactly the amount; every other spender keeps today's rule.
    func testRouterApprovalIsSkippedOnlyWhenExact() {
        let amount = amountIn
        XCTAssertTrue(TransactionSender.approvalIsCovered(allowance: amount, amount: amount, spender: OneInch.router))
        for allowance in [BigUInt(0), amount - 1, amount + 1, amount * 10, TransactionSender.unlimitedAllowance, BigUInt(2).power(256) - 1] {
            XCTAssertFalse(TransactionSender.approvalIsCovered(allowance: allowance, amount: amount, spender: OneInch.router), "\(allowance)")
        }
        for spender in [Uniswap.permit2, Kuru.entrypoint, MondayTrade.swapRouter, stranger] {
            XCTAssertTrue(TransactionSender.approvalIsCovered(allowance: amount, amount: amount, spender: spender))
            XCTAssertTrue(TransactionSender.approvalIsCovered(allowance: amount * 10, amount: amount, spender: spender), "a larger, bounded allowance covers it")
            XCTAssertFalse(TransactionSender.approvalIsCovered(allowance: amount - 1, amount: amount, spender: spender))
            XCTAssertFalse(TransactionSender.approvalIsCovered(allowance: TransactionSender.unlimitedAllowance, amount: amount, spender: spender), "an unlimited one is replaced")
            XCTAssertTrue(TransactionSender.approvalIsCovered(allowance: TransactionSender.unlimitedAllowance, amount: TransactionSender.unlimitedAllowance, spender: spender))
        }
        XCTAssertTrue(TransactionSender.ReplacedAllowance(spender: stranger, allowance: TransactionSender.unlimitedAllowance).isUnlimited)
        XCTAssertFalse(TransactionSender.ReplacedAllowance(spender: OneInch.router, allowance: amount * 10).isUnlimited)
    }
}

/// The device's clock for a run, moved by the test: `start` plus `offset`, or, while `script` has entries, the next one.
final class ClockBox: @unchecked Sendable {
    let start = ContinuousClock.now
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var count = 0
    var script: [Duration] {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }
    private var pending: [Duration] = []

    var now: ContinuousClock.Instant {
        lock.withLock {
            count += 1
            if !pending.isEmpty { offset = pending.removeFirst() }
            return start + offset
        }
    }

    var reads: Int { lock.withLock { count } }

    func advance(_ by: Duration) { lock.withLock { offset += by } }
}

/// Signs like `StubWallet`, counting signatures, and moves the clock by `advanceOnSign` each time it signs.
final class ClockWallet: Wallet, @unchecked Sendable {
    let address = Address(literal: "0x1111111111111111111111111111111111111111")
    private let clock: ClockBox
    private let advanceOnSign: Duration
    private let lock = NSLock()
    private var count = 0
    var signatures: Int { lock.withLock { count } }

    init(clock: ClockBox, advanceOnSign: Duration = .zero) {
        self.clock = clock
        self.advanceOnSign = advanceOnSign
    }

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        lock.withLock { count += 1 }
        clock.advance(advanceOnSign)
        return RLP.unsignedPayload(transaction)
    }

    func signMessage(_ message: Data) async throws -> Data { Data() }
}
