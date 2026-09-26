import BigInt
import XCTest
@testable import DyorKit

/// The session scope in MERA-PLAN §3: a table of plans the live session signs on its own (each app flow's real calldata
/// shape) and a table of plans that must ask — every always-ask class and every violation of the wallet's own check or
/// the caps. Plus the network-fee bound, the Kuru Flow decoder, the wallet-auth message template, the run-time Permit2
/// step, and the on-chain curve lookup.
final class MeraPolicyTests: XCTestCase {
    typealias Policy = Mera.SigningPolicy
    typealias Intent = Mera.Intent

    let account = Address(literal: "0x1111111111111111111111111111111111111111")
    let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    let launchToken = Address(literal: "0x3333333333333333333333333333333333333333")
    let curve = Address(literal: "0x4444444444444444444444444444444444444444")
    let erc20Pair = Address(literal: "0x5555555555555555555555555555555555555555")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var expiresAt: Date { now.addingTimeInterval(15 * 60) }
    var unix: Int { Int(now.timeIntervalSince1970) }
    let moments = MomentsAddresses.monadMainnet
    let usdcIn = BigUInt(50_000_000) // 50 USDC
    let monIn = BigUInt(10).power(18) * 10 // 10 MON

    private var context: Policy.Context {
        Policy.Context(account: account, expiresAt: expiresAt, verifiedCurves: [launchToken: curve])
    }

    // MARK: Builders

    private func call(_ to: Address, _ data: Data, value: BigUInt = 0, from: Address? = nil, chainId: Int = 143) -> Policy.Call {
        Policy.Call(from: from ?? account, to: to, data: data, value: value, chainId: chainId)
    }

    private func encode(_ signature: String, _ args: [ABIValue] = []) -> Data { try! ABI.encodeCall(signature, args) }

    private func approve(_ token: Address, _ spender: Address, _ amount: BigUInt, value: BigUInt = 0) -> Policy.Call {
        call(token, encode("approve(address,uint256)", [.address(spender), .uint(amount)]), value: value)
    }

    private func permit2(_ token: Address, _ amount: BigUInt, spender: Address = Uniswap.universalRouter, expiration: Int) -> Policy.Call {
        call(Uniswap.permit2, try! SwapCalldata.permit2Approve(token: token, spender: spender, amount: amount, expiration: BigUInt(expiration)))
    }

    private var universalRouterSwap: Data { encode("execute(bytes,bytes[],uint256)", [.bytes(Data([0x10])), .array([.bytes(Data([1, 2, 3]))]), .uint(unix + 600)]) }

    /// KuruFlowEntrypoint calldata in the layout read from its bytecode; `recipient` picks the explicit-recipient variant.
    private func kuru(tokenIn: Address, amountIn: BigUInt, tokenOut: Address, minOut: BigUInt, recipient: Address? = nil) -> Data {
        var args: [ABIValue] = [.address(tokenOut), .uint(minOut), .address(tokenIn), .uint(amountIn),
                                .tuple([.address(stranger), .uint(0), .address(.zero), .uint(0), .bool(true)]), .bytes(Data([0x02, 0x01, 0xff]))]
        var types = "address,uint256,address,uint256,(address,uint256,address,uint256,bool),bytes"
        if let recipient { args.append(.address(recipient)); types += ",address" }
        let selector = recipient == nil ? KuruFlowSwap.payCaller : KuruFlowSwap.payRecipient
        return selector + (try! ABI.encode(args, types))
    }

    private func curveCall(_ signature: String, _ amount: BigUInt, recipient: Address? = nil, value: BigUInt = 0, to: Address? = nil) -> Policy.Call {
        call(to ?? curve, encode(signature, [.uint(amount), .uint(1), .address(recipient ?? account)]), value: value)
    }

    /// An `execOrders` desc of `type` (0 OpenLong, 1 OpenShort, 2/3 Close, 4 Cancel, 5 IncreasePositionCollateral).
    private func perplOrders(_ types: [Int]) -> Policy.Call {
        let descs: [[ABIValue]] = types.enumerated().map { i, type in
            [.uint(i + 1), .uint(16), .uint(type), .uint(0), .uint(100), .uint(10), .uint(0), .bool(false), .bool(false), .bool(true), .uint(0), .uint(500), .uint(0), .uint(0), .uint(300)]
        }
        return call(Perpl.exchange, PerplExchange.execOrdersCalldata(descs, revertOnFail: true))
    }

