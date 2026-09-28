import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// Moments v2 against a real v2 deployment on a LOCAL anvil fork of Monad, through the plans DyorKit builds and
/// `TransactionSender` — the path the app takes. Skipped unless both are set:
///
///   DYOR_V2_FORK_RPC      a local RPC (127.0.0.1 / localhost) of chain 143, e.g. `anvil --fork-url https://rpc3.monad.xyz
///                         --no-rate-limit --auto-impersonate --disable-code-size-limit --port 8651`
///   DYOR_V2_FORK_RECORDS  a folder with the fork deploy's `pending-moments-143.json`, deployed with
///                         EXTERNAL_BASE_URI=https://dyorhq.fun/moments/c4/ and a GUARDIAN (`forge script
///                         script/moments/Deploy.s.sol --broadcast` against the fork writes it; add `deployBlock`, the
///                         factory's creation block, by hand, as for mainnet. deploy-v2.sh FORK=1 deletes its records on
///                         exit, so copy them out first)
///
///   DYOR_V2_FORK_RPC=http://127.0.0.1:8651 DYOR_V2_FORK_RECORDS=<folder> swift test --filter V2ForkTests
///
/// The wallet is a fresh in-memory key funded with anvil cheats; governance and the guardian are impersonated on the fork
/// only. Nothing here can reach a public RPC.
final class V2ForkTests: XCTestCase {
    struct Fork {
        let rpc: RPCClient
        let moments: MomentsAddresses
        let governance: Address
        let guardian: Address
        var service: MomentsService { MomentsService(rpc: rpc, addresses: moments) }
        var sender: TransactionSender { TransactionSender(rpc: rpc) }
    }

    /// Kuru's MarginAccount, a large USDC holder on Monad: impersonated on the fork only, to fund the test wallet.
    static let usdcHolder = Address(literal: "0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5")

