// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MomentsForkBase} from "./MomentsForkBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MomentTypes} from "../../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../../src/moments/MomentsFactory.sol";
import {MomentVesting} from "../../../src/moments/MomentVesting.sol";
import {MomentCollect} from "../../../src/moments/MomentCollect.sol";
import {MomentGraduation} from "../../../src/moments/MomentGraduation.sol";
import {MomentBuyback} from "../../../src/moments/MomentBuyback.sol";
import {MomentFeeHook} from "../../../src/moments/MomentFeeHook.sol";
import {MomentLocker} from "../../../src/moments/MomentLocker.sol";
import {MomentCoin} from "../../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../../src/moments/MomentNFT.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";

/// The 2026-09-23 cohort-3 relaunch with the rotated wallets (platform = new fees wallet 0x15ED…, treasury =
/// 0x5aDb…): the stack recorded in deployments/moments-143.json is checked field by field, run through a full
/// $2,000-FDV lifecycle (publish → collect → atomic graduation → trade → payouts) and an expiry, and every payout
/// is checked to land on the NEW wallets — never on the leaked treasury 0x5282… or the old platform 0xf4D4…. The
/// cohort-1 and cohort-2 factories must be paused.
///
///   Rehearsal (anvil fork after the relaunch script ran against it):
///     RELAUNCH_RPC=http://127.0.0.1:8545 forge test --code-size-limit 100000000 --match-path test/moments/fork/Relaunch.t.sol -vv
///   After the real mainnet run (read-only fork of mainnet):
///     forge test --code-size-limit 100000000 --match-path test/moments/fork/Relaunch.t.sol -vv
contract RelaunchTest is MomentsForkBase {
    using PoolIdLibrary for PoolKey;

    address constant GOVERNANCE = 0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10;
    address constant NEW_PLATFORM = 0x15ED3bb488231213b141A2f78b62358D52235Cd7;
    address constant NEW_TREASURY = 0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371;
    address constant LEAKED_TREASURY = 0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045;
    address constant OLD_PLATFORM = 0xf4D4baF60e5fcAF6A092b2d6B5509af9f01Cfb48;
    address constant COHORT1_FACTORY = 0x64698c7702d85F87f43a6dFF7D495CDD2327C020;
    address constant COHORT2_FACTORY = 0xc12B6b6948185cef75F861c5327702c30CB8a581;
    uint256 constant COHORT3_THRESHOLD = 771_428_571; // $2,000 FDV at the default 10% creator allocation
    uint256 constant COLLECT_PRICE = 100_000_000; // $100 per edition: 11 collects reach the threshold

    string json;

    function setUp() public override {
        vm.createSelectFork(vm.envOr("RELAUNCH_RPC", string("monad")));
        json = vm.readFile("deployments/moments-143.json");
        factory = MomentsFactory(vm.parseJsonAddress(json, ".factory"));
        collect = MomentCollect(vm.parseJsonAddress(json, ".collect"));
        vesting = MomentVesting(vm.parseJsonAddress(json, ".vesting"));
        executor = MomentGraduation(vm.parseJsonAddress(json, ".graduation"));
        locker = MomentLocker(vm.parseJsonAddress(json, ".locker"));
        hook = MomentFeeHook(vm.parseJsonAddress(json, ".hook"));
        buyback = MomentBuyback(vm.parseJsonAddress(json, ".buyback"));
        manager = IPoolManager(PM_ADDR);
        usdc = MockUSDC(USDC_ADDR);
        permit2 = MockPermit2(PERMIT2_ADDR);
        swapRouter = new PoolSwapTest(manager);
        address[5] memory users = [alice, bob, carol, dave, creator];
        for (uint256 i = 0; i < users.length; i++) {
            deal(USDC_ADDR, users[i], 1_000_000_000_000);
            vm.startPrank(users[i]);
            usdc.approve(address(collect), type(uint256).max);
            usdc.approve(PERMIT2_ADDR, type(uint256).max);
            usdc.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_record_names_the_cohort3_stack() public view {
        assertTrue(address(factory) != COHORT1_FACTORY && address(factory) != COHORT2_FACTORY, "moments-143.json still names a retired factory");
        assertGt(address(factory).code.length, 0);
        assertEq(vm.parseJsonUint(json, ".chainId"), 143);
        assertEq(vm.parseJsonAddress(json, ".governance"), GOVERNANCE);
        assertEq(vm.parseJsonAddress(json, ".platform"), NEW_PLATFORM);
        assertEq(vm.parseJsonAddress(json, ".treasury"), NEW_TREASURY);
        assertEq(vm.parseJsonUint(json, ".thresholdUsdc"), COHORT3_THRESHOLD);
    }

    function test_wiring_and_policy() public view {
        assertEq(factory.governance(), GOVERNANCE, "owner governs");
        assertEq(factory.pendingGovernance(), address(0));
        assertTrue(factory.modulesSet());
        assertEq(factory.collect(), address(collect));
        assertEq(factory.vesting(), address(vesting));
        assertEq(factory.graduation(), address(executor));
        assertEq(factory.locker(), address(locker));
        assertEq(factory.feeHook(), address(hook));
        assertEq(factory.buyback(), address(buyback));
        assertFalse(factory.publishingPaused(), "cohort 3 is open");
        assertEq(factory.pendingPolicyAt(), 0);
        assertEq(factory.externalBaseURI(), "https://dyorhq.fun/moments/");
        (uint256 threshold, uint256 minPrice, uint16 cBps, uint16 pBps, uint16 rBps, uint16 maxAlloc, uint16 expBps, uint16 royBps, address plat, address treas) = factory.policy();
        assertEq(threshold, COHORT3_THRESHOLD);
        assertEq(minPrice, 100_000);
        assertEq(cBps, 2_000);
        assertEq(pBps, 500);
        assertEq(rBps, 7_500);
        assertEq(maxAlloc, 1_000);
        assertEq(expBps, 7_000);
        assertEq(royBps, 500);
        assertEq(plat, NEW_PLATFORM, "platform = the new fees wallet");
        assertEq(treas, NEW_TREASURY, "treasury = the new treasury");
        assertEq(address(collect.USDC()), USDC_ADDR);
        assertEq(address(collect.PERMIT2()), PERMIT2_ADDR);
        assertEq(address(collect.factory()), address(factory));
        assertEq(address(collect.vesting()), address(vesting));
        assertEq(address(vesting.factory()), address(factory));
        assertEq(address(executor.factory()), address(factory));
        assertEq(address(executor.poolManager()), PM_ADDR);
        assertEq(address(executor.USDC()), USDC_ADDR);
        assertEq(executor.LP_FEE(), 5_000);
        assertEq(address(locker.factory()), address(factory));
        assertEq(address(hook.factory()), address(factory));
        assertEq(Currency.unwrap(hook.usdc()), USDC_ADDR);
        assertEq(uint160(address(hook)) & 0x3FFF, uint160(0x20CC), "hook permission bits");
        assertEq(address(buyback.factory()), address(factory));
    }

    function test_previous_cohorts_are_paused() public view {
        assertTrue(MomentsFactory(COHORT1_FACTORY).publishingPaused(), "cohort 1 paused");
        assertTrue(MomentsFactory(COHORT2_FACTORY).publishingPaused(), "cohort 2 paused");
    }

    function test_lifecycle_pays_the_new_wallets() public {
        uint256 leaked0 = usdc.balanceOf(LEAKED_TREASURY);
        uint256 oldPlat0 = usdc.balanceOf(OLD_PLATFORM);
        (uint256 id, MomentCoin coin, MomentNFT nft) = _publish(creator, COLLECT_PRICE, MAX_ALLOC_BPS, 3001);
        bool usdcIs0 = address(usdc) < address(coin);
        uint256 collects;
        while (_state(id) == MomentTypes.State.Collecting) {
            _collect(id, alice, 1);
            collects++;
        }
        assertEq(collects, 11, "10 full editions + the terminal remainder");
        assertEq(uint8(_state(id)), uint8(MomentTypes.State.Graduated), "graduated atomically");
        MomentGraduation.Record memory r = executor.record(id);
        assertEq(r.reserve, COHORT3_THRESHOLD, "graduates at exactly the $2,000-FDV reserve");
        assertEq(address(r.key.hooks), address(hook));
        assertEq(_lockerPositionLiquidity(id, r.key), r.liquidity, "the new locker owns the position");
        assertTrue(nft.closed());
        _assertSupply(id);

        _buyExactIn(bob, r.key, usdcIs0, 100_000_000);
        assertGt(hook.platformAccrued(id), 0);

        uint256 p0 = usdc.balanceOf(NEW_PLATFORM);
        uint256 platformClaimable = collect.ledger(id).platformClaimable;
        assertGt(platformClaimable, 0);
        vm.startPrank(NEW_PLATFORM);
        collect.withdrawPlatform(id);
        hook.withdrawPlatform(id);
        vm.stopPrank();
        assertGt(usdc.balanceOf(NEW_PLATFORM) - p0, platformClaimable, "the new platform wallet received collect + hook shares");

        // an expired Moment: 30% of its reserve belongs to the NEW treasury
        (uint256 id2,, MomentNFT nft2) = _publish(creator, 1_000_000, 0, 3002);
        _collect(id2, carol, 2);
        vm.warp(factory.getMoment(id2).deadline);
        collect.expire(id2);
        assertTrue(nft2.closed());
        uint256 owed = collect.ledger(id2).treasuryClaimable;
        assertEq(owed, 1_500_000 * 3_000 / 10_000);
        uint256 t0 = usdc.balanceOf(NEW_TREASURY);
        vm.prank(NEW_TREASURY);
        collect.withdrawTreasury(id2);
        assertEq(usdc.balanceOf(NEW_TREASURY) - t0, owed, "the new treasury received 30% of the expired reserve");

        assertEq(usdc.balanceOf(LEAKED_TREASURY), leaked0, "nothing to the leaked treasury");
        assertEq(usdc.balanceOf(OLD_PLATFORM), oldPlat0, "nothing to the old platform wallet");
        _assertSupply(id2);
    }

    function test_withdrawals_are_pull_only_to_the_policy_wallets() public {
        (uint256 id2,,) = _publish(creator, 1_000_000, 0, 3003);
        _collect(id2, carol, 2);
        vm.warp(factory.getMoment(id2).deadline);
        collect.expire(id2);
        vm.prank(LEAKED_TREASURY);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawTreasury(id2);
        vm.prank(OLD_PLATFORM);
        vm.expectRevert(MomentCollect.NotBeneficiary.selector);
        collect.withdrawPlatform(id2);
    }
}