    private var usdc: Address { Monad.usdc }
    private func swapIntent(_ venue: Venue, pay: Address, _ amount: BigUInt, receive: Address = Monad.native, out: BigUInt = 1_000_000, usd: Double? = 50) -> Intent {
        .swap(venue: venue, pay: .init(token: pay, amount: amount), receive: .init(token: receive, amount: out), usd: usd)
    }

    private func review(_ calls: [Policy.Call], _ intent: Intent, caps: Mera.SpendingCaps = Mera.SpendingCaps(), context: Policy.Context? = nil) -> Policy.Verdict {
        Policy.review(calls, intent: intent, context: context ?? self.context, caps: caps)
    }

    // MARK: Prompt-free

    func testSessionScopedPlansAreSilent() {
        let kuruOut = BigUInt(40) * BigUInt(10).power(18)
        let cases: [(String, [Policy.Call], Intent)] = [
            ("Uniswap v4, USDC → MON with exact approvals and a short Permit2 allowance",
             [approve(usdc, Uniswap.permit2, usdcIn), permit2(usdc, usdcIn, expiration: unix + SwapCalldata.exactPermit2Lifetime), call(Uniswap.universalRouter, universalRouterSwap)],
             swapIntent(.uniswap, pay: usdc, usdcIn)),
            ("Uniswap v4, MON in on value", [call(Uniswap.universalRouter, universalRouterSwap, value: monIn)], swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc)),
            ("Uniswap v3 through SwapRouter02", [approve(usdc, Uniswap.swapRouter02, usdcIn), call(Uniswap.swapRouter02, encode("multicall(uint256,bytes[])", [.uint(unix), .array([])]))],
             swapIntent(.uniswap, pay: usdc, usdcIn)),
            ("Monday Trade", [approve(usdc, MondayTrade.swapRouter, usdcIn), call(MondayTrade.swapRouter, encode("multicall(bytes[])", [.array([])]))], swapIntent(.monday, pay: usdc, usdcIn)),
            ("Kuru Flow, output to the caller, 0.5% slippage",
             [approve(usdc, Kuru.entrypoint, usdcIn), call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut * 995 / 1000))],
             swapIntent(.kuru, pay: usdc, usdcIn, out: kuruOut)),
            ("Kuru Flow, MON in, explicit recipient = the account",
             [call(Kuru.entrypoint, kuru(tokenIn: .zero, amountIn: monIn, tokenOut: usdc, minOut: 990, recipient: account), value: monIn)],
             swapIntent(.kuru, pay: Monad.native, monIn, receive: usdc, out: 1000)),
            ("Wrap MON", [call(Monad.wmon, encode("deposit()"), value: monIn)], swapIntent(.wrap, pay: Monad.native, monIn, receive: Monad.wmon, out: monIn)),
            ("Unwrap WMON", [call(Monad.wmon, encode("withdraw(uint256)", [.uint(monIn)]))], swapIntent(.wrap, pay: Monad.wmon, monIn, receive: Monad.native, out: monIn)),
            ("Launchpad buy, MON pair", [curveCall(LaunchpadABI.Curve.buy, monIn, value: monIn)], .launchpadBuy(token: launchToken, pay: .init(token: Monad.native, amount: monIn), usd: 30)),
            ("Launchpad buy, ERC-20 pair", [approve(erc20Pair, curve, usdcIn), curveCall(LaunchpadABI.Curve.buy, usdcIn)],
             .launchpadBuy(token: launchToken, pay: .init(token: erc20Pair, amount: usdcIn), usd: 50)),
            ("Launchpad sell", [approve(launchToken, curve, monIn), curveCall(LaunchpadABI.Curve.sell, monIn)], .launchpadSell(token: launchToken, amount: monIn, usd: 20)),
            ("Moments collect, exact approval", [approve(moments.usdc, moments.collect, usdcIn), call(moments.collect, encode(MomentsABI.Collect.collect, [.uint(7), .uint(2)]))],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50)),
            ("Moments claim", [call(moments.vesting, encode(MomentsABI.Vesting.claim, [.uint(7)]))], .momentsClaim),
            ("Moments claim all", [call(moments.vesting, encode(MomentsABI.Vesting.claimAll, [.array([.uint(7), .uint(8)])]))], .momentsClaim),
            ("Past-cohort claim", [call(MomentsAddresses.retiredMainnet[0].vesting, encode(MomentsABI.Vesting.claim, [.uint(3)]))], .momentsClaim),
            ("Creator proceeds", [call(moments.collect, encode(MomentsABI.Collect.withdrawCreator, [.uint(7)]))], .momentsWithdraw),
            ("Creator pool fees", [call(moments.hook, encode(MomentsABI.Hook.withdrawCreator, [.uint(7)]))], .momentsWithdraw),
            ("Perpl deposit", [approve(Perpl.collateral, Perpl.exchange, usdcIn), call(Perpl.exchange, encode(PerplExchange.Signature.depositCollateral, [.uint(usdcIn)]))],
             .perplDeposit(amount: usdcIn)),
            ("Perpl account opening", [approve(Perpl.collateral, Perpl.exchange, usdcIn), call(Perpl.exchange, encode(PerplExchange.Signature.createAccount, [.uint(usdcIn)]))],
             .perplDeposit(amount: usdcIn)),
            ("Perpl withdraw to self", [call(Perpl.exchange, encode(PerplExchange.Signature.withdrawCollateral, [.uint(usdcIn)]))], .perplWithdraw),
            ("Perpl opening orders", [perplOrders([0, 1])], .perplOrder(usd: 80)),
            ("Swap MON → AUSD, then deposit it",
             [call(Kuru.entrypoint, kuru(tokenIn: .zero, amountIn: monIn, tokenOut: Monad.ausd, minOut: 995), value: monIn),
              approve(Perpl.collateral, Perpl.exchange, 1000), call(Perpl.exchange, encode(PerplExchange.Signature.depositCollateral, [.uint(1000)]))],
             .combining([swapIntent(.kuru, pay: Monad.native, monIn, receive: Monad.ausd, out: 1000, usd: nil), .perplDeposit(amount: 1000)], usd: 60)),
            ("Nothing to sign", [], .momentsClaim),
        ]
        for (name, calls, intent) in cases {
            XCTAssertEqual(review(calls, intent), .allowed, name)
        }
    }

    // MARK: Asks

    func testEveryAlwaysAskClassAsks() {
        let transfer = call(usdc, encode("transfer(address,uint256)", [.address(stranger), .uint(usdcIn)]))
        for what in Mera.AlwaysAsk.allCases {
            XCTAssertEqual(review([transfer], .alwaysAsks(what)), .ask(.alwaysAsks(what)), what.rawValue)
            XCTAssertFalse(what.summary.isEmpty)
        }
        // An untagged sheet fails closed, even for a call a swap would allow.
        XCTAssertEqual(review([call(Uniswap.universalRouter, universalRouterSwap)], .ask), .ask(.alwaysAsks(.unlisted)))
        // A combination with an always-ask part asks as a whole.
        XCTAssertEqual(Intent.combining([swapIntent(.uniswap, pay: usdc, usdcIn), .alwaysAsks(.send)], usd: 1), .alwaysAsks(.send))
    }

    func testViolationsAsk() {
        let uni = swapIntent(.uniswap, pay: usdc, usdcIn)
        let kuruOut = BigUInt(1_000_000)
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: kuruOut)
        let sell = Intent.launchpadSell(token: launchToken, amount: monIn, usd: 20)
        let cases: [(String, [Policy.Call], Intent, Policy.Reason)] = [
            // Chain, sender and allowlist.
            ("another chain", [call(Uniswap.universalRouter, universalRouterSwap, chainId: 1)], uni, .wrongChain),
            ("another sender", [call(Uniswap.universalRouter, universalRouterSwap, from: stranger)], uni, .wrongSender),
            ("an unknown contract", [call(stranger, universalRouterSwap)], uni, .notAllowlisted),
            ("a plain MON transfer inside a swap", [call(stranger, Data(), value: 1)], swapIntent(.uniswap, pay: Monad.native, monIn), .notAllowlisted),
            ("a token transfer inside a swap", [call(usdc, encode("transfer(address,uint256)", [.address(stranger), .uint(1)]))], uni, .notAllowlisted),
            ("a Uniswap call declared as Monday", [call(Uniswap.universalRouter, universalRouterSwap)], swapIntent(.monday, pay: usdc, usdcIn), .notAllowlisted),
            // ERC-20 approvals.
            ("the old standing max approval to Permit2", [approve(usdc, Uniswap.permit2, SwapCalldata.maxUint160)], uni, .approval(.amount)),
            ("an approval above the input", [approve(usdc, Uniswap.swapRouter02, usdcIn + 1)], uni, .approval(.amount)),
            ("an approval to a stranger", [approve(usdc, stranger, usdcIn)], uni, .approval(.spender)),
            ("an approval of another token", [approve(Monad.wmon, Uniswap.permit2, usdcIn)], uni, .approval(.token)),
            ("an approval carrying MON", [approve(usdc, Uniswap.permit2, usdcIn, value: 1)], uni, .approval(.value)),
            ("an approval when the input is MON", [approve(usdc, Uniswap.permit2, 1)], swapIntent(.uniswap, pay: Monad.native, monIn), .approval(.token)),
            // Permit2.
            ("the old 30-day Permit2 allowance", [permit2(usdc, usdcIn, expiration: unix + 30 * 24 * 3600)], uni, .approval(.expiration)),
            ("a Permit2 allowance one second past the session", [permit2(usdc, usdcIn, expiration: Int(expiresAt.timeIntervalSince1970) + 1)], uni, .approval(.expiration)),
            ("a Permit2 allowance above the input", [permit2(usdc, usdcIn + 1, expiration: unix + 60)], uni, .approval(.amount)),
            ("a Permit2 allowance for a stranger", [permit2(usdc, usdcIn, spender: stranger, expiration: unix + 60)], uni, .approval(.spender)),
            ("a Permit2 allowance outside a Uniswap swap", [permit2(usdc, usdcIn, expiration: unix + 60)], swapIntent(.monday, pay: usdc, usdcIn), .notAllowlisted),
            // MON.
            ("more MON than declared", [call(Uniswap.universalRouter, universalRouterSwap, value: monIn + 1)], swapIntent(.uniswap, pay: Monad.native, monIn), .valueOverDeclared),
            ("MON with an ERC-20 input", [call(Uniswap.universalRouter, universalRouterSwap, value: 1)], uni, .valueOverDeclared),
            ("unwrapping more than declared", [call(Monad.wmon, encode("withdraw(uint256)", [.uint(monIn + 1)]))], swapIntent(.wrap, pay: Monad.wmon, monIn), .amountOverDeclared),
            // Kuru Flow.
            ("Kuru output to another address", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut, recipient: stranger))], kuruIntent, .recipient),
            ("Kuru minimum below 99% of the quote", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut * 98 / 100))], kuruIntent, .minimumOut),
            ("Kuru selling another token", [call(Kuru.entrypoint, kuru(tokenIn: Monad.wmon, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut))], kuruIntent, .differentToken),
            ("Kuru buying another token", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.wmon, minOut: kuruOut))], kuruIntent, .differentToken),
            ("Kuru selling more than declared", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn + 1, tokenOut: Monad.native, minOut: kuruOut))], kuruIntent, .amountOverDeclared),
            ("an unknown Kuru function", [call(Kuru.entrypoint, encode("transferOwnership(address)", [.address(stranger)]))], kuruIntent, .notAllowlisted),
            // Launchpad.
            ("a curve no known factory recorded", [curveCall(LaunchpadABI.Curve.sell, monIn, to: stranger)], sell, .unverifiedCurve),
            ("an approval to an unverified curve", [approve(launchToken, curve, monIn)], sell, .unverifiedCurve),
            ("curve proceeds to another address", [curveCall(LaunchpadABI.Curve.sell, monIn, recipient: stranger)], sell, .recipient),
            ("selling more than declared", [curveCall(LaunchpadABI.Curve.sell, monIn + 1)], sell, .amountOverDeclared),
            ("a buy declared as a sell", [curveCall(LaunchpadABI.Curve.buy, monIn)], sell, .notAllowlisted),
            // Moments.
            ("collecting on a retired cohort", [call(MomentsAddresses.retiredMainnet[0].collect, encode(MomentsABI.Collect.collect, [.uint(1), .uint(1)]))],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50), .notAllowlisted),
            ("a platform withdrawal as withdraw-to-self", [call(moments.collect, encode(MomentsABI.Collect.withdrawPlatform, [.uint(7)]))], .momentsWithdraw, .notAllowlisted),
            ("a claim on a stranger contract", [call(stranger, encode(MomentsABI.Vesting.claim, [.uint(7)]))], .momentsClaim, .notAllowlisted),
            // Perpl.
            ("depositing more than declared", [call(Perpl.exchange, encode(PerplExchange.Signature.depositCollateral, [.uint(usdcIn + 1)]))], .perplDeposit(amount: usdcIn), .amountOverDeclared),
            ("a cancel inside an order", [perplOrders([0, 4])], .perplOrder(usd: 10), .notAllowlisted),
            ("a reduce-only close", [perplOrders([2])], .perplOrder(usd: 10), .notAllowlisted),
            ("a margin move", [perplOrders([5])], .perplOrder(usd: 10), .notAllowlisted),
        ]
        for (name, calls, intent, reason) in cases {
            XCTAssertEqual(review(calls, intent, context: name.contains("unverified") ? Policy.Context(account: account, expiresAt: expiresAt) : nil), .ask(reason), name)
        }
    }

    func testCapsAndPricing() {
        let swap = [call(Uniswap.universalRouter, universalRouterSwap, value: monIn)]
        func intent(_ usd: Double?) -> Intent { swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc, usd: usd) }
        XCTAssertEqual(review(swap, intent(100)), .allowed, "exactly the per-action cap")
        XCTAssertEqual(review(swap, intent(nil)), .ask(.unpriced))
        XCTAssertEqual(review(swap, intent(.nan)), .ask(.unpriced))
        XCTAssertEqual(review(swap, intent(100.01)), .ask(.overActionCap))
        var spent = Mera.SpendingCaps()
        spent.charge(100); spent.charge(100)
        XCTAssertEqual(review(swap, intent(50), caps: spent), .allowed, "exactly the session cap")
        XCTAssertEqual(review(swap, intent(50.01), caps: spent), .ask(.overSessionCap))
        // A violation is reported before the caps, whatever the price.
        XCTAssertEqual(review([call(stranger, Data())], intent(nil)), .ask(.notAllowlisted))
        // Reasons read as "Face ID required: <reason>".
        XCTAssertEqual(Policy.Reason.overActionCap.summary, "over the $100 limit per action")
        XCTAssertEqual(Policy.Reason.locked.summary, "your session is locked")
    }

    // MARK: Network fee

    func testNetworkFeeIsBoundedWhateverTheApproval() {
        let gwei = BigUInt(10).power(9)
        let intent = swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc)
        func prepared(to: Address = Uniswap.universalRouter, data: Data? = nil, value: BigUInt? = nil, gasLimit: BigUInt, maxFee: BigUInt, tip: BigUInt = 2 * gwei, chainId: Int = Monad.chainId) -> Policy.Call {
            Policy.Call(PreparedTransaction(from: account, to: to, data: data ?? universalRouterSwap, value: value ?? monIn, nonce: 7,
                                            gasLimit: gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip, chainId: chainId))
        }
        func refusal(_ call: Policy.Call, _ intent: Intent) -> Policy.Reason? { Policy.refusal(call, intent: intent, account: account) }
        // A normal swap: ~300k gas estimated plus 20%, at twice a 100 gwei base fee plus a 2 gwei tip — about 0.07 MON.
        let normal = prepared(gasLimit: 360_000, maxFee: 202 * gwei)
        XCTAssertEqual(normal.gasLimit, 360_000, "the prepared transaction's fee is kept")
        XCTAssertEqual(normal.maxFeePerGas, 202 * gwei)
        XCTAssertEqual(normal.maxPriorityFeePerGas, 2 * gwei)
        XCTAssertNil(refusal(normal, intent))
        XCTAssertEqual(review([normal], intent), .allowed, "the fee is no reason to ask")
        XCTAssertNil(refusal(prepared(gasLimit: 10_000_000, maxFee: 500 * gwei), intent), "exactly 5 MON")
        XCTAssertNil(refusal(prepared(gasLimit: Policy.maxGasLimit, maxFee: 202 * gwei), intent), "exactly the gas limit ceiling")
        // The largest the app sends: a launch with its first buy (~6.2M gas limit), approved by a step-up.
        XCTAssertNil(refusal(prepared(to: stranger, gasLimit: 6_200_000, maxFee: 202 * gwei), .alwaysAsks(.launch)))
        // A graduating Moment collect reserves 3M gas for the graduation: prompt-free still, since its fee is ordinary.
        XCTAssertNil(refusal(prepared(gasLimit: 4_000_000, maxFee: 202 * gwei), intent))
        // A Kuru swap with an exact approval: each step is bounded on its own.
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: 1000)
        let kuruApprove = prepared(to: usdc, data: encode("approve(address,uint256)", [.address(Kuru.entrypoint), .uint(usdcIn)]), value: 0, gasLimit: 60_000, maxFee: 202 * gwei)
        func kuruSwap(_ gasLimit: BigUInt, _ maxFee: BigUInt) -> Policy.Call {
            prepared(to: Kuru.entrypoint, data: kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995), value: 0, gasLimit: gasLimit, maxFee: maxFee)
        }
        XCTAssertNil(refusal(kuruApprove, kuruIntent))
        XCTAssertNil(refusal(kuruSwap(400_000, 202 * gwei), kuruIntent))
        XCTAssertEqual(review([kuruApprove, kuruSwap(400_000, 202 * gwei)], kuruIntent), .allowed)
        XCTAssertEqual(refusal(kuruSwap(400_000, 100_000 * gwei), kuruIntent), .networkFee, "a huge max fee on the swap step")

        let refused: [(String, Policy.Call)] = [
            ("a huge gas limit", prepared(gasLimit: 50_000_000, maxFee: 202 * gwei)),
            ("a gas limit over 15M, even at a tiny fee", prepared(gasLimit: Policy.maxGasLimit + 1, maxFee: 1, tip: 1)),
            ("a huge max fee", prepared(gasLimit: 360_000, maxFee: 1_000_000 * gwei)),
            ("one wei per gas over 5 MON", prepared(gasLimit: 10_000_000, maxFee: 500 * gwei + 1)),
            ("a tip above the max fee", prepared(gasLimit: 360_000, maxFee: 202 * gwei, tip: 202 * gwei + 1)),
            ("a fee given in part", Policy.Call(from: account, to: Uniswap.universalRouter, data: universalRouterSwap, value: monIn, gasLimit: 360_000)),
        ]
        for (name, call) in refused {
            // Refused for a session-OK swap and for an action a step-up approves alike: no Face ID vouches for the fee.
            XCTAssertEqual(refusal(call, intent), .networkFee, name)
            XCTAssertEqual(refusal(call, .ask), .networkFee, "\(name), approved")
            XCTAssertEqual(refusal(call, .alwaysAsks(.send)), .networkFee, "\(name), a send")
        }
        // Only Monad's fee is bounded here: a bridge's source transaction on another chain has that chain's fee market.
        XCTAssertNil(refusal(prepared(gasLimit: 50_000_000, maxFee: 202 * gwei, chainId: 42_161), .alwaysAsks(.bridge)))
        // A preview has no fee yet, so the fee decides nothing before it is prepared.
        let preview = Policy.Call(step: .call(TransactionRequest(to: Uniswap.universalRouter, data: universalRouterSwap, value: monIn), label: "Swap"), from: account)
        XCTAssertNil(preview?.gasLimit)
        XCTAssertNil(preview.flatMap { refusal($0, intent) })
        XCTAssertEqual(Policy.Reason.networkFee.summary, "an unusually high network fee")
    }

    /// Kuru's minimum at the 1% slippage preset is floor(out × 99 / 100), as Kuru and `SwapMath` round it: prompt-free
    /// whatever the quote's last digits, and one unit less asks.
    func testKuruOnePercentMinimumIsPromptFreeWhateverTheRounding() {
        for out in [BigUInt(2_587_123), BigUInt(1_000_001), BigUInt(99), BigUInt(40) * BigUInt(10).power(18) + 7] {
            let intent = swapIntent(.kuru, pay: usdc, usdcIn, out: out)
            let minimum = SwapMath.minAfterSlippage(out, bps: 100)
            func swap(_ minOut: BigUInt) -> [Policy.Call] { [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: minOut))] }
            XCTAssertEqual(review(swap(minimum), intent), .allowed, "1% of \(out)")
            if minimum > 0 { XCTAssertEqual(review(swap(minimum - 1), intent), .ask(.minimumOut), "just under 1% of \(out)") }
        }
    }

    func testForeignRecipientOrTokenIsRefusedWhateverTheApproval() {
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: 1000)
        func refusal(_ call: Policy.Call, _ intent: Intent) -> Policy.Reason? { Policy.refusal(call, intent: intent, account: account) }
        let own = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995))
        let ownExplicit = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995, recipient: account))
        let paysStranger = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995, recipient: stranger))
        let otherToken = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: erc20Pair, minOut: 995))
        XCTAssertNil(refusal(own, kuruIntent))
        XCTAssertNil(refusal(ownExplicit, kuruIntent))
        // The output to someone else: refused for the sheet that declared the swap, and for any approved action too.
        XCTAssertEqual(refusal(paysStranger, kuruIntent), .recipient)
        XCTAssertEqual(refusal(paysStranger, .ask), .recipient)
        XCTAssertEqual(refusal(paysStranger, .alwaysAsks(.send)), .recipient)
        // A token other than the ones shown, when the sheet declared a Kuru swap.
        XCTAssertEqual(refusal(otherToken, kuruIntent), .differentToken)
        XCTAssertEqual(refusal(otherToken, .combining([swapIntent(.kuru, pay: usdc, usdcIn, receive: erc20Pair), kuruIntent], usd: 50)), nil, "any declared Kuru part may match")
        // The session check still names them first for a live session (it would ask); the refusal stops the approval.
        XCTAssertEqual(Policy.check(paysStranger, intent: kuruIntent, context: context), .ask(.recipient))
        // A launchpad trade the sheet declared must pay this account.
        let buy = Intent.launchpadBuy(token: launchToken, pay: .init(token: Monad.native, amount: monIn), usd: 30)
        let sell = Intent.launchpadSell(token: launchToken, amount: 1000, usd: 30)
        XCTAssertNil(refusal(curveCall(LaunchpadABI.Curve.buy, monIn, value: monIn), buy))
        XCTAssertEqual(refusal(curveCall(LaunchpadABI.Curve.buy, monIn, recipient: stranger, value: monIn), buy), .recipient)
        XCTAssertNil(refusal(curveCall(LaunchpadABI.Curve.sell, 1000), sell))
        XCTAssertEqual(refusal(curveCall(LaunchpadABI.Curve.sell, 1000, recipient: stranger), sell), .recipient)
        // Nothing else is second-guessed here: other calls fall to the session check (which asks) and the step-up.
        XCTAssertNil(refusal(call(stranger, Data([1, 2, 3, 4])), .alwaysAsks(.send)))
    }

    // MARK: Messages

    func testOnlyTheWalletAuthTemplateIsPromptFree() {
        let nonce = String(repeating: "ab", count: 32)
        let millis = unix * 1000 + 123
        func signIn(_ address: String, _ nonce: String, _ issued: Int) -> Data { Data(SupabaseClient.signInMessage(address: address, nonce: nonce, issuedAt: issued).utf8) }
        XCTAssertEqual(Policy.check(message: signIn(account.checksummed, nonce, millis), account: account, now: now), .allowed)
        XCTAssertEqual(Policy.check(message: signIn(account.hex, nonce, millis), account: account, now: now), .allowed, "lowercase address as sent")
        let asks: [(String, Data)] = [
            ("another wallet", signIn(stranger.checksummed, nonce, millis)),
            ("issued six minutes ago", signIn(account.checksummed, nonce, millis - 6 * 60 * 1000)),
            ("issued in the future", signIn(account.checksummed, nonce, millis + 6 * 60 * 1000)),
            ("an uppercase nonce", signIn(account.checksummed, nonce.uppercased(), millis)),
            ("a short nonce", signIn(account.checksummed, "abcd", millis)),
            ("a trailing newline", signIn(account.checksummed, nonce, millis) + Data("\n".utf8)),
            ("a carriage return", Data("DyorHQ Sign-In\r\n\r\nWallet: \(account.checksummed)\r\nNonce: \(nonce)\r\nIssued At: \(millis)".utf8)),
            ("an arbitrary message", Data("Transfer all funds".utf8)),
            ("the email rebind message", Data("DyorHQ Email Rebind\n\nEmail: a@b.c\nAddress: \(account.hex)\nIssued At: \(millis)".utf8)),
            ("not UTF-8", Data([0xff, 0xfe, 0x00])),
        ]
        for (name, message) in asks {
            XCTAssertEqual(Policy.check(message: message, account: account, now: now), .ask(.alwaysAsks(.message)), name)
        }
    }

    // MARK: Kuru Flow calldata

    func testKuruFlowSwapDecoding() throws {
        let caller = try XCTUnwrap(KuruFlowSwap(calldata: kuru(tokenIn: usdc, amountIn: 7, tokenOut: .zero, minOut: 5)))
        XCTAssertEqual(caller.tokenIn, usdc)
        XCTAssertEqual(caller.amountIn, 7)
        XCTAssertEqual(caller.tokenOut, .zero)
        XCTAssertEqual(caller.minAmountOut, 5)
        XCTAssertNil(caller.recipient, "ce1e7030 pays msg.sender")
        let explicit = try XCTUnwrap(KuruFlowSwap(calldata: kuru(tokenIn: .zero, amountIn: 7, tokenOut: usdc, minOut: 5, recipient: stranger)))
        XCTAssertEqual(explicit.recipient, stranger)
        // Another selector, a truncated head, or an address word with dirty high bytes decodes to nothing.
        XCTAssertNil(KuruFlowSwap(calldata: Data([0xde, 0xad, 0xbe, 0xef]) + Data(count: 320)))
        XCTAssertNil(KuruFlowSwap(calldata: KuruFlowSwap.payCaller + Data(count: 64)))
        var dirty = kuru(tokenIn: usdc, amountIn: 7, tokenOut: .zero, minOut: 5)
        dirty[4] = 0x01
        XCTAssertNil(KuruFlowSwap(calldata: dirty))
        XCTAssertNil(KuruFlowSwap(calldata: KuruFlowSwap.payRecipient + Data(count: 320)), "the recipient variant needs its eleventh head word")
        // Whatever sits in the eleventh word is the recipient the contract pays, so it is what the check compares.
        let reread = try XCTUnwrap(KuruFlowSwap(calldata: KuruFlowSwap.payRecipient + Data(kuru(tokenIn: usdc, amountIn: 7, tokenOut: .zero, minOut: 5).dropFirst(4))))
        XCTAssertNotEqual(reread.recipient, account)
    }

    // MARK: Builders

    func testRuntimePermit2StepExpiresShortlyAfterItIsSent() throws {
        let step = TransactionStep.permit2Approve(token: usdc, spender: Uniswap.universalRouter, amount: usdcIn, lifetime: SwapCalldata.exactPermit2Lifetime, label: "Permit")
        let request = try XCTUnwrap(try step.request(at: now))
        XCTAssertEqual(request.to, Uniswap.permit2)
        XCTAssertEqual(request.data, try SwapCalldata.permit2Approve(token: usdc, spender: Uniswap.universalRouter, amount: usdcIn, expiration: BigUInt(unix + 120)))
        XCTAssertEqual(review([Policy.Call(step: step, from: account, now: now)!], swapIntent(.uniswap, pay: usdc, usdcIn)), .allowed)
        // In the session's last two minutes the same step would outlast it, so it asks.
        let late = Policy.Context(account: account, expiresAt: now.addingTimeInterval(90))
        XCTAssertEqual(review([Policy.Call(step: step, from: account, now: now)!], swapIntent(.uniswap, pay: usdc, usdcIn), context: late), .ask(.approval(.expiration)))
        // An approval step previews as its `approve` call.
        let approval = TransactionStep.approve(token: usdc, spender: Uniswap.permit2, amount: usdcIn, label: "Approve")
        XCTAssertEqual(Policy.Call(step: approval, from: account)?.data, try ERC20.approveCalldata(spender: Uniswap.permit2, amount: usdcIn))
        XCTAssertFalse(SwapRequest(tokenIn: .usdc, tokenOut: .mon, amountIn: 1, slippageBps: 50, account: account).exactApprovals, "standing approvals stay the default")
    }

    func testKnownCurveComesFromAKnownFactoryRecord() {
        func record(curve: Address, exists: Bool, legacy: Bool) -> ABIValue {
            // 17 fields (16 for the first deployment): token, curve, …, exists last.
            var fields: [ABIValue] = [.address(launchToken), .address(curve), .address(stranger), .address(stranger), .address(.zero), .uint(0),
                                      .uint(0), .uint(0), .int(0), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(exists)]
            if legacy { fields.remove(at: 10) }
            return .tuple(fields)
        }
        let stacks = [LaunchpadAddresses.monadMainnet] + LaunchpadAddresses.retiredStacks
        struct Failed: Error {}
        let found = LaunchpadService.knownCurve(stacks: stacks, records: [
            .failure(Failed()),
            .success([record(curve: .zero, exists: false, legacy: false)]),
            .success([record(curve: stranger, exists: false, legacy: false)]),
            .success([record(curve: curve, exists: true, legacy: true)]),
        ])
        XCTAssertEqual(found, curve, "the first stack that recorded the launch, legacy layout included")
        XCTAssertNil(LaunchpadService.knownCurve(stacks: stacks, records: stacks.map { .success([record(curve: curve, exists: false, legacy: $0.legacyRecord)]) }))
    }
}
