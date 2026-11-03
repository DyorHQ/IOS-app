import BigInt
import XCTest
@testable import DyorKit

/// The passkey policy on 1inch and xStocks, with no venue in the build: anything on 1inch, or touching a known xStock,
/// always asks (an approval included, however small); Aqua and SwapVMRouter are refused outright; a router call is
/// refused while 1inch is off, and otherwise unless it is the declared swap read in full. Every token here but USDC is a
/// test fixture.
final class MeraOneInchPolicyTests: XCTestCase {
    typealias Policy = Mera.SigningPolicy
    typealias Intent = Mera.Intent

    let account = Address(literal: "0x1111111111111111111111111111111111111111")
    let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    let executor = Address(literal: "0x5555555555555555555555555555555555555555")
    /// A test-only stand-in for an xStock: no real token.
    let stock = Address(literal: "0x7777777777777777777777777777777777777777")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let usdcIn = BigUInt(10_000_000) // 10 USDC
    let stockOut = BigUInt(100_000_000_000_000_000) // 0.1 of an 18-decimal token

    private var context: Policy.Context { Policy.Context(account: account, expiresAt: now.addingTimeInterval(15 * 60)) }

    private func call(_ to: Address, _ data: Data, value: BigUInt = 0) -> Policy.Call {
        Policy.Call(from: account, to: to, data: data, value: value)
    }

    private func approve(_ token: Address, _ spender: Address, _ amount: BigUInt) -> Policy.Call {
        call(token, try! ABI.encodeCall("approve(address,uint256)", [.address(spender), .uint(amount)]))
    }

    private func swap(src: Address = Monad.usdc, dst: Address? = nil, receiver: Address? = nil, amount: BigUInt? = nil,
                      minReturn: BigUInt? = nil, flags: BigUInt = 0) -> Data {
        try! OneInchSwap.calldata(executor: executor, srcToken: src, dstToken: dst ?? stock, srcReceiver: executor, dstReceiver: receiver ?? account,
                                  amount: amount ?? usdcIn, minReturn: minReturn ?? SwapMath.minAfterSlippage(stockOut, bps: 100), flags: flags)
    }

    private func oneInchIntent(usd: Double? = 10, out: BigUInt? = nil) -> Intent {
        .swap(venue: .oneInch, pay: .init(token: Monad.usdc, amount: usdcIn), receive: .init(token: stock, amount: out ?? stockOut), usd: usd)
    }

    // MARK: Always asks

    /// An approve-only plan under a 1inch part, $10 of USDC to the router, is never prompt-free; nor is the swap, nor a
    /// combination with an ordinary part the call would otherwise fit.
    func testOneInchAlwaysAsks() {
        let caps = Mera.SpendingCaps()
        let approval = approve(Monad.usdc, OneInch.router, usdcIn)
        XCTAssertEqual(Policy.review([approval], intent: oneInchIntent(), context: context, caps: caps), .ask(.alwaysAsks(.tokenizedStock)))
        XCTAssertNotEqual(Policy.review([approval], intent: oneInchIntent(), context: context, caps: caps), .allowed)
        XCTAssertEqual(Policy.check(approval, intent: oneInchIntent(), context: context), .ask(.alwaysAsks(.tokenizedStock)))
        XCTAssertEqual(Policy.check(call(OneInch.router, swap()), intent: oneInchIntent(), context: context), .ask(.alwaysAsks(.tokenizedStock)))
        XCTAssertEqual(Policy.review([], intent: oneInchIntent(), context: context, caps: caps), .ask(.alwaysAsks(.tokenizedStock)), "even with nothing to sign")
        // A Kuru approval the Kuru part alone would allow still asks next to a 1inch part.
        let combined = Intent.combining([.swap(venue: .kuru, pay: .init(token: Monad.usdc, amount: usdcIn), receive: .init(token: Monad.native, amount: 1), usd: 5),
                                         oneInchIntent()], usd: 15)
        XCTAssertEqual(Policy.check(approve(Monad.usdc, Kuru.entrypoint, usdcIn), intent: combined, context: context), .ask(.alwaysAsks(.tokenizedStock)))
        XCTAssertEqual(Mera.AlwaysAsk.tokenizedStock.summary, "trading xStocks (tokenized stocks)")
    }