    private func fork() async throws -> Fork {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["DYOR_V2_FORK_RPC"], let url = URL(string: text), let folder = env["DYOR_V2_FORK_RECORDS"] else {
            throw XCTSkip("set DYOR_V2_FORK_RPC (a local fork of Monad) and DYOR_V2_FORK_RECORDS (its v2 deploy records)")
        }
        let rpc = RPCClient(url: url)
        guard rpc.isLocal else { throw XCTSkip("DYOR_V2_FORK_RPC must be a local fork (127.0.0.1 or localhost), never a public RPC") }
        let chain = try await rpc.call("eth_chainId")
        XCTAssertEqual(chain.string.flatMap { BigUInt(hexQuantity: $0) }, 143, "a fork of Monad mainnet")
        let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("pending-moments-143.json"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func address(_ key: String) throws -> Address { try XCTUnwrap((record[key] as? String).flatMap(Address.init), key) }
        let moments = MomentsAddresses(
            factory: try address("factory"), collect: try address("collect"), vesting: try address("vesting"), graduation: try address("graduation"),
            locker: try address("locker"), hook: try address("hook"), buyback: try address("buyback"), usdc: try address("usdc"), permit2: try address("permit2"),
            poolManager: try address("poolManager"), platform: try address("platform"), treasury: try address("treasury"),
            deployBlock: try XCTUnwrap((record["deployBlock"] as? NSNumber)?.uint64Value, "deployBlock"), generation: .v2
        )
        return Fork(rpc: rpc, moments: moments, governance: try address("governance"), guardian: try address("guardian"))
    }

    /// A fresh in-memory key, funded with fork MON; it counts what it signs.
    final class ForkWallet: Wallet, @unchecked Sendable {
        let account: Secp256k1Account
        private let lock = NSLock()
        private var signed = 0
        var address: Address { account.address }
        var signatures: Int { lock.lock(); defer { lock.unlock() }; return signed }

        init() {
            var key: Secp256k1Account?
            while key == nil { key = Secp256k1Account(privateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
            account = key!
        }

        func sign(_ transaction: PreparedTransaction) async throws -> Data {
            lock.lock(); signed += 1; lock.unlock()
            return try account.sign(transaction)
        }

        func signMessage(_ message: Data) async throws -> Data { try account.signMessage(message) }
    }

    private func wallet(_ fork: Fork, usdc: BigUInt = 0) async throws -> ForkWallet {
        let wallet = ForkWallet()
        _ = try await fork.rpc.call("anvil_setBalance", [.string(wallet.address.hex), .string("0x3635c9adc5dea00000")]) // 1,000 fork MON
        if usdc > 0 {
            _ = try await fork.rpc.call("anvil_setBalance", [.string(Self.usdcHolder.hex), .string("0x3635c9adc5dea00000")])
            try await sendAs(fork, Self.usdcHolder, to: fork.moments.usdc, data: try ABI.encodeCall("transfer(address,uint256)", [.address(wallet.address), .uint(usdc)]))
        }
        return wallet
    }

    /// Fork only: a transaction from an impersonated account (governance, the guardian, a USDC holder, anyone).
    private func sendAs(_ fork: Fork, _ from: Address, to: Address, data: Data) async throws {
        _ = try await fork.rpc.call("anvil_setBalance", [.string(from.hex), .string("0x3635c9adc5dea00000")])
        _ = try await fork.rpc.call("anvil_impersonateAccount", [.string(from.hex)])
        let hash = try await fork.rpc.call("eth_sendTransaction", [.object(["from": .string(from.hex), "to": .string(to.hex), "data": .string(data.hexString)])])
        let receipt = try await fork.rpc.waitForReceipt(try XCTUnwrap(hash.string.flatMap { Data(hex: $0) }))
        _ = try await fork.rpc.call("anvil_stopImpersonatingAccount", [.string(from.hex)])
        XCTAssertTrue(receipt.success, "impersonated call to \(to.short)")
    }

    private func input(_ name: String, price: BigUInt = 1_000_000) -> MomentPublishInput {
        MomentPublishInput(name: name, symbol: "FORK", mediaURI: "ipfs://bafyfork", mediaHash: Data(repeating: 0x42, count: 32), place: "Accra",
                           date: 1_790_000_000, price: price, creatorAllocBps: 1_000, collectWindow: 86_400)
    }

    private func run(_ fork: Fork, _ steps: [TransactionStep], _ wallet: ForkWallet) async throws -> Data {
        try await fork.sender.run(steps, from: wallet, onEvent: { _ in })
    }

    /// The sentence `TransactionSender.prepare` refuses a step with (its simulation reverted), or nil when it would send.
    private func refusal(_ fork: Fork, _ steps: [TransactionStep], _ wallet: ForkWallet) async -> String? {
        do {
            _ = try await run(fork, steps, wallet)
            return nil
        } catch TransactionError.rejected(let why) {
            return why
        } catch {
            return "\(error)"
        }
    }

    private func policy(_ fork: Fork) async throws -> MomentPolicy {
        let read = try await fork.service.policy()
        return try XCTUnwrap(read)
    }

    // MARK: Reads

    /// The v2 getters on a real deploy: the terms hash the app computes is the factory's, the guardian is named, and the
    /// constants the app assumes hold.
    func testV2TermsAndConstantsOnARealDeploy() async throws {
        let fork = try await fork()
        let policy = try await policy(fork)
        XCTAssertEqual(policy.externalBaseURI, MomentsAddresses.expectedExternalBaseURI)
        XCTAssertEqual(policy.termsHash, policy.localTermsHash, "the app's keccak256(abi.encode(policy, base)) is the factory's termsHash()")
        XCTAssertEqual(policy.guardian, fork.guardian)
        if !policy.publishingPaused, !policy.guardianPaused { XCTAssertTrue(policy.canPublish, "\(String(describing: policy.publishBlock))") }
        let constants = try await Multicall(rpc: fork.rpc).readAll([
            MomentsABI.call(fork.moments.factory, MomentsABI.Factory.policyApplyWindow, returns: "uint256"),
            MomentsABI.call(fork.moments.locker, MomentsABI.Locker.maxIncreaseBps, returns: "uint256"),
            MomentsABI.call(fork.moments.buyback, MomentsABI.Buyback.maxOpenDeviationBps, returns: "uint256"),
        ])
        XCTAssertEqual(Int(constants[0][0].uint), MomentsConstants.policyApplyWindowSeconds)
        XCTAssertEqual(constants[1][0].uint, 50)
        XCTAssertEqual(constants[2][0].uint, 200)
    }

    // MARK: Publish, collect, links

    /// A publish built from the reviewed terms lands; the Moment's link is the c4 base its NFT keeps, and stays so after
    /// governance points the factory elsewhere (which turns Publish off for new Moments). A collect goes through the
    /// exact-approval plan.
    func testPublishCollectAndTheLinkBaseTheNFTKeeps() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork, usdc: 5_000_000)
        let reviewed = try await policy(fork)
        XCTAssertTrue(reviewed.canPublish)
        let publish = try await fork.service.publishPlan(input("Fork sunrise"), termsHash: reviewed.termsHash)
        let hash = try await run(fork, publish, wallet)
        let resultRead = try await fork.service.publishResult(transaction: hash)
        let result = try XCTUnwrap(resultRead)
        XCTAssertEqual(result.creator, wallet.address)
        let detailRead = try await fork.service.moment(id: result.momentId)
        let detail = try XCTUnwrap(detailRead)
        XCTAssertEqual(detail.externalURL, "https://dyorhq.fun/moments/c4/\(result.momentId)")
        XCTAssertEqual(detail.info.moment.platform, reviewed.platform)
        XCTAssertEqual(detail.info.moment.royaltyBps, reviewed.royaltyBps)

        // Collect one edition through the plain-approval plan.
        let collect = await fork.service.collectWithApprovalPlan(momentId: result.momentId, quantity: 1, gross: 1_000_000, symbol: "FORK")
        _ = try await run(fork, collect, wallet)
        let account = try await fork.service.accountView(detail.info, account: wallet.address)
        XCTAssertEqual(account.nftBalance, 1)

        // Governance moves the factory's base: the existing Moment keeps its link, and new publishes are refused here.
        let setBase = "setExternalBaseURI(string)"
        try await sendAs(fork, fork.governance, to: fork.moments.factory, data: try ABI.encodeCall(setBase, [.string("https://dyorhq.fun/moments/elsewhere/")]))
        let movedRead = try await fork.service.moment(id: result.momentId)
        XCTAssertEqual(movedRead?.externalURL, "https://dyorhq.fun/moments/c4/\(result.momentId)")
        let moved = try await policy(fork)
        XCTAssertEqual(moved.publishBlock, .unexpectedLinkBase)
        XCTAssertNotEqual(moved.termsHash, reviewed.termsHash, "the base is part of the terms")
        try await sendAs(fork, fork.governance, to: fork.moments.factory, data: try ABI.encodeCall(setBase, [.string(MomentsAddresses.expectedExternalBaseURI)]))
        let restored = try await policy(fork)
        XCTAssertTrue(restored.canPublish)
    }

    // MARK: Refusals, decoded before anything is signed

    /// MO-4: a proposal applied between the review and the publish. The publish carries the reviewed hash, so the
    /// factory refuses it (`TermsChanged`), `prepare` says so, and the wallet never signs.
    func testTermsChangedBetweenReviewAndPublishIsRefusedUnsigned() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        let reviewed = try await policy(fork)
        XCTAssertTrue(reviewed.canPublish)
        let next: ABIValue = .tuple([.uint(reviewed.threshold), .uint(reviewed.minPrice), .uint(reviewed.creatorBps), .uint(reviewed.platformBps), .uint(reviewed.reserveBps),
                                     .uint(reviewed.maxCreatorAllocBps), .uint(reviewed.expiryCreatorBps), .uint(reviewed.royaltyBps == 750 ? 500 : 750),
                                     .address(reviewed.platform), .address(reviewed.treasury)])
        try await sendAs(fork, fork.governance, to: fork.moments.factory, data: try ABI.encodeCall("proposePolicy((\(MomentsABI.policyFlat)))", [next]))
        let queued = try await policy(fork)
        let pending = try XCTUnwrap(queued.pending)
        XCTAssertEqual(pending.changes(from: queued), [.royalty])
        XCTAssertEqual(pending.lapsesAt, pending.applicableAt.addingTimeInterval(TimeInterval(MomentsConstants.policyApplyWindowSeconds)))
        _ = try await fork.rpc.call("evm_increaseTime", [.number(Double(48 * 3600 + 1))])
        _ = try await fork.rpc.call("evm_mine")
        try await sendAs(fork, wallet.address, to: fork.moments.factory, data: try ABI.encodeCall("applyPolicy()")) // anyone may apply it

        let publish = try await fork.service.publishPlan(input("Fork terms"), termsHash: reviewed.termsHash)
        let why = await refusal(fork, publish, wallet)
        XCTAssertEqual(why, "The Moments terms changed after you reviewed them, so nothing was published. Review them again.")
        XCTAssertEqual(wallet.signatures, 0, "nothing was signed")
        let now = try await policy(fork)
        XCTAssertNotEqual(now.termsHash, reviewed.termsHash)
        XCTAssertTrue(now.canPublish, "the new terms can be reviewed and published")
    }

