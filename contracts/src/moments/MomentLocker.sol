// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IMomentsFactory} from "./interfaces/IMoments.sol";
import {IMomentLocker} from "./interfaces/IMomentsMarket.sol";
import {MomentPoolMath} from "./libraries/MomentPoolMath.sol";

/// @notice Owns every Moment's full-range coin/USDC position, forever. The only liquidity operation this
///         contract can perform is an INCREASE funded from its own balances: `seed` (graduation executor, once)
///         and `increase` (buyback module). There is no function that removes liquidity, no `take` to any address
///         but itself, no token transfer except paying the PoolManager what a position add costs, and no owner.
contract MomentLocker is IMomentLocker, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IMomentsFactory public immutable factory;

    struct Position {
        PoolKey key;
        uint128 liquidity;
        bool exists;
    }

    mapping(uint256 => Position) private _positions;

    event Seeded(uint256 indexed momentId, PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Increased(uint256 indexed momentId, PoolId indexed poolId, uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    error NotGraduation();
    error NotBuyback();
    error NotPoolManager();
    error AlreadySeeded();
    error NotSeeded();
    error NoLiquidity();

    constructor(IPoolManager _poolManager, IMomentsFactory _factory) {
        poolManager = _poolManager;
        factory = _factory;
    }

    /// @notice Mints the initial full-range position from the reserve USDC + pool coins the executor placed here.
    function seed(uint256 momentId, PoolKey calldata key) external returns (uint128 liquidity, uint256 used0, uint256 used1) {
        if (msg.sender != factory.graduation()) revert NotGraduation();
        if (_positions[momentId].exists) revert AlreadySeeded();
        _positions[momentId] = Position({key: key, liquidity: 0, exists: true});
        (liquidity, used0, used1) = _add(momentId, key);
        if (liquidity == 0) revert NoLiquidity();
        emit Seeded(momentId, key.toId(), liquidity, used0, used1);
    }

    /// @notice Adds whatever coin + USDC this contract currently holds for the Moment to its position (buyback-LP).
    function increase(uint256 momentId) external returns (uint128 liquidityAdded, uint256 used0, uint256 used1) {
        if (msg.sender != factory.buyback()) revert NotBuyback();
        Position storage p = _positions[momentId];
        if (!p.exists) revert NotSeeded();
        PoolKey memory key = p.key;
        (liquidityAdded, used0, used1) = _add(momentId, key);
        emit Increased(momentId, key.toId(), liquidityAdded, used0, used1);
    }

    function _add(uint256 momentId, PoolKey memory key) private returns (uint128 liquidity, uint256 used0, uint256 used1) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing));
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing));
        liquidity = MomentPoolMath.liquidityForAmounts(sqrtP, sqrtA, sqrtB, key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());
        if (liquidity == 0) return (0, 0, 0);
        _positions[momentId].liquidity += liquidity; // effect before the PoolManager interaction
        bytes memory result = poolManager.unlock(abi.encode(momentId, key, liquidity));
        (used0, used1) = abi.decode(result, (uint256, uint256));
    }

    /// @dev Only ever adds liquidity. A positive delta (LP fees, if a pool ever had a non-zero LP fee) is taken
    ///      back into this contract — never to an external address — and re-locked on the next increase.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 momentId, PoolKey memory key, uint128 liquidity) = abi.decode(data, (uint256, PoolKey, uint128));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(momentId)
            }),
            ""
        );
        uint256 used0 = _settle(key.currency0, delta.amount0());
        uint256 used1 = _settle(key.currency1, delta.amount1());
        return abi.encode(used0, used1);
    }

    function _settle(Currency currency, int128 amount) private returns (uint256 paid) {
        if (amount < 0) {
            paid = uint256(uint128(-amount));
            poolManager.sync(currency);
            currency.transfer(address(poolManager), paid);
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    // ------------------------------------------------------------------ views

    function positionOf(uint256 momentId) external view returns (PoolKey memory key, uint128 liquidity) {
        Position storage p = _positions[momentId];
        return (p.key, p.liquidity);
    }

    function liquidityOf(uint256 momentId) external view returns (uint128) {
        return _positions[momentId].liquidity;
    }

    function tickRange(int24 tickSpacing) external pure returns (int24 tickLower, int24 tickUpper) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }
}