    /// A part whose input or output is a known xStock always asks, whatever its kind; with the empty registry of this
    /// build, nothing is one.
    func testKnownStockPartsAlwaysAsk() {
        let known: (Address) -> Bool = { $0 == self.stock }
        let uniswapBuy = Intent.Part(kind: .swap(.uniswap), input: .init(token: Monad.usdc, amount: usdcIn), output: .init(token: stock, amount: 1))
        let kuruSell = Intent.Part(kind: .swap(.kuru), input: .init(token: stock, amount: 1), output: .init(token: Monad.usdc, amount: 1))
        let deposit = Intent.Part(kind: .perplDeposit, input: .init(token: stock, amount: 1))
        for part in [uniswapBuy, kuruSell, deposit] {
            XCTAssertTrue(Policy.alwaysAsksForStock(part, isKnown: known), "\(part.kind)")
            XCTAssertFalse(Policy.alwaysAsksForStock(part), "no token is a known xStock in this build")
        }
        XCTAssertTrue(Policy.alwaysAsksForStock(Intent.Part(kind: .swap(.oneInch))))
        XCTAssertFalse(Policy.alwaysAsksForStock(Intent.Part(kind: .swap(.uniswap), input: .init(token: Monad.usdc, amount: 1), output: .init(token: Monad.native, amount: 1)),
                                                 isKnown: known))
    }

    func testRouterIsASpenderNotACurve() {
        XCTAssertEqual(Policy.curveCandidates([approve(Monad.usdc, OneInch.router, usdcIn), approve(Monad.usdc, OneInch.aqua, 1)]), [])
        XCTAssertTrue(Policy.notCurves.isSuperset(of: [OneInch.router, OneInch.aqua, OneInch.swapVMRouter]))
    }

    // MARK: Refused outright

    /// While 1inch is off, every router call is refused, whatever the sheet declared; Aqua and SwapVMRouter always are.
    func testOneInchIsRefusedWhileOff() {
        for intent in [oneInchIntent(), .ask, .swap(venue: .uniswap, pay: .init(token: Monad.usdc, amount: usdcIn), receive: .init(token: stock, amount: stockOut), usd: 10)] {
            XCTAssertEqual(Policy.refusal(call(OneInch.router, swap()), intent: intent, account: account), .unreadableSwap)
            XCTAssertEqual(Policy.refusal(call(OneInch.router, Data(), value: 1), intent: intent, account: account), .unreadableSwap)
            XCTAssertEqual(Policy.refusal(call(OneInch.aqua, swap()), intent: intent, account: account), .unreadableSwap)
            XCTAssertEqual(Policy.refusal(call(OneInch.swapVMRouter, Data([1, 2, 3, 4])), intent: intent, account: account), .unreadableSwap)
            XCTAssertEqual(Policy.refusal(approve(Monad.usdc, OneInch.aqua, 1), intent: intent, account: account), .unreadableSwap)
            XCTAssertEqual(Policy.refusal(call(Monad.usdc, try! ABI.encodeCall("increaseAllowance(address,uint256)", [.address(OneInch.swapVMRouter), .uint(1)])),
                                          intent: intent, account: account), .unreadableSwap)
            XCTAssertEqual(Policy.refusal(call(Uniswap.permit2, try! SwapCalldata.permit2Approve(token: Monad.usdc, spender: OneInch.swapVMRouter, amount: 1, expiration: 1)),
                                          intent: intent, account: account), .unreadableSwap)
            // The exact approval of the router is not refused: it asks (above), and the guard keeps it exact.
            XCTAssertNil(Policy.refusal(approve(Monad.usdc, OneInch.router, usdcIn), intent: intent, account: account))
        }
        XCTAssertEqual(Policy.Reason.unreadableSwap.summary, "a 1inch transaction DyorHQ can’t read in full")
    }

