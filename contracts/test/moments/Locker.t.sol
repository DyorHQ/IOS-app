// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsMarketBase} from "./MomentsMarketBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MomentLocker} from "../../src/moments/MomentLocker.sol";
import {MomentGraduation} from "../../src/moments/MomentGraduation.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";

/// Phase 2 gate: the locker can only ever add liquidity, from its own balances, on the executor's or the
/// buyback's instruction, and nothing it holds can reach an external address.
contract LockerTest is MomentsMarketBase {
    uint256 id;
    MomentCoin coin;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        (id, coin,) = _publishOrdered(creator, PRICE, MAX_ALLOC_BPS, true);
        _completeWithSingles(id, alice);
        key = executor.poolKeyOf(id);
    }

    function test_seed_and_increase_are_role_gated_and_seed_is_once() public {
        vm.prank(gov);
        vm.expectRevert(MomentLocker.NotGraduation.selector);
        locker.seed(id, key);
        vm.prank(address(buyback));
        vm.expectRevert(MomentLocker.NotGraduation.selector);
        locker.seed(id, key);
        vm.prank(address(executor));
        vm.expectRevert(MomentLocker.AlreadySeeded.selector);
        locker.seed(id, key);
        vm.prank(gov);
        vm.expectRevert(MomentLocker.NotBuyback.selector);
        locker.increase(id);
        vm.prank(address(executor));
        vm.expectRevert(MomentLocker.NotBuyback.selector);
        locker.increase(id);
        vm.prank(address(buyback));
        vm.expectRevert(MomentLocker.NotSeeded.selector);
        locker.increase(999);
        vm.expectRevert(MomentLocker.NotPoolManager.selector);
        locker.unlockCallback("");
    }

    function test_increase_only_adds_what_the_locker_holds_and_never_moves_out() public {
        uint128 before = _lockerPositionLiquidity(id, key);
        uint256 pmUsdc = usdc.balanceOf(address(manager));
        uint256 pmCoin = coin.balanceOf(address(manager));
        // nothing to add: no-op
        vm.prank(address(buyback));
        (uint128 added,,) = locker.increase(id);
        assertEq(added, 0);
        assertEq(_lockerPositionLiquidity(id, key), before);
        // donate both assets to the locker, then increase: everything (minus integer dust) goes into the pool
        usdc.mint(address(locker), 1_000_000);
        deal(address(coin), address(locker), coin.balanceOf(address(locker)) + 3e24, true);
        vm.prank(address(buyback));
        (added,,) = locker.increase(id);
        assertGt(added, 0);
        assertEq(_lockerPositionLiquidity(id, key), before + added, "position grew by exactly the added liquidity");
        assertEq(locker.liquidityOf(id), before + added);
        assertGt(usdc.balanceOf(address(manager)), pmUsdc);
        assertGt(coin.balanceOf(address(manager)), pmCoin);
        // the only place tokens went is the PoolManager
        assertEq(usdc.balanceOf(address(buyback)) + usdc.balanceOf(address(executor)) + usdc.balanceOf(gov), 0);
    }

    function test_no_function_can_reduce_the_position() public {
        // Structural: enumerate the locker's external surface and attempt each as every role; liquidity never drops.
        uint128 before = _lockerPositionLiquidity(id, key);
        address[4] memory roles = [gov, creator, address(executor), address(buyback)];
        for (uint256 i = 0; i < roles.length; i++) {
            vm.startPrank(roles[i]);
            try locker.seed(id, key) {} catch {}
            try locker.increase(id) {} catch {}
            try locker.unlockCallback(abi.encode(id, key, uint128(1))) {} catch {}
            vm.stopPrank();
        }
        assertGe(_lockerPositionLiquidity(id, key), before, "liquidity only ever increases");
        assertEq(_poolLiquidity(key), _lockerPositionLiquidity(id, key), "the locker's position is the whole pool");
    }

    function test_locker_holds_only_dust_after_seed() public view {
        MomentGraduation.Record memory r = executor.record(id);
        assertEq(usdc.balanceOf(address(locker)), r.reserve - r.usedUsdc);
        assertLe(usdc.balanceOf(address(locker)), 2);
        assertLe(coin.balanceOf(address(locker)), 1e12);
        (PoolKey memory k, uint128 liq) = locker.positionOf(id);
        assertEq(liq, r.liquidity);
        assertEq(k.tickSpacing, executor.TICK_SPACING());
        assertEq(k.fee, 0, "zero LP fee: the hook charges the Moments fee instead");
    }
}
