import BigInt
import Foundation

/* 1inch's router takes calldata the 1inch API writes, not the app. So nothing about a router call is trusted until it is
   read in full: the one shape accepted is AggregationRouterV6's generic
   `swap(executor, (srcToken, dstToken, srcReceiver, dstReceiver, amount, minReturnAmount, flags), data)`, in its one
   canonical ABI encoding, with nothing after it. Any other selector (unoswap, clipper, an order fill), a stray offset, a
   dirty word, a trailing byte or an oversized payload is not a swap the app can read, and is refused.

   The executor and its data are 1inch's route and are not read: what bounds the trade is the router's own accounting,
   which pulls exactly `amount` of `srcToken` from the caller and reverts unless `dstReceiver` gets at least
   `minReturnAmount` of `dstToken` (UNVERIFIED, research R3: confirm on the deployed router). `srcReceiver` is where the
   router sends the input for the executor to work with, also 1inch's to choose. */

/// A 1inch generic swap, decoded strictly (`init?(calldata:)`), with the checks every signer applies to it.
public struct OneInchSwap: Sendable, Equatable {
    /// `swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)`. UNVERIFIED (research R3): the
    /// selector is computed locally and matches the public AggregationRouterV6 ABI.
    // not localized: a Solidity signature
    public static let signature = "swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)"
    public static let selector = Data([0x07, 0xed, 0x23, 0x79])
    /// The ABI types after the selector.
    // not localized: ABI types
    static let argumentTypes = "address,(address,address,address,address,uint256,uint256,uint256),bytes"
    /// The largest calldata read: a route the app would sign is a few KiB at most.
    public static let maxCalldataBytes = 24 * 1024
    /// The address 1inch's API uses for the chain's native coin. The app never swaps native MON through 1inch.
    public static let nativeMarker = Address(literal: "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE")

    public let executor: Address
    public let srcToken: Address
    public let dstToken: Address
    public let srcReceiver: Address
    public let dstReceiver: Address
    public let amount: BigUInt
    public let minReturn: BigUInt
    public let flags: BigUInt
    /// The executor's route, never read.
    public let executorData: Data

    /// `calldata` read as a generic swap, or nil unless it is exactly one in canonical form: the selector, at most
    /// `maxCalldataBytes`, the strict encoding with no suffix, two real ERC-20s (neither the zero address nor 1inch's
    /// native marker) that differ, and a non-zero amount and minimum.
    public init?(calldata: Data) {
        let data = Data(calldata)
        guard data.count <= Self.maxCalldataBytes, data.prefix(4) == Self.selector,
              let args = ABI.strictDecode(data.dropFirst(4), Self.argumentTypes) else { return nil }
        let desc = args[1].elements
        guard desc.count == 7 else { return nil }
        executor = args[0].address
        srcToken = desc[0].address
        dstToken = desc[1].address
        srcReceiver = desc[2].address
        dstReceiver = desc[3].address
        amount = desc[4].uint
        minReturn = desc[5].uint
        flags = desc[6].uint
        executorData = args[2].bytes
        let markers: Set<Address> = [.zero, Self.nativeMarker]
        guard !markers.contains(srcToken), !markers.contains(dstToken), srcToken != dstToken, amount > 0, minReturn > 0 else { return nil }
    }

    /// What makes a decoded swap one the app never signs, whoever asks.
    public enum Problem: Sendable, Equatable {
        /// The output goes to an address other than the account signing.
        case recipient
        /// Flags are set (partial fill, a permit, unwrapping…): the app sends none.
        case flags
        /// The call carries MON: the app swaps ERC-20s only.
        case value
    }

    /// The first reason this swap, sent with `value` from `account`, must not be signed; nil when it is one the app
    /// could send. The output must go to `account` itself: 1inch's "zero means the caller" is refused too.
    public func problem(account: Address, value: BigUInt) -> Problem? {
        if dstReceiver != account { return .recipient }
        if flags != 0 { return .flags }
        if value != 0 { return .value }
        return nil
    }

    /// Whether this swap trades exactly what `expected` says, for `account`: the same tokens, exactly the amount in, a
    /// minimum no lower than the floor, and no `problem`.
    public func matches(_ expected: TransactionStep.ExpectedSwap, account: Address, value: BigUInt) -> Bool {
        problem(account: account, value: value) == nil && srcToken == expected.tokenIn && dstToken == expected.tokenOut
            && amount == expected.amountIn && minReturn >= expected.minReturnFloor
    }

    /// The calldata for these values, canonical by construction: for tests and fixtures; the app never builds a 1inch
    /// call itself.
    static func calldata(executor: Address, srcToken: Address, dstToken: Address, srcReceiver: Address, dstReceiver: Address,
                         amount: BigUInt, minReturn: BigUInt, flags: BigUInt = 0, executorData: Data = Data()) throws -> Data {
        try ABI.encodeCall(signature, [
            .address(executor),
            .tuple([.address(srcToken), .address(dstToken), .address(srcReceiver), .address(dstReceiver), .uint(amount), .uint(minReturn), .uint(flags)]),
            .bytes(executorData),
        ])
    }
}