    /// The guardian's pause stops publishing like governance's: the app reads it (Publish off), and a publish is refused
    /// with the paused sentence before anything is signed.
    func testGuardianPauseRefusesPublishing() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        let pause = "setGuardianPaused(bool)"
        try await sendAs(fork, fork.guardian, to: fork.moments.factory, data: try ABI.encodeCall(pause, [.bool(true)]))
        let paused = try await policy(fork)
        XCTAssertTrue(paused.guardianPaused)
        XCTAssertEqual(paused.publishBlock, .guardianPaused)
        let publish = try await fork.service.publishPlan(input("Fork paused"), termsHash: paused.termsHash)
        let why = await refusal(fork, publish, wallet)
        XCTAssertEqual(why, "Publishing is paused right now, so nothing was published.")
        XCTAssertEqual(wallet.signatures, 0)
        try await sendAs(fork, fork.guardian, to: fork.moments.factory, data: try ABI.encodeCall(pause, [.bool(false)]))
        let open = try await policy(fork)
        XCTAssertFalse(open.guardianPaused)
    }

    /// A price above the gross that completes the reserve is refused by v2 (`PriceTooHigh`) with its sentence.
    func testAPriceAboveTheCeilingIsRefused() async throws {
        let fork = try await fork()
        let wallet = try await wallet(fork)
        let terms = try await policy(fork)
        let ceiling = try XCTUnwrap(MomentsMath.maxCollectPrice(threshold: terms.threshold, reserveBps: terms.reserveBps))
        let publish = try await fork.service.publishPlan(input("Fork pricey", price: ceiling + 1), termsHash: terms.termsHash)
        let why = await refusal(fork, publish, wallet)
        XCTAssertEqual(why, RevertReason.knownErrors[ABI.selector("PriceTooHigh()").hexString])
        XCTAssertEqual(wallet.signatures, 0)
        // At the ceiling itself the publish goes through.
        let atCeiling = try await fork.service.publishPlan(input("Fork ceiling", price: ceiling), termsHash: terms.termsHash)
        _ = try await run(fork, atCeiling, wallet)
        XCTAssertEqual(wallet.signatures, 1)
    }
}
