import BigInt
import Foundation

/* The last structural check before any wallet signs, whichever signer it is (Privy, an imported key, an email wallet, a
   passkey): `TransactionSender.prepare` asks it first, on every chain, before the transaction is simulated. It sees one
   request and the account sending it, nothing else, so it checks shape only; what a particular swap must trade is bound
   at run time (`TransactionStep.expectedSwap`) and by the passkey policy.

   It is about 1inch's contracts, whose calldata a third-party API writes. Refused:
     - any call to Aqua or SwapVMRouter, and any ERC-20 or Permit2 approval naming either;
     - an ERC-20 approval (`approve`, `increaseAllowance`) of the router for an effectively unlimited amount;
     - a Permit2 approval naming the router (the app approves the router directly, for the exact amount);
     - any call to the router unless 1inch is compiled into this build (`OneInch.compiledIn`) and the call is, on
       Monad, a generic swap that decodes strictly (`OneInchSwap`), pays its output to the sending account, sets no
       flags and carries no MON.
   Every other request passes untouched: the guard never looks further than this list. */
public enum ThirdPartyCalldataGuard {
    /// Why a request was refused.
    public enum Refusal: Sendable, Equatable {
        /// A call to, or an approval naming, Aqua or SwapVMRouter.
        case refusedContract
        /// An effectively unlimited ERC-20 approval of the 1inch router.
        case unlimitedRouterApproval
        /// A Permit2 approval naming the 1inch router.
        case permit2Router
        /// A call to the 1inch router this build can't send: 1inch is off, or the call isn't a swap it reads in full.
        case routerCall

        /// The sentence the sheet shows, in the app's language.
        public var message: String {
            switch self {
            case .refusedContract:
                return L10n.tr("DyorHQ doesn't sign transactions for this 1inch contract, so nothing was sent.")
            case .unlimitedRouterApproval:
                return L10n.tr("DyorHQ only approves the 1inch router for the exact amount of a swap, so nothing was sent.")
            case .permit2Router:
                return L10n.tr("DyorHQ doesn't sign Permit2 approvals for the 1inch router, so nothing was sent.")
            case .routerCall:
                return L10n.tr("DyorHQ couldn't verify this 1inch swap, so nothing was sent.")
            }
        }
    }

    enum Selector {
        static let approve = ABI.selector("approve(address,uint256)")
        static let increaseAllowance = ABI.selector("increaseAllowance(address,uint256)")
        static let permit2Approve = ABI.selector("approve(address,address,uint160,uint48)")
    }

    /// Why `request`, sent from `account` on `chainId`, must not be signed; nil for every request the guard doesn't
    /// cover and for a router swap it reads in full. `compiledIn` is for tests; the app passes `OneInch.compiledIn`.
    public static func refusal(_ request: TransactionRequest, account: Address, chainId: Int,
                               compiledIn: Bool = OneInch.compiledIn) -> Refusal? {
        if OneInch.refusedContracts.contains(request.to) { return .refusedContract }
        if request.to == OneInch.router {
            guard compiledIn, chainId == Monad.chainId, let swap = OneInchSwap(calldata: request.data),
                  swap.problem(account: account, value: request.value) == nil else { return .routerCall }
            return nil
        }
        let data = Data(request.data)
        guard data.count >= 4 else { return nil }
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        if selector == Selector.approve || selector == Selector.increaseAllowance, let spender = spender(args.word(0)) {
            if OneInch.refusedContracts.contains(spender) { return .refusedContract }
            // A missing amount word is read as unlimited: the guard never guesses in a request's favour.
            if spender == OneInch.router, (args.uint(1) ?? TransactionSender.unlimitedAllowance) >= TransactionSender.unlimitedAllowance {
                return .unlimitedRouterApproval
            }
        }
        if selector == Selector.permit2Approve, let spender = spender(args.word(1)) {
            if OneInch.refusedContracts.contains(spender) { return .refusedContract }
            if spender == OneInch.router { return .permit2Router }
        }
        return nil
    }

    /// The address a contract would read from a spender word: its low 20 bytes, whatever the 12 above them hold (an
    /// older token truncates a dirty word instead of reverting, so a dirty word still names that spender).
    private static func spender(_ word: Data?) -> Address? {
        word.flatMap { Address(data: Data($0.suffix(20))) }
    }
}