    /// With 1inch compiled in, a router call is refused unless it is the declared swap, read in full, within the stock
    /// slippage limit: each binding has its own reason. Every call is checked against the stock's reference price ($100,
    /// the price of 10 USDC for 0.1 stock), since without one a router swap is refused for its price.
    func testRouterSwapIsBoundToTheDeclaredSwap() {
        let reference = XStockReference.Snapshot(stock: stock, answer: 10_000_000_000, decimals: 8, stockDecimals: 18, updatedAt: 1, readAt: 2)
        func refusal(_ data: Data, value: BigUInt = 0, intent: Intent? = nil) -> Policy.Reason? {
            Policy.oneInchRefusal(call(OneInch.router, data, value: value), intent: intent ?? oneInchIntent(), account: account, compiledIn: true,
                                  reference: reference)
        }
        let floor = SwapMath.minAfterSlippage(stockOut, bps: OneInch.stockSlippageCapBps)
        XCTAssertNil(refusal(swap()), "the declared swap at the slippage limit")
        XCTAssertNil(refusal(swap(amount: usdcIn - 1, minReturn: stockOut)), "less in, a better minimum")
        XCTAssertEqual(refusal(swap(receiver: stranger)), .recipient)
        XCTAssertEqual(refusal(swap(receiver: .zero)), .recipient)
        XCTAssertEqual(refusal(swap(flags: 1)), .unreadableSwap)
        XCTAssertEqual(refusal(swap(), value: 1), .unreadableSwap)
        XCTAssertEqual(refusal(swap(src: Monad.usdt0)), .differentToken)
        XCTAssertEqual(refusal(swap(dst: stranger)), .differentToken)
        XCTAssertEqual(refusal(swap(amount: usdcIn + 1)), .amountOverDeclared)
        XCTAssertEqual(refusal(swap(minReturn: floor - 1)), .stockMinimumOut)
        // The declared swap with no reference to price it against.
        XCTAssertEqual(Policy.oneInchRefusal(call(OneInch.router, swap()), intent: oneInchIntent(), account: account, compiledIn: true), .stockPrice)
        XCTAssertEqual(refusal(swap() + Data([0x00])), .unreadableSwap, "a suffix")
        XCTAssertEqual(refusal(Data([0x01, 0x02, 0x03, 0x04])), .unreadableSwap)
        XCTAssertEqual(refusal(swap(), intent: .swap(venue: .uniswap, pay: .init(token: Monad.usdc, amount: usdcIn), receive: .init(token: stock, amount: stockOut), usd: 10)),
                       .unreadableSwap, "no 1inch part declares it")
        XCTAssertEqual(refusal(swap(), intent: .ask), .unreadableSwap)
        // Off, the same calls are all refused.
        XCTAssertEqual(Policy.oneInchRefusal(call(OneInch.router, swap()), intent: oneInchIntent(), account: account, compiledIn: false), .unreadableSwap)
        // Calls to anything else are not this check's.
        XCTAssertNil(Policy.oneInchRefusal(call(Kuru.entrypoint, swap()), intent: oneInchIntent(), account: account, compiledIn: true))
        XCTAssertEqual(Policy.Reason.stockMinimumOut.summary, "a minimum received more than 1% below the amount shown")
        XCTAssertNotEqual(Policy.Reason.stockMinimumOut.summary, Policy.Reason.minimumOut.summary, "not the 99% copy")
    }

    /// The stock a passkey wallet reads the reference of before it prices a plan (`referenceStock`): the side of the first
    /// router swap that isn't USDC, for a buy and a sell alike, and none for a plan with no router swap (an approval, a
    /// call elsewhere, unreadable calldata), so nothing is read for it. With that reference, a firm buy and a firm sell
    /// at its price are signed; a reference of another stock refuses.
    func testAPasskeyFirmStockSwapIsPricedAgainstItsStocksReference() {
        let sell = swap(src: stock, dst: Monad.usdc, amount: stockOut, minReturn: SwapMath.minAfterSlippage(usdcIn, bps: 100))
        XCTAssertEqual(Policy.referenceStock([approve(Monad.usdc, OneInch.router, usdcIn), call(OneInch.router, swap())]), stock)
        XCTAssertEqual(Policy.referenceStock([call(OneInch.router, sell)]), stock)
        XCTAssertNil(Policy.referenceStock([approve(Monad.usdc, OneInch.router, usdcIn)]))
        XCTAssertNil(Policy.referenceStock([call(Kuru.entrypoint, swap())]))
        XCTAssertNil(Policy.referenceStock([call(OneInch.router, swap() + Data([0x00]))]))
        XCTAssertNil(Policy.referenceStock([]))

        let reference = XStockReference.Snapshot(stock: stock, answer: 10_000_000_000, decimals: 8, stockDecimals: 18, updatedAt: 1, readAt: 2)
        let sellIntent = Intent.swap(venue: .oneInch, pay: .init(token: stock, amount: stockOut), receive: .init(token: Monad.usdc, amount: usdcIn), usd: 10)
        XCTAssertNil(Policy.oneInchRefusal(call(OneInch.router, swap()), intent: oneInchIntent(), account: account, compiledIn: true, reference: reference), "a buy")
        XCTAssertNil(Policy.oneInchRefusal(call(OneInch.router, sell), intent: sellIntent, account: account, compiledIn: true, reference: reference), "a sell")
        let other = XStockReference.Snapshot(stock: stranger, answer: 10_000_000_000, decimals: 8, stockDecimals: 18, updatedAt: 1, readAt: 2)
        XCTAssertEqual(Policy.oneInchRefusal(call(OneInch.router, swap()), intent: oneInchIntent(), account: account, compiledIn: true, reference: other), .stockPrice)
    }
}
